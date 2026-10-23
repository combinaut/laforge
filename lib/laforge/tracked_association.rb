module LaForge
  # Used to record, forge and inspect one owner's has_many or has_one association declared with
  # `laforged associations:`, described by an AssociationConfig, which also defines how members are named by key. The
  # class methods act on the association across owners.
  #
  # Each source's entry for the association on the owner is its report of the members (see MemberList). Membership is
  # whether a member belongs to the association, decided per member by the highest-precedence report with an opinion on
  # it. A row no report names is left alone.
  #
  # A forge of the owner applies membership. A member it removes goes when the owner is saved, per the association's
  # `dependent:` option. What a report says about a member besides its key waits there as pending until a forge includes
  # the member, and is then recorded on the member as the source's entries, like attributes recorded on the member
  # directly. So nothing is created for a member membership excludes, and a member's attributes are resolved on the
  # member alone. The owner's forge forges the members it records on, and any other member is forged on its own.
  #
  # Withdrawing a source from a member drops the source's entries on the member, and makes each of its reports for the
  # member's own tracked associations withdraw every member it named. A forge withdraws each source whose report
  # excludes or withdrew a member the forge keeps.
  #
  # An instance reads the owner's reports and members when it first needs them, so each operation uses a new one.
  class TrackedAssociation
    class << self
      # Makes the member model laforged if it is not, and autosaves the association so the owner's save writes what a
      # forge changes on its members.
      def declare(owner_class, config)
        config.klass.laforged unless config.klass.respond_to?(:laforged_associations)
        config.reflection.autosave = true
      end

      # Returns { owner id => { source => [member hashes] } } for `records`, each member hash as
      # `with_member_attributes` builds it. A source gives the members its report includes, then the other rows it has
      # entries on. An owner no source has anything on is left out.
      def source_values(owner_class, config, records)
        owner_ids = records.map(&:id)
        entries = DataEntry.where(record_type: owner_class.base_class.name, record_id: owner_ids, attribute_name: config.name).preload(:source).to_a
        rows = member_rows(owner_class, config, owner_ids)
        member_entries = DataEntry.where(record_type: config.klass.base_class.name, record_id: rows.map(&:id)).preload(:source).to_a
                                  .reject { |entry| config.nested_config(entry.attribute_name) }
                                  .group_by(&:record_id)
        rows_by_owner = rows.group_by { |record| record[config.owner_foreign_key] }

        owner_ids.each_with_object({}) do |owner_id, result|
          reports = entries.select { |entry| entry.record_id == owner_id }.to_h { |entry| [entry.source, MemberList.new(entry.value)] }
          values = values_by_source(config, reports, rows_by_owner[owner_id] || [], member_entries)
          result[owner_id] = values if values.any?
        end
      end

      # See `LaForge.tombstone_blocking`.
      def tombstone_blocking(record, source)
        raise ArgumentError, "#{record.class.name} #{record.id} already exists; tombstone_blocking checks a new member before it is created" if record.persisted?

        source_id = DataSource.normalize_source_id(source)
        tracked_associations_of(record).each do |tracked|
          found = tracked.tombstone_blocking(record, source_id)
          return found if found
        end
        nil
      end

      private

      # Returns the members of the owners with `owner_ids`, in the association's scope unless the scope takes the owner,
      # which cannot be applied to several owners at once
      def member_rows(owner_class, config, owner_ids)
        scope = config.klass.where(config.owner_foreign_key => owner_ids)
        scope = scope.where(config.owner_type_column => owner_class.polymorphic_name) if config.owner_type_column
        reflection_scope = config.reflection.scope
        scope = scope.merge(config.klass.unscoped.instance_exec(&reflection_scope)) if reflection_scope&.arity&.zero?
        scope.to_a
      end

      # Returns { source => [member hashes] } for one owner, given its `reports` by source, its member `rows`, and
      # `member_entries` by member id
      def values_by_source(config, reports, rows, member_entries)
        rows = rows.reject { |record| config.blank_key?(config.record_key(record)) }.index_by { |record| config.record_key(record) }
        sources = (reports.keys + rows.values.flat_map { |record| (member_entries[record.id] || []).map(&:source) }).uniq

        sources.to_h do |source|
          listed = listed_members(config, reports[source], rows, member_entries, source)
          [source, listed + unlisted_members(config, listed, rows, member_entries, source)]
        end
      end

      # Returns the member hash of each member `report` includes, or none when the source has no report
      def listed_members(config, report, rows, member_entries, source)
        (report&.include || []).map do |member|
          pending = report.pending.select { |item| config.key_of(item['key']) == config.key_of(member) }.sort_by { |item| item['recorded_at'] }
          with_member_attributes(config, member, rows[config.key_of(member)], member_entries, source, pending)
        end
      end

      # Returns the member hash of each of `rows` that `listed` leaves out and the source has entries on
      def unlisted_members(config, listed, rows, member_entries, source)
        rows.values.reject { |record| listed.any? { |member| config.key_of(member) == config.record_key(record) } }
            .select { |record| (member_entries[record.id] || []).any? { |entry| entry.source == source } }
            .map { |record| with_member_attributes(config, config.key_hash(record), record, member_entries, source, []) }
      end

      # Returns the member's hash as `source` gives it, merging in order:
      # - its key, or nothing for a new member or a tombstone
      # - the source's entries on the member
      # - the source's pending items for it, each without the attributes the member has a newer entry for from the
      #   source
      def with_member_attributes(config, member, record, member_entries, source, pending)
        entries = record ? (member_entries[record.id] || []).select { |entry| entry.source == source } : []
        member = config.build_attributes(member)
        values = entries.to_h { |entry| [entry.attribute_name, entry.value] }
        pending.each do |item|
          recorded_at = Time.iso8601(item['recorded_at'])
          newer = entries.select { |entry| entry.recorded_at && entry.recorded_at > recorded_at }.map(&:attribute_name)
          values.merge!(item['attributes'].except(*newer))
        end
        member.merge(values)
      end

      # Returns a TrackedAssociation for each tracked association the record belongs to through one of its belongs_to
      # associations. Raises when there is none, naming what it checked.
      def tracked_associations_of(record)
        checked = []
        found = record.class.reflect_on_all_associations(:belongs_to).flat_map do |reflection|
          owner = record.public_send(reflection.name)
          checked << (owner ? "#{owner.class.name} #{owner.id} through #{reflection.name}" : "#{reflection.name}, which is not set")
          next [] unless owner.class.respond_to?(:laforged_associations)

          owner.class.laforged_associations.values.select { |config| record.is_a?(config.klass) && config.owner_foreign_key == reflection.foreign_key.to_s }.map { |config| new(owner, config) }
        end
        return found if found.any?

        raise ArgumentError, "#{record.class.name} is not a member of an association LaForge tracks (checked #{checked.join('; ').presence || 'no belongs_to associations'}). " \
                             "Set its owner first, and declare the association with `laforged associations:` on the owner"
      end
    end

    attr_reader :owner, :config

    def initialize(owner, config)
      @owner = owner
      @config = config
    end

    # Applies a source's edits to its report with `edit_member`, one member at a time, and leaves the rest of the report
    # as it is. `value` is what `AssociationConfig#edits` takes. A given `precedence:` is set for the source on the
    # association and given to every attribute the included members' pending items record. A has_one's edit is its
    # single member, recorded as a complete report.
    def edit(value, source, precedence: NOT_GIVEN, recorded_at: Time.current)
      return record(value, source, precedence: precedence, recorded_at: recorded_at) unless config.collection?

      config.edits(value).each { |action, member| edit_member(member, source, action, recorded_at: recorded_at, precedence: precedence) }
      owner.laforge.write_precedence_rule(config.name, source, precedence) unless precedence.equal?(NOT_GIVEN)
    end

    # Writes the source's report of `members`, replacing its previous one. `members` is a list of members, or for
    # `partial: true` either a list to include or { include: [...], exclude: [...] }. A given `precedence:` is set for
    # the source on the association and given to every attribute the report's pending items record. The members the
    # previous report included or withdrew and this one does not name are withdrawn, except new members and tombstones.
    # A partial report keeps the previous one's tombstones, and its exclusions of tombstones this one does not name.
    # Raises for a partial report of a has_one, and for members AssociationConfig rejects.
    def record(members, source, precedence:, partial: false, recorded_at: Time.current)
      raise ArgumentError, "#{owner.class.name}##{config.name} is a has_one, which takes a complete report" if partial && !config.collection?

      included, excluded = partial ? partial_members(members) : [config.normalize_members(members), []]
      keys = included.map(&:first)
      config.assert_references_exist!(owner, keys)
      pending = included.map { |key_hash, attributes| MemberList.pending_item(key_hash, attributes, recorded_at, precedence: precedence) }

      value =
        if partial then MemberList::Partial.replacing(report(source), config, include: keys, exclude: excluded, pending: pending)
        else MemberList::Complete.replacing(report(source), config, include: keys, pending: pending)
        end
      owner.laforge.write_data_entry(config.name, value, source, precedence: precedence, recorded_at: recorded_at)
    end

    # Changes the source's report for one member. A source with no report gets a partial one. `action` is one of:
    # - :include: includes the member, and adds what the edit says about it as a pending item after the earlier ones, so
    #   each edit changes only the attributes it names. Its nested lists are edits too.
    # - :exclude: leaves the member out of a complete report, or adds it to a partial report's exclusions
    # - :forget: drops the member from a partial report, and the report's tombstone when the member is one. Raises for a
    #   complete report, which has an opinion on every member.
    # Excluding or forgetting a member drops its pending items. Excluding a member from a complete report, or forgetting
    # one, withdraws it when the report included it.
    def edit_member(member, source, action, recorded_at: Time.current, precedence: NOT_GIVEN)
      member, attributes = config.normalize_members([member], attributes: action == :include, edit: true).first
      config.assert_references_exist!(owner, [member]) if action == :include
      config.assert_excludable!(owner, [member]) if action == :exclude
      previous = report(source)
      if action == :forget && !previous.partial?
        raise ArgumentError, "#{owner.class.name}##{config.name}: the source's report is a complete list, which has an opinion on every member, so forgetting #{config.describe_key(config.key_of(member))} " \
                             'would exclude it rather than leave it to other sources. Record the list with mode: :partial first, or exclude the member'
      end

      value =
        case action
        when :include then previous.including(config, member, MemberList.pending_item(member, attributes, recorded_at, edit: true, precedence: precedence))
        when :exclude then previous.excluding(config, member)
        when :forget then previous.forgetting(config, member)
        end
      owner.laforge.write_data_entry(config.name, value, source, recorded_at: recorded_at)
    end

    # Applies membership to the owner's members in memory, for the owner's save to write. Does nothing when no source
    # has reported the association.
    def forge
      return if reports.empty?

      include_removed_members
      recognise_tombstones(save: true)
      discard_created
      records = included_records + undecided.map { |key| existing.delete(key) } # one an earlier forge removed stays in the owner's pending writes
      write_order(records)
      forge_members(records)
      clear_pending
      prune_withdrawn
      entomb if config.tombstone_matcher
      remove_unclaimed(records)
    end

    # Returns what a forge would do to the members, without changing anything, or nil when no source has reported the
    # association:
    # - added: each member it would build, as its key, or as what the sources say about it for a new member
    # - removed: the key of each member it would remove
    # - changed: the key of each member whose pending items would change it, merged with those changes
    # - skipped: present only when it has members, the key of each one it would not build, because it is named by an id
    #   that is not one of the owner's, or because no source described it and it is invalid with its key alone
    def diff
      return if reports.empty?

      recognise_tombstones(save: false)
      changed = changed_members
      added, skipped = included.reject { |member| existing.key?(config.key_of(member)) }.partition { |member| buildable?(member) }

      {
        added: added.map { |member| added_member(member) },
        removed: (existing.keys - included_keys - undecided).map { |key| config.key.zip(key).to_h },
        changed: changed
      }.tap { |result| result[:skipped] = skipped.map { |member| config.key_hash(member) } if skipped.any? }
    end

    # Names each saved member of `created` by its id in every report of the association, in place of its placeholder
    # key. Each changed report is saved at once and keeps its recorded_at, since its source said nothing new.
    def name_created(created)
      names = created.select { |_, record| record.persisted? }.transform_values { |record| config.key_hash(record) }
      return if names.empty?

      owner.laforge.filter_data_entries_in_memory(attributes: config.name).each do |entry|
        next if entry.destroyed? || entry.marked_for_destruction?

        value = MemberList.new(entry.value).renamed(config, names)
        entry.update!(value: value) unless value == entry.value
      end
    end

    # Returns the first tombstone the tombstone matcher matches to the unsaved member `record` whose source outranks the
    # source with `source_id`, or nil, which it also is when the association has no tombstone matcher
    def tombstone_blocking(record, source_id)
      return unless config.tombstone_matcher

      outranking = tombstones.select { |tombstone| owner.laforge.outranks?(config.name, tombstone.source_id, source_id) }
      match_tombstone(record, outranking)
    end

    # Returns the tombstones in the reports a forge reads, the highest-precedence source's first and each token once, so
    # inactive sources' tombstones are left out
    def tombstones
      reports.reject { |entry, _| entry.marked_for_destruction? }
             .flat_map { |entry, report| report.tombstones.map { |item| Tombstone.new(owner, config, entry.source_id, item) } }
             .uniq(&:token)
    end

    # Returns an unsaved member pointing at the owner, with the association scope's attributes and the member model's
    # columns among `attributes`, except its primary key.
    def unsaved_member(attributes)
      new_member(reported_columns(attributes))
    end

    def member_sources(member)
      key = config.key_of(member)
      record = config.members_of(owner).find { |candidate| config.record_key(candidate) == key }
      candidates = record ? record.laforge.forging_entries.reject { |entry| entry.marked_for_destruction? || config.nested_config(entry.attribute_name) } : []

      deciding = reports.find { |_, report| report.decision(config, key) }

      {
        membership: (deciding[0].source if deciding && deciding[1].decision(config, key) == :include),
        listed_by: reports.select { |_, report| report.decision(config, key) == :include }.map { |entry, _| entry.source },
        excluded_by: reports.select { |_, report| report.partial? && report.decision(config, key) == :exclude }.map { |entry, _| entry.source },
        attributes: record ? record.laforge.winning_entries(candidates).transform_values { |winner, _| winner.source } : {}
      }
    end

    private

    # Returns [included, excluded] for a partial report's `members`, a list to include or
    # { include: [...], exclude: [...] }. The included are as `AssociationConfig#normalize_members` returns them, and
    # the excluded are key hashes. Raises for an exclusion `AssociationConfig#assert_excludable!` rejects.
    def partial_members(members)
      include, exclude = members.is_a?(Hash) ? [members.fetch(:include) { members['include'] } || [], members.fetch(:exclude) { members['exclude'] } || []] : [members, []]
      included = config.normalize_members(include)
      excluded = config.normalize_members(exclude, attributes: false).map(&:first)
      config.assert_excludable!(owner, excluded)
      [included, excluded]
    end

    # Adds the members an earlier forge removed in the owner's pending writes to `existing`, so this forge can include
    # them again
    def include_removed_members
      owner.laforge.pending_writes.removed_members(config).each { |record| existing[config.record_key(record)] ||= record }
    end

    # Names each new member whose pending item the tombstone matcher matches to a tombstone by that tombstone's key in
    # the reports, so membership decides it as the excluded member it was. With `save: true` the entries take the
    # renamed reports too, to be saved with the owner. Leaves the reports as they are when the association has no
    # tombstone matcher or no tombstones.
    def recognise_tombstones(save:)
      return unless config.tombstone_matcher

      known = tombstones
      return if known.empty?

      @reports = reports.map do |entry, report|
        next [entry, report] if entry.marked_for_destruction?

        names = report.pending.each_with_object({}) do |item, result|
          next unless config.new_member?(item['key'])

          found = match_tombstone(unsaved_member(item['attributes']), known)
          result[config.key_of(item['key'])] = found.key if found
        end
        next [entry, report] if names.empty?

        value = report.renamed(config, names)
        entry.value = value if save
        [entry, MemberList.new(value)]
      end
    end

    # Returns the one of `tombstones` the tombstone matcher picks for `member`, or nil. Raises when the matcher returns
    # a record it was not given.
    def match_tombstone(member, tombstones)
      return if tombstones.empty?

      records = tombstones.map(&:record)
      found = config.tombstone_matcher.call(member, records)
      return if found.nil?

      index = records.index { |record| record.equal?(found) }
      raise ArgumentError, "#{owner.class.name}##{config.name} tombstone_matcher: returned #{found.inspect}, which is not one of the tombstones it was given; return one of them, or nil" unless index

      tombstones[index]
    end

    # Drops from `created` the members an earlier forge built, not saved yet, that membership does not include, and
    # takes a collection's out of the association
    def discard_created
      (created.keys - included_keys).each do |key|
        record = created.delete(key)
        association.target.delete(record) if config.collection?
      end
    end

    # Returns a record for each member membership includes, in order, and records each one's pending items on it. An
    # existing member is taken out of `existing`, and its removal by an earlier forge is cancelled. A member that does
    # not exist is the one an earlier forge built, or is built now, and is left out when it is skipped.
    def included_records
      included.filter_map do |member|
        key = config.key_of(member)
        items = pending.fetch(key, [])
        record = existing.delete(key)&.tap { |kept| owner.laforge.pending_writes.cancel_removal(config, kept) } || created[key] || add(member, described: items.any?)
        next unless record

        recorded = items.map { |source_id, attributes, recorded_at, edit, precedence| record.laforge.record_reported(attributes, source_id, recorded_at, edit: edit, precedence: precedence) }
        recorded_on << record if recorded.any?
        record
      end
    end

    # Returns a member built for an included `member` that does not exist, or nil when it is skipped. A new member is
    # kept in `created` by its placeholder key, so a later forge before the save finds it. A member named by an id that
    # is not one of the owner's is skipped with a warning, since LaForge does not create a record with a given id. Any
    # other is built by `build`, which can skip it too.
    def add(member, described:)
      if config.primary_keyed? && !config.unsaved?(member)
        owner.logger&.warn("LaForge skipped #{config.klass.name} #{config.key_of(member).first.inspect} in #{owner.class.name} #{owner.id}'s #{config.name}: " \
                           "membership includes it, but it is no longer one of them. Report it without its #{config.klass.primary_key} to create a new one")
        return
      end

      record = build(member, described: described)
      created[config.key_of(member)] = record if record && config.unsaved?(member)
      record
    end

    # Returns a new member with the association scope's attributes and `AssociationConfig#build_attributes`, or nil
    # after logging a warning when `described` is false and the member is invalid with those alone. A collection member
    # is built in the association. A has_one member is built outside it, because Rails replaces a has_one's current
    # member as soon as one is built through it, and the forge has the owner's save remove the current one.
    def build(member, described:)
      attributes = config.build_attributes(member)
      record = config.collection? ? association.build(attributes) : new_member(attributes)
      return record if described || record.valid?

      association.target.delete(record) if config.collection?
      owner.logger&.warn("LaForge skipped the #{config.klass.name} with #{config.describe_key(config.key_of(member))} in #{owner.class.name} #{owner.id}'s #{config.name}: " \
                         "membership includes it, but it does not exist and is invalid with its key alone (#{record.errors.full_messages.to_sentence}). " \
                         'It is created when a source next reports it with its attributes')
      nil
    end

    # Writes each record's position in `records` to the association's order column, when it has one
    def write_order(records)
      return unless config.order_column

      records.each_with_index { |record, index| record[config.order_column] = config.order_descending ? records.size - 1 - index : index }
    end

    # Forges each member the forge recorded pending items on or withdrew a source from
    def forge_members(records)
      (recorded_on + withdraw_from_members(records)).uniq.each(&:forge)
    end

    # Withdraws each source whose report excludes or withdrew a member from that member, for each saved one of
    # `records`. Returns the members a withdrawn source had entries on, which need forging.
    def withdraw_from_members(records)
      records.select do |record|
        next false if record.new_record?

        key = config.record_key(record)
        withdrawing = reports.select { |_, report| report.decision(config, key) == :exclude || report.withdrew?(config, key) }
        withdrawing.map { |entry, _| record.laforge.withdraw(entry.source_id, owner) }.any?
      end
    end

    # Drops from the reports the pending items of the included members, which the forge has recorded on them. Each
    # report keeps its recorded_at, since its source said nothing new.
    def clear_pending
      reports.each do |entry, report|
        remaining = report.pending.reject { |item| included_keys.include?(config.key_of(item['key'])) }
        next if remaining.size == report.pending.size

        entry.value = report.with(pending: remaining)
      end
    end

    # Empties each report's withdrawn list, which the forge has applied. A partial report left with no members and no
    # pending items is marked for destruction, to go with the owner's save.
    def prune_withdrawn
      reports.each do |entry, _|
        next if entry.marked_for_destruction?

        report = MemberList.new(entry.value)
        next unless report.withdrawn.any?

        if report.vacant?
          entry.mark_for_destruction
        else
          entry.value = report.with(withdrawn: [])
        end
      end
    end

    # Gives a tombstone to each member left in `existing`, which the forge removes, that a partial report excludes.
    # Every report names the member by the tombstone's key in place of its id, inactive sources' included so they still
    # name it when their source is active again, and each excluding report keeps the tombstone.
    def entomb
      all_reports = owner.laforge.association_reports(config, inactive: true)
      existing.each_value do |record|
        key = config.record_key(record)
        excluding = reports.reject { |entry, _| entry.marked_for_destruction? }.select { |entry, _| MemberList.new(entry.value).exclude.any? { |member| config.key_of(member) == key } }
        next if excluding.empty?

        tombstone = { AssociationConfig::TOMBSTONE => SecureRandom.hex(8) }
        item = MemberList.tombstone_item(tombstone, tombstone_attributes(record), Time.current)
        all_reports.each do |entry, _|
          next if entry.marked_for_destruction?

          report = MemberList.new(MemberList.new(entry.value).renamed(config, { key => tombstone }))
          tombstones = excluding.any? { |excluder, _| excluder.equal?(entry) } ? report.tombstones + [item] : report.tombstones
          value = report.with(tombstones: tombstones)
          entry.value = value unless value == entry.value
        end
      end
    end

    # Returns the removed member's columns as JSON values, without its primary key, its timestamps and its link to the
    # owner
    def tombstone_attributes(record)
      reported_columns(record.attributes).except('created_at', 'updated_at').transform_values(&:as_json)
    end

    # Removes each member left in `existing`, which the forge does not keep, per the association's `dependent:` option.
    # A has_one's target becomes the first of `records`.
    def remove_unclaimed(records)
      if config.collection?
        existing.each_value { |record| owner.laforge.pending_writes.remove(config, record) }
      else
        association.target = records.first
        existing.each_value { |record| owner.laforge.pending_writes.remove_on_save(config, record) }
      end
    end

    # Returns the key of each included member that exists and whose pending items would change it, merged with those
    # changes
    def changed_members
      included.filter_map do |member|
        record = existing[config.key_of(member)]
        items = pending.fetch(config.key_of(member), [])
        next unless record && items.any?

        changes = record.laforge.forge_diff_with(items)
        config.key_hash(record).merge(changes) if changes.any?
      end
    end

    # Whether a forge would build the included `member`, which does not exist
    def buildable?(member)
      return false if config.primary_keyed? && !config.unsaved?(member) # named by an id that is not one of the owner's

      pending.key?(config.key_of(member)) || new_member(config.build_attributes(member)).valid?
    end

    # Returns the included `member`, which does not exist, as `diff` reports it added
    def added_member(member)
      return config.key_hash(member) unless config.unsaved?(member)

      pending.fetch(config.key_of(member), []).inject({}) { |attributes, (_, reported)| attributes.merge(reported) }
    end

    # Returns the member model's columns among `attributes`, without its primary key and its link to the owner
    def reported_columns(attributes)
      attributes.slice(*config.klass.column_names).except(config.klass.primary_key, config.owner_foreign_key, config.owner_type_column)
    end

    # Returns a new member with the association scope's attributes and `attributes`, pointing at the owner but not in
    # the association
    def new_member(attributes)
      config.klass.new(association.scope.scope_for_create.merge(attributes)).tap do |member|
        member[config.owner_foreign_key] = owner.id
        member[config.owner_type_column] = owner.class.polymorphic_name if config.owner_type_column
      end
    end

    # Returns the members this forge recorded pending items on
    def recorded_on
      @recorded_on ||= []
    end

    def included_keys
      included.map { |member| config.key_of(member) }
    end

    # Returns the hashes of the members membership includes (see `resolution`)
    def included
      resolution.first
    end

    # Returns the keys of the existing members a forge leaves as they are (see `resolution`)
    def undecided
      resolution.last
    end

    # Returns [included, undecided], read from the reports and `existing` when first called:
    # - included: the hashes of the members membership includes, the highest-precedence report's first, without those
    #   whose referenced record does not exist
    # - undecided: the keys of the `existing` members a forge leaves as they are, which are those no report names, and
    #   those no report has an opinion on and none withdrew
    def resolution
      @resolution ||= begin
        decision = ->(key) { reports.lazy.filter_map { |_, report| report.decision(config, key) }.first }
        named = reports.flat_map { |_, report| report.reported_keys(config) }.map { |member| config.key_of(member) }.to_set

        candidates = reports.flat_map { |_, report| report.include }.uniq { |member| config.key_of(member) }
        included = config.drop_dangling(candidates.select { |member| decision.(config.key_of(member)) == :include })
        included_keys = included.map { |member| config.key_of(member) }

        undecided = existing.keys.reject do |key|
          included_keys.include?(key) || (named.include?(key) && (decision.(key) || reports.any? { |_, report| report.withdrew?(config, key) }))
        end

        [included, undecided]
      end
    end

    # Returns the reports' pending items by member key, oldest first so they are recorded in the order the sources
    # reported them, as { key => [[source id, attributes, recorded_at, edit, precedence], ...] }. The precedence of an
    # item without one is `NOT_GIVEN`.
    def pending
      @pending ||= begin
        items = reports.flat_map do |entry, report|
          report.pending.map do |item|
            precedence = item.key?('precedence') ? item['precedence'] : NOT_GIVEN
            [config.key_of(item['key']), [entry.source_id, item['attributes'], Time.iso8601(item['recorded_at']), item['edit'] == true, precedence]]
          end
        end
        items.sort_by { |_, (_, _, recorded_at)| recorded_at }.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
      end
    end

    # Returns the owner's members by key (see `AssociationConfig#identified_members_of`). A forge takes out each member
    # it keeps, leaving those it removes.
    def existing
      @existing ||= config.identified_members_of(owner)
    end

    # Returns the new members forges built and the owner has not saved yet, by placeholder key
    def created
      @created ||= owner.laforge.pending_writes.created_members(config)
    end

    # Returns the source's report, or `MemberList.none` when it has none or its entry is marked for destruction
    def report(source)
      entry = owner.laforge.filter_data_entries_in_memory(attributes: config.name, sources: source).first
      entry && !entry.marked_for_destruction? ? MemberList.new(entry.value) : MemberList.none
    end

    # Returns the association's entries in precedence order, each paired with its report, as read when first called
    def reports
      @reports ||= owner.laforge.association_reports(config)
    end

    def association
      owner.association(config.name.to_sym)
    end
  end
end

module LaForge
  # Used to track the has_many and has_one associations declared with `laforged associations:`, each described by an
  # AssociationConfig, which also defines how members are named by key.
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
  module AssociationTracking
    extend self

    # Makes the member model laforged if it is not, and autosaves the association so the owner's save writes what a
    # forge changes on its members.
    def declare(owner_class, config)
      config.klass.laforged unless config.klass.respond_to?(:laforged_associations)
      config.reflection.autosave = true
    end

    # Writes the source's report of `members`, replacing its previous one. `members` is a list of members, or for
    # `partial: true` either a list to include or { include: [...], exclude: [...] }. A given `precedence:` is set for
    # the source on the association and given to every attribute the report's pending items record. The members the
    # previous report included or withdrew and this one does not name are withdrawn, except new members and tombstones.
    # A partial report keeps the previous one's tombstones, and its exclusions of tombstones this one does not name.
    # Raises for a partial report of a has_one, and for members AssociationConfig rejects.
    def record(owner, config, members, source, precedence:, partial: false, recorded_at: Time.current)
      raise ArgumentError, "#{owner.class.name}##{config.name} is a has_one, which takes a complete report" if partial && !config.collection?

      if partial
        include, exclude = members.is_a?(Hash) ? [members.fetch(:include) { members['include'] } || [], members.fetch(:exclude) { members['exclude'] } || []] : [members, []]
        included = config.normalize_members(include)
        excluded = config.normalize_members(exclude, attributes: false).map(&:first)
        config.assert_excludable!(owner, excluded)
      else
        included = config.normalize_members(members)
        excluded = []
      end
      keys = included.map(&:first)
      config.assert_references_exist!(owner, keys)
      pending = included.map { |key_hash, attributes| MemberList.pending_item(key_hash, attributes, recorded_at, precedence: precedence) }

      reported = (keys + excluded).map { |member| config.key_of(member) }
      previous = report(owner, config, source)
      withdrawn = previous ? (previous.include + previous.withdrawn).map { |member| config.key_hash(member) }.uniq.reject { |member| reported.include?(config.key_of(member)) || config.unsaved?(member) } : []
      value =
        if partial
          kept = previous ? previous.exclude.select { |member| config.tombstone?(member) && !reported.include?(config.key_of(member)) } : []
          MemberList.partial(include: keys, exclude: excluded + kept, withdrawn: withdrawn, pending: pending, tombstones: previous&.tombstones || [])
        else
          MemberList.value(include: keys, withdrawn: withdrawn, pending: pending)
        end

      owner.send(:write_data_entry, config.name, value, source, precedence: precedence, recorded_at: recorded_at)
    end

    # Applies a source's edits to its report with `edit_member`, one member at a time, and leaves the rest of the report
    # as it is. `value` is what `AssociationConfig#edits` takes. A given `precedence:` is set for the source on the
    # association and given to every attribute the included members' pending items record. A has_one's edit is its
    # single member, recorded as a complete report.
    def edit(owner, config, value, source, precedence: NOT_GIVEN, recorded_at: Time.current)
      return record(owner, config, value, source, precedence: precedence, recorded_at: recorded_at) unless config.collection?

      config.edits(value).each { |action, member| edit_member(owner, config, member, source, action, recorded_at: recorded_at, precedence: precedence) }
      owner.send(:write_precedence_rule, config.name, source, precedence) unless precedence.equal?(NOT_GIVEN)
    end

    # Changes the source's report for one member. A source with no report gets a partial one. `action` is one of:
    # - :include: includes the member, and adds what the edit says about it as a pending item after the earlier ones, so
    #   each edit changes only the attributes it names. Its nested lists are edits too.
    # - :exclude: leaves the member out of a complete report, or adds it to a partial report's exclusions
    # - :forget: drops the member from a partial report, and the report's tombstone when the member is one. Raises for a
    #   complete report, which has an opinion on every member.
    # Excluding or forgetting a member drops its pending items. Excluding a member from a complete report, or forgetting
    # one, withdraws it when the report included it.
    def edit_member(owner, config, member, source, action, recorded_at: Time.current, precedence: NOT_GIVEN)
      member, attributes = config.normalize_members([member], attributes: action == :include, edit: true).first
      config.assert_references_exist!(owner, [member]) if action == :include
      config.assert_excludable!(owner, [member]) if action == :exclude
      key = config.key_of(member)
      previous = report(owner, config, source)
      if action == :forget && previous && !previous.partial?
        raise ArgumentError, "#{owner.class.name}##{config.name}: the source's report is a complete list, which has an opinion on every member, so forgetting #{config.describe_key(key)} " \
                             'would exclude it rather than leave it to other sources. Record the list with mode: :partial first, or exclude the member'
      end
      others = ->(list) { (list || []).reject { |listed| config.key_of(listed) == key } }
      pending = previous&.pending || []
      pending = pending.reject { |item| config.key_of(item['key']) == key } unless action == :include
      pending += [MemberList.pending_item(member, attributes, recorded_at, edit: true, precedence: precedence)] if action == :include
      tombstones = (previous&.tombstones || []).reject { |item| action == :forget && config.key_of(item['key']) == key }

      value =
        if previous && !previous.partial?
          withdrawn = others.(previous.withdrawn)
          withdrawn << config.key_hash(member) if action != :include && previous.decision(config, key) == :include
          MemberList.value(include: others.(previous.include) + (action == :include ? [member] : []), withdrawn: withdrawn, pending: pending)
        else
          withdrawn = others.(previous&.withdrawn)
          withdrawn << config.key_hash(member) if action == :forget && previous&.decision(config, key) == :include
          MemberList.partial(include: others.(previous&.include) + (action == :include ? [member] : []),
                             exclude: others.(previous&.exclude) + (action == :exclude ? [config.key_hash(member)] : []),
                             withdrawn: withdrawn, pending: pending, tombstones: tombstones)
        end

      owner.send(:write_data_entry, config.name, value, source, recorded_at: recorded_at)
    end

    # Withdraws each source whose report excludes or withdrew a member from that member, for each saved one of
    # `records`. Returns the members a withdrawn source had entries on, which need forging.
    def withdraw_from_members(owner, config, reports, records)
      records.select do |record|
        next false if record.new_record?

        key = config.record_key(record)
        withdrawing = reports.select { |_, report| report.decision(config, key) == :exclude || report.withdrew?(config, key) }
        withdrawing.map { |entry, _| record.laforge_withdraw(entry.source_id, owner) }.any?
      end
    end

    # Makes the report in `entry` a partial one that withdraws every member it named, so the source has no opinion on
    # any. Its pending items and tombstones are dropped, and so are the new members and tombstones it named.
    def withdraw(config, entry)
      entry.value = MemberList.partial(withdrawn: MemberList.new(entry.value).reported_keys(config).reject { |member| config.unsaved?(member) })
    end

    # Applies membership to the owner's members in memory, for the owner's save to write. Does nothing when no source
    # has reported the association.
    def forge(owner, config)
      reports = owner.send(:laforge_association_reports, config)
      return if reports.empty?

      existing = config.identified_members_of(owner)
      owner.laforge_scheduled_members(config).each { |record| existing[config.record_key(record)] ||= record } # scheduled for removal by an earlier forge, not saved yet
      reports = recognise_tombstones(owner, config, reports, save: true)
      created = owner.laforge_created_members(config)
      included, undecided = resolve(config, reports, existing)
      pending = pending_by_key(config, reports)
      included_keys = included.map { |member| config.key_of(member) }
      discard_created(owner, config, created, included_keys)

      described = []
      records = included.filter_map do |member|
        key = config.key_of(member)
        items = pending.fetch(key, [])
        record = existing.delete(key)&.tap { |kept| owner.laforge_cancel_removal(config, kept) } || created[key] || add(owner, config, member, created, described: items.any?)
        next unless record

        recorded = items.map { |source_id, attributes, recorded_at, edit, precedence| record.laforge_record_reported(attributes, source_id, recorded_at, edit: edit, precedence: precedence) }
        described << record if recorded.any?
        record
      end
      records += undecided.map { |key| existing.delete(key) } # one an earlier forge scheduled for removal stays scheduled
      records.each_with_index do |record, index|
        record[config.order_column] = config.order_descending ? records.size - 1 - index : index if config.order_column
      end

      described += withdraw_from_members(owner, config, reports, records)
      described.uniq.each(&:forge)
      clear_pending(config, reports, included_keys)
      prune_withdrawn(config, reports)
      entomb(config, reports, owner.send(:laforge_association_reports, config, inactive: true), existing.values) if config.tombstone_matcher

      if config.collection?
        existing.each_value { |record| owner.laforge_remove(config, record) }
      else
        owner.association(config.name.to_sym).target = records.first
        existing.each_value { |record| owner.laforge_remove_on_save(config, record) }
      end
    end

    # Returns what a forge would do to the members, without changing anything, or nil when no source has reported the
    # association:
    # - added: each member it would build, as its key, or as what the sources say about it for a new member
    # - removed: the key of each member it would remove
    # - changed: the key of each member whose pending items would change it, merged with those changes
    # - skipped: present only when it has members, the key of each one it would not build, because it is named by an id
    #   that is not one of the owner's, or because no source described it and it is invalid with its key alone
    def diff(owner, config)
      reports = owner.send(:laforge_association_reports, config)
      return if reports.empty?

      existing = config.identified_members_of(owner)
      reports = recognise_tombstones(owner, config, reports, save: false)
      included, undecided = resolve(config, reports, existing)
      pending = pending_by_key(config, reports)
      keys = included.map { |member| config.key_of(member) } + undecided

      changed = included.filter_map do |member|
        record = existing[config.key_of(member)]
        items = pending.fetch(config.key_of(member), [])
        next unless record && items.any?

        changes = record.laforge_forge_diff_with(items)
        config.key_hash(record).merge(changes) if changes.any?
      end

      added, skipped = included.reject { |member| existing.key?(config.key_of(member)) }.partition do |member|
        next false if config.primary_keyed? && !config.unsaved?(member) # named by an id that is not one of the owner's

        pending.key?(config.key_of(member)) || new_member(owner, config, config.build_attributes(member)).valid?
      end

      {
        added: added.map { |member| config.unsaved?(member) ? pending.fetch(config.key_of(member), []).inject({}) { |attributes, (_, reported)| attributes.merge(reported) } : config.key_hash(member) },
        removed: (existing.keys - keys).map { |key| config.key.zip(key).to_h },
        changed: changed
      }.tap { |result| result[:skipped] = skipped.map { |member| config.key_hash(member) } if skipped.any? }
    end

    # Returns { owner id => { source => [member hashes] } } for `records`, each member hash as `with_member_attributes`
    # builds it. A source gives the members its report includes, then the other rows it has entries on. An owner no
    # source has anything on is left out.
    def source_values(owner_class, config, records)
      owner_ids = records.map(&:id)
      entries = DataEntry.where(record_type: owner_class.base_class.name, record_id: owner_ids, attribute_name: config.name).preload(:source).to_a

      member_scope = config.klass.where(config.owner_foreign_key => owner_ids)
      member_scope = member_scope.where(config.owner_type_column => owner_class.polymorphic_name) if config.owner_type_column
      scope = config.reflection.scope
      member_scope = member_scope.merge(config.klass.unscoped.instance_exec(&scope)) if scope&.arity&.zero? # a scope taking the owner cannot be applied to several owners at once
      member_records = member_scope.to_a
      member_entries = DataEntry.where(record_type: config.klass.base_class.name, record_id: member_records.map(&:id)).preload(:source).to_a
                                .reject { |entry| config.nested_config(entry.attribute_name) }
                                .group_by(&:record_id)

      members_by_owner = member_records.group_by { |record| record[config.owner_foreign_key] }

      owner_ids.each_with_object({}) do |owner_id, result|
        reports = entries.select { |entry| entry.record_id == owner_id }.to_h { |entry| [entry.source, MemberList.new(entry.value)] }
        rows = (members_by_owner[owner_id] || []).reject { |record| config.blank_key?(config.record_key(record)) }.index_by { |record| config.record_key(record) }
        sources = (reports.keys + rows.values.flat_map { |record| (member_entries[record.id] || []).map(&:source) }).uniq

        values = sources.to_h do |source|
          report = reports[source]
          listed = (report&.include || []).map do |member|
            pending = report.pending.select { |item| config.key_of(item['key']) == config.key_of(member) }.sort_by { |item| item['recorded_at'] }
            with_member_attributes(config, member, rows[config.key_of(member)], member_entries, source, pending)
          end
          unlisted = rows.values.reject { |record| listed.any? { |member| config.key_of(member) == config.record_key(record) } }
                         .select { |record| (member_entries[record.id] || []).any? { |entry| entry.source == source } }
                         .map { |record| with_member_attributes(config, config.key_hash(record), record, member_entries, source, []) }
          [source, listed + unlisted]
        end

        result[owner_id] = values if values.any?
      end
    end

    # Names each saved member of `created` by its id in every report of the association, in place of its placeholder
    # key. Each changed report is saved at once and keeps its recorded_at, since its source said nothing new.
    def name_created(owner, config, created)
      names = created.select { |_, record| record.persisted? }.transform_values { |record| config.key_hash(record) }
      return if names.empty?

      owner.send(:filter_data_entries_in_memory, attributes: config.name).each do |entry|
        next if entry.destroyed? || entry.marked_for_destruction?

        value = MemberList.new(entry.value).renamed(config, names)
        entry.update!(value: value) unless value == entry.value
      end
    end

    # Returns the tombstones in `reports`, the highest-precedence source's first and each token once. By default those
    # are the reports a forge reads, so inactive sources' tombstones are left out.
    def tombstones(owner, config, reports = owner.send(:laforge_association_reports, config))
      reports.reject { |entry, _| entry.marked_for_destruction? }
             .flat_map { |entry, report| report.tombstones.map { |item| Tombstone.new(owner, config, entry.source_id, item) } }
             .uniq(&:token)
    end

    # See `LaForge.tombstone_blocking`.
    def tombstone_blocking(record, source)
      raise ArgumentError, "#{record.class.name} #{record.id} already exists; tombstone_blocking checks a new member before it is created" if record.persisted?

      source_id = DataSource.normalize_source_id(source)
      tracked_owners(record).each do |owner, config|
        next unless config.tombstone_matcher

        outranking = tombstones(owner, config).select { |tombstone| owner.laforge_outranks?(config.name, tombstone.source_id, source_id) }
        found = match_tombstone(owner, config, record, outranking)
        return found if found
      end
      nil
    end

    # Returns an unsaved member pointing at the owner, with the association scope's attributes and the member model's
    # columns among `attributes`, except its primary key.
    def unsaved_member(owner, config, attributes)
      new_member(owner, config, reported_columns(config, attributes))
    end

    def member_sources(owner, config, member)
      reports = owner.send(:laforge_association_reports, config)
      key = config.key_of(member)
      record = config.members_of(owner).find { |candidate| config.record_key(candidate) == key }
      candidates = record ? record.send(:laforge_forging_entries).reject { |entry| entry.marked_for_destruction? || config.nested_config(entry.attribute_name) } : []

      deciding = reports.find { |_, report| report.decision(config, key) }

      {
        membership: (deciding[0].source if deciding && deciding[1].decision(config, key) == :include),
        listed_by: reports.select { |_, report| report.decision(config, key) == :include }.map { |entry, _| entry.source },
        excluded_by: reports.select { |_, report| report.partial? && report.decision(config, key) == :exclude }.map { |entry, _| entry.source },
        attributes: record ? record.send(:laforge_winning_entries, candidates).transform_values { |winner, _| winner.source } : {}
      }
    end

    private

    # Returns `reports` with each new member whose pending item the tombstone matcher matches to a tombstone named by
    # that tombstone's key, so membership decides it as the excluded member it was. With `save: true` the entries take
    # the renamed reports too, to be saved with the owner. Returns `reports` as they are when the association has no
    # tombstone matcher or no tombstones.
    def recognise_tombstones(owner, config, reports, save:)
      return reports unless config.tombstone_matcher

      known = tombstones(owner, config, reports)
      return reports if known.empty?

      reports.map do |entry, report|
        next [entry, report] if entry.marked_for_destruction?

        names = report.pending.each_with_object({}) do |item, result|
          next unless config.new_member?(item['key'])

          found = match_tombstone(owner, config, unsaved_member(owner, config, item['attributes']), known)
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
    def match_tombstone(owner, config, member, tombstones)
      return if tombstones.empty?

      records = tombstones.map(&:record)
      found = config.tombstone_matcher.call(member, records)
      return if found.nil?

      index = records.index { |record| record.equal?(found) }
      raise ArgumentError, "#{owner.class.name}##{config.name} tombstone_matcher: returned #{found.inspect}, which is not one of the tombstones it was given; return one of them, or nil" unless index

      tombstones[index]
    end

    # Gives a tombstone to each of the `removed` members that a partial report in `reports` excludes. Every report in
    # `all_reports` names the member by the tombstone's key in place of its id, and each excluding report keeps the
    # tombstone. `all_reports` adds inactive sources' reports to `reports`, so they still name the member when their
    # source is active again.
    def entomb(config, reports, all_reports, removed)
      removed.each do |record|
        key = config.record_key(record)
        excluding = reports.reject { |entry, _| entry.marked_for_destruction? }.select { |entry, _| MemberList.new(entry.value).then { |report| report.partial? && report.exclude.any? { |member| config.key_of(member) == key } } }
        next if excluding.empty?

        tombstone = { AssociationConfig::TOMBSTONE => SecureRandom.hex(8) }
        item = MemberList.tombstone_item(tombstone, tombstone_attributes(config, record), Time.current)
        all_reports.each do |entry, _|
          next if entry.marked_for_destruction?

          report = MemberList.new(MemberList.new(entry.value).renamed(config, { key => tombstone }))
          tombstones = excluding.any? { |excluder, _| excluder.equal?(entry) } ? report.tombstones + [item] : report.tombstones
          value = MemberList.value(include: report.include, exclude: report.exclude, withdrawn: report.withdrawn, pending: report.pending, tombstones: tombstones, partial: report.partial?)
          entry.value = value unless value == entry.value
        end
      end
    end

    # Returns the removed member's columns as JSON values, without its primary key, its timestamps and its link to the
    # owner
    def tombstone_attributes(config, record)
      reported_columns(config, record.attributes).except('created_at', 'updated_at').transform_values(&:as_json)
    end

    # Returns the member model's columns among `attributes`, without its primary key and its link to the owner
    def reported_columns(config, attributes)
      attributes.slice(*config.klass.column_names).except(config.klass.primary_key, config.owner_foreign_key, config.owner_type_column)
    end

    # Returns [[owner, config], ...] for each tracked association the record belongs to through one of its belongs_to
    # associations. Raises when there is none, naming what it checked.
    def tracked_owners(record)
      checked = []
      found = record.class.reflect_on_all_associations(:belongs_to).flat_map do |reflection|
        owner = record.public_send(reflection.name)
        checked << (owner ? "#{owner.class.name} #{owner.id} through #{reflection.name}" : "#{reflection.name}, which is not set")
        next [] unless owner.class.respond_to?(:laforged_associations)

        owner.class.laforged_associations.values.select { |config| record.is_a?(config.klass) && config.owner_foreign_key == reflection.foreign_key.to_s }.map { |config| [owner, config] }
      end
      return found if found.any?

      raise ArgumentError, "#{record.class.name} is not a member of an association LaForge tracks (checked #{checked.join('; ').presence || 'no belongs_to associations'}). " \
                           "Set its owner first, and declare the association with `laforged associations:` on the owner"
    end

    # Returns the reports' pending items by member key, oldest first so they are recorded in the order the sources
    # reported them, as { key => [[source id, attributes, recorded_at, edit, precedence], ...] }. The precedence of an
    # item without one is `NOT_GIVEN`.
    def pending_by_key(config, reports)
      items = reports.flat_map do |entry, report|
        report.pending.map do |item|
          precedence = item.key?('precedence') ? item['precedence'] : NOT_GIVEN
          [config.key_of(item['key']), [entry.source_id, item['attributes'], Time.iso8601(item['recorded_at']), item['edit'] == true, precedence]]
        end
      end
      items.sort_by { |_, (_, _, recorded_at)| recorded_at }.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    end

    # Drops from `created` the members an earlier forge built, not saved yet, that membership does not include, and
    # takes a collection's out of the association
    def discard_created(owner, config, created, included_keys)
      (created.keys - included_keys).each do |key|
        record = created.delete(key)
        owner.association(config.name.to_sym).target.delete(record) if config.collection?
      end
    end

    # Returns a member built for an included `member` that does not exist, or nil when it is skipped. A new member is
    # kept in `created` by its placeholder key, so a later forge before the save finds it. A member named by an id that
    # is not one of the owner's is skipped with a warning, since LaForge does not create a record with a given id. Any
    # other is built by `build`, which can skip it too.
    def add(owner, config, member, created, described:)
      if config.primary_keyed? && !config.unsaved?(member)
        owner.logger&.warn("LaForge skipped #{config.klass.name} #{config.key_of(member).first.inspect} in #{owner.class.name} #{owner.id}'s #{config.name}: " \
                           "membership includes it, but it is no longer one of them. Report it without its #{config.klass.primary_key} to create a new one")
        return
      end

      record = build(owner, config, member, described: described)
      created[config.key_of(member)] = record if record && config.unsaved?(member)
      record
    end

    # Returns a new member with the association scope's attributes and `AssociationConfig#build_attributes`, or nil
    # after logging a warning when `described` is false and the member is invalid with those alone. A collection member
    # is built in the association. A has_one member is built outside it, because Rails replaces a has_one's current
    # member as soon as one is built through it, and the forge has the owner's save remove the current one.
    def build(owner, config, member, described:)
      association = owner.association(config.name.to_sym)
      attributes = config.build_attributes(member)
      record = config.collection? ? association.build(attributes) : new_member(owner, config, attributes)
      return record if described || record.valid?

      association.target.delete(record) if config.collection?
      owner.logger&.warn("LaForge skipped the #{config.klass.name} with #{config.describe_key(config.key_of(member))} in #{owner.class.name} #{owner.id}'s #{config.name}: " \
                         "membership includes it, but it does not exist and is invalid with its key alone (#{record.errors.full_messages.to_sentence}). " \
                         'It is created when a source next reports it with its attributes')
      nil
    end

    # Returns a new member with the association scope's attributes and those in `key_hash`, pointing at the owner but
    # not in the association
    def new_member(owner, config, key_hash)
      config.klass.new(owner.association(config.name.to_sym).scope.scope_for_create.merge(key_hash)).tap do |member|
        member[config.owner_foreign_key] = owner.id
        member[config.owner_type_column] = owner.class.polymorphic_name if config.owner_type_column
      end
    end

    # Drops from the reports the pending items of the members with `keys`, which the forge has recorded on them. Each
    # report keeps its recorded_at, since its source said nothing new.
    def clear_pending(config, reports, keys)
      reports.each do |entry, report|
        remaining = report.pending.reject { |item| keys.include?(config.key_of(item['key'])) }
        next if remaining.size == report.pending.size

        entry.value = report.with_pending(remaining)
      end
    end

    # Empties each report's withdrawn list, which the forge has applied. A partial report left with no members and no
    # pending items is marked for destruction, to go with the owner's save.
    def prune_withdrawn(config, reports)
      reports.each do |entry, _|
        next if entry.marked_for_destruction?

        report = MemberList.new(entry.value)
        next unless report.withdrawn.any?

        if !report.partial?
          entry.value = MemberList.value(include: report.include, pending: report.pending) # an empty complete report still excludes every member
        elsif report.include.empty? && report.exclude.empty? && report.pending.empty?
          entry.mark_for_destruction
        else
          entry.value = MemberList.partial(include: report.include, exclude: report.exclude, pending: report.pending, tombstones: report.tombstones)
        end
      end
    end

    # Returns the source's report, or nil when it has none or its entry is marked for destruction
    def report(owner, config, source)
      entry = owner.send(:filter_data_entries_in_memory, attributes: config.name, sources: source).first
      MemberList.new(entry.value) if entry && !entry.marked_for_destruction?
    end

    # Returns [included, undecided]:
    # - included: the hashes of the members membership includes, the highest-precedence report's first, without those
    #   whose referenced record does not exist
    # - undecided: the keys of the `existing` members a forge leaves as they are, which are those no report names, and
    #   those no report has an opinion on and none withdrew
    def resolve(config, reports, existing)
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

    # Returns the member's hash as `source` gives it, merging in order:
    # - its key, or nothing for a new member or a tombstone
    # - the source's entries on the member
    # - the source's pending items for it, each without the attributes the member has a newer entry for from the source
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
  end
end

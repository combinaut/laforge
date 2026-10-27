module LaForge
  # `TrackedAssociation` is used to record, forge and inspect one owner's has_many or has_one association declared with
  # `laforged associations:`, described by an `AssociationConfig`, which also defines how members are named by key. The
  # class methods act on the association across owners.
  #
  # Each source's entry for the association on the owner is its member list (see MemberList). Membership is
  # whether a member belongs to the association, decided per member by the highest-precedence member list that covers
  # it. A row no member list names is left alone.
  #
  # A forge of the owner applies membership. A member it removes goes when the owner is saved, per the association's
  # `dependent:` option. What a member list says about a member besides its key waits there as pending until a forge
  # includes the member, and is then recorded on the member as the source's entries, like attributes recorded on the
  # member directly. So nothing is created for a member membership excludes, and a member's attributes are resolved on
  # the member alone. The owner's forge forges the members it records on or withdraws a source from, and any other
  # member is forged on its own.
  #
  # Withdrawing a source from a member drops the source's entries on the member, and makes each of its member lists for
  # the member's own tracked associations withdraw every member it named. A forge withdraws each source whose member
  # list excludes or withdrew a member the forge keeps.
  #
  # An instance reads the owner's member lists and members when it first needs them, so each operation uses a new one.
  class TrackedAssociation
    class << self
      # Makes the member model laforged if it is not, and autosaves the association so the owner's save writes what a
      # forge changes on its members. Its members are then validated with the owner, as `accepts_nested_attributes_for`
      # has them validated, which a has_one declared without `autosave: true` would otherwise skip.
      def declare(owner_class, config)
        config.klass.laforged unless config.klass.respond_to?(:laforge)
        return if config.reflection.options[:autosave] == true # Rails already added the validations

        config.reflection.autosave = true
        owner_class.send(:define_autosave_validation_callbacks, config.reflection)
      end

      # Returns { owner id => { source => [member hashes] } } for `records`, each member hash as
      # `with_member_attributes` builds it. A source gives the members its member list includes, then the other rows it
      # has entries on. An owner no source has anything on is left out.
      def source_values(owner_class, config, records)
        owner_keys = records.to_h { |record| [record.id, config.owner_key(record)] } # members point at the owner key, entries at the id
        entries = DataEntry.where(record_type: owner_class.base_class.name, record_id: owner_keys.keys, attribute_name: config.name).preload(:source).group_by(&:record_id)
        rows = member_rows(owner_class, config, owner_keys.values.compact)
        member_entries = DataEntry.where(record_type: config.klass.base_class.name, record_id: rows.map(&:id)).preload(:source).to_a
                                  .reject { |entry| config.nested_config(entry.attribute_name) }
                                  .group_by(&:record_id)
        rows_by_owner = rows.group_by { |record| record[config.owner_foreign_key] }

        owner_keys.each_with_object({}) do |(owner_id, owner_key), result|
          member_lists = (entries[owner_id] || []).to_h { |entry| [entry.source, MemberList.new(entry.value)] }
          values = values_by_source(config, member_lists, rows_by_owner[owner_key] || [], member_entries)
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

      # Returns the members of the owners with `owner_keys` (see `AssociationConfig#owner_key`), in the association's
      # scope unless the scope takes the owner, which cannot be applied to several owners at once
      def member_rows(owner_class, config, owner_keys)
        scope = config.klass.where(config.owner_foreign_key => owner_keys)
        scope = scope.where(config.owner_type_column => owner_class.polymorphic_name) if config.owner_type_column
        reflection_scope = config.reflection.scope
        scope = scope.merge(config.klass.unscoped.instance_exec(&reflection_scope)) if reflection_scope&.arity&.zero?
        scope.to_a
      end

      # Returns { source => [member hashes] } for one owner, given its `member_lists` by source, its member `rows`, and
      # `member_entries` by member id
      def values_by_source(config, member_lists, rows, member_entries)
        rows = rows.reject { |record| config.blank_key?(config.record_key(record)) }.index_by { |record| config.record_key(record) }
        sources = (member_lists.keys + rows.values.flat_map { |record| (member_entries[record.id] || []).map(&:source) }).uniq

        sources.to_h do |source|
          listed = listed_members(config, member_lists[source], rows, member_entries, source)
          [source, listed + unlisted_members(config, listed, rows, member_entries, source)]
        end
      end

      # Returns the member hash of each member `list` includes, or none when the source has no member list
      def listed_members(config, list, rows, member_entries, source)
        (list&.include || []).map do |member|
          pending = list.pending.select { |item| config.key_of(item['key']) == config.key_of(member) }.sort_by { |item| item['recorded_at'] }
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
          values.merge!(RecordingSettings.strip(item['attributes']).except(*newer))
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
          next [] unless owner.class.respond_to?(:laforge)

          owner.class.laforge.associations.values.select { |config| record.is_a?(config.klass) && config.owner_foreign_key == reflection.foreign_key.to_s }.map { |config| new(owner, config) }
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

    # Applies a source's edits to its member list with `edit_member`, one member at a time, and leaves the rest of the
    # member list as it is. `value` is what `AssociationConfig#edits` takes. The settings' precedence is set for the
    # source on the association, with their expiry, even when there is nothing to edit. Each member edited takes the
    # settings, or its wrapper's. A has_one's edit is its single member, recorded as a complete list. `recorded_at`,
    # when given, is when the edit was made, and its precedence rule is made at that time rather than now (see
    # Expiring).
    def edit(value, source, settings: RecordingSettings::DEFAULT, recorded_at: nil)
      at = recorded_at || Time.current
      return record(value, source, settings: settings, recorded_at: at) unless config.collection?

      config.edits(value).each { |action, member| edit_member(member, source, action, recorded_at: at, settings: settings) }
      return unless settings.precedence_given?

      rule = owner.laforge.write_precedence_rule(config.name, source, settings, made_at: recorded_at)
      owner.laforge.expire_replayed(config.name, recorded_at, [rule]) if recorded_at
    end

    # Writes the source's member list of `members`, replacing its previous one. `members` is a list of members, or for
    # `partial: true` either a list to include or { include: [...], exclude: [...] }. `settings` are the member list's.
    # Their precedence is set for the source on the association, their expiry is the member list's entry's and that
    # rule's, and both are given to every attribute the member list's pending items record. A wrapped member or
    # exclusion takes its wrapper's settings instead, and an expiry of its own other than the member list's is kept
    # among the member list's expiries (see MemberList). It replaces the previous member list as
    # `MemberList::Complete.replacing` and `MemberList::Partial.replacing` do. Raises for a partial list of a has_one,
    # and for members AssociationConfig rejects.
    def record(members, source, settings: RecordingSettings::DEFAULT, partial: false, recorded_at: Time.current)
      raise ArgumentError, "#{owner.class.name}##{config.name} is a has_one, which takes a complete list. Record it without mode: :partial" if partial && !config.collection?

      included, excluded = partial ? partial_members(members, settings) : [normalize_with_settings(members, settings), []]
      keys = included.map(&:first)
      config.assert_references_exist!(owner, keys)
      pending = included.map { |key_hash, attributes, member_settings| MemberList.pending_item(key_hash, attributes, recorded_at, settings: member_settings) }
      expiries = member_expiries(included + excluded, settings, recorded_at)

      value =
        if partial then MemberList::Partial.replacing(member_list(source), config, include: keys, exclude: excluded.map(&:first), pending: pending, expiries: expiries)
        else MemberList::Complete.replacing(member_list(source), config, include: keys, pending: pending, expiries: expiries)
        end
      owner.laforge.write_data_entry(config.name, value, source, settings: settings, recorded_at: recorded_at)
    end

    # Changes the source's member list for one member. A source with no member list, or an expired one, gets a partial
    # one. `action` is one of:
    # - :include: includes the member, and adds what the edit says about it as a pending item after the earlier ones, so
    #   each edit changes only the attributes it names. Its nested lists are edits too.
    # - :exclude: leaves the member out of a complete list, or adds it to a partial list's exclusions
    # - :forget: drops the member from a partial list, and the member list's tombstone when the member is one. Raises
    #   for a complete list, which covers every member.
    # Excluding or forgetting a member drops its pending items, and may withdraw it (see
    # `MemberList::Complete#excluding` and `MemberList::Partial#forgetting`). The member's inclusion or exclusion takes
    # the settings' expiry as its own, in place of any an earlier edit gave it, and forgetting the member drops its
    # expiry. The member list's entry keeps its own expiry, unless it has expired, when the new member list has none.
    # Raises for an expiry on an exclusion from a complete list, which cannot expire, for a wrapper on a member to
    # forget, and as `AssociationConfig#assert_references_exist!` and `AssociationConfig#assert_excludable!` do.
    def edit_member(member, source, action, recorded_at: Time.current, settings: RecordingSettings::DEFAULT)
      raise ArgumentError, "#{owner.class.name}##{config.name}: forgetting a member takes no settings; remove LaForge.with_settings around it" if action == :forget && RecordingSettings.wrapped?(member)

      (member, attributes, member_settings), = normalize_with_settings([member], settings, attributes: action == :include, edit: true)
      config.assert_references_exist!(owner, [member]) if action == :include
      config.assert_excludable!(owner, [member]) if action == :exclude
      previous = member_list(source)
      assert_editable!(previous, member, action, member_settings)

      expiry = MemberList.expiry_item(config.key_hash(member), member_settings, recorded_at) if member_settings.expiring?
      value =
        case action
        when :include then previous.including(config, member, MemberList.pending_item(member, attributes, recorded_at, edit: true, settings: member_settings), expiry: expiry)
        when :exclude then previous.excluding(config, member, expiry: expiry)
        when :forget then previous.forgetting(config, member)
        end
      owner.laforge.write_data_entry(config.name, value, source, settings: edit_entry_settings(source, settings), recorded_at: recorded_at)
    end

    # Expires at `recorded_at` the inclusions and exclusions in other sources' member lists on the owner that expire on
    # `source_id` and were made before `recorded_at` (see MemberList#expired_on)
    def expire_members_on(source_id, recorded_at)
      owner.laforge.filter_data_entries_in_memory(attributes: config.name).each do |entry|
        next if entry.source_id == source_id || entry.marked_for_destruction?

        saved = entry.new_record? ? [] : MemberList.new(entry.attribute_in_database('value')).expiries
        value = MemberList.new(entry.value).expired_on(source_id, recorded_at, saved: saved)
        entry.value = value if value
      end
    end

    # Returns the expiries in every one of the owner's member lists for the association, as
    # [{ source_id:, key:, expires_at:, expires_on_source_id: }]. Expired items are included, and so are the member
    # lists of inactive sources, expired member lists and member lists marked for destruction.
    def membership_expiries
      owner.laforge.filter_data_entries_in_memory(attributes: config.name).flat_map do |entry|
        MemberList.new(entry.value).expiries.map do |item|
          { source_id: entry.source_id, key: item['key'], expires_at: item['expires_at'] && Time.iso8601(item['expires_at']), expires_on_source_id: item['expires_on_source_id'] }
        end
      end
    end

    # Applies membership to the owner's members in memory, for the owner's save to write. Does nothing when no source
    # has a member list for the association.
    def forge
      return if member_lists.empty?

      include_removed_members
      recognize_tombstones(save: true)
      discard_created
      records = included_records + undecided.map { |key| existing.delete(key) } # one an earlier forge removed stays in the owner's pending writes
      forge_members(records)
      write_order(records) # after the members' forges, so list order wins over a position recorded on a member
      clear_pending
      prune_withdrawn
      entomb if config.tombstone_matcher
      remove_unclaimed(records)
    end

    # Returns what a forge would do to the members, without changing anything, or nil when no source has a member
    # list for the association:
    # - added: each member it would build, as its key, or as what the sources say about it for a new member
    # - removed: the key of each member it would remove
    # - changed: the key of each member whose pending items would change it, merged with those changes
    # - skipped: present only when it has members, the key of each one it would not build, because it is named by an id
    #   that is not one of the owner's, or because no source described it and it is invalid with its key alone
    def diff
      return if member_lists.empty?

      recognize_tombstones(save: false)
      changed = changed_members
      added, skipped = included.reject { |member| existing.key?(config.key_of(member)) }.partition { |member| buildable?(member) }

      {
        added: added.map { |member| added_member(member) },
        removed: (existing.keys - included_keys - undecided).map { |key| config.key.zip(key).to_h },
        changed: changed
      }.tap { |result| result[:skipped] = skipped.map { |member| config.key_hash(member) } if skipped.any? }
    end

    # Names each saved member of `created` by its id in every member list of the association that has not expired, in
    # place of its placeholder key. Each changed member list is saved at once and keeps its recorded_at, since its
    # source said nothing new.
    def name_created(created)
      names = created.select { |_, record| record.persisted? }.transform_values { |record| config.key_hash(record) }
      return if names.empty?

      owner.laforge.filter_data_entries_in_memory(attributes: config.name).each do |entry|
        next if entry.destroyed? || entry.marked_for_destruction? || entry.expired?

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

    # Returns the tombstones whose exclusions have not expired in the member lists a forge reads, which leaves out those
    # of inactive sources, expired entries and entries marked for destruction. The highest-precedence source's come
    # first, and each token once.
    def tombstones
      member_lists.reject { |entry, _| entry.marked_for_destruction? }
             .flat_map { |entry, list| list.counting_tombstones(config).map { |item| Tombstone.new(owner, config, entry.source_id, item) } }
             .uniq(&:token)
    end

    # Returns an unsaved member pointing at the owner, with the association scope's attributes and the member model's
    # columns among `attributes`, except its primary key.
    def unsaved_member(attributes)
      new_member(member_columns(RecordingSettings.strip(attributes)))
    end

    def member_sources(member)
      key = config.key_of(member)
      record = config.members_of(owner).find { |candidate| config.record_key(candidate) == key }
      candidates = record ? record.laforge.forging_entries.reject { |entry| entry.marked_for_destruction? || config.nested_config(entry.attribute_name) } : []
      record&.laforge&.reset_resolver_unless_held # a loaded member's selector value may have changed since it last ranked

      deciding = member_lists.find { |_, list| list.decision(config, key) }

      {
        membership: (deciding[0].source if deciding && deciding[1].decision(config, key) == :include),
        listed_by: member_lists.select { |_, list| list.decision(config, key) == :include }.map { |entry, _| entry.source },
        excluded_by: member_lists.select { |_, list| list.partial? && list.decision(config, key) == :exclude }.map { |entry, _| entry.source },
        attributes: record ? record.laforge.winning_entries(candidates).transform_values { |winner, _| winner.source } : {}
      }
    end

    private

    # Returns [included, excluded] for a partial list's `members`, a list to include or
    # { include: [...], exclude: [...] }, both as `normalize_with_settings` returns them. Raises for other keys in the
    # hash, and for an exclusion `AssociationConfig#assert_excludable!` rejects.
    def partial_members(members, settings)
      lists = members.is_a?(Hash) ? members.stringify_keys : { 'include' => members }
      unknown = lists.keys - %w[include exclude]
      if unknown.any?
        raise ArgumentError, "#{owner.class.name}##{config.name}: a partial list is given as a list of members or as { include:, exclude: }, not with #{unknown.join(', ')}. " \
                             'To forget a member, record it with mode: :edit'
      end

      included = normalize_with_settings(lists['include'] || [], settings)
      excluded = normalize_with_settings(lists['exclude'] || [], settings, attributes: false)
      config.assert_excludable!(owner, excluded.map(&:first))
      [included, excluded]
    end

    # Returns [[key hash, attributes, settings], ...] for `members`, normalized as `AssociationConfig#normalize_members`
    # does, each with its wrapper's settings or `settings`. Raises for a wrapper around the whole list, and as
    # `assert_member_precedence!` does.
    def normalize_with_settings(members, settings, attributes: true, edit: false)
      if RecordingSettings.wrapped?(members)
        raise ArgumentError, "#{owner.class.name}##{config.name}: LaForge.with_settings can wrap each member, or the association's whole value, not a list of members"
      end

      given = members.is_a?(Array) ? members.map { |member| settings.for(member) } : nil
      normalized = config.normalize_members(given ? given.map(&:first) : members, attributes: attributes, edit: edit)
      normalized.zip(given ? given.map(&:last) : Array.new(normalized.size, settings)).map do |(key_hash, member_attributes), member_settings|
        assert_member_precedence!(key_hash, member_attributes, member_settings, settings)
        [key_hash, member_attributes, member_settings]
      end
    end

    # Raises for a member with no attributes wrapped with a precedence other than the one `settings` give, since a
    # precedence ranks the source for the whole association
    def assert_member_precedence!(key_hash, attributes, member_settings, settings)
      return unless member_settings.precedence_given? && attributes.empty? && !(settings.precedence_given? && settings.precedence == member_settings.precedence)

      raise ArgumentError, "#{owner.class.name}##{config.name}: LaForge.with_settings(precedence:) around #{config.describe_key(config.key_of(key_hash))}, which has no attributes, " \
                           "would rank the source for the whole association. Pass the precedence for the call, or wrap the association's whole value"
    end

    # Returns an expiries item (see MemberList) for each of `members`, as `normalize_with_settings` returns them, whose
    # settings give an expiry other than the member list's `settings`
    def member_expiries(members, settings, recorded_at)
      members.filter_map do |key_hash, _, member_settings|
        MemberList.expiry_item(key_hash, member_settings, recorded_at) if member_settings.expiring? && member_settings.expiry != settings.expiry
      end
    end

    # Raises when the source's `previous` member list cannot take the edit `action` of `member`, with `member_settings`:
    # - forgetting a member of a complete list, which covers every member
    # - excluding a member from a complete list with an expiry, since that exclusion cannot expire
    def assert_editable!(previous, member, action, member_settings)
      return if previous.partial?

      described = config.describe_key(config.key_of(member))
      if action == :forget
        raise ArgumentError, "#{owner.class.name}##{config.name}: the source has a complete list, which covers every member, so forgetting #{described} " \
                             'would exclude it rather than leave it to other sources. Record the member list with mode: :partial first, or exclude the member'
      end
      return unless action == :exclude && member_settings.expiring?

      raise ArgumentError, "#{owner.class.name}##{config.name}: the source has a complete list, which excludes #{described} by leaving it out, " \
                           'and leaving a member out cannot expire. Record the member list with mode: :partial, or exclude the member from another source'
    end

    # Adds the members an earlier forge removed in the owner's pending writes to `existing`, so this forge can include
    # them again
    def include_removed_members
      owner.laforge.pending_writes.removed_members(config).each { |record| existing[config.record_key(record)] ||= record }
    end

    # Names each new member whose pending item the tombstone matcher matches to a tombstone by that tombstone's key in
    # the member lists, so membership decides it as the excluded member it was. With `save: true` the entries take the
    # renamed member lists too, to be saved with the owner. Leaves the member lists as they are when the association has
    # no tombstone matcher or no tombstones.
    def recognize_tombstones(save:)
      return unless config.tombstone_matcher

      known = tombstones
      return if known.empty?

      @member_lists = member_lists.map do |entry, list|
        next [entry, list] if entry.marked_for_destruction?

        names = list.pending.each_with_object({}) do |item, result|
          next unless config.new_member?(item['key'])

          found = match_tombstone(unsaved_member(item['attributes']), known)
          result[config.key_of(item['key'])] = found.key if found
        end
        next [entry, list] if names.empty?

        value = list.renamed(config, names)
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
    # existing member is taken out of `existing`, and its removal by an earlier forge is canceled (see `keep`). A member
    # that does not exist is the one an earlier forge built, or is built now, and is left out when it is skipped.
    def included_records
      included.filter_map do |member|
        key = config.key_of(member)
        items = pending.fetch(key, [])
        record = existing.delete(key)&.then { |kept| keep(kept) } || created[key] || add(member, described: items.any?)
        next unless record

        recorded = items.map { |source_id, attributes, recorded_at, edit, settings| record.laforge.record_pending(attributes, source_id, recorded_at, edit: edit, settings: settings) }
        recorded_on << record if recorded.any?
        record
      end
    end

    # Cancels an earlier forge's removal of `record`, and puts it back in the association when that forge took it out
    # unsaved (see `remove_unclaimed`)
    def keep(record)
      owner.laforge.pending_writes.cancel_removal(config, record)
      association.target << record if config.collection? && record.new_record? && association.target.none? { |member| member.equal?(record) }
      record
    end

    # Returns a member built for an included `member` that does not exist, or nil when it is skipped. A new member is
    # kept in `created` by its placeholder key, so a later forge before the save finds it. A member named by an id that
    # is not one of the owner's is skipped with a warning, since LaForge does not create a record with a given id. Any
    # other is built by `build`, which can skip it too.
    def add(member, described:)
      if config.primary_keyed? && !config.unsaved?(member)
        owner.logger&.warn("LaForge skipped #{config.klass.name} #{config.key_of(member).first.inspect} in #{owner.class.name} #{owner.id}'s #{config.name}: " \
                           "membership includes it, but it is no longer one of them. List it without its #{config.klass.primary_key} to create a new one")
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
                         'It is created when a source next lists it with its attributes')
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

    # Withdraws each source whose member list excludes or withdrew a member from that member, for each saved one of
    # `records`. Returns the members a withdrawn source had entries on, which need forging.
    def withdraw_from_members(records)
      records.select do |record|
        next false if record.new_record?

        key = config.record_key(record)
        withdrawing = member_lists.select { |_, list| list.decision(config, key) == :exclude || list.withdrew?(config, key) }
        withdrawing.map { |entry, _| record.laforge.withdraw(entry.source_id, owner) }.any?
      end
    end

    # Drops from the member lists the pending items of the included members, which the forge has recorded on them. A
    # member list whose inclusion of the member has expired keeps them, as the forge did not record them. Each member
    # list keeps its recorded_at, since its source said nothing new.
    def clear_pending
      member_lists.each do |entry, list|
        remaining = list.pending.reject { |item| included_keys.include?(config.key_of(item['key'])) && !list.expired?(config, config.key_of(item['key'])) }
        next if remaining.size == list.pending.size

        entry.value = list.with(pending: remaining)
      end
    end

    # Empties each member list's withdrawn list, which the forge has applied. A partial list left with no members and no
    # pending items is marked for destruction, to go with the owner's save, whether or not it withdrew any.
    def prune_withdrawn
      member_lists.each do |entry, _|
        next if entry.marked_for_destruction?

        list = MemberList.new(entry.value)
        if list.vacant?
          entry.mark_for_destruction
        elsif list.withdrawn.any?
          entry.value = list.with(withdrawn: [])
        end
      end
    end

    # Gives a tombstone to each member left in `existing`, which the forge removes, that a partial list excludes by an
    # exclusion that has not expired. Every member list that has not expired names the member by the tombstone's key in
    # place of its id. That includes inactive sources' member lists, so they still name it when the source is active
    # again. Each excluding member list keeps the tombstone.
    def entomb
      all_member_lists = owner.laforge.association_member_lists(config, inactive: true)
      existing.each_value do |record|
        key = config.record_key(record)
        excluding = member_lists.reject { |entry, _| entry.marked_for_destruction? }.select { |entry, _| MemberList.new(entry.value).then { |list| list.partial? && list.decision(config, key) == :exclude } }
        next if excluding.empty?

        tombstone = { AssociationConfig::TOMBSTONE => SecureRandom.hex(8) }
        item = MemberList.tombstone_item(tombstone, tombstone_attributes(record), Time.current)
        all_member_lists.each do |entry, _|
          next if entry.marked_for_destruction? || entry.expired?

          list = MemberList.new(MemberList.new(entry.value).renamed(config, { key => tombstone }))
          tombstones = excluding.any? { |excluder, _| excluder.equal?(entry) } ? list.tombstones + [item] : list.tombstones
          value = list.with(tombstones: tombstones)
          entry.value = value unless value == entry.value
        end
      end
    end

    # Returns the removed member's columns as JSON values, without its primary key, its timestamps and its link to the
    # owner
    def tombstone_attributes(record)
      member_columns(record.attributes).except('created_at', 'updated_at').transform_values(&:as_json)
    end

    # Removes each member left in `existing`, which the forge does not keep, per the association's `dependent:` option.
    # A collection member an earlier forge built, not saved yet, is taken out of the association, so the owner's save
    # does not insert it, and stays in the pending writes for a later forge to include again. A has_one's target becomes
    # the first of `records`.
    def remove_unclaimed(records)
      if config.collection?
        existing.each_value do |record|
          next owner.laforge.pending_writes.remove(config, record) unless record.new_record?

          association.target.delete(record)
          owner.laforge.pending_writes.remove_on_save(config, record)
        end
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

    # Returns the included `member`, which does not exist, as `diff` shows it added
    def added_member(member)
      return config.key_hash(member) unless config.unsaved?(member)

      pending.fetch(config.key_of(member), []).inject({}) { |attributes, (_, provided)| attributes.merge(RecordingSettings.strip(provided)) }
    end

    # Returns the member model's columns among `attributes`, without its primary key and its link to the owner
    def member_columns(attributes)
      attributes.slice(*config.klass.column_names).except(config.klass.primary_key, config.owner_foreign_key, config.owner_type_column)
    end

    # Returns a new member with the association scope's attributes and `attributes`, pointing at the owner but not in
    # the association
    def new_member(attributes)
      config.klass.new(association.scope.scope_for_create.merge(attributes)).tap do |member|
        member[config.owner_foreign_key] = config.owner_key(owner)
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

    # Returns [included, undecided], read from the member lists and `existing` when first called:
    # - included: the hashes of the members membership includes, the highest-precedence member list's first, without
    #   those whose referenced record does not exist
    # - undecided: the keys of the `existing` members a forge leaves as they are, which are those no member list names,
    #   and those no member list covers and none withdrew
    def resolution
      @resolution ||= begin
        decision = ->(key) { member_lists.lazy.filter_map { |_, list| list.decision(config, key) }.first }
        named = member_lists.flat_map { |_, list| list.listed_keys(config) }.map { |member| config.key_of(member) }.to_set

        candidates = member_lists.flat_map { |_, list| list.include }.uniq { |member| config.key_of(member) }
        included = config.drop_dangling(candidates.select { |member| decision.(config.key_of(member)) == :include })
        included_keys = included.map { |member| config.key_of(member) }

        undecided = existing.keys.reject do |key|
          included_keys.include?(key) || (named.include?(key) && (decision.(key) || member_lists.any? { |_, list| list.withdrew?(config, key) }))
        end

        [included, undecided]
      end
    end

    # Returns the member lists' pending items by member key, oldest first so they are recorded in the order the sources
    # provided them, as { key => [[source id, attributes, recorded_at, edit, settings], ...] }. The items of a member
    # whose inclusion in that member list has expired are left out.
    def pending
      @pending ||= begin
        items = member_lists.flat_map do |entry, list|
          RecordingSettings.without_deleted_sources(list.counting_pending(config)).map do |item|
            [config.key_of(item['key']), [entry.source_id, item['attributes'], Time.iso8601(item['recorded_at']), item['edit'] == true, RecordingSettings.from_item(item)]]
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

    # Returns the source's member list, or `MemberList.none` when it has none or its entry has expired. An expired
    # member list counts as if it did not exist, so one replacing it starts afresh and withdraws nothing. An entry
    # marked for destruction gives a member list that withdraws what it named, so a member list replacing it withdraws
    # those members.
    def member_list(source)
      entry = source_entry(source)
      entry && !entry.expired? ? MemberList.new(entry.value, marked: entry.marked_for_destruction?) : MemberList.none
    end

    # Returns `settings` for the source's entry an edit writes. They keep the entry's own expiry, unless it has
    # expired, when the edit starts a new member list with no expiry.
    def edit_entry_settings(source, settings)
      settings.with_entry_expiry(source_entry(source)&.expired? ? Expiring::NONE : nil)
    end

    def source_entry(source)
      owner.laforge.filter_data_entries_in_memory(attributes: config.name, sources: source).first
    end

    # Returns the association's entries in precedence order, each paired with its member list, as read when first called
    def member_lists
      @member_lists ||= owner.laforge.association_member_lists(config)
    end

    def association
      owner.association(config.name.to_sym)
    end
  end
end

module LaForge
  # Tracks has_many and has_one associations declared with `laforged associations:`.
  #
  # Each source's entry on the owner holds its report of the members by key (see MemberList). Membership is decided per
  # member by the highest-precedence report with an opinion on it.
  #
  # What a source says about a member besides its key is kept in its report as pending until a forge of the owner
  # includes the member, then recorded on the member as that source's entries, like any attributes recorded on the member
  # directly. So nothing is created for a member that membership excludes, its attributes wait in the report until
  # membership includes it, and a member's attributes are resolved on the member alone. The owner's forge forges the
  # members it records on; any other member is forged on its own.
  module AssociationTracking
    extend self

    def declare(owner_class, config)
      config.klass.laforged unless config.klass.respond_to?(:laforged_associations)
      config.reflection.autosave = true
    end

    # A complete report replaces the source's previous one. A partial report does too, and withdraws the members the
    # source reported before but no longer includes or excludes.
    def record(owner, config, members, source, precedence:, partial: false, recorded_at: Time.current)
      raise ArgumentError, "#{owner.class.name}##{config.name} is a has_one, which takes a complete report" if partial && !config.collection?

      if partial
        include, exclude = members.is_a?(Hash) ? [members.fetch(:include) { members['include'] } || [], members.fetch(:exclude) { members['exclude'] } || []] : [members, []]
        included = config.normalize_members(include)
        excluded = config.normalize_members(exclude, attributes: false).map(&:first)
      else
        included = config.normalize_members(members)
        excluded = []
      end
      keys = included.map(&:first)
      config.assert_references_exist!(owner, keys)
      pending = included.map { |key_hash, attributes| MemberList.pending_item(key_hash, attributes, recorded_at) }

      value =
        if partial
          reported = (keys + excluded).map { |member| config.key_of(member) }
          previous = report(owner, config, source)
          withdrawn = previous ? (previous.include + previous.withdrawn).map { |member| config.key_hash(member) }.uniq.reject { |member| reported.include?(config.key_of(member)) || config.new_member?(member) } : []
          MemberList.partial(include: keys, exclude: excluded, withdrawn: withdrawn, pending: pending)
        else
          MemberList.value(include: keys, pending: pending)
        end

      owner.send(:write_data_entry, config.name, value, source, precedence: precedence, recorded_at: recorded_at)
    end

    # Changes one member in the source's report: :include adds it, :exclude removes it even if other sources include
    # it, :forget drops the source's opinion on it. A source with no report, or a partial one, keeps a partial report.
    def edit_member(owner, config, member, source, action)
      member, attributes = config.normalize_members([member], attributes: action == :include).first
      config.assert_references_exist!(owner, [member]) if action == :include
      key = config.key_of(member)
      previous = report(owner, config, source)
      others = ->(list) { (list || []).reject { |listed| config.key_of(listed) == key } }
      pending = (previous&.pending || []).reject { |item| config.key_of(item['key']) == key }
      pending << MemberList.pending_item(member, attributes, Time.current) if action == :include

      value =
        if previous && !previous.partial?
          MemberList.value(include: others.(previous.include) + (action == :include ? [member] : []), pending: pending)
        else
          withdrawn = others.(previous&.withdrawn)
          withdrawn << config.key_hash(member) if action == :forget && previous&.decision(config, key) == :include
          MemberList.partial(include: others.(previous&.include) + (action == :include ? [member] : []),
                             exclude: others.(previous&.exclude) + (action == :exclude ? [config.key_hash(member)] : []),
                             withdrawn: withdrawn, pending: pending)
        end

      owner.send(:write_data_entry, config.name, value, source)
    end

    # Each source whose report excludes or withdrew a member the forge keeps is withdrawn from that member, as the source
    # no longer says anything about it: its entries on the member go, and its reports there become withdrawals, which the
    # member's forge applies in turn. Returns the members to forge.
    def withdraw_from_members(owner, config, reports, records)
      records.select do |record|
        next false if record.new_record?

        key = config.record_key(record)
        withdrawing = reports.select { |_, report| report.decision(config, key) == :exclude || report.withdrew?(config, key) }
        withdrawing.map { |entry, _| record.laforge_withdraw(entry.source_id, owner) }.any?
      end
    end

    # The source no longer reports anything for the association: every member it reported is withdrawn, and what it said
    # about members not yet recorded on them is dropped, along with new members it reported that were never created
    def withdraw(config, entry)
      entry.value = MemberList.partial(withdrawn: MemberList.new(entry.value).reported_keys(config).reject { |member| config.new_member?(member) })
    end

    def forge(owner, config)
      reports = owner.send(:laforge_association_reports, config)
      return if reports.empty?

      existing = config.identified_members_of(owner)
      created = owner.laforge_created_members(config)
      included, undecided = resolve(config, reports, existing)
      pending = pending_by_key(config, reports)
      included_keys = included.map { |member| config.key_of(member) }
      discard_created(owner, config, created, included_keys)

      described = []
      records = included.filter_map do |member|
        key = config.key_of(member)
        items = pending.fetch(key, [])
        record = existing.delete(key) || created[key] || add(owner, config, member, created, described: items.any?)
        next unless record

        recorded = items.map { |source_id, attributes, recorded_at| record.laforge_record_reported(attributes, source_id, recorded_at) }
        described << record if recorded.any?
        record
      end
      records += undecided.map { |key| existing.delete(key) }
      records.each_with_index do |record, index|
        record[config.order_column] = index if config.order_column
      end

      described += withdraw_from_members(owner, config, reports, records)
      described.uniq.each(&:forge)
      clear_pending(config, reports, included_keys)
      prune_withdrawn(config, reports)

      if config.collection?
        existing.each_value { |record| config.remove(record) }
      else
        owner.association(config.name.to_sym).target = records.first
        existing.each_value { |record| owner.laforge_remove_on_save(config, record) }
      end
    end

    # Members a forge would add, remove and change, and those it would skip because no source described them and they are
    # invalid with their key alone, without changing anything
    def diff(owner, config)
      reports = owner.send(:laforge_association_reports, config)
      return if reports.empty?

      existing = config.identified_members_of(owner)
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
        next false if config.primary_keyed? && !config.new_member?(member) # no longer one of the owner's members

        pending.key?(config.key_of(member)) || new_member(owner, config, config.build_attributes(member)).valid?
      end

      {
        added: added.map { |member| config.new_member?(member) ? pending.fetch(config.key_of(member), []).inject({}) { |attributes, (_, reported)| attributes.merge(reported) } : config.key_hash(member) },
        removed: (existing.keys - keys).map { |key| config.key.zip(key).to_h },
        changed: changed
      }.tap { |result| result[:skipped] = skipped.map { |member| config.key_hash(member) } if skipped.any? }
    end

    def source_values(owner_class, config, records)
      owner_ids = records.map(&:id)
      entries = DataEntry.where(record_type: owner_class.base_class.name, record_id: owner_ids, attribute_name: config.name).preload(:source).to_a

      member_scope = config.klass.where(config.owner_foreign_key => owner_ids)
      member_scope = member_scope.where(config.owner_type_column => owner_class.polymorphic_name) if config.owner_type_column
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
            pending = report.pending.find { |item| config.key_of(item['key']) == config.key_of(member) }
            with_member_attributes(config, member, rows[config.key_of(member)], member_entries, source, pending)
          end
          unlisted = rows.values.reject { |record| listed.any? { |member| config.key_of(member) == config.record_key(record) } }
                         .select { |record| (member_entries[record.id] || []).any? { |entry| entry.source == source } }
                         .map { |record| with_member_attributes(config, config.key_hash(record), record, member_entries, source, nil) }
          [source, listed + unlisted]
        end

        result[owner_id] = values if values.any?
      end
    end

    # Names the members forges created by their new ids, in place of the placeholders the reports named them by. Called
    # once the owner, and so the members, have been saved. The reports' recorded_at is kept, since no source said anything.
    def name_created(owner, config, created)
      ids = created.select { |_, record| record.persisted? }.transform_values(&:id)
      return if ids.empty?

      owner.send(:filter_data_entries_in_memory, attributes: config.name).each do |entry|
        next if entry.destroyed? || entry.marked_for_destruction?

        value = MemberList.new(entry.value).renamed(config, ids)
        entry.update!(value: value) unless value == entry.value
      end
    end

    def member_sources(owner, config, member)
      reports = owner.send(:laforge_association_reports, config)
      key = config.key_of(member)
      record = config.members_of(owner).find { |candidate| config.record_key(candidate) == key }
      candidates = record ? record.send(:filter_data_entries_in_memory).reject { |entry| entry.marked_for_destruction? || config.nested_config(entry.attribute_name) } : []

      deciding = reports.find { |_, report| report.decision(config, key) }

      {
        membership: (deciding[0].source if deciding && deciding[1].decision(config, key) == :include),
        listed_by: reports.select { |_, report| report.decision(config, key) == :include }.map { |entry, _| entry.source },
        excluded_by: reports.select { |_, report| report.partial? && report.decision(config, key) == :exclude }.map { |entry, _| entry.source },
        attributes: candidates.group_by(&:attribute_name).transform_values { |list| DataEntry.in_precedence_order(list, record: record).first.source }
      }
    end

    private

    # { key values => [[source id, attributes, recorded at], ...] } for what the reports say about members besides their
    # keys and has not yet been recorded on them, oldest first, so the entries are created in the order they were reported
    def pending_by_key(config, reports)
      items = reports.flat_map do |entry, report|
        report.pending.map { |item| [config.key_of(item['key']), [entry.source_id, item['attributes'], Time.iso8601(item['recorded_at'])]] }
      end
      items.sort_by { |_, (_, _, recorded_at)| recorded_at }.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    end

    # Removes from the association the members an earlier forge created, not yet saved, that membership no longer includes
    def discard_created(owner, config, created, included_keys)
      (created.keys - included_keys).each do |key|
        record = created.delete(key)
        owner.association(config.name.to_sym).target.delete(record) if config.collection?
      end
    end

    # A member that membership includes but that does not exist. A new member is built and kept by its placeholder, so
    # a second forge before saving finds it, and saving names it by its id. A member named by an id that is no longer one
    # of the owner's is skipped, since LaForge does not create a record with a given id. Any other is built from its key.
    def add(owner, config, member, created, described:)
      if config.primary_keyed? && !config.new_member?(member)
        owner.logger&.warn("LaForge skipped #{config.klass.name} #{config.key_of(member).first.inspect} in #{owner.class.name} #{owner.id}'s #{config.name}: " \
                           "membership includes it, but it is no longer one of them. Report it without its #{config.klass.primary_key} to create a new one")
        return
      end

      record = build(owner, config, member, described: described)
      created[config.key_of(member)] = record if record && config.new_member?(member)
      record
    end

    # A new member built as the association's `build` would, with its scope's attributes. A collection member is added to
    # the association; a has_one member is not, since Rails writes a has_one replacement immediately, and the owner
    # removes the current one when it is saved. Returns nil, after logging, for a member that no source described and
    # that is invalid with its key alone.
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

    # A new member with the association scope's attributes, pointing at the owner, but not in the association
    def new_member(owner, config, key_hash)
      config.klass.new(owner.association(config.name.to_sym).scope.scope_for_create.merge(key_hash)).tap do |member|
        member[config.owner_foreign_key] = owner.id
        member[config.owner_type_column] = owner.class.polymorphic_name if config.owner_type_column
      end
    end

    # Drops from the reports what they say about the included members, which the forge has now recorded on them. The
    # report's recorded_at is kept, since the source said nothing new.
    def clear_pending(config, reports, keys)
      reports.each do |entry, report|
        remaining = report.pending.reject { |item| keys.include?(config.key_of(item['key'])) }
        next if remaining.size == report.pending.size

        entry.value = report.with_pending(remaining)
      end
    end

    # Drops the withdrawn keys the forge has now settled. A partial report left with nothing in it is destroyed with the
    # owner's next save, since the source no longer says anything about the association.
    def prune_withdrawn(config, reports)
      reports.each do |entry, _|
        next if entry.marked_for_destruction?

        report = MemberList.new(entry.value)
        next unless report.partial? && report.withdrawn.any?

        if report.include.empty? && report.exclude.empty? && report.pending.empty?
          entry.mark_for_destruction
        else
          entry.value = MemberList.partial(include: report.include, exclude: report.exclude, pending: report.pending)
        end
      end
    end

    # The source's own current report on the owner, if it has one
    def report(owner, config, source)
      entry = owner.send(:filter_data_entries_in_memory, attributes: config.name, sources: source).first
      MemberList.new(entry.value) if entry && !entry.marked_for_destruction?
    end

    # The member hashes the reports include, in order (the highest-precedence report's order first), and the keys of
    # existing rows that no report has an opinion on and none withdrew, which are left as they are
    def resolve(config, reports, existing)
      decision = ->(key) { reports.lazy.filter_map { |_, report| report.decision(config, key) }.first }

      candidates = reports.flat_map { |_, report| report.include }.uniq { |member| config.key_of(member) }
      included = config.drop_dangling(candidates.select { |member| decision.(config.key_of(member)) == :include })
      included_keys = included.map { |member| config.key_of(member) }

      undecided = existing.keys.reject do |key|
        included_keys.include?(key) || decision.(key) || reports.any? { |_, report| report.withdrew?(config, key) }
      end

      [included, undecided]
    end

    # A member's values from a source: its key from the source's list, with the source's entries on the member and what
    # the source's report says about it that has not been recorded on it yet, unless the member has a newer value
    def with_member_attributes(config, member, record, member_entries, source, pending)
      entries = record ? (member_entries[record.id] || []).select { |entry| entry.source == source } : []
      member = config.build_attributes(member)
      values = entries.to_h { |entry| [entry.attribute_name, entry.value] }
      if pending
        recorded_at = Time.iso8601(pending['recorded_at'])
        newer = entries.select { |entry| entry.recorded_at && entry.recorded_at > recorded_at }.map(&:attribute_name)
        values.merge!(pending['attributes'].except(*newer))
      end
      member.merge(values)
    end
  end
end

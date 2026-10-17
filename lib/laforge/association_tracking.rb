module LaForge
  # Tracks has_many and has_one associations declared with `laforged associations:`.
  #
  # Each source's entry on the owner holds its report of the members by key (see MemberList). Membership is decided per
  # member by the highest-precedence report with an opinion on it.
  #
  # What a source says about a member besides its key is held on the owner until it is forged, then recorded on the
  # member as that source's entries, like any attributes recorded on the member directly. So nothing is created for a
  # member that membership excludes, and a member's attributes are resolved on the member alone. The owner's forge
  # forges the members it records on; any other member is forged on its own.
  module AssociationTracking
    extend self

    def declare(owner_class, config)
      config.klass.laforged unless config.klass.respond_to?(:laforged_associations)
      config.reflection.autosave = true
    end

    # A complete report replaces the source's previous one. A partial report does too, and withdraws the members the
    # source reported before but no longer includes or excludes.
    def record(owner, config, members, source, precedence:, partial: false)
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
      config.assert_references_exist!(keys)

      value =
        if partial
          reported = (keys + excluded).map { |member| config.key_of(member) }
          previous = report(owner, config, source)
          withdrawn = previous ? (previous.include + previous.withdrawn).map { |member| config.key_hash(member) }.uniq.reject { |member| reported.include?(config.key_of(member)) } : []
          MemberList.partial(include: keys, exclude: excluded, withdrawn: withdrawn)
        else
          keys
        end

      owner.laforge_member_data(config)[DataSource.normalize_source_id(source)] = included.to_h { |key_hash, attributes| [config.key_of(key_hash), attributes] }.reject { |_, attributes| attributes.empty? }
      owner.send(:write_data_entry, config.name, value, source, precedence: precedence)
    end

    # Changes one member in the source's report: :include adds it, :exclude removes it even if other sources include
    # it, :forget drops the source's opinion on it. A source with no report, or a partial one, keeps a partial report.
    def edit_member(owner, config, member, source, action)
      member, attributes = config.normalize_members([member], attributes: action == :include).first
      config.assert_references_exist!([member]) if action == :include
      key = config.key_of(member)
      previous = report(owner, config, source)
      others = ->(list) { (list || []).reject { |listed| config.key_of(listed) == key } }

      value =
        if previous && !previous.partial?
          others.(previous.include) + (action == :include ? [member] : [])
        else
          withdrawn = others.(previous&.withdrawn)
          withdrawn << config.key_hash(member) if action == :forget && previous&.decision(config, key) == :include
          MemberList.partial(include: others.(previous&.include) + (action == :include ? [member] : []),
                             exclude: others.(previous&.exclude) + (action == :exclude ? [config.key_hash(member)] : []),
                             withdrawn: withdrawn)
        end

      data = owner.laforge_member_data(config)[DataSource.normalize_source_id(source)] ||= {}
      data.delete(key)
      data[key] = attributes if attributes.any?
      owner.send(:write_data_entry, config.name, value, source)
    end

    # The source no longer reports anything for the association: every member it reported is withdrawn
    def withdraw(owner, config, entry)
      owner.laforge_member_data(config).delete(entry.source_id)
      entry.value = MemberList.partial(withdrawn: MemberList.new(entry.value).reported_keys(config))
    end

    def forge(owner, config)
      reports = owner.send(:laforge_association_reports, config)
      return if reports.empty?

      existing = config.identified_members_of(owner)
      included, undecided = resolve(config, reports, existing)
      data = owner.laforge_member_data(config)

      described = []
      records = included.filter_map do |member|
        key = config.key_of(member)
        attributes = member_attributes(data, key)
        record = existing.delete(key) || build(owner, config, config.key_hash(member), described: attributes.any?)
        next unless record

        if attributes.any?
          attributes.each { |source_id, values| record.record_data_entries(values, source_id) }
          described << record
        end
        record
      end
      records += undecided.map { |key| existing.delete(key) }
      records.each_with_index do |record, index|
        record[config.order_column] = index if config.order_column
      end

      described.each(&:forge)
      data.clear

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
      data = owner.laforge_member_data(config)
      keys = included.map { |member| config.key_of(member) } + undecided

      changed = included.filter_map do |member|
        record = existing[config.key_of(member)]
        attributes = member_attributes(data, config.key_of(member))
        next unless record && attributes.any?

        changes = record.laforge_forge_diff_with(attributes)
        config.key_hash(record).merge(changes) if changes.any?
      end

      added, skipped = included.reject { |member| existing.key?(config.key_of(member)) }.partition do |member|
        member_attributes(data, config.key_of(member)).any? || new_member(owner, config, config.key_hash(member)).valid?
      end

      {
        added: added.map { |member| config.key_hash(member) },
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
        lists = entries.select { |entry| entry.record_id == owner_id }.to_h { |entry| [entry.source, MemberList.new(entry.value).include] }
        rows = (members_by_owner[owner_id] || []).reject { |record| config.blank_key?(config.record_key(record)) }.index_by { |record| config.record_key(record) }
        sources = (lists.keys + rows.values.flat_map { |record| (member_entries[record.id] || []).map(&:source) }).uniq

        values = sources.to_h do |source|
          listed = (lists[source] || []).map { |member| with_member_attributes(config, member, rows[config.key_of(member)], member_entries, source) }
          unlisted = rows.values.reject { |record| listed.any? { |member| config.key_of(member) == config.record_key(record) } }
                         .select { |record| (member_entries[record.id] || []).any? { |entry| entry.source == source } }
                         .map { |record| with_member_attributes(config, config.key_hash(record), record, member_entries, source) }
          [source, listed + unlisted]
        end

        result[owner_id] = values if values.any?
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

    # [[source id, attributes], ...] that sources said about the member with the given key, in the order they were recorded
    def member_attributes(data, key)
      data.filter_map { |source_id, by_key| [source_id, by_key[key]] if by_key.key?(key) }
    end

    # A new member built as the association's `build` would, with its scope's attributes. A collection member is added to
    # the association; a has_one member is not, since Rails writes a has_one replacement immediately, and the owner
    # removes the current one when it is saved. Returns nil, after logging, for a member that no source described and
    # that is invalid with its key alone.
    def build(owner, config, key_hash, described:)
      association = owner.association(config.name.to_sym)
      record = config.collection? ? association.build(key_hash) : new_member(owner, config, key_hash)
      return record if described || record.valid?

      association.target.delete(record) if config.collection?
      owner.logger&.warn("LaForge skipped the #{config.klass.name} with #{config.describe_key(config.key_of(key_hash))} in #{owner.class.name} #{owner.id}'s #{config.name}: " \
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

    # A member's values from a source: its key from the source's list, with the source's entries on the member
    def with_member_attributes(config, member, record, member_entries, source)
      return member unless record

      member.merge((member_entries[record.id] || []).select { |entry| entry.source == source }.to_h { |entry| [entry.attribute_name, entry.value] })
    end
  end
end

module LaForge
  # Tracks has_many and has_one associations declared with `laforged associations:`.
  #
  # Each source's entry on the owner holds its report of the members exactly as the source made it: keys, attributes and
  # nested lists (see MemberList). Membership is decided per member by the highest-precedence report with an opinion on
  # it. A member's attributes are resolved on the member itself, from every report that includes it (whether or not
  # that report decided its membership) together with the entries recorded directly on the member, ranked by the
  # member's precedence rules. Nothing reported through a list is copied onto the member.
  module AssociationTracking
    extend self

    def declare(owner_class, config)
      config.klass.laforged unless config.klass.respond_to?(:laforged_associations)
      config.klass.laforge_owner_configs += [config]
      config.reflection.autosave = true
    end

    # A complete report replaces the source's previous one. A partial report does too, and withdraws the members the
    # source reported before but no longer includes or excludes.
    def record(owner, config, members, source, precedence:, partial: false)
      raise ArgumentError, "#{owner.class.name}##{config.name} is a has_one, which takes a complete report" if partial && !config.collection?

      value =
        if partial
          include, exclude = members.is_a?(Hash) ? [members.fetch(:include) { members['include'] } || [], members.fetch(:exclude) { members['exclude'] } || []] : [members, []]
          include = config.normalize_members(include)
          exclude = config.normalize_members(exclude).map { |member| config.key_hash(member) }
          config.assert_references_exist!(include)

          reported = (include + exclude).map { |member| config.key_of(member) }
          previous = report(owner, config, source)
          withdrawn = previous ? (previous.include + previous.withdrawn).map { |member| config.key_hash(member) }.uniq.reject { |member| reported.include?(config.key_of(member)) } : []
          MemberList.partial(include: include, exclude: exclude, withdrawn: withdrawn)
        else
          config.normalize_members(members).tap { |list| config.assert_references_exist!(list) }
        end

      owner.send(:write_data_entry, config.name, value, source, precedence: precedence)
    end

    # Changes one member in the source's report: :include adds it, :exclude removes it even if other sources include
    # it, :forget drops the source's opinion on it. A source with no report, or a partial one, keeps a partial report.
    def edit_member(owner, config, member, source, action)
      member = config.normalize_members([member]).first
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

      owner.send(:write_data_entry, config.name, value, source)
    end

    # The source no longer reports anything for the association: every member it reported is withdrawn
    def withdraw(owner, config, entry)
      entry.value = MemberList.partial(withdrawn: MemberList.new(entry.value).reported_keys(config))
    end

    def forge(owner, config)
      reports = owner.send(:laforge_association_reports, config)
      return if reports.empty?

      existing = config.members_of(owner).index_by { |record| config.record_key(record) }
      included, undecided = resolve(config, reports, existing)

      records = included.map { |member| existing.delete(config.key_of(member)) || build(owner, config, config.key_hash(member)) }
      records += undecided.map { |key| existing.delete(key) }
      records.each_with_index do |record, index|
        record[config.order_column] = index if config.order_column
        record.laforge_list_owner!(config, owner)
      end

      records.each(&:forge)
      if config.collection?
        existing.each_value { |record| config.remove(record) }
      else
        owner.association(config.name.to_sym).target = records.first
        existing.each_value { |record| owner.laforge_remove_on_save(config, record) }
      end
    end

    def diff(owner, config)
      reports = owner.send(:laforge_association_reports, config)
      return if reports.empty?

      existing = config.members_of(owner).index_by { |record| config.record_key(record) }
      included, undecided = resolve(config, reports, existing)
      keys = included.map { |member| config.key_of(member) } + undecided
      kept = keys.filter_map { |key| existing[key] }
      kept.each { |record| record.laforge_list_owner!(config, owner) }

      {
        added: included.reject { |member| existing.key?(config.key_of(member)) }.map { |member| config.key_hash(member) },
        removed: (existing.keys - keys).map { |key| config.key.zip(key).to_h },
        changed: kept.filter_map { |record| (changes = record.forge_diff).any? && config.key_hash(record).merge(changes) }
      }
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
        rows = (members_by_owner[owner_id] || []).index_by { |record| config.record_key(record) }
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
      record&.laforge_list_owner!(config, owner)
      candidates = record ? record.send(:laforge_candidate_entries).reject { |entry| config.nested_config(entry.attribute_name) } : []

      deciding = reports.find { |_, report| report.decision(config, key) }

      {
        membership: (deciding[0].source if deciding && deciding[1].decision(config, key) == :include),
        listed_by: reports.select { |_, report| report.decision(config, key) == :include }.map { |entry, _| entry.source },
        excluded_by: reports.select { |_, report| report.partial? && report.decision(config, key) == :exclude }.map { |entry, _| entry.source },
        attributes: candidates.group_by(&:attribute_name).transform_values { |list| DataEntry.in_precedence_order(list, record: record).first.source }
      }
    end

    private

    # A new member: added to a has_many collection, or built for a has_one without replacing the current one yet, since
    # Rails writes a has_one replacement immediately. The owner removes the current one when it is saved.
    def build(owner, config, attributes)
      return owner.association(config.name.to_sym).reader.build(attributes) if config.collection?

      config.klass.new(attributes).tap do |record|
        record[config.owner_foreign_key] = owner.id
        record[config.owner_type_column] = owner.class.polymorphic_name if config.owner_type_column
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

    # A member's values in a source's report: what the list says about it, overlaid with that source's direct entries
    def with_member_attributes(config, member, record, member_entries, source)
      return member unless record

      member.merge((member_entries[record.id] || []).select { |entry| entry.source == source }.to_h { |entry| [entry.attribute_name, entry.value] })
    end
  end
end

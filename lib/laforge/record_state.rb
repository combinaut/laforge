module LaForge
  # Used to hold what LaForge keeps for one laforged record, its pending writes and the precedence resolver of its last
  # forge, and the low-level methods bound to the record that LaForge's own objects call. Reached through
  # `record.laforge`.
  class RecordState
    def initialize(record)
      @record = record
    end

    # Returns `forge_diff` as it would be once `reported` is recorded on the record, then restores the record's entries
    # and rules. `reported` is what its owner's reports say about it, as
    # [[source id, attributes, recorded_at, edit, precedence], ...].
    def forge_diff_with(reported)
      entries = @record.data_entries.to_a
      values = entries.to_h { |entry| [entry, [entry.value, entry.recorded_at, entry.marked_for_destruction?]] }
      rules = @record.precedence_rules.to_a # recording with a precedence builds or changes rules, which the owner's next save writes
      precedences = rules.to_h { |rule| [rule, [rule.precedence, rule.marked_for_destruction?]] }
      reported.each { |source_id, attributes, recorded_at, edit, precedence| record_reported(attributes, source_id, recorded_at, edit: edit, precedence: precedence) }
      @record.forge_diff
    ensure
      @record.data_entries.target.replace(entries)
      values.each { |entry, (value, recorded_at, marked)| entry.value = value; entry.recorded_at = recorded_at; LaForge::ActiveRecord.set_marked_for_destruction(entry, marked) }
      @record.precedence_rules.target.replace(rules)
      precedences.each { |rule, (precedence, marked)| rule.precedence = precedence; LaForge::ActiveRecord.set_marked_for_destruction(rule, marked) }
    end

    # Records one attribute, without checking its group
    def record_attribute(attribute_name, value, source, precedence: NOT_GIVEN)
      reflection = @record.class.reflect_on_association(attribute_name)
      if reflection&.belongs_to?
        return reference_columns(reflection, value).each { |column, column_value| write_data_entry(column, column_value, source, precedence: precedence) }
      end

      raise InvalidAttributeName, "#{@record.class.name}##{attribute_name} is not a tracked association" if reflection
      raise InvalidAttributeName, "Cannot set #{attribute_name} on #{@record.class.name}" unless @record.respond_to?("#{attribute_name}=")
      raise InvalidValue, "Cannot record #{value.class} for #{@record.class.name}##{attribute_name}; values are stored as JSON, so record a string, number, boolean, date, nil, or an array or hash of those" unless DataEntry.storable?(value)

      write_data_entry(attribute_name, value, source, precedence: precedence)
    end

    # Records what the source's report on the record's owner said about it at `recorded_at`, which the owner validated
    # when recording the report. An attribute the record has a newer entry for from the same source is left out, so an
    # older report does not undo it. With `edit`, nested lists are recorded as edits. `precedence` covers everything
    # recorded, nested lists included. Returns whether anything was recorded.
    def record_reported(attributes, source, recorded_at, edit: false, precedence: NOT_GIVEN)
      newer = filter_data_entries_in_memory(sources: source).select { |entry| entry.recorded_at && entry.recorded_at > recorded_at }.map(&:attribute_name)
      attributes = attributes.except(*newer)

      attributes.each do |attribute_name, value|
        if (config = @record.laforged_associations[attribute_name]) && edit && config.collection?
          TrackedAssociation.new(@record, config).edit(value, source, precedence: precedence, recorded_at: recorded_at)
        elsif config
          TrackedAssociation.new(@record, config).record(value, source, precedence: precedence, recorded_at: recorded_at)
        else
          write_data_entry(attribute_name, value, source, precedence: precedence, recorded_at: recorded_at)
        end
      end
      attributes.any?
    end

    # Withdraws the source from the record, a member of `owner`, in memory, as `owner`'s forge does when the source's
    # report there excludes or has withdrawn it. The source's attribute entries are dropped, to be destroyed when
    # `owner` is saved, and each of its reports in the record's tracked associations withdraws every member it named.
    # Returns whether the source had any entry on the record not marked for destruction.
    def withdraw(source_id, owner)
      entries = filter_data_entries_in_memory(sources: source_id).reject(&:marked_for_destruction?)
      entries.each do |data_entry|
        if (config = @record.laforged_associations[data_entry.attribute_name])
          data_entry.value = MemberList.new(data_entry.value).withdrawing_all(config)
        else
          @record.data_entries.target.delete(data_entry)
          owner.laforge.pending_writes.delete_entry(data_entry) if data_entry.persisted?
        end
      end
      entries.any?
    end

    # Makes the record's pending writes once it is saved, then drops them
    def write_pending_writes!
      pending_writes.write!
      @pending_writes = nil
    end

    # Returns the record's pending writes (see PendingWrites), which forges add to and its next save makes
    def pending_writes
      @pending_writes ||= PendingWrites.new(@record)
    end

    # Returns the association's entries in precedence order, each paired with its report (see MemberList). Inactive
    # sources' entries are left out unless `inactive` is true.
    def association_reports(config, inactive: false)
      entries = inactive ? filter_data_entries_in_memory(attributes: config.name) : forging_entries(attributes: config.name)
      by_precedence(entries).map { |data_entry| [data_entry, MemberList.new(data_entry.value, marked: data_entry.marked_for_destruction?)] }
    end

    # Returns { attribute_name => [winning entry, the attribute's entry from the winning source] } for `entries`. They
    # are the same entry for an attribute outside a group. For a group, the winner is the highest-ranked entry for any
    # of its attributes, and each attribute takes that source's entry, or nil when it has none.
    def winning_entries(entries)
      entries = by_precedence(entries)
      entries.each_with_object({}) do |entry, winners|
        next if winners.key?(entry.attribute_name)

        group = @record.class.laforge_attribute_group(entry.attribute_name)
        next winners[entry.attribute_name] = [entry, entry] unless group

        @record.class.laforged_attribute_groups.fetch(group).each do |attribute_name|
          winners[attribute_name] = [entry, entries.find { |candidate| candidate.attribute_name == attribute_name && candidate.source_id == entry.source_id }]
        end
      end
    end

    # Returns the entries matching the filters that forging reads, leaving out those of inactive sources and of
    # `except_sources`
    def forging_entries(attributes: nil, sources: nil, except_sources: nil)
      left_out = DataSource.inactive_ids + DataSource.normalize_source_ids(except_sources)
      filter_data_entries_in_memory(attributes: attributes, sources: sources).reject { |data_entry| left_out.include?(data_entry.source_id) }
    end

    # Writes the source's entry for the attribute in memory, and the precedence rule for the attribute, or its attribute
    # group, when `precedence` is given. Recording onto an entry marked for destruction undoes the unsaved removal.
    def write_data_entry(attribute_name, value, source, precedence: NOT_GIVEN, recorded_at: Time.current)
      data_entry = filter_data_entries_in_memory(attributes: attribute_name, sources: source).first
      data_entry ||= @record.data_entries.build(attribute_name: attribute_name, source_id: DataSource.normalize_source_id(source))
      LaForge::ActiveRecord.set_marked_for_destruction(data_entry, false)
      data_entry.value = value
      data_entry.recorded_at = recorded_at if data_entry.new_record? || data_entry.will_save_change_to_value?
      write_precedence_rule(@record.class.laforge_attribute_group(attribute_name) || attribute_name, source, precedence) unless precedence.equal?(NOT_GIVEN)
    end

    # Sets the record's rule for the attribute and source in memory, and returns it. With a nil `precedence`, marks a
    # saved rule for destruction and returns it, or otherwise drops any unsaved rule and returns nil.
    def write_precedence_rule(attribute_name, source, precedence)
      source_id = DataSource.normalize_source_id(source)
      rule = @record.precedence_rules.find { |candidate| candidate.attribute_name == attribute_name.to_s && candidate.source_id == source_id }

      if precedence.nil?
        return unless rule

        if rule.new_record?
          @record.precedence_rules.target.delete(rule)
          return
        end
        rule.mark_for_destruction
      else
        rule ||= @record.precedence_rules.build(attribute_name: attribute_name.to_s, source_id: source_id)
        LaForge::ActiveRecord.set_marked_for_destruction(rule, false) # setting a precedence again undoes an unsaved removal
        rule.precedence = precedence
      end
      rule
    end

    # Returns the record's entries matching the filters, from the in-memory association: every saved
    # entry (loaded on first use), plus entries built but not yet saved and entries marked for destruction.
    def filter_data_entries_in_memory(attributes: nil, sources: nil)
      list = @record.data_entries.to_a

      unless attributes.nil?
        attributes = Array.wrap(attributes).map(&:to_s)
        list.select! {|data_entry| attributes.include?(data_entry.attribute_name) }
      end

      unless sources.nil?
        source_ids = Array.wrap(sources).map {|source| DataSource.normalize_source_id(source) }
        list.select! {|data_entry| source_ids.include?(data_entry.source_id) }
      end

      return list
    end

    # Returns the effective precedence of `data_entry` on the record
    def precedence_of(data_entry)
      resolver.precedence(@record, data_entry.attribute_name, data_entry.source_id)
    end

    # Returns the rank of `data_entry`'s source for its attribute on the record (see `PrecedenceRule::Resolver#rank`)
    def rank_of(data_entry)
      resolver.rank(@record, data_entry.attribute_name, data_entry.source_id)
    end

    # Whether one source's value for an attribute of the record outranks another's
    def outranks?(attribute_name, source_id, other_source_id)
      rank = ->(id) { resolver.rank(@record, attribute_name, id) }
      (rank.(source_id) <=> rank.(other_source_id)) == 1
    end

    # Returns the precedence resolver the record ranks by, kept until `reset_resolver`
    def resolver
      @resolver ||= PrecedenceRule::Resolver.new(@record.class)
    end

    # Forgets the model-wide and global rules the resolver read, so the next ranking reads them again
    def reset_resolver
      @resolver = nil
    end

    private

    # Returns { foreign_key => id, foreign_type => class name } for `target`, a record or nil, assigned to the
    # belongs_to `reflection`, foreign_type only when it is polymorphic. Raises unless `target` is nil or a saved record
    # of a class the association takes.
    def reference_columns(reflection, target)
      unless target.nil? || target.is_a?(::ActiveRecord::Base)
        raise InvalidValue, "#{@record.class.name}##{reflection.name} must be recorded as a record or nil, not #{target.class}"
      end
      raise InvalidValue, "Cannot record an unsaved #{target.class.name} for #{@record.class.name}##{reflection.name}" if target&.new_record?
      if target && !reflection.polymorphic? && !target.is_a?(reflection.klass)
        raise InvalidValue, "#{@record.class.name}##{reflection.name} must be a #{reflection.klass.name}, not #{target.class.name}"
      end

      primary_key = reflection.polymorphic? ? target&.class&.primary_key : reflection.association_primary_key
      columns = { reflection.foreign_key.to_s => target && target[primary_key] }
      columns[reflection.foreign_type.to_s] = target&.class&.polymorphic_name if reflection.polymorphic?
      columns
    end

    def by_precedence(entries)
      DataEntry.in_precedence_order(entries, record: @record)
    end
  end
end

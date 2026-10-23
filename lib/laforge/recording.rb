module LaForge
  # Used to record what sources say about a laforged record, as its data entries and its tracked associations' reports
  module Recording
    # Record a single piece of information from a source.
    # Optionally pass `precedence` to set this record's precedence for the attribute and source, saved with the record.
    # Omitting it keeps an existing precedence, and passing nil removes it.
    # Pass a record or nil for a belongs_to association, which is recorded as its foreign key, and its type when
    # polymorphic.
    # A tracked association's value is a complete report, and the shapes a Rails form submits raise, as in the default
    # mode of `record_data_entries`.
    # Raises for an attribute in an attribute group, whose attributes are recorded together with `record_data_entries`.
    def record_data_entry(attribute_name, value, source, precedence: NOT_GIVEN)
      self.class.laforge_assert_whole_groups!([attribute_name], where: "Recording #{self.class.name}##{attribute_name}")
      record_data_entries({ attribute_name => value }, source, precedence: precedence)
    end

    # Record several pieces of information from the same source.
    # `mode:` says what kind of report a tracked association's value is (see MemberList):
    # - :complete (the default): a complete report, given as the list of members it includes
    # - :partial: a partial report, given as the list of members it includes or as { include: [...], exclude: [...] }
    # - :edit: changes to the source's report for the members named, given as a list of members to include or as
    #   { include: [...], exclude: [...], forget: [...] }. The rest of the report is kept, and the members' nested lists
    #   are edits too. The shapes a Rails form submits, `*_attributes` for a tracked association and `*_ids`, are
    #   accepted (see Payload).
    # A complete or partial report replaces the source's previous one.
    # A member is a hash of its key and what the source says about it (see TrackedAssociation), or a saved record.
    # Where members are keyed by primary key, a hash without an id is a new member.
    # `precedence:` covers everything the call records, members' attributes included (see `record_data_entry`).
    # The attributes of an attribute group are recorded together, on the record and on members alike.
    def record_data_entries(attributes_hash, source, precedence: NOT_GIVEN, mode: :complete)
      raise ArgumentError, "Unknown mode #{mode.inspect}; pass :complete, :partial or :edit" unless %i[complete partial edit].include?(mode)

      edit = mode == :edit
      payload = Payload.translate(self.class, attributes_hash, (self unless new_record?), edit: edit, owner: self)
      self.class.laforge_assert_whole_groups!(payload.keys.reject { |attribute_name| laforged_associations.key?(attribute_name.to_s) }, where: "Recording #{self.class.name}")
      payload.each do |attribute_name, value|
        if edit && (config = laforged_associations[attribute_name.to_s])
          TrackedAssociation.new(self, config).edit(value, source, precedence: precedence)
        elsif (config = laforged_associations[attribute_name.to_s])
          options = { precedence: precedence }
          options[:partial] = true if mode == :partial
          TrackedAssociation.new(self, config).record(value, source, **options)
        else
          laforge_record_attribute(attribute_name, value, source, precedence: precedence)
        end
      end
    end

    # Mark several data entries for destruction, so they are destroyed when the record is saved and a forge leaves them
    # out. To blank an attribute instead, record nil for it.
    # Optionally pass `attribute_names` to remove only the entries for those attributes, and `sources` to remove only
    # the entries from those sources. An attribute in a group removes the entries for its whole group.
    def remove_data_entries(attribute_names: nil, sources: nil)
      attribute_names = self.class.laforge_with_groups(attribute_names) unless attribute_names.nil?
      filter_data_entries_in_memory(attributes: attribute_names, sources: sources).each do |data_entry|
        data_entry.mark_for_destruction
      end
    end

    # Destroys the source's attribute entries on this record and withdraws every member its reports in tracked
    # associations named, as when the source no longer reports the record. Saved immediately, without forging.
    # Precedence rules for the source are kept.
    def withdraw_source(source)
      transaction do
        filter_data_entries_in_memory(sources: source).each do |data_entry|
          if (config = laforged_associations[data_entry.attribute_name])
            data_entry.value = MemberList.new(data_entry.value).withdrawing_all(config)
            data_entry.save! if data_entry.persisted?
          else
            data_entries.destroy(data_entry)
          end
        end
      end
    end

    # @api private
    # Records one attribute, without checking its group
    def laforge_record_attribute(attribute_name, value, source, precedence: NOT_GIVEN)
      reflection = self.class.reflect_on_association(attribute_name)
      if reflection&.belongs_to?
        return laforge_reference_columns(reflection, value).each { |column, column_value| write_data_entry(column, column_value, source, precedence: precedence) }
      end

      raise InvalidAttributeName, "#{self.class.name}##{attribute_name} is not a tracked association" if reflection
      raise InvalidAttributeName, "Cannot set #{attribute_name} on #{self.class.name}" unless respond_to?("#{attribute_name}=")
      raise InvalidValue, "Cannot record #{value.class} for #{self.class.name}##{attribute_name}; values are stored as JSON, so record a string, number, boolean, date, nil, or an array or hash of those" unless DataEntry.storable?(value)

      write_data_entry(attribute_name, value, source, precedence: precedence)
    end

    # @api private
    # Withdraws the source from this record, a member of `owner`, in memory, as `owner`'s forge does when the source's
    # report there excludes or has withdrawn it. The source's attribute entries are dropped, to be destroyed when
    # `owner` is saved, and each of its reports in this record's tracked associations withdraws every member it named.
    # Returns whether the source had any entry on this record not marked for destruction.
    def laforge_withdraw(source_id, owner)
      entries = filter_data_entries_in_memory(sources: source_id).reject(&:marked_for_destruction?)
      entries.each do |data_entry|
        if (config = laforged_associations[data_entry.attribute_name])
          data_entry.value = MemberList.new(data_entry.value).withdrawing_all(config)
        else
          data_entries.target.delete(data_entry)
          owner.laforge_destroy_on_save(data_entry) if data_entry.persisted?
        end
      end
      entries.any?
    end

    # @api private
    # Records what the source's report on this record's owner said about it at `recorded_at`, which the owner validated
    # when recording the report. An attribute this record has a newer entry for from the same source is left out, so an
    # older report does not undo it. With `edit`, nested lists are recorded as edits. `precedence` covers everything
    # recorded, nested lists included. Returns whether anything was recorded.
    def laforge_record_reported(attributes, source, recorded_at, edit: false, precedence: NOT_GIVEN)
      newer = filter_data_entries_in_memory(sources: source).select { |entry| entry.recorded_at && entry.recorded_at > recorded_at }.map(&:attribute_name)
      attributes = attributes.except(*newer)

      attributes.each do |attribute_name, value|
        if (config = laforged_associations[attribute_name]) && edit && config.collection?
          TrackedAssociation.new(self, config).edit(value, source, precedence: precedence, recorded_at: recorded_at)
        elsif config
          TrackedAssociation.new(self, config).record(value, source, precedence: precedence, recorded_at: recorded_at)
        else
          write_data_entry(attribute_name, value, source, precedence: precedence, recorded_at: recorded_at)
        end
      end
      attributes.any?
    end

    private

    # Writes the source's entry for the attribute in memory, and the precedence rule for the attribute, or its attribute
    # group, when `precedence` is given. Recording onto an entry marked for destruction undoes the unsaved removal.
    def write_data_entry(attribute_name, value, source, precedence: NOT_GIVEN, recorded_at: Time.current)
      data_entry = filter_data_entries_in_memory(attributes: attribute_name, sources: source).first
      data_entry ||= data_entries.build(attribute_name: attribute_name, source_id: DataSource.normalize_source_id(source))
      LaForge::ActiveRecord.set_marked_for_destruction(data_entry, false)
      data_entry.value = value
      data_entry.recorded_at = recorded_at if data_entry.new_record? || data_entry.will_save_change_to_value?
      write_precedence_rule(self.class.laforge_attribute_group(attribute_name) || attribute_name, source, precedence) unless precedence.equal?(NOT_GIVEN)
    end

    # Returns { foreign_key => id, foreign_type => class name } for `target`, a record or nil, assigned to the
    # belongs_to `reflection`, foreign_type only when it is polymorphic. Raises unless `target` is nil or a saved record
    # of a class the association takes.
    def laforge_reference_columns(reflection, target)
      unless target.nil? || target.is_a?(::ActiveRecord::Base)
        raise InvalidValue, "#{self.class.name}##{reflection.name} must be recorded as a record or nil, not #{target.class}"
      end
      raise InvalidValue, "Cannot record an unsaved #{target.class.name} for #{self.class.name}##{reflection.name}" if target&.new_record?
      if target && !reflection.polymorphic? && !target.is_a?(reflection.klass)
        raise InvalidValue, "#{self.class.name}##{reflection.name} must be a #{reflection.klass.name}, not #{target.class.name}"
      end

      primary_key = reflection.polymorphic? ? target&.class&.primary_key : reflection.association_primary_key
      columns = { reflection.foreign_key.to_s => target && target[primary_key] }
      columns[reflection.foreign_type.to_s] = target&.class&.polymorphic_name if reflection.polymorphic?
      columns
    end
  end
end

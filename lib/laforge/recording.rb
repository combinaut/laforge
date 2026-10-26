module LaForge
  # Used to record what sources say about a laforged record, as its data entries and its tracked associations' reports
  module Recording
    extend ActiveSupport::Concern

    API = %i[record_data_entry record_data_entries remove_data_entries withdraw_source].freeze

    # RECORDED_COLUMNS are the columns of an entry that a recording makes the change again by changing (see Expiring)
    RECORDED_COLUMNS = %w[value expires_at expires_on_source_id].freeze

    # Record a single piece of information from a source.
    # Optionally pass `precedence` to set this record's precedence for the attribute and source, saved with the record.
    # Omitting it keeps an existing precedence, and passing nil removes it.
    # Pass a record or nil for a belongs_to association, which is recorded as its foreign key, and its type when
    # polymorphic.
    # A tracked association's value is a complete report, and the shapes a Rails form submits raise, as in the default
    # mode of `record_data_entries`.
    # `expires_at:` and `expires_on:` expire the entry, and a precedence passed with it, as for `record_data_entries`. A
    # value wrapped with `LaForge.with_settings` takes the wrapper's settings.
    # Raises for an attribute in an attribute group, whose attributes are recorded together with `record_data_entries`.
    def record_data_entry(attribute_name, value, source, precedence: NOT_GIVEN, expires_at: nil, expires_on: nil)
      self.class.assert_whole_groups!([attribute_name], where: "Recording #{record.class.name}##{attribute_name}")
      record_data_entries({ attribute_name => value }, source, precedence: precedence, expires_at: expires_at, expires_on: expires_on)
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
    # `expires_at:` and `expires_on:` expire what the call records, and a precedence passed with it (see Expiring).
    # Recording again replaces the expiry, and leaving them out clears it. A complete or partial report expires as a
    # whole, and what it says about its members is recorded on them with the same expiry. An edit's expiry goes to each
    # member it includes or excludes and to a precedence passed with it, and not to the report (see MemberList).
    # A part of the payload wrapped with `LaForge.with_settings` takes the wrapper's settings in place of the call's.
    def record_data_entries(attributes_hash, source, precedence: NOT_GIVEN, mode: :complete, expires_at: nil, expires_on: nil)
      raise ArgumentError, "Unknown mode #{mode.inspect}; pass :complete, :partial or :edit" unless %i[complete partial edit].include?(mode)

      where = "Recording #{record.class.name}"
      settings = RecordingSettings.given(precedence: precedence, expires_at: expires_at, expires_on: expires_on, source: source, where: where)
      RecordingSettings.assert_wrappers_valid!(attributes_hash.to_h, DataSource.normalize_source_id(source), where: where)
      edit = mode == :edit
      payload = Payload.translate(record.class, attributes_hash, (record unless record.new_record?), edit: edit, owner: record)
      self.class.assert_whole_groups!(payload.keys.reject { |attribute_name| associations.key?(attribute_name.to_s) }, where: where)
      RecordingSettings.assert_groups_alike!(record.class, payload, where: where)
      payload.each do |attribute_name, value|
        value, field_settings = settings.for(value)
        if edit && (config = associations[attribute_name.to_s])
          TrackedAssociation.new(record, config).edit(value, source, settings: field_settings)
        elsif (config = associations[attribute_name.to_s])
          TrackedAssociation.new(record, config).record(value, source, settings: field_settings, partial: mode == :partial)
        else
          record_attribute(attribute_name, value, source, settings: field_settings)
        end
      end
    end

    # Mark several data entries for destruction, so they are destroyed when the record is saved and a forge leaves them
    # out. To blank an attribute instead, record nil for it.
    # Optionally pass `attribute_names` to remove only the entries for those attributes, and `sources` to remove only
    # the entries from those sources. An attribute in a group removes the entries for its whole group.
    def remove_data_entries(attribute_names: nil, sources: nil)
      attribute_names = self.class.with_groups(attribute_names) unless attribute_names.nil?
      filter_data_entries_in_memory(attributes: attribute_names, sources: sources).each do |data_entry|
        data_entry.mark_for_destruction
      end
    end

    # Destroys the source's attribute entries on this record and withdraws every member its reports in tracked
    # associations named, as when the source no longer reports the record. Saved immediately, without forging.
    # Precedence rules for the source are kept.
    def withdraw_source(source)
      record.transaction do
        filter_data_entries_in_memory(sources: source).each do |data_entry|
          if (config = associations[data_entry.attribute_name])
            data_entry.value = MemberList.new(data_entry.value).withdrawing_all(config)
            data_entry.save! if data_entry.persisted?
          else
            record.data_entries.destroy(data_entry)
          end
        end
      end
    end

    # @api private
    # Records one attribute, without checking its group. A `belongs_to` is recorded as its reference columns (see
    # `reference_columns`). Raises for any other association LaForge does not track, an attribute with no setter, a
    # value wrapped with settings, and a value JSON cannot store.
    def record_attribute(attribute_name, value, source, settings: RecordingSettings::DEFAULT)
      reflection = record.class.reflect_on_association(attribute_name)
      if reflection&.belongs_to?
        return reference_columns(reflection, value).each { |column, column_value| write_data_entry(column, column_value, source, settings: settings) }
      end

      raise InvalidAttributeName, "#{record.class.name}##{attribute_name} is not a tracked association" if reflection
      raise InvalidAttributeName, "Cannot set #{attribute_name} on #{record.class.name}" unless record.respond_to?("#{attribute_name}=")
      RecordingSettings.assert_none_in!(value, where: "Recording #{record.class.name}##{attribute_name}")
      raise InvalidValue, "Cannot record #{value.class} for #{record.class.name}##{attribute_name}; values are stored as JSON, so record a string, number, boolean, date, nil, or an array or hash of those" unless DataEntry.storable?(value)

      write_data_entry(attribute_name, value, source, settings: settings)
    end

    # @api private
    # Records what the source's report on the record's owner said about it at `recorded_at`, which the owner validated
    # when recording the report. An attribute the record has a newer entry for from the same source is left out, so an
    # older report does not undo it. With `edit`, nested lists are recorded as edits. `settings` cover everything
    # recorded, nested lists included, except a part wrapped with settings of its own. What this records is made at
    # `recorded_at` (see Expiring). Returns whether anything was recorded.
    def record_reported(attributes, source, recorded_at, edit: false, settings: RecordingSettings::DEFAULT)
      newer = filter_data_entries_in_memory(sources: source).select { |entry| entry.recorded_at && entry.recorded_at > recorded_at }.map(&:attribute_name)
      attributes = attributes.except(*newer)

      @replaying = true
      attributes.each do |attribute_name, value|
        value, field_settings = settings.for(value)
        if (config = associations[attribute_name]) && edit && config.collection?
          TrackedAssociation.new(record, config).edit(value, source, settings: field_settings, recorded_at: recorded_at)
        elsif config
          TrackedAssociation.new(record, config).record(value, source, settings: field_settings, recorded_at: recorded_at)
        else
          write_data_entry(attribute_name, value, source, settings: field_settings, recorded_at: recorded_at)
        end
      end
      attributes.any?
    ensure
      @replaying = false
    end

    # @api private
    # Withdraws the source from the record, a member of `owner`, in memory, as `owner`'s forge does when the source's
    # report there excludes or has withdrawn it. The source's attribute entries are dropped, to be destroyed when
    # `owner` is saved, and each of its reports in the record's tracked associations withdraws every member it named.
    # Returns whether the source had any entry on the record not marked for destruction.
    def withdraw(source_id, owner)
      entries = filter_data_entries_in_memory(sources: source_id).reject(&:marked_for_destruction?)
      entries.each do |data_entry|
        if (config = associations[data_entry.attribute_name])
          data_entry.value = MemberList.new(data_entry.value).withdrawing_all(config)
        else
          record.data_entries.target.delete(data_entry)
          owner.laforge.pending_writes.delete_entry(data_entry) if data_entry.persisted?
        end
      end
      entries.any?
    end

    # @api private
    # Writes the source's entry for the attribute in memory, with the settings' entry expiry, and the precedence rule
    # for the attribute, or its attribute group, when the settings give a precedence. Then expires the record's changes
    # for the attribute that expire on the source (see `expire_on_recording`). Recording onto an entry marked for
    # destruction undoes the unsaved removal.
    def write_data_entry(attribute_name, value, source, settings: RecordingSettings::DEFAULT, recorded_at: Time.current)
      source_id = DataSource.normalize_source_id(source)
      data_entry = filter_data_entries_in_memory(attributes: attribute_name, sources: source_id).first
      data_entry ||= record.data_entries.build(attribute_name: attribute_name, source_id: source_id)
      LaForge::ActiveRecord.set_marked_for_destruction(data_entry, false)
      before = data_entry.attributes.slice(*RECORDED_COLUMNS)
      data_entry.value = value
      settings.apply_to_entry(data_entry)
      note_recorded(data_entry, recorded_at, before)
      rule_name = self.class.group_of(attribute_name) || attribute_name.to_s
      rule = write_precedence_rule(rule_name, source_id, settings, made_at: (recorded_at if @replaying)) if settings.precedence_given?
      expire_on_recording(rule_name, source_id, recorded_at)
      expire_replayed(rule_name, recorded_at, [data_entry, rule]) if @replaying
    end

    # @api private
    # Expires `rows`, an entry and a rule a replay of a report made at `recorded_at` has just written, on a recording
    # their expiry's source made between the report and the replay. That recording found nothing waiting, since the
    # rows did not exist yet. The source's entries for the attribute, attribute group or association show when it last
    # recorded them, and the earliest after `recorded_at` counts. A recording that changed nothing leaves no trace.
    def expire_replayed(rule_name, recorded_at, rows)
      attribute_names = attribute_groups.fetch(rule_name) { [rule_name] }
      rows.compact.filter_map(&:expires_on_source_id).uniq.each do |trigger_id|
        later = filter_data_entries_in_memory(attributes: attribute_names, sources: trigger_id).filter_map(&:recorded_at).select { |time| time > recorded_at }.min
        expire_on_recording(rule_name, trigger_id, later) if later
      end
    end

    # @api private
    # Returns the record's entries matching the filters, from the in-memory association: every saved
    # entry (loaded on first use), plus entries built but not yet saved and entries marked for destruction.
    def filter_data_entries_in_memory(attributes: nil, sources: nil)
      list = record.data_entries.to_a

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

    private

    # Sets the entry's `recorded_at` and notes the change made again (see Expiring#remade) when this recording creates
    # the entry or changes its value or expiry, from what is saved or from `before`, the columns as they were in memory.
    # An expiry on a source that fired in memory and is set back as saved is a change too. A recording replayed from a
    # pending report makes it at `recorded_at`.
    def note_recorded(data_entry, recorded_at, before)
      changed = before != data_entry.attributes.slice(*RECORDED_COLUMNS) || RECORDED_COLUMNS.any? { |column| data_entry.will_save_change_to_attribute?(column) }
      return unless data_entry.new_record? || changed

      data_entry.recorded_at = recorded_at
      data_entry.remade((recorded_at if @replaying))
    end

    # Expires at `recorded_at` each change for the attribute, attribute group or association `rule_name` that expires on
    # the source and was made before `recorded_at`, among:
    # - the record's entries for it
    # - the record's own rules for it
    # - for a tracked association, the inclusions and exclusions in other sources' reports
    # Any recording counts, whether or not it changes a value. One from a report kept pending counts at the time it was
    # reported.
    def expire_on_recording(rule_name, source_id, recorded_at)
      attribute_names = attribute_groups.fetch(rule_name) { [rule_name] }
      waiting = filter_data_entries_in_memory(attributes: attribute_names) + record.precedence_rules.select { |rule| rule.attribute_name == rule_name }
      waiting.each do |row|
        row.expire(recorded_at) if row.expires_on_source_id == source_id && recorded_at > row.changed_at
      end
      TrackedAssociation.new(record, associations[rule_name]).expire_members_on(source_id, recorded_at) if associations.key?(rule_name)
    end

    # Returns { foreign_key => key, foreign_type => class name } for `target`, a record or nil, assigned to the
    # belongs_to `reflection`, foreign_type only when it is polymorphic. The key is the column `primary_key:` names, or
    # the target's primary key. Raises unless `target` is nil or a saved record of a class the association takes.
    def reference_columns(reflection, target)
      unless target.nil? || target.is_a?(::ActiveRecord::Base)
        raise InvalidValue, "#{record.class.name}##{reflection.name} must be recorded as a record or nil, not #{target.class}"
      end
      raise InvalidValue, "Cannot record an unsaved #{target.class.name} for #{record.class.name}##{reflection.name}" if target&.new_record?
      if target && !reflection.polymorphic? && !target.is_a?(reflection.klass)
        raise InvalidValue, "#{record.class.name}##{reflection.name} must be a #{reflection.klass.name}, not #{target.class.name}"
      end

      primary_key = reflection.polymorphic? ? target && reflection.association_primary_key(target.class) : reflection.association_primary_key
      columns = { reflection.foreign_key.to_s => target && target[primary_key] }
      columns[reflection.foreign_type.to_s] = target&.class&.polymorphic_name if reflection.polymorphic?
      columns
    end
  end
end

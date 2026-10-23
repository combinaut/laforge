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
          laforge.record_attribute(attribute_name, value, source, precedence: precedence)
        end
      end
    end

    # Mark several data entries for destruction, so they are destroyed when the record is saved and a forge leaves them
    # out. To blank an attribute instead, record nil for it.
    # Optionally pass `attribute_names` to remove only the entries for those attributes, and `sources` to remove only
    # the entries from those sources. An attribute in a group removes the entries for its whole group.
    def remove_data_entries(attribute_names: nil, sources: nil)
      attribute_names = self.class.laforge_with_groups(attribute_names) unless attribute_names.nil?
      laforge.filter_data_entries_in_memory(attributes: attribute_names, sources: sources).each do |data_entry|
        data_entry.mark_for_destruction
      end
    end

    # Destroys the source's attribute entries on this record and withdraws every member its reports in tracked
    # associations named, as when the source no longer reports the record. Saved immediately, without forging.
    # Precedence rules for the source are kept.
    def withdraw_source(source)
      transaction do
        laforge.filter_data_entries_in_memory(sources: source).each do |data_entry|
          if (config = laforged_associations[data_entry.attribute_name])
            data_entry.value = MemberList.new(data_entry.value).withdrawing_all(config)
            data_entry.save! if data_entry.persisted?
          else
            data_entries.destroy(data_entry)
          end
        end
      end
    end
  end
end

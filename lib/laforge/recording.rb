module LaForge
  # Used to record what sources say about a laforged record, as its data entries
  module Recording
    extend ActiveSupport::Concern

    API = %i[record_data_entry record_data_entries remove_data_entries].freeze

    # Record a single piece of information from a source.
    # Optionally pass `precedence` to set this record's precedence for the attribute and source, saved with the record.
    # Omitting it keeps an existing precedence, and passing nil removes it.
    def record_data_entry(attribute_name, value, source, precedence: NOT_GIVEN)
      record_data_entries({ attribute_name => value }, source, precedence: precedence)
    end

    # Record several pieces of information from the same source.
    # `precedence:` covers everything the call records (see `record_data_entry`).
    def record_data_entries(attributes_hash, source, precedence: NOT_GIVEN)
      attributes_hash.each do |attribute_name, value|
        record_attribute(attribute_name, value, source, precedence: precedence)
      end
    end

    # Mark several data entries for destruction, so they are destroyed when the record is saved and a forge leaves them
    # out. To blank an attribute instead, record nil for it.
    # Optionally pass `attribute_names` to remove only the entries for those attributes, and `sources` to remove only
    # the entries from those sources.
    def remove_data_entries(attribute_names: nil, sources: nil)
      filter_data_entries_in_memory(attributes: attribute_names, sources: sources).each do |data_entry|
        data_entry.mark_for_destruction
      end
    end

    # @api private
    # Records one attribute. Raises for an attribute with no setter.
    def record_attribute(attribute_name, value, source, precedence: NOT_GIVEN)
      raise InvalidAttributeName, "Cannot set #{attribute_name} on #{record.class.name}" unless record.respond_to?("#{attribute_name}=")

      write_data_entry(attribute_name, value, source, precedence: precedence)
    end

    # @api private
    # Writes the source's entry for the attribute in memory, and the precedence rule for the attribute when
    # `precedence` is given.
    def write_data_entry(attribute_name, value, source, precedence: NOT_GIVEN)
      data_entry = filter_data_entries_in_memory(attributes: attribute_name, sources: source).first
      data_entry ||= record.data_entries.build(attribute_name: attribute_name, source_id: DataSource.normalize_source_id(source))
      data_entry.value = value
      write_precedence_rule(attribute_name, source, precedence) unless precedence.equal?(NOT_GIVEN)
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
  end
end

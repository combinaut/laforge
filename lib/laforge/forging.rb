module LaForge
  # Used to forge a laforged record's attributes from its data entries
  module Forging
    extend ActiveSupport::Concern

    API = %i[forge! forge forge_diff forge_attributes].freeze

    # Assign attributes and save the record based on the data entries
    def forge!(**forge_options, &block)
      record.transaction do
        block.call if block_given?
        record.forge(**forge_options) # through the model, so a `forge` it defines after `laforged` runs here too
        record.save!
      end
    end

    # Assign attributes based on the data entries
    def forge(attributes: nil, sources: nil)
      record.attributes = forge_attributes(attributes: attributes, sources: sources)
    end

    # Returns a hash of the attribute changes between the saved record and the data entries
    def forge_diff(**forge_options)
      diff = {}
      forge_attrs = forge_attributes(**forge_options)
      record_attrs = record.slice(*forge_attrs.keys)

      record_attrs.each do |key, value|
        diff[key] = [value, forge_attrs[key]] if forge_attrs[key] != value
      end

      return diff
    end

    # Returns a hash of the attributes generated from the record's the data entries
    # Optionally pass `attributes` to limit data entries used in the calculation to only those for the given attributes
    # Optionally pass `sources` to limit data entries used in the calculation to only those from the given sources
    # Optionally pass `except_sources` to leave out the entries of the given sources, as when asking what would be
    # forged without one source's values
    # An attribute in `attributes` brings in the rest of its group. The entries of inactive sources are left out.
    # Entries marked for destruction are left out, so each of their attributes takes the value of the next entry, and an
    # attribute with no other entry is left out of the hash.
    # An attribute of a group is nil when the source that supplies the group has no entry for it.
    def forge_attributes(attributes: nil, sources: nil, except_sources: nil)
      reset_resolver # each forge reads the model-wide and global rules again (see PrecedenceCache)
      forged_attrs = {}
      attributes = self.class.with_groups(attributes) unless attributes.nil?
      data_entries = forging_entries(attributes: attributes, sources: sources, except_sources: except_sources).reject { |data_entry| data_entry.marked_for_destruction? }
      winners = winning_entries(data_entries)

      # The hash's key order is the order `forge` calls the setters, which matters when one setter
      # resets another attribute. It is by the rank of each attribute's highest-ranked entry, highest first,
      # and a group's attributes come together where the first of them would. Attributes whose entries
      # rank equally come in no defined order.
      assignment_order = self.class.with_groups(data_entries.sort_by { |data_entry| rank_of(data_entry) }.reverse.map(&:attribute_name).uniq)

      assignment_order.each do |attribute_name|
        next unless record.respond_to?("#{attribute_name}=")

        data_entry = winners.fetch(attribute_name).last
        forged_attrs[attribute_name] = data_entry&.value
      end

      return forged_attrs
    end

    # @api private
    # Returns { attribute_name => [winning entry, the attribute's entry from the winning source] } for `entries`. They
    # are the same entry for an attribute outside a group. For a group, the winner is the highest-ranked entry for any
    # of its attributes, and each attribute takes that source's entry, or nil when it has none.
    def winning_entries(entries)
      entries = by_precedence(entries)
      entries.each_with_object({}) do |entry, winners|
        next if winners.key?(entry.attribute_name)

        group = self.class.group_of(entry.attribute_name)
        next winners[entry.attribute_name] = [entry, entry] unless group

        attribute_groups.fetch(group).each do |attribute_name|
          winners[attribute_name] = [entry, entries.find { |candidate| candidate.attribute_name == attribute_name && candidate.source_id == entry.source_id }]
        end
      end
    end

    # @api private
    # Returns the entries matching the filters that forging reads, leaving out those of inactive sources and of
    # `except_sources`
    def forging_entries(attributes: nil, sources: nil, except_sources: nil)
      left_out = DataSource.inactive_ids + DataSource.normalize_source_ids(except_sources)
      filter_data_entries_in_memory(attributes: attributes, sources: sources).reject { |data_entry| left_out.include?(data_entry.source_id) }
    end

    private

    def by_precedence(entries)
      DataEntry.in_precedence_order(entries, record: record)
    end
  end
end

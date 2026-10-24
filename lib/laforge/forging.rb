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
    # Entries marked for destruction are left out, so each of their attributes takes the value of the next entry, and an
    # attribute with no other entry is left out of the hash.
    def forge_attributes(attributes: nil, sources: nil)
      reset_resolver # each forge reads the model-wide and global rules again (see PrecedenceCache)
      forged_attrs = {}
      data_entries = filter_data_entries_in_memory(attributes: attributes, sources: sources).reject { |data_entry| data_entry.marked_for_destruction? }
      winners = DataEntry.in_precedence_order(data_entries, record: record).uniq(&:attribute_name).index_by(&:attribute_name)

      # The hash's key order is the order `forge` calls the setters, which matters when one setter
      # resets another attribute. It is by each attribute's highest effective precedence, highest first.
      # Attributes that share one come in no defined order.
      assignment_order = data_entries.sort_by { |data_entry| precedence_of(data_entry) }.reverse.map(&:attribute_name).uniq

      assignment_order.each do |attribute_name|
        next unless record.respond_to?("#{attribute_name}=")

        forged_attrs[attribute_name] = winners.fetch(attribute_name).value
      end

      return forged_attrs
    end
  end
end

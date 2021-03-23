# TODO: create generator to generate tables
module LaForge
  module ActiveRecord
    def self.laforged
      has_many :data_entries, dependent: :delete_all, class_name: 'LaForge::DataEntry'
      has_many :data_sources, through: :source_data_entries, class_name: 'LaForge::DataSource'

      scope :from_data_source, ->(source) { joins(:data_entries).merge(DataEntry.from_source(source)) }
      scope :with_attribute_from_data_source, ->(attribute, source) { joins(:data_entries).merge(DataEntry.for_attribute(attribute).from_source(source)) }
      scope :without_data_source, ->(source = nil) { source.nil? ? left_outer_joins(:data_entries).where(data_entries: { source_id: nil }) : left_outer_joins(:data_entries).where.not(data_entries: { source_id: source }) }
      scope :without_attribute_from_data_source, ->(attribute, source = nil) { source.nil? ? left_outer_joins(:data_entries).merge(DataEntry.for_attribute(attribute)).where(data_entries: { source_id: nil }) : left_outer_joins(:data_entries).merge(DataEntry.for_attribute(attribute)).where.not(data_entries: { source_id: source }) }

      extend ClassMethods
      include InstanceMethods
    end
  end

  module ClassMethods
    # Create a record from the given data entries
    def forge!(data_entries)

    end
  end

  module InstanceMethods
    # Assign attributes and save the record based on the data entries
    def forge!(**forge_options)
      forge(**forge_options)
      save!
    end

    # Assign attributes based on the data entries
    def forge(**forge_options)
      self.attributes = forge_attributes(**forge_options)
    end

    # Returns a hash of the attribute changes between the saved record and the data entries
    def forge_diff(**forge_options)
      diff = {}
      forge_attrs = forge_attributes(**forge_options)
      record_attrs = slice(*forge_attrs.keys)

      record_attrs.each do |key, value|
        diff[key] = [value, forge_attrs[key]] if forge_attrs[key] != value
      end

      return diff
    end

    # Returns a hash of the attributes generated from the record's the data entries
    # Optionally pass `attributes` to limit data entries used in the calculation to only those for the given attributes
    # Optionally pass `sources` to limit data entries used in the calculation to only those from the given sources
    def forge_attributes(attributes: nil, sources: nil)
      forged_attrs = {}
      filter_loaded_data_entries(attributes: attributes, sources: sources, present: true).sort_by(&:priority_with_fallback).reverse.uniq_by(&:attribute).each do |data_entry|
        forged_attrs[data_entry.attribute] = data_entry.value
      end

      return forged_attrs
    end

    # Record several pieces of information from the same source.
    def record_data_entries(attributes_hash, source, **data_entry_options)
      attributes_hash.each do |attribute, value|
        record_data_entry(attribute, value, source, **data_entry_options)
      end
    end

    # Record a single piece of information from a source.
    # Optionally pass a custom priority for that attribute and source at the same time.
    # Optionally pass `replace: false` to leave the existing entry for the attribute and source instead of deleting it
    def record_data_entry(attribute, value, source, priority: nil, replace: true)
      data_entries.destroy(*filter_loaded_data_entries(attributes: attribute, sources: source)) if replace
      data_entries << DataEntry.new(attribute: attribute, value: value, source: source, priority: priority)
    end

    # Set and save the priority of a source for the source of a single attribute
    def update_attribute_source_priority(attribute, source, priority)
      filter_loaded_data_entries(attributes: attribute, sources: source).each {|data_entry| data_entry.update(priority: priority) }
    end

    private

    # Returns a list of the entries matching the filters
    def filter_loaded_data_entries(attributes: nil, sources: nil, present: nil)
      list = data_entries.to_a

      unless attribute.nil?
        attributes = Array.wrap(attributes).map(&:to_s)
        list.select! {|data_entry| attributes.include?(data_entry.attribute) }
      end

      unless sources.nil?
        sources = Array.wrap(sources).map {|source| source.id if source.is_a?(ActiveRecord::Base) }
        list.select! {|data_entry| sources.include?(data_entry.source_id) }
      end

      list.select!(&:present?) if present == true
      list.reject!(&:present?) if present == false

      return list
    end
  end
end

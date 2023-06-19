module LaForge
  module ActiveRecord
    def laforged
      has_many :data_entries, as: :record, dependent: :delete_all, class_name: 'LaForge::DataEntry'
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
    def forge!(**forge_options, &block)
      transaction do
        block.call if block_given?
        forge(**forge_options)
        save!
      end
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
      filter_loaded_data_entries(attributes: attributes, source_ids: sources, present: true).sort_by(&:priority_with_fallback).reverse.uniq(&:attribute_name).each do |data_entry|
        forged_attrs[data_entry.attribute_name] = data_entry.value
      end

      return forged_attrs
    end

    # Record several pieces of information from the same source.
    def record_data_entries(attributes_hash, source_name, **data_entry_options)
      source_id = DataSource.find_by(name: source_name)&.id
      attributes_hash.each do |attribute_name, value|
        record_data_entry(attribute_name, value, source_id, **data_entry_options)
      end
    end

    # Record a single piece of information from a source.
    # Optionally pass a custom priority for that attribute and source at the same time.
    # Optionally pass `replace: false` to leave the existing entry for the attribute and source instead of deleting it
    def record_data_entry(attribute_name, value, source_id, priority: nil, replace: true)
      data_entries.destroy(*filter_loaded_data_entries(attributes: attribute_name, source_ids: source_id)) if replace
      data_entries << DataEntry.new(attribute_name: attribute_name, value: value, source_id: source_id, priority: priority)
    end

    # Set and save the priority of a source for the source of a single attribute
    def update_attribute_source_priority(attribute, source, priority)
      filter_loaded_data_entries(attributes: attribute, source_ids: source).each {|data_entry| data_entry.update(priority: priority) }
    end

    private

    # Returns a list of the entries matching the filters
    def filter_loaded_data_entries(attributes: nil, source_ids: nil, present: nil)
      list = data_entries.to_a
      return list if list.blank?

      unless attributes.nil?
        attributes = Array.wrap(attributes).map(&:to_s)
        list.select! {|data_entry| attributes.include?(data_entry.attribute_name) }
      end

      unless source_ids.nil?
        source_ids = Array.wrap(source_ids)
        list.select! {|data_entry| source_ids.include?(data_entry.source_id) }
      end

      list.select!(&:present?) if present == true
      list.reject!(&:present?) if present == false

      return list
    end
  end
end

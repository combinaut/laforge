module LaForge
  module ActiveRecord
    extend ActiveSupport::Concern

    def laforged
      has_many :data_entries, as: :record, dependent: :delete_all, autosave: true, class_name: 'LaForge::DataEntry'
      has_many :data_sources, through: :source_data_entries, class_name: 'LaForge::DataSource'

      scope :with_source, ->(source) { joins(:data_entries).merge(DataEntry.with_source(source)) }
      scope :without_source, ->(source) { joins(:data_entries).merge(DataEntry.without_source(source)) }
      scope :with_attribute, ->(attribute) { joins(:data_entries).merge(DataEntry.with_attribute(attribute)) }
      scope :without_attribute, ->(attribute) { joins(:data_entries).merge(DataEntry.without_attribute(attribute)) }
      scope :with_attribute_with_source, ->(attribute, source) { joins(:data_entries).merge(DataEntry.with_attribute(attribute).with_source(source)) }
      scope :with_attribute_without_source, ->(attribute, source) { joins(:data_entries).merge(DataEntry.with_attribute(attribute).without_source(source)) }
      scope :without_attribute_with_source, ->(attribute, source) { joins(:data_entries).merge(DataEntry.without_attribute(attribute).with_source(source)) }

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

      filter_loaded_data_entries(attributes: attributes, sources: sources, present: true).sort_by(&:priority_with_fallback).reverse.uniq(&:attribute_name).each do |data_entry|
        next unless respond_to?("#{data_entry.attribute_name}=")

        value = data_entry.marked_for_destruction? ? nil : data_entry.value
        forged_attrs[data_entry.attribute_name] = value
      end

      return forged_attrs
    end

    # Mark several data entries for destruction
    # Optionally pass `attributes` to limit data entries used in the calculation to only those for the given attributes
    # Optionally pass `sources` to limit data entries used in the calculation to only those from the given sources
    def remove_data_entries(attribute_names: nil, sources: nil)
      filter_loaded_data_entries(attributes: attribute_names, sources: sources).each do |data_entry|
        data_entry.mark_for_destruction
      end
    end

    # Record several pieces of information from the same source.
    def record_data_entries(attributes_hash, source, **data_entry_options)
      attributes_hash.each do |attribute_name, value|
        record_data_entry(attribute_name, value, source, **data_entry_options)
      end
    end

    # Record a single piece of information from a source.
    # Optionally pass a custom priority for that attribute and source at the same time.
    def record_data_entry(attribute_name, value, source, priority: nil)
      raise InvalidAttributeName, "Cannot set #{attribute_name} on #{self.class.name}" unless respond_to?("#{attribute_name}=")

      exiting_data_entry = filter_loaded_data_entries(attributes: attribute_name, sources: source).first
      if exiting_data_entry
        exiting_data_entry.value = value
        exiting_data_entry.priority = priority
      else
        data_entries.build(attribute_name: attribute_name, value: value, source_id: source, priority: priority)
      end
    end

    # Set and save the priority of a source for the source of a single attribute
    def update_attribute_source_priority(attribute, source, priority)
      filter_loaded_data_entries(attributes: attribute, sources: source).each {|data_entry| data_entry.update(priority: priority) }
    end

    def data_source?(source)
      filter_loaded_data_entries(sources: source).any?
    end

    def data_source_names(attributes: nil)
      filter_loaded_data_entries(attributes: attributes).map(&:source).map(&:name).uniq
    end

    private

    # Returns a list of the entries matching the filters
    def filter_loaded_data_entries(attributes: nil, sources: nil, present: nil)
      list = data_entries.to_a

      unless attributes.nil?
        attributes = Array.wrap(attributes).map(&:to_s)
        list.select! {|data_entry| attributes.include?(data_entry.attribute_name) }
      end

      unless sources.nil?
        source_ids = Array.wrap(sources).map {|source| DataSource.normalize_source_id(source) }
        list.select! {|data_entry| source_ids.include?(data_entry.source_id) }
      end

      list = list.select(&:present?) if present == true
      list = list.reject(&:present?) if present == false

      return list
    end
  end

  class InvalidAttributeName < StandardError; end
end

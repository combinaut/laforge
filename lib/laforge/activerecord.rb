module LaForge
  module ActiveRecord
    extend ActiveSupport::Concern

    def laforged
      has_many :data_entries, as: :record, dependent: :delete_all, autosave: true, class_name: 'LaForge::DataEntry'
      has_many :data_sources, -> { distinct }, through: :data_entries, source: :source, class_name: 'LaForge::DataSource'

      scope :with_source, ->(source) { joins(:data_entries).merge(DataEntry.with_source(source)) }
      scope :without_source, ->(source) { joins(:data_entries).merge(DataEntry.without_source(source)) }
      scope :with_attribute, ->(attribute) { joins(:data_entries).merge(DataEntry.with_attribute(attribute)) }
      scope :without_attribute, ->(attribute) { joins(:data_entries).merge(DataEntry.without_attribute(attribute)) }
      scope :with_attribute_with_source, ->(attribute, source) { joins(:data_entries).merge(DataEntry.with_attribute(attribute).with_source(source)) }
      scope :with_attribute_without_source, ->(attribute, source) { joins(:data_entries).merge(DataEntry.with_attribute(attribute).without_source(source)) }
      scope :without_attribute_with_source, ->(attribute, source) { joins(:data_entries).merge(DataEntry.without_attribute(attribute).with_source(source)) }

      include InstanceMethods
    end
  end

  module InstanceMethods
    PRIORITY_NOT_GIVEN = Object.new.freeze
    private_constant :PRIORITY_NOT_GIVEN

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
      data_entries = filter_data_entries_in_memory(attributes: attributes, sources: sources)
      winners = DataEntry.in_precedence_order(data_entries).uniq(&:attribute_name).index_by(&:attribute_name)

      # The hash's key order is the order `forge` calls the setters, which matters when one setter
      # resets another attribute. It follows priority, highest first, independently of which entry
      # wins each attribute. Attributes that share a priority come in no defined order.
      assignment_order = data_entries.sort_by { |data_entry| data_entry.priority_with_fallback || -Float::INFINITY }.reverse.map(&:attribute_name).uniq

      assignment_order.each do |attribute_name|
        next unless respond_to?("#{attribute_name}=")

        data_entry = winners.fetch(attribute_name)
        forged_attrs[attribute_name] = data_entry.marked_for_destruction? ? nil : data_entry.value
      end

      return forged_attrs
    end

    # Mark several data entries for destruction
    # Optionally pass `attributes` to limit data entries used in the calculation to only those for the given attributes
    # Optionally pass `sources` to limit data entries used in the calculation to only those from the given sources
    def remove_data_entries(attribute_names: nil, sources: nil)
      filter_data_entries_in_memory(attributes: attribute_names, sources: sources).each do |data_entry|
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
    # Optionally pass a custom priority for that attribute and source at the same time. Re-recording
    # without `priority` keeps the entry's existing priority; pass `priority: nil` to clear it.
    def record_data_entry(attribute_name, value, source, priority: PRIORITY_NOT_GIVEN)
      raise InvalidAttributeName, "Cannot set #{attribute_name} on #{self.class.name}" unless respond_to?("#{attribute_name}=")

      existing_data_entry = filter_data_entries_in_memory(attributes: attribute_name, sources: source).first
      if existing_data_entry
        existing_data_entry.value = value
        existing_data_entry.priority = priority unless priority.equal?(PRIORITY_NOT_GIVEN)
      else
        priority = nil if priority.equal?(PRIORITY_NOT_GIVEN)
        data_entries.build(attribute_name: attribute_name, value: value, source_id: source, priority: priority)
      end
    end

    # Set and save the priority of a source for the source of a single attribute
    def update_attribute_source_priority(attribute, source, priority)
      filter_data_entries_in_memory(attributes: attribute, sources: source).each {|data_entry| data_entry.update(priority: priority) }
    end

    def data_source?(source)
      filter_data_entries_in_memory(sources: source).any?
    end

    def data_source_names(attributes: nil)
      filter_data_entries_in_memory(attributes: attributes).map(&:source).map(&:name).uniq
    end

    private

    # Returns the record's entries matching the filters, from the in-memory association: every saved
    # entry (loaded on first use), plus entries built but not yet saved and entries marked for destruction.
    def filter_data_entries_in_memory(attributes: nil, sources: nil)
      list = data_entries.to_a

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

  class InvalidAttributeName < StandardError; end
end

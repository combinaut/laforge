module LaForge
  # Distinguishes "no precedence passed" from an explicit nil so re-recording keeps a custom precedence
  NOT_GIVEN = Object.new.freeze

  module ActiveRecord
    extend ActiveSupport::Concern

    def laforged
      has_many :data_entries, as: :record, dependent: :delete_all, autosave: true, class_name: 'LaForge::DataEntry'
      has_many :data_sources, -> { distinct }, through: :data_entries, source: :source, class_name: 'LaForge::DataSource'
      has_many :precedence_rules, as: :record, dependent: :delete_all, autosave: true, class_name: 'LaForge::PrecedenceRule'

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
    # Set and save the precedence of a source for one attribute on every record of this model. Pass nil to remove it.
    def update_attribute_source_precedence(attribute, source, precedence)
      update_model_precedence_rule(attribute.to_s, source, precedence)
    end

    # Set and save the precedence of a source for every attribute on every record of this model. Pass nil to remove it.
    def update_source_precedence(source, precedence)
      update_model_precedence_rule(PrecedenceRule::ANY_ATTRIBUTE, source, precedence)
    end

    # Returns { attribute_name => { source => precedence } } for the model-wide rules, '' standing for every attribute
    def source_precedences
      PrecedenceRule.for_model(self).includes(:source).group_by(&:attribute_name).transform_values { |rules| rules.to_h { |rule| [rule.source, rule.precedence] } }
    end

    private

    def update_model_precedence_rule(attribute_name, source, precedence)
      rules = PrecedenceRule.for_model(self).where(attribute_name: attribute_name, source_id: DataSource.normalize_source_id(source))
      return rules.destroy_all if precedence.nil?

      rule = rules.first_or_initialize
      rule.update!(precedence: precedence)
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
    # Entries marked for destruction are left out, as the next forge will not find them, so each attribute falls back to
    # the next source, and an attribute no other source has an entry for keeps its value.
    def forge_attributes(attributes: nil, sources: nil)
      @laforge_precedence_resolver = nil # read the model-wide and global rules afresh (or from the precedence cache) for each forge
      forged_attrs = {}
      data_entries = filter_data_entries_in_memory(attributes: attributes, sources: sources).reject(&:marked_for_destruction?)
      winners = DataEntry.in_precedence_order(data_entries, record: self).uniq(&:attribute_name).index_by(&:attribute_name)

      # The hash's key order is the order `forge` calls the setters, which matters when one setter
      # resets another attribute. It follows precedence, highest first, independently of which entry
      # wins each attribute. Attributes that share a precedence come in no defined order.
      assignment_order = data_entries.sort_by { |data_entry| laforge_precedence_of(data_entry) }.reverse.map(&:attribute_name).uniq

      assignment_order.each do |attribute_name|
        next unless respond_to?("#{attribute_name}=")

        forged_attrs[attribute_name] = winners.fetch(attribute_name).value
      end

      return forged_attrs
    end

    # Mark several data entries for destruction, so they are destroyed when the record is saved and a forge leaves them
    # out. To blank an attribute instead, record nil for it.
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
    # Optionally pass a precedence for that attribute and source on this record at the same time; it is saved with the
    # record. An existing precedence is kept when none is passed, and removed when nil is passed.
    def record_data_entry(attribute_name, value, source, precedence: NOT_GIVEN)
      raise InvalidAttributeName, "Cannot set #{attribute_name} on #{self.class.name}" unless respond_to?("#{attribute_name}=")

      write_data_entry(attribute_name, value, source, precedence: precedence)
    end

    # Forgets the precedence rules read for the last forge, so they are read afresh, as the next forge would
    def reload(*)
      @laforge_precedence_resolver = nil
      super
    end

    # Set the precedence of a source for one attribute of this record, whether or not the source has recorded it yet.
    # Saved immediately on a persisted record, otherwise with the record. Pass nil to remove it.
    def update_attribute_source_precedence(attribute, source, precedence)
      rule = write_precedence_rule(attribute, source, precedence)
      return unless persisted? && rule

      rule.marked_for_destruction? ? precedence_rules.destroy(rule) : rule.save!
    end

    # Returns { attribute_name => { source => precedence } } for the rules set on this record
    def source_precedences
      precedence_rules.reject(&:marked_for_destruction?).group_by(&:attribute_name).transform_values { |rules| rules.to_h { |rule| [rule.source, rule.precedence] } }
    end

    # The precedence a data entry's value is ranked by on this record
    def laforge_precedence_of(data_entry)
      laforge_precedence_resolver.precedence(self, data_entry.attribute_name, data_entry.source_id)
    end

    # The source's global precedence, which breaks ties between equal effective precedences
    def laforge_global_precedence(source_id)
      laforge_precedence_resolver.global_precedence(source_id)
    end

    def data_source?(source)
      filter_data_entries_in_memory(sources: source).any?
    end

    def data_source_names(attributes: nil)
      filter_data_entries_in_memory(attributes: attributes).map(&:source).map(&:name).uniq
    end

    private

    def write_data_entry(attribute_name, value, source, precedence: NOT_GIVEN)
      existing_data_entry = filter_data_entries_in_memory(attributes: attribute_name, sources: source).first
      if existing_data_entry
        existing_data_entry.value = value
      else
        data_entries.build(attribute_name: attribute_name, value: value, source_id: source)
      end
      write_precedence_rule(attribute_name, source, precedence) unless precedence.equal?(NOT_GIVEN)
    end

    # Set this record's rule for an attribute and source in memory; nil marks an existing rule for destruction
    def write_precedence_rule(attribute_name, source, precedence)
      source_id = DataSource.normalize_source_id(source)
      rule = precedence_rules.find { |candidate| candidate.attribute_name == attribute_name.to_s && candidate.source_id == source_id }

      if precedence.nil?
        return unless rule

        if rule.new_record?
          precedence_rules.target.delete(rule)
          return
        end
        rule.mark_for_destruction
      else
        rule ||= precedence_rules.build(attribute_name: attribute_name.to_s, source_id: source_id)
        rule.instance_variable_set(:@marked_for_destruction, false) # setting a precedence again undoes an unsaved removal
        rule.precedence = precedence
      end
      rule
    end

    def laforge_precedence_resolver
      @laforge_precedence_resolver ||= PrecedenceRule::Resolver.new(self.class)
    end

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

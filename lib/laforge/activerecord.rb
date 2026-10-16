module LaForge
  # Distinguishes "no precedence passed" from an explicit nil so re-recording keeps a custom precedence
  NOT_GIVEN = Object.new.freeze

  module ActiveRecord
    extend ActiveSupport::Concern

    # associations: { name => { key: } } tracks has_many associations; keys of join members are derived from the reflection
    def laforged(associations: {})
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

      class_attribute :laforged_associations, instance_writer: false, default: {}
      # The owners' tracked associations this model is a member of, whose lists can report its attributes
      class_attribute :laforge_owner_configs, instance_writer: false, default: [] unless respond_to?(:laforge_owner_configs)

      configs = associations.to_h { |name, options| [name.to_s, AssociationConfig.new(self, name, **options)] }
      configs.each_value { |config| AssociationTracking.declare(self, config) }
      self.laforged_associations = configs
      after_save :laforge_remove_replaced_members

      extend ClassMethods
      include InstanceMethods
    end
  end

  module ClassMethods
    def laforged_association(name)
      laforged_associations.fetch(name.to_s)
    end

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

    # Returns { record_id => { source => [member hashes] } } for the given records
    def source_values(name, records:)
      AssociationTracking.source_values(self, laforged_association(name), records)
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

    # Assign attributes and associations based on the data entries
    def forge(attributes: nil, sources: nil)
      self.attributes = forge_attributes(attributes: attributes, sources: sources)
      forge_associations(associations: attributes)
    end

    def forge_associations(associations: nil)
      names = associations ? Array.wrap(associations).map(&:to_s) : laforged_associations.keys
      laforged_associations.slice(*names).each_value { |config| AssociationTracking.forge(self, config) }
    end

    # Returns a hash of the attribute changes between the saved record and the data entries
    def forge_diff(**forge_options)
      diff = {}
      forge_attrs = forge_attributes(**forge_options)
      record_attrs = slice(*forge_attrs.keys)

      record_attrs.each do |key, value|
        diff[key] = [value, forge_attrs[key]] if forge_attrs[key] != value
      end

      laforged_associations.each do |name, config|
        association_diff = AssociationTracking.diff(self, config)
        diff[name] = association_diff if association_diff
      end

      return diff
    end

    # Returns a hash of the attributes generated from the record's the data entries
    # Optionally pass `attributes` to limit data entries used in the calculation to only those for the given attributes
    # Optionally pass `sources` to limit data entries used in the calculation to only those from the given sources
    def forge_attributes(attributes: nil, sources: nil)
      @laforge_precedence_resolver = nil # read the model-wide and global rules afresh (or from the precedence cache) for each forge
      @laforge_list_entries = nil
      forged_attrs = {}
      data_entries = laforge_candidate_entries(attributes: attributes, sources: sources).reject { |data_entry| laforged_associations.key?(data_entry.attribute_name) }
      winners = DataEntry.in_precedence_order(data_entries, record: self).uniq(&:attribute_name).index_by(&:attribute_name)

      # The hash's key order is the order `forge` calls the setters, which matters when one setter
      # resets another attribute. It follows precedence, highest first, independently of which entry
      # wins each attribute. Attributes that share a precedence come in no defined order.
      assignment_order = data_entries.sort_by { |data_entry| laforge_precedence_of(data_entry) }.reverse.map(&:attribute_name).uniq

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
    # A tracked association's value is the source's whole member list. Pass `partial: true` when the source reports only
    # some members: the value is then the members it includes, or { include: [...], exclude: [...] }, and members other
    # sources report are left to them.
    def record_data_entries(attributes_hash, source, precedence: NOT_GIVEN, partial: false)
      attributes_hash.each do |attribute_name, value|
        if (config = laforged_associations[attribute_name.to_s])
          options = { precedence: precedence }
          options[:partial] = true if partial
          AssociationTracking.record(self, config, value, source, **options)
        else
          record_data_entry(attribute_name, value, source, precedence: precedence)
        end
      end
    end

    # Record a single piece of information from a source.
    # Optionally pass a precedence for that attribute and source on this record at the same time; it is saved with the
    # record. An existing precedence is kept when none is passed, and removed when nil is passed.
    # A belongs_to association is recorded as its foreign key (and type, when polymorphic): pass the record or nil.
    def record_data_entry(attribute_name, value, source, precedence: NOT_GIVEN)
      reflection = self.class.reflect_on_association(attribute_name)
      if reflection&.belongs_to?
        return laforge_reference_columns(reflection, value).each { |column, column_value| write_data_entry(column, column_value, source, precedence: precedence) }
      end

      raise InvalidAttributeName, "#{self.class.name}##{attribute_name} is not a tracked association" if reflection
      raise InvalidAttributeName, "Cannot set #{attribute_name} on #{self.class.name}" unless respond_to?("#{attribute_name}=")
      raise InvalidValue, "Cannot record #{value.class} for #{self.class.name}##{attribute_name}; values are stored as JSON, so record a string, number, boolean, date, nil, or an array or hash of those" unless DataEntry.storable?(value)

      write_data_entry(attribute_name, value, source, precedence: precedence)
    end

    # Forgets the precedence rules read for the last forge, so they are read afresh, as the next forge would
    def reload(*)
      @laforge_precedence_resolver = nil
      super
    end

    # Add one member to the source's report for a tracked association, leaving the rest of its report as it is
    def include_association_member(name, member, source)
      AssociationTracking.edit_member(self, self.class.laforged_association(name), member, source, :include)
    end

    # Remove one member through the source's report, even if lower-precedence sources include it
    def exclude_association_member(name, member, source)
      AssociationTracking.edit_member(self, self.class.laforged_association(name), member, source, :exclude)
    end

    # Drop the source's opinion on one member, so membership falls to the other sources
    def forget_association_member(name, member, source)
      AssociationTracking.edit_member(self, self.class.laforged_association(name), member, source, :forget)
    end

    # For an orphan sweep: the source no longer reports this record. Destroys its attribute entries and withdraws every
    # member it reported in tracked associations, so the next forge removes those members unless another source still
    # includes them. Saved immediately, without forging. Precedence rules for the source are kept.
    def withdraw_source(source)
      transaction do
        filter_data_entries_in_memory(sources: source).each do |data_entry|
          if (config = laforged_associations[data_entry.attribute_name])
            AssociationTracking.withdraw(self, config, data_entry)
            data_entry.save! if data_entry.persisted?
          else
            data_entries.destroy(data_entry)
          end
        end
      end
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

    # Whether the source has entries on this record, or reports it in a tracked association's list
    def data_source?(source)
      laforge_candidate_entries(sources: source).any?
    end

    # The sources with entries on this record, or that report it in a tracked association's list
    def data_source_names(attributes: nil)
      laforge_candidate_entries(attributes: attributes).map(&:source).map(&:name).uniq
    end

    # Returns { source => [member hashes] } for a tracked association
    def source_values(name)
      self.class.source_values(name, records: [self])[id] || {}
    end

    # Returns { membership: source, listed_by: [sources], attributes: { attribute => source } } for one member
    def member_sources(name, **member)
      AssociationTracking.member_sources(self, self.class.laforged_association(name), member.stringify_keys)
    end

    # Schedules a has_one member that forge replaced or dropped for removal once this owner is saved, per the
    # association's dependent option, so forging alone writes nothing
    def laforge_remove_on_save(config, record)
      (@laforge_replaced_members ||= []) << [config, record]
    end

    # Tells this member which in-memory owner holds the lists for a tracked association, so lists recorded but not yet
    # saved count when the member is forged through its owner
    def laforge_list_owner!(config, owner)
      (@laforge_list_owners ||= {})[config] = owner
      @laforge_list_entries = nil
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

    # { foreign_key => id, foreign_type => class name } for a record (or nil) assigned to a belongs_to association
    def laforge_reference_columns(reflection, target)
      unless target.nil? || target.is_a?(::ActiveRecord::Base)
        raise InvalidValue, "#{self.class.name}##{reflection.name} must be recorded as a record or nil, not #{target.class}"
      end
      raise InvalidValue, "Cannot record an unsaved #{target.class.name} for #{self.class.name}##{reflection.name}" if target&.new_record?
      if target && !reflection.polymorphic? && !target.is_a?(reflection.klass)
        raise InvalidValue, "#{self.class.name}##{reflection.name} must be a #{reflection.klass.name}, not #{target.class.name}"
      end

      primary_key = reflection.polymorphic? ? target&.class&.primary_key : reflection.association_primary_key
      columns = { reflection.foreign_key.to_s => target && target[primary_key] }
      columns[reflection.foreign_type.to_s] = target&.class&.polymorphic_name if reflection.polymorphic?
      columns
    end

    def laforge_remove_replaced_members
      (@laforge_replaced_members || []).each do |config, record|
        case config.reflection.options[:dependent]
        when :destroy, :destroy_async then record.destroy!
        when :delete then record.delete
        else
          record[config.owner_foreign_key] = nil
          record[config.owner_type_column] = nil if config.owner_type_column
          record.save!(validate: false)
        end
      end
      @laforge_replaced_members = nil
    end

    def laforge_precedence_resolver
      @laforge_precedence_resolver ||= PrecedenceRule::Resolver.new(self.class)
    end

    # The association's entries in precedence order, paired with their member lists. An entry marked for destruction
    # contributes an empty list, as a marked scalar entry contributes nil.
    def laforge_association_lists(config)
      laforge_association_reports(config).map { |data_entry, report| [data_entry, report.include] }
    end

    # The association's entries in precedence order, paired with their reports (see MemberList)
    def laforge_association_reports(config)
      entries = laforge_candidate_entries(attributes: config.name)
      laforge_by_precedence(entries).map { |data_entry| [data_entry, MemberList.new(data_entry.value, marked: data_entry.marked_for_destruction?)] }
    end

    def laforge_by_precedence(entries)
      DataEntry.in_precedence_order(entries, record: self)
    end

    # The record's own entries plus the values its owners' lists report about it, matching the filters
    def laforge_candidate_entries(attributes: nil, sources: nil)
      list = filter_data_entries_in_memory(attributes: attributes, sources: sources) + laforge_list_entries

      list.select! { |data_entry| Array.wrap(attributes).map(&:to_s).include?(data_entry.attribute_name) } unless attributes.nil?
      unless sources.nil?
        source_ids = DataSource.normalize_source_ids(sources)
        list.select! { |data_entry| source_ids.include?(data_entry.source_id) }
      end
      list.uniq
    end

    # Unsaved entries standing for what each owner's list says about this member, one per reported attribute. They are
    # rebuilt from the lists rather than stored, so a source's values disappear when its list stops including the member.
    def laforge_list_entries
      @laforge_list_entries ||= self.class.laforge_owner_configs.flat_map do |config|
        owner = laforge_list_owner_for(config)
        next [] unless owner

        key = config.record_key(self)
        owner.send(:laforge_candidate_entries, attributes: config.name).reject(&:marked_for_destruction?).flat_map do |list_entry|
          member = MemberList.new(list_entry.value).include.find { |listed| config.key_of(listed) == key }
          next [] unless member

          member.except(*config.key).map { |field, value| DataEntry.new(attribute_name: field, value: value, source_id: list_entry.source_id) }
        end
      end
    end

    def laforge_list_owner_for(config)
      owner = @laforge_list_owners&.[](config)
      return owner if owner

      owner_id = self[config.owner_foreign_key]
      return unless owner_id
      return if config.owner_type_column && self[config.owner_type_column] != config.owner_class.base_class.polymorphic_name

      config.owner_class.find_by(config.owner_class.primary_key => owner_id)
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
  class InvalidValue < StandardError; end
end

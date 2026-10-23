module LaForge
  # `NOT_GIVEN` stands for an omitted `precedence:` argument, so omitting it can be told from passing nil, which removes
  # the precedence.
  NOT_GIVEN = Object.new.freeze

  module ActiveRecord
    extend ActiveSupport::Concern

    # Declares the model's data entries, data sources and precedence rules, with these options:
    # - associations: { name => options }, the has_many and has_one associations to track (see TrackedAssociation),
    #   each with the options AssociationConfig takes
    # - attribute_groups: { name => [attributes] }. An attribute group is a set of attributes that come from one source
    #   together, such as the lines of a postal address. Sources record a group's attributes together, precedence rules
    #   are set on the group, and forging takes every attribute of the group from the highest-ranked source with an
    #   entry for any of them.
    def laforged(associations: {}, attribute_groups: {})
      LaForge::ActiveRecord.assert_no_collisions!(self)
      groups = LaForge::ActiveRecord.attribute_groups(self, attribute_groups, associations)

      LaForge::ActiveRecord.declare_data_associations(self)
      LaForge::ActiveRecord.declare_scopes(self)

      class_attribute :laforged_associations, instance_writer: false, default: {}
      class_attribute :laforged_attribute_groups, instance_writer: false, default: {}
      self.laforged_attribute_groups = groups

      configs = associations.to_h { |name, options| [name.to_s, AssociationConfig.new(self, name, **options)] }
      configs.each_value { |config| TrackedAssociation.declare(self, config) }
      self.laforged_associations = configs
      after_save :laforge_after_save

      extend ClassMethods
      include InstanceMethods
    end

    # OVERRIDES are the methods LaForge defines over Active Record's own, calling super, which `assert_no_collisions!`
    # lets through
    OVERRIDES = %i[reload initialize_dup].freeze

    # Raises when the model already has a method by a name `laforged` adds, other than `OVERRIDES`, naming each one. A
    # method defined after `laforged` is not checked, so a model can wrap LaForge's and call super. Nothing is checked
    # when the model already has LaForge's methods, as when `laforged` is declared again.
    def self.assert_no_collisions!(model)
      instance_names = model.include?(InstanceMethods) ? [] : InstanceMethods.public_instance_methods + InstanceMethods.private_instance_methods - OVERRIDES
      instance = instance_names.select { |name| model.method_defined?(name) || model.private_method_defined?(name) }
      class_names = model.singleton_class.include?(ClassMethods) ? [] : ClassMethods.public_instance_methods
      klass = class_names.select { |name| model.respond_to?(name) }
      return if instance.empty? && klass.empty?

      names = instance.map { |name| "##{name}" } + klass.map { |name| ".#{name}" }
      raise ArgumentError, "#{model.name} already defines #{names.join(', ')}, which would hide LaForge's of the same name. Rename #{model.name}'s " \
                           "#{names.one? ? 'method' : 'methods'}, or, to wrap LaForge's and call super, define #{names.one? ? 'it' : 'them'} after `laforged`"
    end

    # Returns the attribute groups declared on a model as { group name => [attribute names] }, names as strings. Raises
    # unless:
    # - each group names at least two distinct attributes
    # - no group is named like an attribute of any group
    # - no attribute is in two groups or is a tracked association
    def self.attribute_groups(model, groups, associations)
      groups = groups.to_h { |name, attributes| [name.to_s, Array.wrap(attributes).map(&:to_s)] }
      seen = {}
      groups.each do |name, attributes|
        raise ArgumentError, "#{model.name} attribute group #{name} names #{attributes.size} attribute#{'s' unless attributes.one?}; a group needs at least two" if attributes.uniq.size < 2
        raise ArgumentError, "#{model.name} attribute group #{name} is named like one of its attributes; give the group its own name" if attributes.include?(name)

        attributes.each do |attribute|
          raise ArgumentError, "#{model.name}##{attribute} is in attribute groups #{seen[attribute]} and #{name}; an attribute belongs to one group at most" if seen[attribute]
          raise ArgumentError, "#{model.name}##{attribute} is a tracked association, which cannot be in an attribute group" if associations.key?(attribute) || associations.key?(attribute.to_sym)

          seen[attribute] = name
        end
      end
      clash = groups.keys & seen.keys
      raise ArgumentError, "#{model.name} attribute group #{clash.first} is also an attribute of group #{seen[clash.first]}; give the group its own name" if clash.any?

      groups
    end

    # Declares the model's associations to its data entries, data sources and precedence rules
    def self.declare_data_associations(model)
      model.has_many :data_entries, as: :record, dependent: :delete_all, autosave: true, class_name: 'LaForge::DataEntry' do
        # Returns the tombstones of the tracked association `name` (see Tombstone)
        def tombstones(name)
          owner = proxy_association.owner
          TrackedAssociation.new(owner, owner.class.laforged_association(name)).tombstones
        end
      end
      model.has_many :data_sources, -> { distinct }, through: :data_entries, source: :source, class_name: 'LaForge::DataSource'
      model.has_many :precedence_rules, as: :record, dependent: :delete_all, autosave: true, class_name: 'LaForge::PrecedenceRule'
    end

    # Declares the scopes that find the model's records by the sources and attributes of their entries
    def self.declare_scopes(model)
      model.scope :with_source, ->(source) { joins(:data_entries).merge(DataEntry.with_source(source)) }
      model.scope :without_source, ->(source) { joins(:data_entries).merge(DataEntry.without_source(source)) }
      model.scope :with_attribute, ->(attribute) { joins(:data_entries).merge(DataEntry.with_attribute(attribute)) }
      model.scope :without_attribute, ->(attribute) { joins(:data_entries).merge(DataEntry.without_attribute(attribute)) }
      model.scope :with_attribute_with_source, ->(attribute, source) { joins(:data_entries).merge(DataEntry.with_attribute(attribute).with_source(source)) }
      model.scope :with_attribute_without_source, ->(attribute, source) { joins(:data_entries).merge(DataEntry.with_attribute(attribute).without_source(source)) }
      model.scope :without_attribute_with_source, ->(attribute, source) { joins(:data_entries).merge(DataEntry.without_attribute(attribute).with_source(source)) }
    end

    # Sets whether `record` is marked for destruction, which undoes an unsaved removal when `marked` is false. Active
    # Record offers no method to unmark a record, so this sets the flag `marked_for_destruction?` reads.
    def self.set_marked_for_destruction(record, marked)
      record.instance_variable_set(:@marked_for_destruction, marked)
    end

    # Returns `sources` highest-ranked first, as [{ source:, level: }], given each source's rank from the block (see
    # `PrecedenceRule::Resolver#rank`). `levels` names the rank's positions, and a source's level is the first one it
    # has a rule at. Sources that rank equally come in id order. A source with no rule at any level, such as one without
    # a global precedence, comes last with a nil level.
    def self.order_by_rank(sources, levels)
      ranked = sources.map { |source| [source, yield(source)] }.sort_by { |source, rank| rank.map(&:-@) + [source.id] }
      ranked.map do |source, rank|
        level = rank.index { |precedence| precedence != -Float::INFINITY }
        { source: source, level: level && levels[level] }
      end
    end
  end

  # The class methods `laforged` adds
  module ClassMethods
    include Precedence::ClassMethods

    def laforged_association(name)
      laforged_associations.fetch(name.to_s)
    end

    # Returns what each source says about the members of the tracked association `name` on each of `records`, as
    # { record_id => { source => [member hashes] } }
    def source_values(name, records:)
      TrackedAssociation.source_values(self, laforged_association(name), records)
    end

    # @api private
    # Returns the attribute names as strings, each attribute in a group replaced by its whole group, in the group's
    # order. With a group `address: [:street, :city]`, `[:name, :city]` becomes `['name', 'street', 'city']`.
    def laforge_with_groups(attribute_names)
      Array.wrap(attribute_names).map(&:to_s).flat_map { |name| (group = laforge_attribute_group(name)) ? laforged_attribute_groups[group] : [name] }.uniq
    end

    # @api private
    # Raises unless the attributes recorded together include every attribute of each group they touch, naming the
    # missing ones. `where` describes what is being recorded, for the message.
    def laforge_assert_whole_groups!(attribute_names, where: name)
      attribute_names = attribute_names.map(&:to_s)
      laforged_attribute_groups.each do |group, attributes|
        given = attributes & attribute_names
        next if given.empty? || given.size == attributes.size

        raise ArgumentError, "#{where}: #{attributes.join(', ')} are attribute group #{group}, which a source records together (missing: #{(attributes - given).join(', ')}). " \
                             'Pass nil for a value the source does not have'
      end
    end

    # @api private
    # Raises when `attribute` is in an attribute group, since its precedence rules are set on the group
    def laforge_assert_rule_attribute!(attribute)
      group = laforge_attribute_group(attribute)
      raise ArgumentError, "#{name}##{attribute} is in attribute group #{group}, which is ranked as a whole; set the precedence on #{group}" if group
    end

    # @api private
    # The name of the attribute group an attribute belongs to, or nil
    def laforge_attribute_group(attribute_name)
      attribute_name = attribute_name.to_s
      laforged_attribute_groups.find { |_, attributes| attributes.include?(attribute_name) }&.first
    end
  end

  # The instance methods `laforged` adds
  module InstanceMethods
    include Recording
    include Forging
    include Precedence

    # Whether the source has entries on this record
    def data_source?(source)
      laforge.filter_data_entries_in_memory(sources: source).any?
    end

    # Returns the names of the sources with entries on this record, for `attributes` when given
    def data_source_names(attributes: nil)
      laforge.filter_data_entries_in_memory(attributes: attributes).map(&:source).map(&:name).uniq
    end

    # Returns what each source says about the members of the tracked association `name`, as
    # { source => [member hashes] } (see the class method)
    def source_values(name)
      self.class.source_values(name, records: [self])[id] || {}
    end

    # Returns { membership: source, listed_by: [sources], excluded_by: [sources], attributes: { attribute => source } }
    # for one member
    def member_sources(name, **member)
      TrackedAssociation.new(self, self.class.laforged_association(name)).member_sources(member.stringify_keys)
    end

    # @api private
    # Returns what LaForge keeps for this record (see RecordState), made on first use
    def laforge
      @laforge ||= RecordState.new(self)
    end

    # Also drops what LaForge keeps for this record, so its pending writes go and the next ranking reads the model-wide
    # and global rules again
    def reload(*)
      @laforge = nil
      super
    end

    # Gives a duplicate its own `laforge`, rather than the one bound to the record it was duplicated from
    def initialize_dup(*)
      @laforge = nil
      super
    end
  end

  class InvalidAttributeName < StandardError; end
  class InvalidValue < StandardError; end
  class DuplicateMemberKey < StandardError; end
end

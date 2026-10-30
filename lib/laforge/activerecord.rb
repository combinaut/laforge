module LaForge
  # `LaForge::ActiveRecord` is used to declare a model laforged, with `laforged`
  module ActiveRecord
    extend ActiveSupport::Concern

    # Declares the model's data entries, data sources and precedence rules, with these options:
    # - associations: { name => options }, the has_many and has_one associations to track (see TrackedAssociation),
    #   each with the options AssociationConfig takes
    # - attribute_groups: { name => [attributes] }, the model's attribute groups (see AttributeGroups)
    # - ruleset_selector: the model's own ruleset selector, in place of `LaForge.ruleset_selector`. It is a method name
    #   (Symbol), a Proc given the record, or false for the base rules.
    def laforged(associations: {}, attribute_groups: {}, ruleset_selector: nil)
      LaForge::ActiveRecord.assert_no_collisions!(self)
      LaForge.assert_ruleset_selector!(ruleset_selector, where: "#{name} laforged ruleset_selector:", model: true)
      groups = LaForge::ActiveRecord.attribute_groups(self, attribute_groups, associations)
      include Model

      LaForge::ActiveRecord.declare_data_associations(self)
      LaForge::ActiveRecord.declare_scopes(self)

      laforge.attribute_groups = groups
      laforge.ruleset_selector = ruleset_selector

      configs = associations.to_h { |name, options| [name.to_s, AssociationConfig.new(self, name, **options)] }
      configs.each_value { |config| TrackedAssociation.declare(self, config) }
      laforge.associations = configs
      after_save { laforge.write_pending_writes! }
    end

    # Raises when the model already has a method by a name `laforged` adds, naming each one. A method defined after
    # `laforged` is not checked, so a model can wrap LaForge's and call super. Nothing is checked when the model already
    # includes `Model`, as when `laforged` is declared again.
    def self.assert_no_collisions!(model)
      return if model.include?(Model)

      instance = (Record::API + [:laforge]).select { |name| model.method_defined?(name) || model.private_method_defined?(name) }
      klass = (Record::CLASS_API + [:laforge]).select { |name| model.respond_to?(name) }
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
          proxy_association.owner.laforge.tombstones(name)
        end

        # Returns the expiries in the member lists of the tracked association `name` (see
        # Inspection#membership_expiries)
        def membership_expiries(name)
          proxy_association.owner.laforge.membership_expiries(name)
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

    # Used to give a laforged model its `laforge` and to delegate LaForge's methods to it
    module Model
      extend ActiveSupport::Concern

      delegate(*Record::API, to: :laforge)

      # Returns the record's `LaForge::Record`, through which LaForge records, forges and ranks it, made on first use
      def laforge
        @laforge ||= self.class.laforge.new(self)
      end

      # Also drops the record's `laforge`, so its pending writes go and the next ranking reads the model-wide and global
      # rules again
      def reload(*)
        @laforge = nil
        super
      end

      # Gives a duplicate its own `laforge`, bound to the duplicate
      def initialize_dup(*)
        @laforge = nil
        super
      end

      class_methods do
        delegate(*Record::CLASS_API, to: :laforge)

        # Returns the model's own subclass of LaForge::Record, made on first use. A subclass of a laforged model gets a
        # subclass of its parent's, so it keeps what `laforged` declared on the parent.
        def laforge
          @laforge ||= Class.new(superclass.respond_to?(:laforge) ? superclass.laforge : Record).tap { |klass| klass.model = self }
        end
      end
    end
  end

  class InvalidAttributeName < StandardError; end
  class InvalidValue < StandardError; end
  class DuplicateMemberKey < StandardError; end
end

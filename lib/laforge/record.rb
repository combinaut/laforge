module LaForge
  # `Record` is used to record, forge and rank one laforged record, reached through `record.laforge`. Each laforged
  # model has its own subclass, reached through `Model.laforge`, whose class methods act on the model. The model
  # delegates `API` and `CLASS_API` to them, so `place.forge!` is `place.laforge.forge!`. The methods marked
  # `@api private` are the low-level ones LaForge's own objects call.
  class Record
    include AttributeGroups
    include Recording
    include Forging
    include Precedence
    include Inspection

    # What `laforged` declared on the model:
    # - model: the laforged model
    # - associations: { name => AssociationConfig } for its tracked associations
    # - attribute_groups: { group name => [attribute names] }
    # - ruleset_selector: its own ruleset selector (see Rulesets)
    # - match_by: { attribute name => proc giving a value's match value } (see ValueMatcher)
    # - value_matchers: { attribute name => ValueMatcher }, filled as matchers are first used
    class_attribute :model, :associations, :attribute_groups, :ruleset_selector, :match_by, :value_matchers, instance_writer: false, instance_predicate: false
    self.associations = {}
    self.attribute_groups = {}
    self.match_by = {}
    self.value_matchers = {}

    API = [Recording::API, Forging::API, Precedence::API, Inspection::API].flatten.uniq.freeze
    CLASS_API = [Precedence::CLASS_API, Inspection::CLASS_API].flatten.uniq.freeze

    class << self
      # Adds what a `laforged` call declares to what the earlier calls declared, on the model or on a model it inherits
      # from. `associations` is { name => AssociationConfig }, and the rest are as `laforged` takes them. The attribute
      # groups and `match_by` are checked against everything declared (see `LaForge::ActiveRecord.attribute_groups` and
      # `.match_by`). Raises for a name an earlier call declared, and for a ruleset selector other than an earlier
      # call's, and then declares nothing. A subclass's call adds to what its parent had declared by then, so what the
      # parent declares afterwards does not reach that subclass. The writers are private, so no caller replaces what
      # another declared.
      def declare(associations:, attribute_groups:, ruleset_selector:, match_by:)
        attribute_groups = attribute_groups.to_h
        match_by = match_by.to_h
        assert_not_declared!(:associations, associations, self.associations)
        assert_not_declared!(:attribute_groups, attribute_groups, self.attribute_groups)
        assert_not_declared!(:match_by, match_by, self.match_by)
        assert_same_ruleset_selector!(ruleset_selector)
        associations = self.associations.merge(associations)
        groups = LaForge::ActiveRecord.attribute_groups(model, self.attribute_groups.merge(attribute_groups), associations.keys)
        match_values = LaForge::ActiveRecord.match_by(model, self.match_by.merge(match_by), associations.keys, groups)

        self.associations = associations
        self.attribute_groups = groups
        self.ruleset_selector = ruleset_selector unless ruleset_selector.nil?
        self.match_by = match_values
        self.value_matchers = {}
      end

      # Returns the AssociationConfig of the tracked association `name`
      def association(name)
        associations.fetch(name.to_s)
      end

      # Returns the matcher for `attribute`, kept until `laforged` is called on the model again. The model's first one
      # checks that it has the attributes of its `match_by`, which `laforged` leaves to here because that reads its
      # columns.
      def value_matcher(attribute)
        value_matchers.fetch(attribute.to_s) do |name|
          match_by.each_key { |declared| ValueMatcher.assert_attribute!(model, declared) } if value_matchers.empty?
          value_matchers[name] = ValueMatcher.new(match_by[name])
        end
      end

      def inspect
        model ? "#{model.name}.laforge" : super
      end
      alias to_s inspect

      private :associations=, :attribute_groups=, :ruleset_selector=, :match_by=, :value_matchers=

      private

      # Raises when `declared`, what a `laforged` call gives `option`, has a name among `earlier`, what the earlier
      # calls declared for it, naming each one
      def assert_not_declared!(option, declared, earlier)
        names = declared.keys.map(&:to_s) & earlier.keys
        return if names.empty?

        raise ArgumentError, "#{model.name} `laforged #{option}:` declares #{names.join(', ')}, which #{earlier_call} already declared. " \
                             "Declare #{names.one? ? names.first : 'each'} in one call only"
      end

      # Raises when a `laforged` call gives a ruleset selector other than the one the earlier calls declared. Two procs
      # are the same selector only when they are the same object.
      def assert_same_ruleset_selector!(selector)
        earlier = ruleset_selector
        return if selector.nil? || earlier.nil? || selector == earlier

        raise ArgumentError, "#{model.name} `laforged ruleset_selector:` is #{selector.inspect}, but #{earlier_call} declared #{earlier.inspect}. " \
                             "Declare #{model.name}'s ruleset selector in one call only"
      end

      # Returns the words an error uses for the `laforged` calls made before the one that raises
      def earlier_call
        superclass == Record ? 'an earlier `laforged` call' : "an earlier `laforged` call, on #{model.name} or a model it inherits from,"
      end
    end

    attr_reader :record

    def initialize(record)
      @record = record
    end

    def inspect
      "#<#{self.class.inspect} #{record.class.name}##{record.id.inspect}>"
    end
  end
end

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
      # Returns the AssociationConfig of the tracked association `name`
      def association(name)
        associations.fetch(name.to_s)
      end

      # Returns the matcher for `attribute`, kept until `laforged` declares the model again. The model's first one checks
      # that it has the attributes of its `match_by`, which `laforged` leaves to here because that reads its columns.
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

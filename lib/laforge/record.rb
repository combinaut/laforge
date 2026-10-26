module LaForge
  # Used to record, forge and rank one laforged record, reached through `record.laforge`. Each laforged model has its
  # own subclass, reached through `Model.laforge`, whose class methods act on the model. The model delegates `API` and
  # `CLASS_API` to them, so `place.forge!` is `place.laforge.forge!`. The methods marked `@api private` are the
  # low-level ones LaForge's own objects call.
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
    class_attribute :model, :associations, :attribute_groups, :ruleset_selector, instance_writer: false, instance_predicate: false
    self.associations = {}
    self.attribute_groups = {}

    API = [Recording::API, Forging::API, Precedence::API, Inspection::API].flatten.uniq.freeze
    CLASS_API = [Precedence::CLASS_API, Inspection::CLASS_API].flatten.uniq.freeze

    class << self
      # Returns the AssociationConfig of the tracked association `name`
      def association(name)
        associations.fetch(name.to_s)
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

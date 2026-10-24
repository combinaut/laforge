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
    # - attribute_groups: { group name => [attribute names] }
    class_attribute :model, :attribute_groups, instance_writer: false, instance_predicate: false
    self.attribute_groups = {}

    API = [Recording::API, Forging::API, Precedence::API, Inspection::API].flatten.uniq.freeze
    CLASS_API = [Precedence::CLASS_API].flatten.uniq.freeze

    class << self
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

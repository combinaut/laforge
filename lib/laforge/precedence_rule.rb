module LaForge
  # One rule ranking a source's values at one of four levels, from most to least specific:
  #
  #   record_type  record_id  attribute_name  applies to
  #   'Tenant'     1          'name'          one attribute of one record
  #   'Tenant'     0          'name'          one attribute of every record of a model
  #   'Tenant'     0          ''              every attribute of every record of a model
  #   ''           0          ''              everything (the source's global precedence)
  #
  # "Any" is stored as '' or 0 rather than NULL so the unique index on the scope and source covers every level, and so
  # lookups by record_type, record_id and attribute_name use its prefix. The generated `global_precedence` column holds
  # the precedence of global rules only, so a unique index on it keeps the global order free of ties.
  class PrecedenceRule < ::ActiveRecord::Base
    self.table_name = "laforge_precedence_rules"

    ANY_TYPE = ''.freeze
    ANY_ID = 0
    ANY_ATTRIBUTE = ''.freeze

    belongs_to :source, class_name: 'LaForge::DataSource'

    scope :global, -> { where(record_type: ANY_TYPE, record_id: ANY_ID, attribute_name: ANY_ATTRIBUTE) }
    scope :for_model, ->(model) { where(record_type: model_type(model), record_id: ANY_ID) }

    validates :precedence, presence: true, numericality: { only_integer: true }
    validates :source_id, uniqueness: { scope: %i[record_type record_id attribute_name] }
    validate :scope_is_one_of_the_four_levels

    attribute :record_type, default: ANY_TYPE
    attribute :record_id, default: ANY_ID
    attribute :attribute_name, default: ANY_ATTRIBUTE

    def self.model_type(model)
      model.base_class.polymorphic_name
    end

    def global?
      record_type == ANY_TYPE
    end

    # The rules that can apply to records of a model, indexed for `Resolver`: { [record_id, attribute_name, source_id] => precedence }
    def self.index_for(scope)
      scope.pluck(:record_id, :attribute_name, :source_id, :precedence).to_h { |record_id, attribute_name, source_id, precedence| [[record_id, attribute_name, source_id], precedence] }
    end

    # Answers the effective precedence of a source's value for one attribute of one record, loading the model-wide and
    # global rules once and taking the record's own rules from its in-memory association, so unsaved rules count too.
    class Resolver
      def initialize(model)
        @model = model
        @model_rules = PrecedenceRule.index_for(PrecedenceRule.for_model(model))
        @global_rules = PrecedenceRule.index_for(PrecedenceRule.global)
      end

      def precedence(record, attribute_name, source_id)
        attribute_name = attribute_name.to_s
        record_rule(record, attribute_name, source_id) || model_precedence(attribute_name, source_id) || global_precedence(source_id)
      end

      # The model-wide rule for an attribute and source, if there is one
      def model_precedence(attribute_name, source_id)
        @model_rules[[ANY_ID, attribute_name.to_s, source_id]] || @model_rules[[ANY_ID, ANY_ATTRIBUTE, source_id]]
      end

      def global_precedence(source_id)
        @global_rules[[ANY_ID, ANY_ATTRIBUTE, source_id]] || 0
      end

      private

      def record_rule(record, attribute_name, source_id)
        return unless record.respond_to?(:precedence_rules)

        record.precedence_rules.find { |rule| !rule.marked_for_destruction? && rule.attribute_name == attribute_name && rule.source_id == source_id }&.precedence
      end
    end

    private

    def scope_is_one_of_the_four_levels
      if record_type == ANY_TYPE
        errors.add(:base, 'a global rule cannot name a record or attribute') unless record_id == ANY_ID && attribute_name == ANY_ATTRIBUTE
      elsif record_id != ANY_ID && attribute_name == ANY_ATTRIBUTE
        errors.add(:attribute_name, 'is required for a rule on one record')
      end
    end
  end
end

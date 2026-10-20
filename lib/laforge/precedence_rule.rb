module LaForge
  # One rule ranking a source's values at one of four levels, from most to least specific:
  #
  #   record_type  record_id  attribute_name  applies to
  #   'Tenant'     1          'name'          one attribute of one record
  #   'Tenant'     0          'name'          one attribute of every record of a model
  #   'Tenant'     0          ''              every attribute of every record of a model
  #   ''           0          ''              everything (the source's global precedence)
  #
  # The middle two levels are a model's model-wide rules, and the first is a record's own rules. A value's effective
  # precedence is that of the most specific rule for its record, attribute and source.
  #
  # "Any" is stored as `ANY_TYPE`, `ANY_ID` or `ANY_ATTRIBUTE` and never as NULL, which a unique index lets repeat, so
  # the unique index on the scope and source covers every level. The generated `global_precedence` column holds the
  # precedence of global rules only, so a unique index on it keeps the global order free of ties.
  class PrecedenceRule < ::ActiveRecord::Base
    self.table_name = "laforge_precedence_rules"

    ANY_TYPE = ''.freeze
    ANY_ID = 0
    ANY_ATTRIBUTE = ''.freeze

    belongs_to :source, class_name: 'LaForge::DataSource'

    scope :global, -> { where(record_type: ANY_TYPE, record_id: ANY_ID, attribute_name: ANY_ATTRIBUTE) }
    scope :for_model, ->(model) { where(record_type: model_type(model), record_id: ANY_ID) }
    scope :for_records, ->(model) { where(record_type: model_type(model)).where.not(record_id: ANY_ID) }

    validates :precedence, presence: true, numericality: { only_integer: true }
    validates :source_id, uniqueness: { scope: %i[record_type record_id attribute_name] }
    validate :scope_is_one_of_the_four_levels

    # A rule change clears the precedence cache at once, so later forges in the same transaction see it, and a rollback
    # clears it again, so no forge sees the undone change
    after_save { PrecedenceCache.clear }
    after_destroy { PrecedenceCache.clear }
    after_rollback { PrecedenceCache.clear }

    attribute :record_type, default: ANY_TYPE
    attribute :record_id, default: ANY_ID
    attribute :attribute_name, default: ANY_ATTRIBUTE

    def self.model_type(model)
      model.base_class.polymorphic_name
    end

    def global?
      record_type == ANY_TYPE
    end

    # Returns the rules in `scope` as `{ [record_id, attribute_name, source_id] => precedence }`, for `Resolver` to
    # look up
    def self.index_for(scope)
      scope.pluck(:record_id, :attribute_name, :source_id, :precedence).to_h { |record_id, attribute_name, source_id, precedence| [[record_id, attribute_name, source_id], precedence] }
    end

    # Answers how a source's value for one attribute of one record ranks, loading the model-wide and global rules once and
    # taking the record's own rules from its in-memory association, so unsaved rules count too.
    #
    # Sources rank by level first: a source with a rule at a more specific level outranks every source whose most specific
    # rule is less specific, and precedences are compared within a level. So an order set at one level, such as one
    # record's order for an attribute, puts the sources it names above the rest, which keep the order of the next level.
    class Resolver
      def initialize(model)
        @model = model
        @groups = model.respond_to?(:laforge_attribute_group) ? model : nil
        type = PrecedenceRule.model_type(model)
        @model_rules = PrecedenceCache.fetch([:model, type]) { PrecedenceRule.index_for(PrecedenceRule.for_model(model)) }
        @global_rules = PrecedenceCache.fetch(:global) { PrecedenceRule.index_for(PrecedenceRule.global) }
      end

      # The source's rank, to compare with other sources' ranks for the same attribute and record: its precedence at each
      # level, most specific first, with -Infinity where it has no rule
      def rank(record, attribute_name, source_id)
        attribute_name = rule_name(attribute_name)
        levels = [record_rule(record, attribute_name, source_id), @model_rules[[ANY_ID, attribute_name, source_id]], @model_rules[[ANY_ID, ANY_ATTRIBUTE, source_id]]]
        levels.map { |precedence| precedence || -Float::INFINITY } + [global_precedence(source_id)]
      end

      # The precedence of the most specific rule for the source, which is the level it ranks at
      def precedence(record, attribute_name, source_id)
        attribute_name = rule_name(attribute_name)
        record_rule(record, attribute_name, source_id) || model_precedence(attribute_name, source_id) || global_precedence(source_id)
      end

      # Returns the precedence of the most specific model-wide rule for the attribute and source, or nil when there is
      # none
      def model_precedence(attribute_name, source_id)
        @model_rules[[ANY_ID, rule_name(attribute_name), source_id]] || @model_rules[[ANY_ID, ANY_ATTRIBUTE, source_id]]
      end

      # Returns the source's global precedence, or `-Float::INFINITY` when it has none, as for the entries of a deleted
      # source, so that source ranks below every other
      def global_precedence(source_id)
        @global_rules[[ANY_ID, ANY_ATTRIBUTE, source_id]] || -Float::INFINITY
      end

      private

      # The attribute group an attribute belongs to ranks it, so rules are set on the group
      def rule_name(attribute_name)
        @groups&.laforge_attribute_group(attribute_name) || attribute_name.to_s
      end

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

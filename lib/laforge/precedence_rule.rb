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
  # Sources rank by level first. A source with a rule at a more specific level outranks every source whose most specific
  # rule is less specific, precedences are compared only within a level, and global precedence breaks a tie. A
  # precedence order is the order of sources at one level, highest first, as `update_precedence_order` sets it. The
  # sources it lists rank above the rest, which keep the order of the next level down.
  #
  # Model-wide and global rules are base rules or belong to a ruleset (see `lib/laforge/rulesets.rb`), and a record's
  # own rules are stored as base rules but apply whatever its ruleset. `ruleset` holds the ruleset's name, or `BASE`.
  #
  # "Any" is stored as `ANY_TYPE`, `ANY_ID` or `ANY_ATTRIBUTE` and never as NULL, which a unique index lets repeat, so
  # the unique index on the scope, source and ruleset covers every level. The generated `global_precedence` column holds
  # the precedence of global rules only, so a unique index on it and `ruleset` keeps the global order of the base rules,
  # and of each ruleset, free of ties.
  #
  # Only a record's own rules can expire (see Expiring), so the model-wide and global rules `PrecedenceCache` holds do
  # not depend on the time.
  class PrecedenceRule < ::ActiveRecord::Base
    self.table_name = "laforge_precedence_rules"
    include Expiring

    ANY_TYPE = ''.freeze
    ANY_ID = 0
    ANY_ATTRIBUTE = ''.freeze
    BASE = ''.freeze
    # RULESET_LENGTH bounds a ruleset's name so the unique index on the scope, source and ruleset stays within MySQL's
    # 3072-byte index limit under utf8mb4, alongside the two 255-character strings
    RULESET_LENGTH = 100

    belongs_to :source, class_name: 'LaForge::DataSource'

    # `global` and `for_model` return base rules only. Chain `in_ruleset` to return a ruleset's, as in
    # `global.in_ruleset('north')`.
    scope :global, -> { where(record_type: ANY_TYPE, record_id: ANY_ID, attribute_name: ANY_ATTRIBUTE, ruleset: BASE) }
    scope :for_model, ->(model) { where(record_type: model_type(model), record_id: ANY_ID, ruleset: BASE) }
    scope :for_records, ->(model) { where(record_type: model_type(model)).where.not(record_id: ANY_ID) }
    scope :in_ruleset, ->(ruleset) { rewhere(ruleset: ruleset) }

    validates :precedence, presence: true, numericality: { only_integer: true }
    validates :source_id, uniqueness: { scope: %i[record_type record_id attribute_name ruleset] }
    validates :precedence, uniqueness: { scope: :ruleset, conditions: -> { where(record_type: ANY_TYPE) } }, if: -> { global? && ruleset != BASE }
    validate :scope_is_one_of_the_four_levels
    validate :expires_only_on_one_record
    # Checked on update too, as `update!(ruleset:)` or `update!(record_id:)` could otherwise move a rule where LaForge
    # would never write it
    validate :ruleset_written_through_laforge, if: -> { will_save_change_to_ruleset? || will_save_change_to_record_id? }

    # A rule change clears the precedence cache at once, so later forges in the same transaction see it, and a rollback
    # clears it again, so no forge sees the undone change
    after_save { PrecedenceCache.clear }
    after_destroy { PrecedenceCache.clear }
    after_rollback { PrecedenceCache.clear }

    attribute :record_type, default: ANY_TYPE
    attribute :record_id, default: ANY_ID
    attribute :attribute_name, default: ANY_ATTRIBUTE
    attribute :ruleset, default: BASE

    def self.model_type(model)
      model.base_class.polymorphic_name
    end

    # Returns the stored name for a `ruleset:` argument, as a String stripped of surrounding whitespace, and `BASE` for
    # nil or a blank name. Raises, naming `where`, for anything but a String, Symbol or nil, and for a name longer than
    # `RULESET_LENGTH`.
    def self.ruleset_name(ruleset, where:)
      unless ruleset.nil? || ruleset.is_a?(String) || ruleset.is_a?(Symbol)
        raise ArgumentError, "#{where}: ruleset: must be a String or Symbol naming the ruleset, or nil for the base rules, not #{ruleset.class} #{ruleset.inspect}"
      end

      name = ruleset.to_s.strip
      raise ArgumentError, "#{where}: ruleset: #{name.inspect} is longer than #{RULESET_LENGTH} characters; pass a shorter name" if name.length > RULESET_LENGTH

      name
    end

    # Returns whether the ruleset is in use, and false for `BASE`
    def self.ruleset_in_use?(ruleset)
      return false if ruleset == BASE

      PrecedenceCache.fetch([:ruleset, ruleset]) { where(ruleset: ruleset).exists? }
    end

    def global?
      record_type == ANY_TYPE
    end

    # Returns the rules in `scope` as `{ [record_id, attribute_name, source_id] => precedence }`, for `Resolver` to
    # look up
    def self.index_for(scope)
      scope.pluck(:record_id, :attribute_name, :source_id, :precedence).to_h { |record_id, attribute_name, source_id, precedence| [[record_id, attribute_name, source_id], precedence] }
    end

    # Used to rank a source's value for one attribute of a record. It reads a model's model-wide rules and the global
    # rules once, through `PrecedenceCache`, and takes a record's own rules from its in-memory association, so unsaved
    # rules count, and rules marked for destruction or expired do not. The model-wide and global rules are those of the
    # ruleset given when it is in use, and the base rules otherwise.
    class Resolver
      # The ruleset it ranks by, or nil when it ranks by the base rules
      attr_reader :ruleset

      def initialize(model, ruleset: nil)
        @model = model
        @groups = model.respond_to?(:laforge) ? model.laforge : nil
        @ruleset = ruleset if ruleset.present? && PrecedenceRule.ruleset_in_use?(ruleset)
        stored = @ruleset || BASE
        type = PrecedenceRule.model_type(model)
        @model_rules = PrecedenceCache.fetch([:model, type, stored]) { PrecedenceRule.index_for(PrecedenceRule.for_model(model).in_ruleset(stored)) }
        @global_rules = PrecedenceCache.fetch([:global, stored]) { PrecedenceRule.index_for(PrecedenceRule.global.in_ruleset(stored)) }
      end

      # Returns the source's rank for the attribute on `record`, which compares with `<=>` to other sources' ranks for
      # the same attribute and record. It holds a precedence for each of the record, attribute and model levels, which
      # is that of the source's most specific rule at that rule's level and `-Float::INFINITY` at the others, then the
      # source's global precedence. A source with only a model-wide rule of 3 and a global precedence of 7 ranks
      # `[-Infinity, -Infinity, 3, 7]`. A nil `record` has no rules of its own.
      def rank(record, attribute_name, source_id)
        attribute_name = rule_name(attribute_name)
        attribute_rule = @model_rules[[ANY_ID, attribute_name, source_id]] unless attribute_name == ANY_ATTRIBUTE # its rule is the model level
        levels = [record_rule(record, attribute_name, source_id), attribute_rule, @model_rules[[ANY_ID, ANY_ATTRIBUTE, source_id]]]
        specific = levels.index { |precedence| !precedence.nil? }
        levels.each_with_index.map { |precedence, index| index == specific ? precedence : -Float::INFINITY } + [global_precedence(source_id)]
      end

      # Returns the precedence of the source's most specific rule for the attribute on `record`, or its global
      # precedence (see `global_precedence`) when it has no other
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

      # Returns the name an attribute's rules are stored under, which is its attribute group's name when it is in one
      def rule_name(attribute_name)
        @groups&.group_of(attribute_name) || attribute_name.to_s
      end

      def record_rule(record, attribute_name, source_id)
        return unless record.respond_to?(:precedence_rules)

        record.precedence_rules.find { |rule| !rule.marked_for_destruction? && !rule.expired? && rule.attribute_name == attribute_name && rule.source_id == source_id }&.precedence
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

    # Raises for a rule on one record given a ruleset, and for a rule in a ruleset not yet in use, which LaForge forks
    # before writing its first rule
    def ruleset_written_through_laforge
      return if ruleset == BASE

      if record_id != ANY_ID
        raise ArgumentError, "A precedence rule on one record belongs to the base rules, not ruleset #{ruleset.inspect}: a record's own rules apply whatever its ruleset. Leave out ruleset:"
      end
      return if PrecedenceRule.where(ruleset: ruleset).exists?

      raise ArgumentError, "Ruleset #{ruleset.inspect} has no rules yet, and its first rule copies the base rules into it. Write it with Model.update_precedence_order(..., ruleset:) " \
                           'or LaForge.update_precedence_order(..., ruleset:), or call LaForge.fork_ruleset first'
    end

    def expires_only_on_one_record
      return if record_id != ANY_ID || (expires_at.nil? && expires_on_source_id.nil?)

      rule = global? ? 'a global rule' : "a model-wide rule on #{record_type}"
      raise ArgumentError, "Only a precedence rule on one record can expire, and this is #{rule}. Model-wide and global rules are configuration: " \
                           'leave out expires_at and expires_on_source, and set the order again when it should change, or set the rule on each record'
    end
  end
end

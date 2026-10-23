module LaForge
  # Used to set and read the precedence rules of a laforged record and, in the class methods, of its model
  module Precedence
    extend ActiveSupport::Concern

    API = %i[update_attribute_source_precedence update_precedence_order precedence_order source_precedences].freeze
    CLASS_API = %i[update_attribute_source_precedence update_source_precedence update_precedence_order precedence_order source_precedences].freeze

    # Set the precedence of a source for one attribute, or one attribute group, of this record, whether or not the
    # source has recorded it yet. Saved immediately on a persisted record, otherwise with the record. Pass nil to remove
    # it. Raises for an attribute in a group, whose precedence is set on the group.
    # `expires_at:` and `expires_on:` expire the precedence (see Expiring). Setting it again replaces the expiry,
    # leaving them out clears it, and passing either with a nil precedence raises.
    def update_attribute_source_precedence(attribute, source, precedence, expires_at: nil, expires_on: nil)
      self.class.assert_rule_attribute!(attribute)
      settings = RecordingSettings.given(precedence: precedence, expires_at: expires_at, expires_on: expires_on, where: "#{record.class.name}#update_attribute_source_precedence(:#{attribute})",
                                         removing: ("a nil precedence" if precedence.nil?))
      rule = write_precedence_rule(attribute, source, settings)
      return unless record.persisted? && rule

      rule.marked_for_destruction? ? record.precedence_rules.destroy(rule) : rule.save!
    end

    # Set the precedence order of this record's own rules for one attribute, or attribute group. It replaces the
    # record's other rules for the attribute, so nil or [] removes them. Saved with the record. Raises for an attribute
    # in a group, whose precedence is set on the group.
    # `expires_at:` and `expires_on:` expire the order (see Expiring), after which the next level's order applies.
    # Setting it again replaces the expiry, leaving them out clears it, and passing either with no sources raises.
    def update_precedence_order(attribute, sources, expires_at: nil, expires_on: nil)
      self.class.assert_rule_attribute!(attribute)
      source_ids = DataSource.normalize_source_ids(sources)
      settings = RecordingSettings.given(expires_at: expires_at, expires_on: expires_on, where: "#{record.class.name}#update_precedence_order(:#{attribute})", removing: ("no sources" if source_ids.empty?))
      record.precedence_rules.select { |rule| rule.attribute_name == attribute.to_s && !source_ids.include?(rule.source_id) }.each { |rule| write_precedence_rule(attribute, rule.source_id, settings.with_precedence(nil)) }
      source_ids.each_with_index { |source_id, index| write_precedence_rule(attribute, source_id, settings.with_precedence(source_ids.size - index)) }
    end

    # Returns the active sources in the order they rank for one attribute of this record, as [{ source:, level: }]. An
    # attribute in a group ranks as its group. The level is the most specific one the source has a rule at, :record,
    # :attribute, :model or :global, or nil when it has none.
    def precedence_order(attribute)
      resolver = PrecedenceRule::Resolver.new(record.class) # not the last forge's, so rules changed since then count
      LaForge::ActiveRecord.order_by_rank(DataSource.active.to_a, %i[record attribute model global]) { |source| resolver.rank(record, attribute, source.id) }
    end

    # Returns `{ attribute_name => { source => precedence } }` for this record's own rules, unsaved ones included and
    # those marked for destruction or expired left out
    def source_precedences
      record.precedence_rules.reject { |rule| rule.marked_for_destruction? || rule.expired? }.group_by(&:attribute_name).transform_values { |rules| rules.to_h { |rule| [rule.source, rule.precedence] } }
    end

    # @api private
    # Sets the record's rule for the attribute and source in memory from the settings, and returns it. A rule the
    # settings create or change is noted as made, and its `recorded_at` set, at `made_at` when given or now (see
    # Expiring#remade). With a nil precedence, marks a saved rule for destruction and returns it, or otherwise drops any
    # unsaved rule and returns nil.
    def write_precedence_rule(attribute_name, source, settings, made_at: nil)
      source_id = DataSource.normalize_source_id(source)
      rule = record.precedence_rules.find { |candidate| candidate.attribute_name == attribute_name.to_s && candidate.source_id == source_id }

      if settings.precedence.nil?
        return unless rule

        if rule.new_record?
          record.precedence_rules.target.delete(rule)
          return
        end
        rule.mark_for_destruction
      else
        rule ||= record.precedence_rules.build(attribute_name: attribute_name.to_s, source_id: source_id)
        LaForge::ActiveRecord.set_marked_for_destruction(rule, false) # setting a precedence again undoes an unsaved removal
        columns = %w[precedence expires_at expires_on_source_id]
        before = rule.attributes.slice(*columns) # in memory, so setting back an expiry that fired since the save is a change
        settings.apply_to_rule(rule)
        if rule.new_record? || before != rule.attributes.slice(*columns) || columns.any? { |column| rule.will_save_change_to_attribute?(column) }
          rule.recorded_at = made_at || Time.current
          rule.remade(made_at)
        end
      end
      rule
    end

    # @api private
    # Returns the effective precedence of `data_entry` on the record
    def precedence_of(data_entry)
      resolver.precedence(record, data_entry.attribute_name, data_entry.source_id)
    end

    # @api private
    # Returns the rank of `data_entry`'s source for its attribute on the record (see `PrecedenceRule::Resolver#rank`)
    def rank_of(data_entry)
      resolver.rank(record, data_entry.attribute_name, data_entry.source_id)
    end

    # @api private
    # Whether one source's value for an attribute of the record outranks another's
    def outranks?(attribute_name, source_id, other_source_id)
      rank = ->(id) { resolver.rank(record, attribute_name, id) }
      (rank.(source_id) <=> rank.(other_source_id)) == 1
    end

    # @api private
    # Returns the precedence resolver the record ranks by, kept until `reset_resolver`
    def resolver
      @resolver ||= PrecedenceRule::Resolver.new(record.class)
    end

    # @api private
    # Forgets the model-wide and global rules the resolver read, so the next ranking reads them again
    def reset_resolver
      @resolver = nil
    end

    class_methods do
      # Set and save the precedence of a source for one attribute, or one attribute group, on every record of this
      # model. Pass nil to remove it. Raises for an attribute in a group, whose precedence is set on the group.
      def update_attribute_source_precedence(attribute, source, precedence)
        assert_rule_attribute!(attribute)
        update_model_precedence_rule(attribute.to_s, source, precedence)
      end

      # Set and save the precedence of a source for every attribute on every record of this model. Pass nil to remove
      # it.
      def update_source_precedence(source, precedence)
        update_model_precedence_rule(PrecedenceRule::ANY_ATTRIBUTE, source, precedence)
      end

      # Set and save the precedence order of this model's model-wide rules for one attribute, or attribute group, or for
      # every attribute when `attribute` is nil. It replaces every rule at that level, so nil or [] removes them. Raises
      # for an attribute in a group, whose precedence is set on the group.
      def update_precedence_order(sources, attribute: nil)
        assert_rule_attribute!(attribute) if attribute
        attribute_name = attribute ? attribute.to_s : PrecedenceRule::ANY_ATTRIBUTE
        source_ids = DataSource.normalize_source_ids(sources)

        model.transaction do
          PrecedenceRule.for_model(model).where(attribute_name: attribute_name).where.not(source_id: source_ids).destroy_all
          source_ids.each_with_index { |source_id, index| update_model_precedence_rule(attribute_name, source_id, source_ids.size - index) }
        end
      end

      # Returns the active sources in the order they rank for one attribute, or for every attribute when `attribute` is
      # nil, on a record of this model with no rules of its own, as [{ source:, level: }]. An attribute in a group ranks
      # as its group. The level is the most specific one the source has a rule at, :attribute, :model or :global, or nil
      # when it has none.
      def precedence_order(attribute: nil)
        resolver = PrecedenceRule::Resolver.new(model)
        LaForge::ActiveRecord.order_by_rank(DataSource.active.to_a, %i[record attribute model global]) { |source| resolver.rank(nil, attribute.to_s, source.id) }
      end

      # Returns `{ attribute_name => { source => precedence } }` for this model's model-wide rules. A rule for every
      # attribute is keyed by `PrecedenceRule::ANY_ATTRIBUTE`.
      def source_precedences
        PrecedenceRule.for_model(model).includes(:source).group_by(&:attribute_name).transform_values { |rules| rules.to_h { |rule| [rule.source, rule.precedence] } }
      end

      # @api private
      # Raises when `attribute` is in an attribute group, since its precedence rules are set on the group
      def assert_rule_attribute!(attribute)
        group = group_of(attribute)
        raise ArgumentError, "#{model.name}##{attribute} is in attribute group #{group}, which is ranked as a whole; set the precedence on #{group}" if group
      end

      private

      def update_model_precedence_rule(attribute_name, source, precedence)
        rules = PrecedenceRule.for_model(model).where(attribute_name: attribute_name, source_id: DataSource.normalize_source_id(source))
        return rules.destroy_all if precedence.nil?

        rule = rules.first_or_initialize
        rule.update!(precedence: precedence)
      end
    end
  end
end

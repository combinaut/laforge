module LaForge
  # Used to set and read the precedence rules of a laforged record and, in the class methods, of its model
  module Precedence
    extend ActiveSupport::Concern

    API = %i[update_attribute_source_precedence source_precedences].freeze
    CLASS_API = %i[update_attribute_source_precedence update_source_precedence source_precedences].freeze

    # Set the precedence of a source for one attribute of this record, whether or not the source has recorded it yet.
    # Saved immediately on a persisted record, otherwise with the record. Pass nil to remove it.
    def update_attribute_source_precedence(attribute, source, precedence)
      rule = write_precedence_rule(attribute, source, precedence)
      return unless record.persisted? && rule

      rule.marked_for_destruction? ? record.precedence_rules.destroy(rule) : rule.save!
    end

    # Returns `{ attribute_name => { source => precedence } }` for this record's own rules, unsaved ones included and
    # those marked for destruction left out
    def source_precedences
      record.precedence_rules.reject(&:marked_for_destruction?).group_by(&:attribute_name).transform_values { |rules| rules.to_h { |rule| [rule.source, rule.precedence] } }
    end

    # @api private
    # Sets the record's rule for the attribute and source in memory, and returns it. With a nil `precedence`, marks a
    # saved rule for destruction and returns it, or otherwise drops any unsaved rule and returns nil.
    def write_precedence_rule(attribute_name, source, precedence)
      source_id = DataSource.normalize_source_id(source)
      rule = record.precedence_rules.find { |candidate| candidate.attribute_name == attribute_name.to_s && candidate.source_id == source_id }

      if precedence.nil?
        return unless rule

        if rule.new_record?
          record.precedence_rules.target.delete(rule)
          return
        end
        rule.mark_for_destruction
      else
        rule ||= record.precedence_rules.build(attribute_name: attribute_name.to_s, source_id: source_id)
        LaForge::ActiveRecord.set_marked_for_destruction(rule, false) # setting a precedence again undoes an unsaved removal
        rule.precedence = precedence
      end
      rule
    end

    # @api private
    # Returns the effective precedence of `data_entry` on the record
    def precedence_of(data_entry)
      resolver.precedence(record, data_entry.attribute_name, data_entry.source_id)
    end

    # @api private
    # Returns the global precedence of the source with `source_id`, or `-Float::INFINITY` when it has none
    def global_precedence(source_id)
      resolver.global_precedence(source_id)
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
      # Set and save the precedence of a source for one attribute on every record of this model. Pass nil to remove it.
      def update_attribute_source_precedence(attribute, source, precedence)
        update_model_precedence_rule(attribute.to_s, source, precedence)
      end

      # Set and save the precedence of a source for every attribute on every record of this model. Pass nil to remove
      # it.
      def update_source_precedence(source, precedence)
        update_model_precedence_rule(PrecedenceRule::ANY_ATTRIBUTE, source, precedence)
      end

      # Returns `{ attribute_name => { source => precedence } }` for this model's model-wide rules. A rule for every
      # attribute is keyed by `PrecedenceRule::ANY_ATTRIBUTE`.
      def source_precedences
        PrecedenceRule.for_model(model).includes(:source).group_by(&:attribute_name).transform_values { |rules| rules.to_h { |rule| [rule.source, rule.precedence] } }
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

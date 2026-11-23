module LaForge
  # `Precedence` is used to set and read the precedence rules of a laforged record and, in the class methods, of its
  # model
  module Precedence
    extend ActiveSupport::Concern

    API = %i[update_attribute_source_precedence update_source_precedence update_precedence_order precedence_order source_precedences].freeze
    CLASS_API = %i[update_attribute_source_precedence update_source_precedence update_precedence_order precedence_order source_precedences].freeze
    # What to do instead of passing a blank `attribute:` to an order, for the error that refuses it
    EVERY_ATTRIBUTE_ORDER = 'leave out attribute: for the order for every attribute'

    # Set the precedence of a source for one attribute, or one attribute group, of this record, whether or not the
    # source has an entry for it yet. Saved immediately on a persisted record, otherwise with the record. Pass nil to
    # remove it. Raises for a nil or blank attribute, which names none, for an attribute in a group, whose precedence is
    # set on the group, and for a `ruleset:`, since a record's own rules apply whatever its ruleset.
    # `expires_at:`, `expires_on:` and `expires_when:` expire the precedence (see Expiring). Setting it again replaces
    # the expiry, leaving them out clears it, and passing any with a nil precedence raises. With
    # `expires_when: :matches`, raises as `assert_can_match!` does.
    def update_attribute_source_precedence(attribute, source, precedence, expires_at: nil, expires_on: nil, expires_when: nil, ruleset: nil)
      assert_no_ruleset!(ruleset, :update_attribute_source_precedence)
      self.class.assert_rule_attribute!(attribute, where: "#{record.class.name}#update_attribute_source_precedence", instead: 'set the precedence for every attribute with update_source_precedence(source, precedence)')
      update_record_precedence_rule(attribute.to_s, source, precedence, where: "#{record.class.name}#update_attribute_source_precedence(:#{attribute})",
                                    expires_at: expires_at, expires_on: expires_on, expires_when: expires_when)
    end

    # Set the precedence of a source for every attribute of this record, below the record's rules for single
    # attributes, as `update_attribute_source_precedence` does for one attribute. Raises for `expires_when: :matches`,
    # which compares one attribute's values (see `assert_can_match!`).
    def update_source_precedence(source, precedence, expires_at: nil, expires_on: nil, expires_when: nil, ruleset: nil)
      assert_no_ruleset!(ruleset, :update_source_precedence)
      update_record_precedence_rule(PrecedenceRule::ANY_ATTRIBUTE, source, precedence, where: "#{record.class.name}#update_source_precedence",
                                    instead: 'Use update_attribute_source_precedence(attribute, ...) for each attribute whose precedence should end on a match',
                                    expires_at: expires_at, expires_on: expires_on, expires_when: expires_when)
    end

    # Set the precedence order of this record's own rules for one attribute, or attribute group, given as `attribute:`,
    # or without `attribute:`, for every attribute, below the record's orders for single attributes. It replaces the
    # record's rules at that level alone, so nil or [] removes the order at that level and leaves the other. Saved with
    # the record. Raises for a blank `attribute:`, which names none, for an attribute in a group, whose precedence is set
    # on the group, and for a `ruleset:`, since a record's own rules apply whatever its ruleset.
    # `expires_at:`, `expires_on:` and `expires_when:` expire the order (see Expiring), after which the next level's
    # order applies. Setting it again replaces the expiry, leaving them out clears it, and passing any with no sources
    # raises. With `expires_when: :matches`, each source's rule expires on its own, and raises as `assert_can_match!`
    # does, so the order for every attribute raises for it.
    def update_precedence_order(sources, attribute: nil, expires_at: nil, expires_on: nil, expires_when: nil, ruleset: nil)
      assert_no_ruleset!(ruleset, :update_precedence_order)
      self.class.assert_rule_attribute!(attribute, where: "#{record.class.name}#update_precedence_order", instead: Precedence::EVERY_ATTRIBUTE_ORDER) unless attribute.nil?
      attribute_name = attribute ? attribute.to_s : PrecedenceRule::ANY_ATTRIBUTE
      source_ids = DataSource.normalize_source_ids(sources)
      where = "#{record.class.name}#update_precedence_order#{"(attribute: :#{attribute})" if attribute}"
      settings = RecordingSettings.given(expires_at: expires_at, expires_on: expires_on, expires_when: expires_when, where: where, removing: ("no sources" if source_ids.empty?))
      assert_can_match!(attribute_name, source_ids, settings, where: where, instead: 'Pass attribute: for each attribute whose order should end on a match')
      record.precedence_rules.select { |rule| rule.attribute_name == attribute_name && !source_ids.include?(rule.source_id) }.each { |rule| write_precedence_rule(attribute_name, rule.source_id, settings.with_precedence(nil)) }
      rules = source_ids.each_with_index.map { |source_id, index| write_precedence_rule(attribute_name, source_id, settings.with_precedence(source_ids.size - index)) }
      expire_matched(rules) if settings.trigger.compares_values?
    end

    # Returns the active sources in the order they rank for one attribute of this record, or for every attribute when
    # `attribute` is nil, as [{ source:, level:, precedence:, ruleset: }]. An attribute in a group ranks as its group.
    # The level is the most specific one the source has a rule at, :record_attribute, :record, :model_attribute,
    # :model or :global, or nil when it has none, and the precedence is that rule's, or nil with a nil level. With a
    # nil `attribute`, the levels are :record, :model and :global. The ruleset is the one ranked by, nil for the base
    # rules, at the :record_attribute and :record levels, or with a nil level. Raises for a blank `attribute:`, which
    # names none.
    def precedence_order(attribute: nil)
      self.class.assert_attribute_named!(attribute, where: "#{record.class.name}#precedence_order", instead: Precedence::EVERY_ATTRIBUTE_ORDER) unless attribute.nil?
      # Not the last forge's resolver, so the ruleset and rules as they are now count
      resolver = PrecedenceRule::Resolver.new(record.class, ruleset: LaForge.ruleset_for(record))
      DataSource.precedence_order(attribute, resolver: resolver, record: record)
    end

    # Returns `{ attribute_name => { source => precedence } }` for this record's own rules, unsaved ones included and
    # those marked for destruction or expired left out. A rule for every attribute is keyed by
    # `PrecedenceRule::ANY_ATTRIBUTE`.
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
        columns = ['precedence', *Expiring::COLUMNS]
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
    # Expires each of `rules` that already matches, and nothing else. Setting a rule saves that rule alone, so a sweep of
    # the record could expire other rows in memory only. They are checked at the next recording (see ExpirySweep).
    def expire_matched(rules)
      rules.each { |rule| ExpirySweep.new(self, rule.source_id, rule.recorded_at).run([rule]) }
    end

    # @api private
    # Raises when settings that expire on a match can't apply to the record's rules for `attribute`, or attribute group,
    # and the sources `source_ids`. A rule has no value of its own, so it compares its source's entry, which must exist
    # and must not be the entry it would compare with. A record's rule for every attribute, for
    # `PrecedenceRule::ANY_ATTRIBUTE`, has no one entry to compare, so it raises naming `where`, and `instead`, what to
    # call for one attribute. A tracked association raises as `AssociationConfig#assert_no_match!` does.
    def assert_can_match!(attribute, source_ids, settings, where:, instead: nil)
      return unless settings.trigger.compares_values?

      name = attribute.to_s
      if name == PrecedenceRule::ANY_ATTRIBUTE
        raise ArgumentError, "#{where}: expires_when: :matches compares a rule's source's value for one attribute with that of expires_on:, and a rule for every attribute has no one value to compare. " \
                             "#{instead}, or expire this one with expires_when: :changes or :records"
      end
      associations[name]&.assert_no_match!(settings)
      if source_ids.include?(settings.expiry[:expires_on_source_id])
        raise ArgumentError, "#{record.class.name}##{name}: expires_when: :matches compares each source's value with that of expires_on:, which is one of these sources, so its rule would match itself. " \
                             'Leave that source out, or leave out expires_when:'
      end

      self.class.attributes_of(name).product(source_ids).each do |attribute_name, source_id|
        next if provided_entry(attribute_name, source_id)

        raise ArgumentError, "#{record.class.name}##{name}: #{DataSource.find(source_id).name} provides no value for #{attribute_name} on this record, and expires_when: :matches compares a rule's source's value. " \
                             'Record a value from that source first, or leave out expires_when:'
      end
    end

    # @api private
    # Raises unless `ruleset` is nil, naming `method` and the model-wide method that takes a ruleset
    def assert_no_ruleset!(ruleset, method)
      return if ruleset.nil?

      raise ArgumentError, "#{record.class.name}##{method} sets this record's own rules, which apply whatever its ruleset, so it takes no ruleset:. " \
                           "Leave it out, or set the rule for every record in the ruleset with #{record.class.name}.#{method}(..., ruleset:)"
    end

    # @api private
    # Yields with the record's current ruleset, which is selected once, now, and held while the block runs, so everything
    # the block ranks on the record uses that one ruleset. Inside an outer call on the record, yields with the ruleset
    # the outer call holds. Only this record's ruleset is held. Each member of a tracked association holds its own
    # during its own forge.
    def with_current_ruleset
      return yield if @ruleset_held

      begin
        @resolver = nil
        resolver
        @ruleset_held = true
        yield
      ensure
        @ruleset_held = false
      end
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
    # Returns the precedence resolver the record ranks by, made with the ruleset its selector selects when the resolver
    # is first needed after `reset_resolver_unless_held` or a reload forgot it
    def resolver
      @resolver ||= PrecedenceRule::Resolver.new(record.class, ruleset: LaForge.ruleset_for(record))
    end

    # @api private
    # Forgets the resolver, so the next ranking selects the ruleset and reads the model-wide and global rules again,
    # unless `with_current_ruleset` holds the ruleset
    def reset_resolver_unless_held
      @resolver = nil unless @ruleset_held
    end

    private

    # Sets the record's rule for `attribute_name` and the source to `precedence`, with the expiry the `expiry` keywords
    # give, and saves it at once on a persisted record. `where` and `instead` are for `assert_can_match!`.
    def update_record_precedence_rule(attribute_name, source, precedence, where:, instead: nil, **expiry)
      settings = RecordingSettings.given(precedence: precedence, **expiry, where: where, removing: ("a nil precedence" if precedence.nil?))
      assert_can_match!(attribute_name, [DataSource.normalize_source_id(source)], settings, where: where, instead: instead)
      rule = write_precedence_rule(attribute_name, source, settings)
      expire_matched([rule]) if settings.trigger.compares_values?
      return unless record.persisted? && rule

      rule.marked_for_destruction? ? record.precedence_rules.destroy(rule) : rule.save!
    end

    class_methods do
      # Set and save the precedence of a source for one attribute, or one attribute group, on every record of this
      # model, in the base rules or in a ruleset. Pass nil to remove it. Raises for a nil or blank attribute, which names
      # none, and for an attribute in a group, whose precedence is set on the group.
      def update_attribute_source_precedence(attribute, source, precedence, ruleset: nil)
        assert_rule_attribute!(attribute, where: "#{model.name}.update_attribute_source_precedence", instead: 'set the precedence for every attribute with update_source_precedence(source, precedence)')
        update_model_precedence_rule(attribute.to_s, source, precedence, PrecedenceRule.ruleset_name(ruleset, where: "#{model.name}.update_attribute_source_precedence"))
      end

      # Set and save the precedence of a source for every attribute on every record of this model, in the base rules or
      # in a ruleset. Pass nil to remove it.
      def update_source_precedence(source, precedence, ruleset: nil)
        update_model_precedence_rule(PrecedenceRule::ANY_ATTRIBUTE, source, precedence, PrecedenceRule.ruleset_name(ruleset, where: "#{model.name}.update_source_precedence"))
      end

      # Set and save the precedence order of this model's model-wide rules for one attribute, or attribute group, or for
      # every attribute when `attribute` is nil, in the base rules or in a ruleset. It replaces every rule at that
      # level, so nil or [] removes them. Raises for a blank `attribute:`, which names none, and for an attribute in a
      # group, whose precedence is set on the group.
      def update_precedence_order(sources, attribute: nil, ruleset: nil)
        assert_rule_attribute!(attribute, where: "#{model.name}.update_precedence_order", instead: EVERY_ATTRIBUTE_ORDER) unless attribute.nil?
        attribute_name = attribute ? attribute.to_s : PrecedenceRule::ANY_ATTRIBUTE
        source_ids = DataSource.normalize_source_ids(sources)
        ruleset = PrecedenceRule.ruleset_name(ruleset, where: "#{model.name}.update_precedence_order")

        model.transaction do
          LaForge.fork_ruleset(ruleset) unless ruleset == PrecedenceRule::BASE
          PrecedenceRule.for_model(model).in_ruleset(ruleset).where(attribute_name: attribute_name).where.not(source_id: source_ids).destroy_all
          source_ids.each_with_index { |source_id, index| update_model_precedence_rule(attribute_name, source_id, source_ids.size - index, ruleset) }
        end
      end

      # Returns the active sources in the order they rank for one attribute, or for every attribute when `attribute` is
      # nil, on a record of this model with no rules of its own, by the base rules or by a ruleset, as
      # [{ source:, level:, precedence:, ruleset: }]. An attribute in a group ranks as its group. The level is the most
      # specific one the source has a rule at, :model_attribute, :model or :global, or nil when it has none, and the
      # precedence is that rule's, or nil with a nil level. The ruleset is the one ranked by, nil for the base rules,
      # for a ruleset not in use, or with a nil level. Raises for a blank `attribute:`, which names none.
      def precedence_order(attribute: nil, ruleset: nil)
        assert_attribute_named!(attribute, where: "#{model.name}.precedence_order", instead: EVERY_ATTRIBUTE_ORDER) unless attribute.nil?
        resolver = PrecedenceRule::Resolver.new(model, ruleset: PrecedenceRule.ruleset_name(ruleset, where: "#{model.name}.precedence_order"))
        DataSource.precedence_order(attribute, resolver: resolver)
      end

      # Returns `{ attribute_name => { source => precedence } }` for this model's model-wide rules, in the base rules or
      # in a ruleset. A rule for every attribute is keyed by `PrecedenceRule::ANY_ATTRIBUTE`.
      def source_precedences(ruleset: nil)
        rules = PrecedenceRule.for_model(model).in_ruleset(PrecedenceRule.ruleset_name(ruleset, where: "#{model.name}.source_precedences"))
        rules.includes(:source).group_by(&:attribute_name).transform_values { |list| list.to_h { |rule| [rule.source, rule.precedence] } }
      end

      # @api private
      # Raises as `assert_attribute_named!` does, and when `attribute` is in an attribute group, since its precedence
      # rules are set on the group
      def assert_rule_attribute!(attribute, where:, instead:)
        assert_attribute_named!(attribute, where: where, instead: instead)
        group = group_of(attribute)
        raise ArgumentError, "#{model.name}##{attribute} is in attribute group #{group}, which is ranked as a whole; set the precedence on #{group}" if group
      end

      # @api private
      # Raises when `attribute` is nil or blank, naming `where`. Rules for every attribute are stored under a blank name,
      # so without this it would silently stand for every attribute. `instead` says what to call for every attribute.
      def assert_attribute_named!(attribute, where:, instead:)
        return unless attribute.to_s.blank?

        raise ArgumentError, "#{where} was given #{attribute.inspect} for the attribute, which names no attribute. Pass an attribute's name, or #{instead}"
      end

      private

      def update_model_precedence_rule(attribute_name, source, precedence, ruleset)
        model.transaction do
          LaForge.fork_ruleset(ruleset) unless ruleset == PrecedenceRule::BASE
          rules = PrecedenceRule.for_model(model).in_ruleset(ruleset).where(attribute_name: attribute_name, source_id: DataSource.normalize_source_id(source))
          next rules.destroy_all if precedence.nil?

          rules.first_or_initialize.update!(precedence: precedence)
        end
      end
    end
  end
end

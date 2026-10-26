module LaForge
  # Rulesets let groups of records rank their sources in different orders while sharing the sources, data entries and
  # records' own rules. The vocabulary, used throughout LaForge:
  # - ruleset: a named set of model-wide and global rules (see PrecedenceRule)
  # - base rules: the model-wide and global rules of no ruleset
  # - ruleset selector: names a record's ruleset. It is `ruleset_selector`, or the model's own
  #   `laforged ruleset_selector:`.
  # - in use: a ruleset is in use when it has rules. Below its own rules, a record ranks by its selected ruleset when
  #   that ruleset is in use, and by the base rules otherwise. The two are never mixed.
  # - forking: copying every base rule into a ruleset, in the same transaction as the ruleset's first rule, so its
  #   records rank as before except for that rule. A forked ruleset does not follow later changes to the base rules.
  class << self
    # The ruleset selector of every laforged model without one of its own. It is a method name (Symbol) the record
    # responds to, a Proc given the record, or nil for the base rules. It is called when a record is forged or ranked,
    # and its value is turned into a String, nil or blank selecting the base rules.
    attr_reader :ruleset_selector

    def ruleset_selector=(selector)
      assert_ruleset_selector!(selector, where: 'LaForge.ruleset_selector =')
      @ruleset_selector = selector
    end

    # Forks the ruleset unless it is in use already. Raises for nil or a blank name, which stand for the base rules.
    # Writing a ruleset's first rule forks it, so calling this ahead of time only makes the copy before anything
    # changes. The unique indexes skip the rows another process's fork inserted first.
    def fork_ruleset(ruleset)
      ruleset = named_ruleset(ruleset, where: 'LaForge.fork_ruleset')
      return if PrecedenceRule.where(ruleset: ruleset).exists?

      # A copy keeps its base rule's `recorded_at`, since forking changes no ranking
      columns = %i[record_type attribute_name source_id precedence recorded_at]
      copies = PrecedenceRule.where(ruleset: PrecedenceRule::BASE, record_id: PrecedenceRule::ANY_ID).pluck(*columns).map do |values|
        columns.zip(values).to_h.merge(record_id: PrecedenceRule::ANY_ID, ruleset: ruleset)
      end
      PrecedenceRule.insert_all(copies) if copies.any?
      clear_cache_now_and_on_rollback
    end

    # Deletes the ruleset's rules, so the records it is selected for rank by the base rules again. Raises for nil or a
    # blank name.
    def reset_ruleset(ruleset)
      PrecedenceRule.where(ruleset: named_ruleset(ruleset, where: 'LaForge.reset_ruleset')).delete_all
      clear_cache_now_and_on_rollback
    end

    # Returns the names of the rulesets in use, sorted
    def rulesets
      PrecedenceRule.where.not(ruleset: PrecedenceRule::BASE).distinct.order(:ruleset).pluck(:ruleset)
    end

    # Set and save the global precedence of a source, in the base rules as `source.update!(precedence:)` does, or in a
    # ruleset. Raises for a nil precedence, since every source keeps a global precedence in the base rules and in each
    # ruleset, which keeps forging free of ties.
    def update_source_precedence(source, precedence, ruleset: nil)
      ruleset = PrecedenceRule.ruleset_name(ruleset, where: 'LaForge.update_source_precedence')
      if precedence.nil?
        within = ruleset == PrecedenceRule::BASE ? '' : " in ruleset #{ruleset.inspect}"
        raise ArgumentError, "LaForge.update_source_precedence: a source keeps a global precedence#{within}, which keeps forging free of ties, so it cannot be removed. " \
                             "Pass a new number, or reorder the sources with LaForge.update_precedence_order#{'(..., ruleset:)' unless within.empty?}#{'; LaForge.reset_ruleset drops a whole ruleset' unless within.empty?}"
      end
      return DataSource.find(DataSource.normalize_source_id(source)).update!(precedence: precedence) if ruleset == PrecedenceRule::BASE

      PrecedenceRule.transaction do
        fork_ruleset(ruleset)
        PrecedenceRule.global.in_ruleset(ruleset).where(source_id: DataSource.normalize_source_id(source)).first_or_initialize.update!(precedence: precedence)
      end
    end

    # @api private
    # Gives the source a global rule one below the lowest in each ruleset in use that has none for it, so every
    # ruleset's global order includes every source, as the base one does. A ruleset with a global rule for the source is
    # left alone.
    def place_in_rulesets(source)
      unplaced = rulesets - PrecedenceRule.global.in_ruleset(rulesets).where(source_id: source.id).pluck(:ruleset)
      lowest = PrecedenceRule.global.in_ruleset(unplaced).group(:ruleset).minimum(:precedence)
      unplaced.each { |ruleset| PrecedenceRule.create!(source_id: source.id, ruleset: ruleset, precedence: lowest.fetch(ruleset, 1) - 1) }
      PrecedenceCache.clear if unplaced.any?
    end

    # @api private
    # Returns the name of the ruleset the record's selector selects, by its model's own selector or else
    # `ruleset_selector`, or nil when the selector is nil or false or gives a blank value. The ruleset need not be in
    # use. Raises when a Symbol selector names a method the record does not respond to.
    def ruleset_for(record)
      own = record.class.laforge.ruleset_selector
      selector, origin = own.nil? ? [ruleset_selector, 'LaForge.ruleset_selector'] : [own, "#{record.class.name}'s laforged ruleset_selector:"]
      value =
        case selector
        when nil, false then nil
        when Symbol
          unless record.respond_to?(selector)
            raise ArgumentError, "#{origin} names #{selector.inspect}, which #{record.class.name} does not respond to. Define #{record.class.name}##{selector}, " \
                                 "or give #{record.class.name} a selector of its own with `laforged ruleset_selector:` (false for the base rules)"
          end
          record.public_send(selector)
        else selector.call(record)
        end
      value.to_s.strip.presence # stripped as `PrecedenceRule.ruleset_name` strips a `ruleset:` argument
    end

    # @api private
    # Raises unless the selector is nil, a Symbol or callable, or false where `model` is true
    def assert_ruleset_selector!(selector, where:, model: false)
      return if selector.nil? || selector.is_a?(Symbol) || selector.respond_to?(:call) || (model && selector == false)

      raise ArgumentError, "#{where} takes a method name (Symbol) or a Proc given the record, #{'false for the base rules, ' if model}or nil, not #{selector.class} #{selector.inspect}"
    end

    private

    # Clears the precedence cache now and again if the current transaction rolls back, for writes that skip the rules'
    # callbacks
    def clear_cache_now_and_on_rollback
      PrecedenceCache.clear
      ::ActiveRecord::Base.current_transaction.after_rollback { PrecedenceCache.clear }
    end

    # Returns `PrecedenceRule.ruleset_name` for the ruleset, raising when it names the base rules
    def named_ruleset(ruleset, where:)
      name = PrecedenceRule.ruleset_name(ruleset, where: where)
      raise ArgumentError, "#{where}: pass the name of a ruleset; the base rules are not one. Use the methods without ruleset: for them" if name == PrecedenceRule::BASE

      name
    end
  end
end

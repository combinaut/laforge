module LaForge
  # `CurrentRulesets` is used to rank each record by one ruleset for the duration of a block, which is one forge or one
  # `forge_diff`. Inside the outermost block, a record's selector selects its ruleset the first time the record is
  # ranked. Every later ranking of that record in the block ranks by the same ruleset, whether it comes from the
  # record's own forge, its owner's, an inspection method or a callback of the application. Each record has its own: a
  # member of a tracked association ranks by the ruleset its own selector selects, not by its owner's.
  #
  # It holds the resolver (see `PrecedenceRule::Resolver`) each record first ranked with, so the model-wide and global
  # rules that resolver read are held with the ruleset. Records are told apart as objects, since a new record has no id,
  # so two instances of one row each select their own.
  #
  # Nothing clears it before the outermost block ends. It does not see a change to what a selector reads, which is why
  # it is private and spans no more than a forge. Outside a block, each forge and each inspection method selects the
  # ruleset again. It is separate from `PrecedenceCache`, which holds rules across forges and is cleared when they
  # change.
  module CurrentRulesets
    KEY = :laforge_current_rulesets

    def self.with
      return yield if active?

      begin
        ActiveSupport::IsolatedExecutionState[KEY] = {}.compare_by_identity
        yield
      ensure
        ActiveSupport::IsolatedExecutionState.delete(KEY)
      end
    end

    def self.active?
      !ActiveSupport::IsolatedExecutionState[KEY].nil?
    end

    # Returns the resolver held for `record`, which is the block's value the first time the record is asked for.
    # Outside `with`, returns nil without calling the block.
    def self.fetch(record)
      store = ActiveSupport::IsolatedExecutionState[KEY]
      return unless store

      store.fetch(record) { store[record] = yield }
    end
  end

  # @api private
  # Ranks each record by the ruleset it first ranks by inside the block, until the block ends (see CurrentRulesets).
  # Nested calls join the outermost block.
  def self.with_current_rulesets(&block)
    CurrentRulesets.with(&block)
  end
end

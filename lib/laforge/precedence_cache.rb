module LaForge
  # Caches the global and model-wide precedence rules for the duration of a block, such as an import run, so that each
  # forge doesn't read them again. A record's own rules are not cached; they load with the record.
  #
  # Rules changed through LaForge inside the block clear the cache, so later forges see them. Changes made outside
  # LaForge, by SQL or by another process, are not seen until the block ends.
  module PrecedenceCache
    KEY = :laforge_precedence_cache

    def self.with
      return yield if active?

      begin
        ActiveSupport::IsolatedExecutionState[KEY] = {}
        yield
      ensure
        ActiveSupport::IsolatedExecutionState.delete(KEY)
      end
    end

    def self.active?
      ActiveSupport::IsolatedExecutionState.key?(KEY)
    end

    # Returns the cached value for the key, computing it with the block on a miss; computes it every time outside `with`
    def self.fetch(key)
      store = ActiveSupport::IsolatedExecutionState[KEY]
      return yield unless store

      store.fetch(key) { store[key] = yield }
    end

    def self.clear
      ActiveSupport::IsolatedExecutionState[KEY]&.clear
    end
  end

  # Caches the global and model-wide precedence rules while the block runs. Nested calls share the outer cache.
  def self.with_precedence_cache(&block)
    PrecedenceCache.with(&block)
  end
end

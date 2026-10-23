module LaForge
  # Used to cache the global and model-wide precedence rules for the duration of a block, such as an import run, so each
  # forge in it doesn't read them again. A record's own rules are not cached, as they load with the record.
  #
  # Changing a rule through LaForge inside the block clears the cache, so later forges see the change. A change made
  # outside LaForge, by SQL or by another process, is not seen until the outermost block ends.
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

    # Returns the cached value for `key`, computing it with the block on a miss. Outside `with`, computes it every time.
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

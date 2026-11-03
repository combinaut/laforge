module LaForge
  # `ExpiryTrigger` is used to decide when an expiry on a source fires. Each value of `expires_when` has one (see
  # `Expiring.trigger`), which `ExpirySweep` asks about each row waiting on the source of a recording.
  class ExpiryTrigger
    attr_reader :name

    def initialize(name)
      @name = name
      freeze
    end

    # Returns whether a recording from the source can fire the row's expiry
    def waits_on?(row, source_id)
      row.expires_on_source_id == source_id
    end

    # Returns whether the trigger compares a change's value, which a tracked association doesn't have
    def compares_values?
      false
    end

    # Returns the time the row expires at for `sweep`, or nil when its expiry doesn't fire
    def fires_at(_row, _sweep)
      raise NotImplementedError
    end

    # Returns whether `recorded`, a member list from the source, fires an expiry on the member with the given key
    def fires_for_member?(_recorded, _config, _key)
      false
    end

    # `Changes` is used for `expires_when: :changes`, which fires on the first value from the source that differs from
    # its own entry, made after the change
    class Changes < ExpiryTrigger
      def fires_at(row, sweep)
        sweep.recorded_for(row).select(&:changed).map(&:at).select { |at| at > row.changed_at }.min
      end

      def fires_for_member?(recorded, config, key)
        recorded.coverage_changed?(config, key)
      end
    end

    # `Matches` is used for `expires_when: :matches`, which fires once the change's value matches the source's. It is a
    # state, so a recording from either source checks it, whatever it recorded. It expires at the sweep's time, or later
    # when the change or either source's values were recorded later, as they can be than what pending items replay.
    class Matches < ExpiryTrigger
      def waits_on?(row, source_id)
        super || row.source_id == source_id
      end

      def compares_values?
        true
      end

      def fires_at(row, sweep)
        return if row.marked_for_destruction? || !sweep.laforge.matches_source?(row)

        attributes = sweep.laforge.class.attributes_of(row.attribute_name)
        agreed_at = sweep.laforge.filter_data_entries_in_memory(attributes: attributes, sources: [row.source_id, row.expires_on_source_id]).map(&:recorded_at)
        [sweep.at, row.recorded_at, *agreed_at].compact.max
      end
    end
  end
end

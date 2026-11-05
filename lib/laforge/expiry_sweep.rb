module LaForge
  # `ExpirySweep` is used to expire what a recording from one source fires, once the recording is complete, so a group is
  # compared whole. `Recording#sweeping` keeps one for each source while the recording runs, or while pending items
  # replay, and each write notes what it recorded.
  class ExpirySweep
    # What one write recorded from the source, for the attribute, attribute group or association `rule_name`, at `at`:
    # - changed: whether it differs from the source's entry (see `Recording#provides_another_value?`)
    # - lists: for a tracked association, the source's member lists before and after. nil when the write is only known
    #   from an entry's `recorded_at` (see `Recording#note_replayed`), which counts for every member.
    # - edited: the key of the one member an edit named, as `lists` name it, or nil
    Recorded = Struct.new(:rule_name, :at, :changed, :lists, :edited, keyword_init: true) do
      # Returns whether the source covers the member differently after the write
      def coverage_changed?(config, key)
        lists.nil? || lists.map { |list| list.recorded_coverage(config, key) }.uniq.size > 1
      end

      # Returns whether the write says something about the member
      def names_member?(config, key)
        return true if lists.nil?

        edited ? edited == key : !lists.last.recorded_coverage(config, key).nil?
      end
    end

    attr_reader :laforge, :source_id, :at

    def initialize(laforge, source_id, at)
      @laforge = laforge
      @source_id = source_id
      @at = at
      @recorded = []
    end

    def note(rule_name, at, changed:, lists: nil, edited: nil)
      @recorded << Recorded.new(rule_name: rule_name, at: at, changed: changed, lists: lists, edited: edited)
    end

    # Expires each of `rows` that waits on the source and whose trigger fires, then what member lists fire. Triggers that
    # compare values go last, since an expired entry provides no value, and each kind is read before any of it expires.
    def run(rows)
      events, states = rows.select { |row| row.trigger.waits_on?(row, source_id) }.partition { |row| !row.trigger.compares_values? }
      fire(events)
      expire_members
      fire(states)
    end

    # Returns what the sweep noted for the row's attribute, attribute group or association
    def recorded_for(row)
      rule_name = laforge.class.group_of(row.attribute_name) || row.attribute_name
      @recorded.select { |recorded| recorded.rule_name == rule_name }
    end

    private

    def fire(rows)
      rows.filter_map { |row| (at = row.trigger.fires_at(row, self)) && [row, at] }.each { |row, at| row.expire(at) }
    end

    def expire_members
      @recorded.each do |recorded|
        config = laforge.associations[recorded.rule_name]
        TrackedAssociation.new(laforge.record, config).expire_members_on(source_id, recorded) if config
      end
    end
  end
end

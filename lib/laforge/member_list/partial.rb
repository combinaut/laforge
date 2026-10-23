module LaForge
  class MemberList
    # A partial report (see MemberList)
    class Partial < MemberList
      # Returns the value stored for a partial report with the given lists. Pending items whose attributes are empty are
      # left out.
      def self.value(include: [], exclude: [], withdrawn: [], pending: [], tombstones: [], expiries: [])
        pending = pending.reject { |item| item['attributes'].empty? }
        value = { 'partial' => true, 'include' => include, 'exclude' => exclude, 'withdrawn' => withdrawn }
        value['tombstones'] = tombstones if tombstones.any?
        value['expiries'] = expiries if expiries.any?
        value['pending'] = pending if pending.any?
        value
      end

      # Returns the stored value for a partial report of `include` and `exclude` replacing `previous`, withdrawing what
      # `previous` included or withdrew and this one does not name (see `MemberList#left_out_by`). It keeps the
      # tombstones of `previous`, and its exclusions of tombstones this one does not name, with their expiries.
      def self.replacing(previous, config, include:, exclude:, pending:, expiries:)
        reported = (include + exclude).map { |member| config.key_of(member) }
        kept = previous.exclude.select { |member| config.tombstone?(member) && !reported.include?(config.key_of(member)) }
        kept_keys = kept.map { |member| config.key_of(member) }
        kept_expiries = previous.expiries.select { |item| kept_keys.include?(config.key_of(item['key'])) }
        value(include: include, exclude: exclude + kept, withdrawn: previous.left_out_by(config, include + exclude), pending: pending, tombstones: previous.tombstones,
              expiries: expiries + kept_expiries)
      end

      def initialize(value)
        @include = Array(value['include'])
        @exclude = Array(value['exclude'])
        @withdrawn = Array(value['withdrawn'])
        @pending = Array(value['pending'])
        @tombstones = Array(value['tombstones'])
        @expiries = Array(value['expiries'])
      end

      def partial?
        true
      end

      # Returns :include or :exclude for the member with the given key, or nil when this report has no opinion on it. An
      # expired inclusion or exclusion is no opinion.
      def decision(config, key)
        return if expired?(config, key)
        return :include if includes?(config, key)
        return :exclude if exclude.any? { |member| config.key_of(member) == key }

        nil
      end

      # Whether this report includes, excludes and has pending items for no member, so it says nothing once its
      # withdrawn list is applied
      def vacant?
        include.empty? && exclude.empty? && pending.empty?
      end

      # Returns the stored value for this report with the member named by the key hash `member` added to its exclusions,
      # without its pending items. The member's expiry is replaced as `including` replaces it.
      def excluding(config, member, expiry: nil)
        key = config.key_of(member)
        with(include: others(config, include, key), exclude: others(config, exclude, key) + [config.key_hash(member)], withdrawn: others(config, withdrawn, key),
             pending: items_without(config, pending, key), expiries: expiries_with(config, key, expiry))
      end

      # Returns the stored value for this report with no opinion on the member named by the key hash `member`. It drops
      # the member's pending items, its expiry, and its tombstone when the member is one, and withdraws the member when
      # this report included it by an inclusion that has not expired, or withdrew it.
      def forgetting(config, member)
        key = config.key_of(member)
        with(include: others(config, include, key), exclude: others(config, exclude, key), withdrawn: withdrawn_with(config, member),
             pending: items_without(config, pending, key), tombstones: items_without(config, tombstones, key), expiries: items_without(config, expiries, key))
      end
    end
  end
end

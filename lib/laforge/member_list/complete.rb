module LaForge
  class MemberList
    # A complete report (see MemberList)
    class Complete < MemberList
      # Returns the value stored for a complete report with the given lists. It has no exclusions or tombstones, so
      # those given are left out, and so are pending items whose attributes are empty.
      def self.value(include: [], exclude: [], withdrawn: [], pending: [], tombstones: [], expiries: [])
        pending = pending.reject { |item| item['attributes'].empty? }
        return include if withdrawn.empty? && pending.empty? && expiries.empty?

        value = { 'include' => include }
        value['withdrawn'] = withdrawn if withdrawn.any?
        value['expiries'] = expiries if expiries.any?
        value['pending'] = pending if pending.any?
        value
      end

      # Returns the stored value for a complete report of `include` replacing `previous`, withdrawing what `previous`
      # included or withdrew and this one leaves out (see `MemberList#left_out_by`)
      def self.replacing(previous, config, include:, pending:, expiries:)
        value(include: include, withdrawn: previous.left_out_by(config, include), pending: pending, expiries: expiries)
      end

      def initialize(value)
        @include = Array(value.is_a?(Hash) ? value['include'] : value)
        @exclude = []
        @withdrawn = Array(value.is_a?(Hash) ? value['withdrawn'] : nil)
        @pending = value.is_a?(Hash) ? Array(value['pending']) : []
        @tombstones = []
        @expiries = value.is_a?(Hash) ? Array(value['expiries']) : []
      end

      def partial?
        false
      end

      # Returns :include for a member this report includes by an inclusion that has not expired, and :exclude for every
      # other member
      def decision(config, key)
        includes?(config, key) && !expired?(config, key) ? :include : :exclude
      end

      # Returns false, since an empty complete report still excludes every member
      def vacant?
        false
      end

      # Returns the stored value for this report leaving out the member named by the key hash `member`, without its
      # pending items, and withdrawing it. It is withdrawn even when this report did not include it, so a row no report
      # named is removed too. The member's expiry is replaced as `including` replaces it.
      def excluding(config, member, expiry: nil)
        key = config.key_of(member)
        with(include: others(config, include, key), withdrawn: others(config, withdrawn, key) + [config.key_hash(member)], pending: items_without(config, pending, key),
             expiries: expiries_with(config, key, expiry))
      end
    end
  end
end

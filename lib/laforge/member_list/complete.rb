module LaForge
  class MemberList
    # A complete report (see MemberList)
    class Complete < MemberList
      # Returns the value stored for a complete report with the given lists. It has no exclusions or tombstones, so
      # those given are left out, and so are pending items whose attributes are empty.
      def self.value(include: [], exclude: [], withdrawn: [], pending: [], tombstones: [])
        pending = pending.reject { |item| item['attributes'].empty? }
        return include if withdrawn.empty? && pending.empty?

        value = { 'include' => include }
        value['withdrawn'] = withdrawn if withdrawn.any?
        value['pending'] = pending if pending.any?
        value
      end

      # Returns the stored value for a complete report of `include` replacing `previous`, withdrawing what `previous`
      # included or withdrew and this one leaves out (see `MemberList#left_out_by`)
      def self.replacing(previous, config, include:, pending:)
        value(include: include, withdrawn: previous.left_out_by(config, include), pending: pending)
      end

      def initialize(value, marked: false)
        listed = Array(value.is_a?(Hash) ? value['include'] : value)
        @include = marked ? [] : listed
        @exclude = []
        @withdrawn = Array(value.is_a?(Hash) ? value['withdrawn'] : nil) + (marked ? listed : [])
        @pending = marked || !value.is_a?(Hash) ? [] : Array(value['pending'])
        @tombstones = []
      end

      def partial?
        false
      end

      # Returns :include for a member this report includes, and :exclude for every other member
      def decision(config, key)
        includes?(config, key) ? :include : :exclude
      end

      # Returns false, since an empty complete report still excludes every member
      def vacant?
        false
      end

      # Returns the stored value for this report leaving out the member named by the key hash `member`, without its
      # pending items, and withdrawing it when this report included it
      def excluding(config, member)
        key = config.key_of(member)
        with(include: others(config, include, key), withdrawn: withdrawn_with(config, member), pending: items_without(config, pending, key))
      end
    end
  end
end

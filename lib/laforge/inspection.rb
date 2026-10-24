module LaForge
  # Used to find where a laforged record's values and tracked associations' members came from
  module Inspection
    extend ActiveSupport::Concern

    API = %i[data_source? data_source_names source_values member_sources tombstones membership_expiries].freeze
    CLASS_API = %i[source_values].freeze

    # Whether the source has entries on this record
    def data_source?(source)
      filter_data_entries_in_memory(sources: source).any?
    end

    # Returns the names of the sources with entries on this record, for `attributes` when given
    def data_source_names(attributes: nil)
      filter_data_entries_in_memory(attributes: attributes).map(&:source).map(&:name).uniq
    end

    # Returns what each source says about the members of the tracked association `name`, as
    # { source => [member hashes] } (see the class method)
    def source_values(name)
      self.class.source_values(name, records: [record])[record.id] || {}
    end

    # Returns { membership: source, listed_by: [sources], excluded_by: [sources], attributes: { attribute => source } }
    # for one member
    def member_sources(name, **member)
      reset_resolver # selects the ruleset and reads the rules again
      TrackedAssociation.new(record, self.class.association(name)).member_sources(member.stringify_keys)
    end

    # Returns the tombstones of the tracked association `name` (see Tombstone)
    def tombstones(name)
      TrackedAssociation.new(record, self.class.association(name)).tombstones
    end

    # Returns the expiries in the reports of the tracked association `name` (see MemberList). The `expiring` scope (see
    # Expiring) finds only rows, so it misses these.
    def membership_expiries(name)
      TrackedAssociation.new(record, self.class.association(name)).membership_expiries
    end

    class_methods do
      # Returns what each source says about the members of the tracked association `name` on each of `records`, as
      # { record_id => { source => [member hashes] } }
      def source_values(name, records:)
        TrackedAssociation.source_values(model, association(name), records)
      end
    end
  end
end

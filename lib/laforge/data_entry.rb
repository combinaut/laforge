module LaForge
  class DataEntry < ActiveRecord::Base
    self.table_name = "laforge_data_entries"
    include Expiring

    # STORABLE_TYPES are the classes of value an entry can store. Values are stored as JSON, so symbols, dates and times
    # read back as strings. `storable?` also accepts arrays and hashes of them.
    STORABLE_TYPES = [NilClass, TrueClass, FalseClass, String, Symbol, Numeric, Date, Time, ActiveSupport::TimeWithZone].freeze

    belongs_to :record, polymorphic: true
    belongs_to :source, class_name: 'LaForge::DataSource'

    scope :with_source, ->(sources) { where(source_id: DataSource.normalize_source_ids(sources)) }
    scope :without_source, ->(sources) { where.not(source_id: DataSource.normalize_source_ids(sources)) }
    scope :with_attribute, ->(attribute_names) { where(attribute_name: Array.wrap(attribute_names)) }
    scope :without_attribute, ->(attribute_names) { where.not(attribute_name: Array.wrap(attribute_names)) }

    delegate :precedence, to: :source, prefix: true, allow_nil: true

    # `recorded_at` is when a source said the entry's value and expiry, which recording them again unchanged leaves as
    # it is. Recording through LaForge sets it, and an entry saved without one gets the time of the save.
    before_save { self.recorded_at ||= Time.current }

    # Returns `recorded_at`, as an entry's change is made when a source says it (see Expiring#changed_at)
    def saved_changed_at
      recorded_at
    end

    # CHANGED is the `ActiveSupport::Notifications` event published when an entry is created, its value or expiry
    # changes, or it is destroyed, so a host can follow what sources say without reading every entry (see
    # `publish_change`). It is published once the transaction commits, and not at all if it rolls back. An expiry on a
    # source that fires sets `expires_at`, which is published when the entry is saved, and an entry expiring at its time
    # publishes nothing. `LaForge.merge` moves and combines entries without publishing, and entries deleted with their
    # record publish nothing.
    CHANGED = 'data_entry_changed.laforge'.freeze

    after_save do
      if previously_new_record? || saved_change_to_value? || saved_change_to_expires_at? || saved_change_to_expires_on_source_id?
        DataEntry.publish_change(self, value_was: value_before_last_save, value: value)
      end
    end
    after_destroy { DataEntry.publish_change(self, value_was: value, value: nil, destroyed: true) }

    # Publishes CHANGED for the entry once the current transaction commits. The payload is taken now, its values deep
    # copied, so a later save or in-place change in the same transaction does not alter it. It holds:
    # - entry: the DataEntry
    # - record_type, record_id, attribute_name, source_id: the entry's
    # - value_was, value: its value before and after the write
    # - destroyed: whether the write destroyed it
    # - expires_at, expires_on_source_id: its expiry after the write
    def self.publish_change(entry, value_was:, value:, destroyed: false)
      payload = { entry: entry, record_type: entry.record_type, record_id: entry.record_id, attribute_name: entry.attribute_name,
                  source_id: entry.source_id, value_was: value_was.deep_dup, value: value.deep_dup, destroyed: destroyed,
                  expires_at: entry.expires_at, expires_on_source_id: entry.expires_on_source_id }
      ::ActiveRecord::Base.current_transaction.after_commit { ActiveSupport::Notifications.instrument(CHANGED, payload) }
    end

    # Returns this entry's effective precedence on its record. Entries rank by level first (see PrecedenceRule), so this
    # number alone does not order two entries. `in_precedence_order` does.
    def effective_precedence
      record.laforge.precedence_of(self)
    end

    # Returns one record's `entries` in the order `forge` ranks them, highest first. `record` defaults to the first
    # entry's record. The order is by:
    #   - the rank of the entry's source for its attribute on `record` (see PrecedenceRule)
    #   - recency, which is the id for saved entries. An unsaved entry is newer than every saved one, and among unsaved
    #     entries a later position in `entries` is newer.
    def self.in_precedence_order(entries, record: entries.first&.record)
      entries.each_with_index.sort_by do |entry, position|
        record.laforge.rank_of(entry).map(&:-@) + [-(entry.id || Float::INFINITY), -position]
      end.map(&:first)
    end

    # Returns whether `value` can be stored, which takes an instance of one of `STORABLE_TYPES`, or an array or hash of
    # storable values whose keys are strings or symbols
    def self.storable?(value)
      case value
      when *STORABLE_TYPES then true
      when Array then value.all? { |item| storable?(item) }
      when Hash then value.all? { |key, item| (key.is_a?(String) || key.is_a?(Symbol)) && storable?(item) }
      else false
      end
    end

    def source_id=(source)
      super DataSource.normalize_source_id(source)
    end
  end
end

module LaForge
  class DataEntry < ActiveRecord::Base
    self.table_name = "laforge_data_entries"

    belongs_to :record, polymorphic: true
    belongs_to :source, class_name: 'LaForge::DataSource'

    scope :with_source, ->(sources) { where(source_id: DataSource.normalize_source_ids(sources)) }
    scope :without_source, ->(sources) { where.not(source_id: DataSource.normalize_source_ids(sources)) }
    scope :with_attribute, ->(attribute_names) { where(attribute_name: Array.wrap(attribute_names)) }
    scope :without_attribute, ->(attribute_names) { where.not(attribute_name: Array.wrap(attribute_names)) }

    delegate :precedence, to: :source, prefix: true, allow_nil: true

    # recorded_at is when a source said the value, which an older report pending on an owner is compared with. Recording
    # through LaForge sets it; an entry created any other way gets the time it is saved.
    before_save { self.recorded_at ||= Time.current }

    # Publishes CHANGED when an entry's value is saved changed, or the entry is destroyed, so a host can follow what
    # sources say without reading every entry. It is published once the write is committed, and not at all if it rolls
    # back, so a subscriber only hears of changes that happened. Writes that skip callbacks, such as `LaForge.merge`
    # moving entries between records and database cascades, publish nothing.
    CHANGED = 'data_entry_changed.laforge'.freeze

    after_save { DataEntry.publish_change(self, value_was: value_before_last_save, value: value) if previously_new_record? || saved_change_to_value? }
    after_destroy { DataEntry.publish_change(self, value_was: value, value: nil, destroyed: true) }

    # Publishes the change once the current transaction commits, with the payload as it is now: the entry, its
    # record_type, record_id, attribute_name and source_id, its value before and after, and whether it was destroyed.
    # Taking the payload when the write is made keeps value_was right when one transaction saves an entry more than once.
    def self.publish_change(entry, value_was:, value:, destroyed: false)
      payload = { entry: entry, record_type: entry.record_type, record_id: entry.record_id, attribute_name: entry.attribute_name,
                  source_id: entry.source_id, value_was: value_was, value: value, destroyed: destroyed }
      ::ActiveRecord::Base.current_transaction.after_commit { ActiveSupport::Notifications.instrument(CHANGED, payload) }
    end

    # The precedence of the most specific precedence rule for its record, attribute and source, falling back to the
    # source's global precedence. Entries rank by level first (see PrecedenceRule::Resolver), so compare entries with
    # `in_precedence_order` rather than by this number.
    def effective_precedence
      record.laforge_precedence_of(self)
    end

    # Returns one record's `entries` highest-ranked first, so the first entry for each attribute is the one `forge`
    # applies. Entries rank by their sources' rules, most specific level first, then by the sources' global precedence
    # (see PrecedenceRule::Resolver), then by recency. Recency is the id for saved entries; an unsaved entry is newer than
    # every saved one, and among unsaved entries a later position in `entries` is newer.
    def self.in_precedence_order(entries, record: entries.first&.record)
      entries.each_with_index.sort_by do |entry, position|
        record.laforge_rank_of(entry).map(&:-@) + [-(entry.id || Float::INFINITY), -position]
      end.map(&:first)
    end

    # Whether a value survives being stored as JSON and read back: strings, numbers, booleans, dates and times (stored
    # as strings), nil, and arrays and hashes of those
    def self.storable?(value)
      case value
      when nil, true, false, String, Symbol, Numeric, Date, Time, ActiveSupport::TimeWithZone then true
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

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

    # Returns this entry's effective precedence on its record
    def effective_precedence
      record.laforge.precedence_of(self)
    end

    # Returns one record's `entries` in the order `forge` ranks them, so the first entry for each attribute is the one
    # it applies. `record` defaults to the first entry's record. The order is by, highest first:
    #   - the entry's effective precedence on `record`
    #   - its source's global precedence, a source without one ranking below every other
    #   - recency, which is the id for saved entries. An unsaved entry is newer than every saved one, and among unsaved
    #     entries a later position in `entries` is newer.
    def self.in_precedence_order(entries, record: entries.first&.record)
      entries.each_with_index.sort_by do |entry, position|
        [-record.laforge.precedence_of(entry), -record.laforge.global_precedence(entry.source_id), -(entry.id || Float::INFINITY), -position]
      end.map(&:first)
    end

    def source_id=(source)
      super DataSource.normalize_source_id(source)
    end
  end
end

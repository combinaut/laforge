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

    # The precedence this entry's value is ranked by: the most specific precedence rule for its record, attribute and
    # source, falling back to the source's global precedence
    def effective_precedence
      record.laforge_precedence_of(self)
    end

    # Returns one record's `entries` highest precedence first, so the first entry for each attribute is the one `forge`
    # applies. Precedence is the entry's effective precedence on the record, then its source's global precedence, then
    # recency. Recency is the id for saved entries; an unsaved entry is newer than every saved one, and among unsaved
    # entries a later position in `entries` is newer.
    def self.in_precedence_order(entries, record: entries.first&.record)
      entries.each_with_index.sort_by do |entry, position|
        [-record.laforge_precedence_of(entry), -record.laforge_global_precedence(entry.source_id), -(entry.id || Float::INFINITY), -position]
      end.map(&:first)
    end

    def source_id=(source)
      super DataSource.normalize_source_id(source)
    end
  end
end

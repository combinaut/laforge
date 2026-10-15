module LaForge
  class DataEntry < ActiveRecord::Base
    self.table_name = "laforge_data_entries"

    belongs_to :record, polymorphic: true
    belongs_to :source, class_name: 'LaForge::DataSource'

    scope :with_source, ->(sources) { where(source_id: DataSource.normalize_source_ids(sources)) }
    scope :without_source, ->(sources) { where.not(source_id: DataSource.normalize_source_ids(sources)) }
    scope :with_attribute, ->(attribute_names) { where(attribute_name: Array.wrap(attribute_names)) }
    scope :without_attribute, ->(attribute_names) { where.not(attribute_name: Array.wrap(attribute_names)) }

    delegate :priority, to: :source, prefix: true, allow_nil: true

    def priority_with_fallback
      priority || source_priority
    end

    # Returns `entries` highest precedence first, so the first entry for each attribute is the one
    # `forge` applies. Precedence is effective priority, then source priority, then recency. Recency
    # is the id for saved entries; an unsaved entry is newer than every saved one, and among unsaved
    # entries a later position in `entries` is newer. A missing priority ranks below every number.
    def self.in_precedence_order(entries)
      entries.each_with_index.sort_by do |entry, position|
        [-(entry.priority_with_fallback || -Float::INFINITY), -(entry.source_priority || -Float::INFINITY), -(entry.id || Float::INFINITY), -position]
      end.map(&:first)
    end

    def source_id=(source)
      super DataSource.normalize_source_id(source)
    end
  end
end

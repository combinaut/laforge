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

    def source_id=(source)
      super DataSource.normalize_source_id(source)
    end
  end
end

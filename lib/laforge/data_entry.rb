module LaForge
  class DataEntry < ActiveRecord::Base
    self.table_name = "la_forge_data_entries"

    belongs_to :record, polymorphic: true
    belongs_to :source, class_name: 'LaForge::DataSource'

    delegate :priority, to: :source, prefix: true, allow_nil: true

    def priority_with_fallback
      priority || source_priority
    end
  end
end

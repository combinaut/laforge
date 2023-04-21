# create_table :laforge_data_entries do |t|
#   t.belongs_to :record, polymorphic: true, null: false, index: false
#   t.string :attribute_name, null: false
#   t.belongs_to :source, null: false, index: false
#   t.text :value
#   t.integer :priority
#   t.timestamps null: false
# end
# add_index :laforge_data_entries, [:record_id, :record_type, :attribute, :source_id]


module LaForge
  class DataEntry < ActiveRecord::Base
    self.table_name = "la_forge_data_entries"

    belongs_to :record, polymorphic: true
    belongs_to :source, class_name: 'LaForge::DataSource'

    delegate :priority, to: :source, prefix: true, allow_nil: true

    before_save :normalize_value

    def priority_with_fallback
      priority || source_priority
    end

    private

    def normalize_value
      self.value = nil unless value.present?
    end
  end
end

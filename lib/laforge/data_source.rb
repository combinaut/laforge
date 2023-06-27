module LaForge
  class DataSource < ActiveRecord::Base
    self.table_name = "laforge_data_sources"

    has_many :data_entries, class_name: 'LaForge::DataEntry'

    validates :priority, presence: true, uniqueness: true
    validates :name, presence: true, uniqueness: { case_sensitive: false }
  end
end

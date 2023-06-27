module LaForge
  class DataSource < ActiveRecord::Base
    self.table_name = "laforge_data_sources"

    has_many :data_entries, class_name: 'LaForge::DataEntry'

    validates_presence_of :priority
  end
end

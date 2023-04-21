module LaForge
  class DataSource < ActiveRecord::Base
    has_many :data_entries, class_name: 'LaForge::DataEntry'

    validates_presence_of :priority
  end
end

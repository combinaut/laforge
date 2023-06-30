require 'rails/all'
require 'laforge/data_entry'
require 'laforge/data_source'
require 'laforge/activerecord'

module LaForge
end

ActiveSupport.on_load :active_record do
  extend LaForge::ActiveRecord
end

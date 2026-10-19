require 'rails/all'
require 'laforge/data_entry'
require 'laforge/data_source'
require 'laforge/precedence_cache'
require 'laforge/precedence_rule'
require 'laforge/association_config'
require 'laforge/member_list'
require 'laforge/association_tracking'
require 'laforge/payload'
require 'laforge/activerecord'

ActiveSupport.on_load :active_record do
  extend LaForge::ActiveRecord
end

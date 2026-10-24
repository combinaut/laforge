require 'rails/all'
require 'laforge/data_entry'
require 'laforge/data_source'
require 'laforge/precedence_cache'
require 'laforge/precedence_rule'
require 'laforge/attribute_groups'
require 'laforge/recording'
require 'laforge/forging'
require 'laforge/precedence'
require 'laforge/inspection'
require 'laforge/record'
require 'laforge/activerecord'

ActiveSupport.on_load :active_record do
  extend LaForge::ActiveRecord
end

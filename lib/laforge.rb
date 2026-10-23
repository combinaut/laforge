require 'rails/all'
require 'laforge/data_entry'
require 'laforge/data_source'
require 'laforge/precedence_cache'
require 'laforge/precedence_rule'
require 'laforge/association_config'
require 'laforge/member_list'
require 'laforge/member_list/complete'
require 'laforge/member_list/partial'
require 'laforge/tombstone'
require 'laforge/merge'
require 'laforge/tracked_association'
require 'laforge/payload'
require 'laforge/recording'
require 'laforge/forging'
require 'laforge/precedence'
require 'laforge/pending_writes'
require 'laforge/activerecord'

ActiveSupport.on_load :active_record do
  extend LaForge::ActiveRecord
end

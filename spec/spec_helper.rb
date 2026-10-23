ENV['RAILS_ENV'] ||= 'test'

require 'bundler'
Bundler.require :default, :development

require 'rspec/rails'

# Add additional requires below this line. Rails is not loaded until this point!
ActiveRecord::Base.establish_connection(adapter: "mysql2", host: "127.0.0.1", database: "laforge_test", username: 'root', password: ENV.fetch('MYSQL_PASSWORD', ''))

ENGINE_RAILS_ROOT = File.join(File.dirname(__FILE__), '../')
Dir[File.join(ENGINE_RAILS_ROOT, "spec/support/**/*.rb")].each {|f| require f }

RSpec.configure do |config|
  config.order = "random"
end

ActiveRecord::Schema.define(version: 0) do
  create_table :schema_migrations, id: false, force: true do |t|
    t.string :version
  end

  create_table :active_record_mocks, force: true do |t|
    t.string :name
    t.boolean :active
    t.integer :count
    t.bigint :parent_id
    t.string :subject_type
    t.bigint :subject_id
    t.timestamps null: false
  end

  # Both reference laforge_data_sources, so they go first
  drop_table :laforge_precedence_rules, if_exists: true
  drop_table :laforge_data_entries, if_exists: true

  create_table :laforge_data_sources, force: true do |t|
    t.text :name
    t.boolean :active, null: false, default: true
    t.timestamps precision: 6, null: false
  end

  create_table :laforge_data_entries, force: true do |t|
    t.belongs_to :record, polymorphic: true, null: false, index: false
    t.string :attribute_name, null: false
    t.belongs_to :source, null: false, index: false
    t.json :value
    t.datetime :recorded_at, precision: 6, null: false
    t.datetime :expires_at, precision: 6, index: true
    t.references :expires_on_source, foreign_key: { to_table: :laforge_data_sources, on_delete: :nullify }
    t.timestamps precision: 6, null: false
  end

  create_table :laforge_precedence_rules, force: true do |t|
    t.string :record_type, null: false, default: ''
    t.bigint :record_id, null: false, default: 0
    t.string :attribute_name, null: false, default: ''
    t.references :source, null: false, index: false, foreign_key: { to_table: :laforge_data_sources, on_delete: :cascade }
    t.integer :precedence, null: false
    t.datetime :expires_at, precision: 6, index: true
    t.references :expires_on_source, foreign_key: { to_table: :laforge_data_sources, on_delete: :nullify }
    t.virtual :global_precedence, type: :integer, as: "CASE WHEN record_type = '' THEN precedence END", stored: true
    t.timestamps precision: 6, null: false
    t.index %i[record_type record_id attribute_name source_id], unique: true, name: :index_laforge_precedence_rules_on_scope_and_source
    t.index :global_precedence, unique: true
  end
end

class ActiveRecordMock < ActiveRecord::Base
  belongs_to :parent, class_name: 'ActiveRecordMock', optional: true
  belongs_to :subject, polymorphic: true, optional: true

  laforged
end

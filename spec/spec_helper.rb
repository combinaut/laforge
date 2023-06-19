ENV['RAILS_ENV'] ||= 'test'

require 'bundler'
Bundler.require :default, :development

require 'rspec/rails'

# Add additional requires below this line. Rails is not loaded until this point!
ActiveRecord::Base.establish_connection(adapter: "mysql2", database: "laforge_test", username: 'root', password: '')

ENGINE_RAILS_ROOT = File.join(File.dirname(__FILE__), '../')
Dir[File.join(ENGINE_RAILS_ROOT, "spec/support/**/*.rb")].each {|f| require f }

RSpec.configure do |config|
  config.fixture_path = "#{::Rails.root}/spec/fixtures"
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
    t.timestamps null: false
  end

  create_table :la_forge_data_sources, force: true do |t|
    t.text :name
    t.integer :priority
    t.timestamps null: false
  end

  create_table :la_forge_data_entries, force: true do |t|
    t.belongs_to :record, polymorphic: true, null: false, index: false
    t.string :attribute_name, null: false
    t.belongs_to :source, null: false, index: false
    t.json :value
    t.integer :priority
    t.timestamps null: false
  end
end

class ActiveRecordMock < ActiveRecord::Base
  laforged
end

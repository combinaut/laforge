require "rails/generators"
require "rails/generators/active_record"

module Laforge
  module Generators
    # Upgrades an existing install: adds expires_at and expires_on_source_id to data entries and precedence rules, and
    # recorded_at to precedence rules
    class ExpiryGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration
      source_root File.join(__dir__, "templates")

      desc "Adds expires_at and expires_on_source_id to laforge_data_entries and laforge_precedence_rules, and recorded_at to laforge_precedence_rules."

      def copy_templates
        migration_template "expiry_migration.rb", "db/migrate/add_expiry_to_laforge_data_entries_and_precedence_rules.rb", migration_version: migration_version
      end

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end

require "rails/generators"
require "rails/generators/active_record"

module Laforge
  module Generators
    # Upgrades an existing install: adds recorded_at to data entries, filled from updated_at
    class RecordedAtGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration
      source_root File.join(__dir__, "templates")

      desc "Adds recorded_at to laforge_data_entries, filled from updated_at."

      def copy_templates
        migration_template "recorded_at_migration.rb", "db/migrate/add_recorded_at_to_laforge_data_entries.rb", migration_version: migration_version
      end

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end

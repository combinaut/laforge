require "rails/generators"
require "rails/generators/active_record"

module Laforge
  module Generators
    # Upgrades an existing install: adds active to data sources, every existing source active
    class ActiveSourcesGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration
      source_root File.join(__dir__, "templates")

      desc "Adds active to laforge_data_sources, every existing source active."

      def copy_templates
        migration_template "active_sources_migration.rb", "db/migrate/add_active_to_laforge_data_sources.rb", migration_version: migration_version
      end

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end

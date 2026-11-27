require "rails/generators"
require "rails/generators/active_record"

module Laforge
  module Generators
    # Used to upgrade an existing install by renaming `name` to `key` on `laforge_data_sources`, a required string with a
    # unique index
    class SourceKeyGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration
      source_root File.join(__dir__, "templates")

      desc "Renames name to key on laforge_data_sources, a required string with a unique index."

      def copy_templates
        migration_template "source_key_migration.rb", "db/migrate/rename_name_to_key_on_laforge_data_sources.rb", migration_version: migration_version
      end

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end

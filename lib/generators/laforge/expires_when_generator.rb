require "rails/generators"
require "rails/generators/active_record"

module Laforge
  module Generators
    # Used to upgrade an existing install by adding `expires_when` to data entries and precedence rules, every existing
    # change keeping today's trigger
    class ExpiresWhenGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration
      source_root File.join(__dir__, "templates")

      desc "Adds expires_when to laforge_data_entries and laforge_precedence_rules."

      def copy_templates
        migration_template "expires_when_migration.rb", "db/migrate/add_expires_when_to_laforge_data_entries_and_precedence_rules.rb", migration_version: migration_version
      end

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end

require "rails/generators"
require "rails/generators/active_record"

module Laforge
  module Generators
    # Upgrades an existing install: moves source and entry priorities into the precedence rules table
    class PrecedenceRulesGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration
      source_root File.join(__dir__, "templates")

      desc "Moves LaForge source and entry priorities into the laforge_precedence_rules table."

      def copy_templates
        migration_template "precedence_rules_migration.rb", "db/migrate/move_laforge_priorities_to_precedence_rules.rb", migration_version: migration_version
      end

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end

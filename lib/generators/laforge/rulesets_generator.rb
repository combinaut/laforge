require "rails/generators"
require "rails/generators/active_record"

module Laforge
  module Generators
    # Used to upgrade an existing install by adding `ruleset` to `laforge_precedence_rules`, every existing rule a base
    # rule
    class RulesetsGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration
      source_root File.join(__dir__, "templates")

      desc "Adds ruleset to laforge_precedence_rules, every existing rule a base rule."

      def copy_templates
        migration_template "rulesets_migration.rb", "db/migrate/add_ruleset_to_laforge_precedence_rules.rb", migration_version: migration_version
      end

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end

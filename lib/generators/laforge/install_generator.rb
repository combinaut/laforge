require "rails/generators"
require "rails/generators/active_record"

module Laforge
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration
      source_root File.join(__dir__, "templates")

      class_option :database, type: :string, aliases: "-d"

      desc "Creates a Laforge initializer and copy locale files to your application."

      def copy_templates
        migration_template "migration.rb", "db/migrate/add_laforge_data_sources_and_entries.rb", migration_version: migration_version
        puts <<~TEXT
          Almost set! Last, run:
          rails db:migrate
        TEXT
      end

      # use connection_config instead of connection.adapter
      # so database connection isn't needed
      def adapter
        if ActiveRecord::VERSION::STRING.to_f >= 6.1
          ActiveRecord::Base.connection_db_config.adapter.to_s
        else
          ActiveRecord::Base.connection_config[:adapter].to_s
        end
      end

      def migration_version
        "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
      end
    end
  end
end

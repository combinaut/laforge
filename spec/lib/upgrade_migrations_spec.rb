require 'spec_helper'

# The upgrade from 0.0.1.alpha that the README documents, run in its order on the 0.0.1.alpha schema and back again.
# It replaces LaForge's tables, so it puts them back as laforge:install creates them when it is done.
describe 'The upgrade migrations' do
  let(:tables) { %i[laforge_precedence_rules laforge_data_entries laforge_data_sources] } # those referencing sources first
  let(:upgrades) do
    {
      'precedence_rules_migration' => 'MoveLaforgePrioritiesToPrecedenceRules',
      'recorded_at_migration' => 'AddRecordedAtToLaforgeDataEntries',
      'active_sources_migration' => 'AddActiveToLaforgeDataSources',
      'expiry_migration' => 'AddExpiryToLaforgeDataEntriesAndPrecedenceRules',
      'rulesets_migration' => 'AddRulesetToLaforgePrecedenceRules'
    }
  end

  # The schema laforge:install created in 0.0.1.alpha, with the whole-second timestamps the Rails of its day created
  let(:alpha_migration) do
    Class.new(ActiveRecord::Migration[ActiveRecord::Migration.current_version]) do
      def change
        create_table :laforge_data_sources do |t|
          t.text :name
          t.integer :priority
          t.timestamps precision: nil, null: false
        end

        create_table :laforge_data_entries do |t|
          t.belongs_to :record, polymorphic: true, null: false, index: false
          t.string :attribute_name, null: false
          t.belongs_to :source, null: false, index: false
          t.json :value
          t.integer :priority
          t.timestamps precision: nil, null: false
        end

        add_index :laforge_data_entries, [:record_id, :record_type, :attribute_name, :source_id], name: :index_laforge_data_entries_on_record_and_attribute_and_source
      end
    end
  end

  let(:connection) { ActiveRecord::Base.connection }

  def migration(template_name, migration_class_name)
    migration_version = "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
    template = File.read(File.expand_path("../../lib/generators/laforge/templates/#{template_name}.rb.tt", __dir__))
    Module.new.tap { |namespace| namespace.module_eval(ERB.new(template).result(binding)) }.const_get(migration_class_name)
  end

  def migrate(migration_class, direction)
    ActiveRecord::Migration.suppress_messages { migration_class.migrate(direction) }
  end

  def drop_tables
    tables.each { |table| connection.drop_table(table, if_exists: true) }
  end

  # Each table's columns, indexes and foreign keys, regardless of the order they were added in
  def schema
    tables.select { |table| connection.table_exists?(table) }.index_with do |table|
      {
        columns: connection.columns(table).map { |column| [column.name, column.sql_type, column.null, column.default] }.sort,
        indexes: connection.indexes(table).map { |index| [index.name, index.columns, index.unique] }.sort,
        foreign_keys: connection.foreign_keys(table).map { |key| [key.column, key.to_table, key.on_delete] }.sort
      }
    end
  end

  around do |example|
    drop_tables
    example.run
  ensure
    drop_tables
    migrate(migration('migration', 'AddLaforgeDataSourcesAndEntries'), :up)
    [LaForge::DataSource, LaForge::DataEntry, LaForge::PrecedenceRule].each(&:reset_column_information)
  end

  it 'reaches the schema laforge:install creates, and goes back to the 0.0.1.alpha schema with its priorities' do
    migrate(migration('migration', 'AddLaforgeDataSourcesAndEntries'), :up)
    installed = schema
    drop_tables

    migrate(alpha_migration, :up)
    alpha = schema
    connection.execute("INSERT INTO laforge_data_sources (id, name, priority, created_at, updated_at) VALUES (1, 'Cadastre', 10, NOW(), NOW()), (2, 'Map Editor', 20, NOW(), NOW())")
    connection.execute(<<~SQL)
      INSERT INTO laforge_data_entries (record_type, record_id, attribute_name, source_id, value, priority, created_at, updated_at)
      VALUES ('Place', 1, 'name', 1, '"Harbor Building"', 30, NOW(), NOW()), ('Place', 1, 'name', 2, '"Harbour Building"', NULL, NOW(), NOW())
    SQL

    upgrades.each { |template_name, migration_class_name| migrate(migration(template_name, migration_class_name), :up) }
    expect(schema).to eq(installed)
    expect(connection.select_rows('SELECT record_type, record_id, attribute_name, source_id, precedence, ruleset FROM laforge_precedence_rules ORDER BY id'))
      .to eq([['', 0, '', 1, 10, ''], ['', 0, '', 2, 20, ''], ['Place', 1, 'name', 1, 30, '']])

    connection.execute("INSERT INTO laforge_precedence_rules (source_id, precedence, ruleset, created_at, updated_at) VALUES (2, 5, 'north', NOW(), NOW())")
    upgrades.reverse_each { |template_name, migration_class_name| migrate(migration(template_name, migration_class_name), :down) }
    expect(schema).to eq(alpha)
    expect(connection.select_rows('SELECT name, priority FROM laforge_data_sources ORDER BY id')).to eq([['Cadastre', 10], ['Map Editor', 20]]) # not the ruleset's 5
    expect(connection.select_rows('SELECT source_id, priority FROM laforge_data_entries ORDER BY id')).to eq([[1, 30], [2, nil]])
  end
end

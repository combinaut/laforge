require 'spec_helper'

describe 'The precedence rules migration' do
  let(:migration) do
    migration_class_name = 'MoveLaforgePrioritiesToPrecedenceRules'
    migration_version = "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
    template = File.read(File.expand_path('../../lib/generators/laforge/templates/precedence_rules_migration.rb.tt', __dir__))
    Module.new.tap { |namespace| namespace.module_eval(ERB.new(template).result(binding)) }.const_get(migration_class_name).new
  end

  def sources(missing: [], orphaned: [], shared: [], conflicting: [], outranked: [])
    allow(migration).to receive(:select_values).and_return(missing, orphaned)
    allow(migration).to receive(:select_rows).and_return(shared, conflicting, outranked)
  end

  it 'raises, naming the sources, before creating anything when a source has no priority' do
    sources(missing: ['Cadastre', 'Map Editor'])
    expect(migration).not_to receive(:create_table)

    expect { migration.up }.to raise_error(RuntimeError, /Give these LaForge data sources a priority before migrating, as each becomes the source's global precedence: Cadastre, Map Editor/)
  end

  it 'raises, naming the ids of the missing sources, before creating anything when entries with a priority belong to a deleted source' do
    sources(orphaned: [7, 9])
    expect(migration).not_to receive(:create_table)

    expect { migration.up }.to raise_error(RuntimeError, /LaForge data entries with a priority belong to sources that no longer exist \(source ids 7, 9\)/)
  end

  it 'raises, naming the shared values and their sources, before creating anything when sources share a priority' do
    sources(shared: [[5, 'Cadastre'], [5, 'Map Editor'], [7, 'Business Directory'], [7, 'Business Registry']])
    expect(migration).not_to receive(:create_table)

    expect { migration.up }.to raise_error(RuntimeError, /LaForge data sources share priorities 5 \(Cadastre, Map Editor\); 7 \(Business Directory, Business Registry\)\. Give each source a unique priority/)
  end

  it 'raises, naming them, before creating anything when entries for the same record, attribute and source have different priorities' do
    sources(conflicting: [['Place', 12, 'name', 3]])
    expect(migration).not_to receive(:create_table)

    expect { migration.up }.to raise_error(RuntimeError, /LaForge data entries for the same record, attribute and source have different priorities, or a priority on some and none on others \(Place 12 name from source 3\). One precedence rule replaces them/)
  end

  it 'raises, naming them and the source they rank below, before creating anything when an entry has a priority below that of another source whose entry has none' do
    sources(outranked: [['Place', 12, 'name', 3, 5], ['Place', 14, 'name', 3, 5]])
    expect(migration).not_to receive(:create_table)

    expect { migration.up }.to raise_error(RuntimeError, /LaForge data entries have a priority below the priority of another source whose entry for the same record and attribute has none \(Place 12 name from source 3, below source 5; Place 14 name from source 3, below source 5\)\. .*give the other source's entries for that record and attribute their source's priority/)
  end

  it 'goes on to create the table when every check passes' do
    sources
    expect(migration).to receive(:create_table).and_raise('created') # stops before the rest of the migration

    expect { migration.up }.to raise_error('created')
  end
end

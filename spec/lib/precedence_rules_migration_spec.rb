require 'spec_helper'

# The upgrade from sources and entries with a priority column, checked before it changes anything
describe 'The precedence rules migration' do
  let(:migration) do
    migration_class_name = 'MoveLaforgePrioritiesToPrecedenceRules'
    migration_version = "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
    template = File.read(File.expand_path('../../lib/generators/laforge/templates/precedence_rules_migration.rb.tt', __dir__))
    Module.new.tap { |namespace| namespace.module_eval(ERB.new(template).result(binding)) }.const_get(migration_class_name).new
  end

  def sources(missing: [], shared: [])
    allow(migration).to receive(:select_values).and_return(missing)
    allow(migration).to receive(:select_rows).and_return(shared)
  end

  it 'raises, naming the sources, before creating anything when a source has no priority' do
    sources(missing: ['Cadastre', 'Map Editor'])
    expect(migration).not_to receive(:create_table)

    expect { migration.up }.to raise_error(RuntimeError, /Give these LaForge data sources a priority before migrating, as each becomes the source's global precedence: Cadastre, Map Editor/)
  end

  it 'raises, naming the shared values and their sources, before creating anything when sources share a priority' do
    sources(shared: [[5, 'Cadastre'], [5, 'Map Editor'], [7, 'Business Directory'], [7, 'Business Registry']])
    expect(migration).not_to receive(:create_table)

    expect { migration.up }.to raise_error(RuntimeError, /LaForge data sources share priorities 5 \(Cadastre, Map Editor\); 7 \(Business Directory, Business Registry\); give each source a unique priority/)
  end

  it 'goes on to create the table when every source has its own priority' do
    sources
    expect(migration).to receive(:create_table).and_raise('created') # stops before the rest of the migration

    expect { migration.up }.to raise_error('created')
  end
end

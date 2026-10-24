require 'spec_helper'

# Where a test sets a ruleset selector, places select their ruleset by `region`.
describe 'Rulesets' do
  include ActiveSupport::Testing::TimeHelpers

  before do
    AssociationCapabilities.setup!
    AssociationCapabilities.reset!
    LaForge::PrecedenceRule.where.not(ruleset: LaForge::PrecedenceRule::BASE).delete_all
    LaForge::DataSource.where(name: ['Cadastre', 'Business Directory', 'Business Registry', 'Map Editor']).delete_all
  end

  around do |example|
    example.run
  ensure
    LaForge.ruleset_selector = nil
  end

  after do
    LaForge::DataSource.where(name: ['Cadastre', 'Business Directory', 'Business Registry', 'Map Editor']).delete_all # their rules go with them
    LaForge::PrecedenceRule.where.not(ruleset: LaForge::PrecedenceRule::BASE).delete_all
  end

  let!(:business_registry) { LaForge::DataSource.create!(name: 'Business Registry', precedence: 41) }
  let!(:cadastre) { LaForge::DataSource.create!(name: 'Cadastre', precedence: 42) }
  let!(:business_directory) { LaForge::DataSource.create!(name: 'Business Directory', precedence: 43) }
  let!(:map_editor) { LaForge::DataSource.create!(name: 'Map Editor', precedence: 44) }

  let(:north_place) { Place.create!(name: 'Harbor Building', region: 'north') }
  let(:south_place) { Place.create!(name: 'Harbor Building', region: 'south') }

  def record_names(place)
    { cadastre => 'From Cadastre', business_directory => 'From Business Directory', map_editor => 'From Map Editor' }.each do |source, name|
      place.record_data_entries({ name: name }, source)
    end
    place.save!
  end

  def forged_name(place) = place.reload.tap(&:forge!).reload.name
  def order_of(place) = place.reload.precedence_order(:name).first(3).map { |item| [item[:source], item[:level], item[:ruleset]] }

  describe 'choosing a ruleset' do
    before do
      [north_place, south_place].each { |place| record_names(place) }
      Place.update_precedence_order([cadastre], attribute: :name, ruleset: 'north')
    end

    it 'ranks by the base rules without a selector, whatever rulesets are in use' do
      expect(forged_name(north_place)).to eq('From Map Editor')
      expect(order_of(north_place).first).to eq([map_editor, :global, nil])
    end

    it 'chooses a ruleset with the app-wide selector, a method name or a Proc given the record' do
      LaForge.ruleset_selector = :region
      expect(forged_name(north_place)).to eq('From Cadastre')
      expect(order_of(north_place)).to eq([[cadastre, :attribute, 'north'], [map_editor, :global, 'north'], [business_directory, :global, 'north']])
      expect(forged_name(south_place)).to eq('From Map Editor') # south has no rules, so its places rank by the base rules

      LaForge.ruleset_selector = ->(place) { place.region == 'south' ? :north : nil }
      expect(forged_name(south_place)).to eq('From Cadastre') # a Symbol is turned into a String
      expect(forged_name(north_place)).to eq('From Map Editor') # nil chooses the base rules
    end

    it "uses a model's own selector in place of the app-wide one, and false for the base rules" do
      LaForge.ruleset_selector = ->(_record) { 'north' }
      stub_const('RegionalPlace', Class.new(ActiveRecord::Base))
      RegionalPlace.table_name = 'places'
      RegionalPlace.laforged(ruleset_selector: ->(place) { place.region == 'south' ? 'north' : '' })
      stub_const('BasePlace', Class.new(ActiveRecord::Base))
      BasePlace.table_name = 'places'
      BasePlace.laforged(ruleset_selector: false)
      RegionalPlace.update_precedence_order([cadastre], attribute: :name, ruleset: 'north')

      regional = RegionalPlace.find(south_place.id)
      record_names(regional)
      expect(forged_name(regional)).to eq('From Cadastre')
      expect(forged_name(RegionalPlace.find(north_place.id).tap { |place| record_names(place) })).to eq('From Map Editor') # blank chooses the base rules
      expect(forged_name(BasePlace.find(north_place.id).tap { |place| record_names(place) })).to eq('From Map Editor')
    end

    it "ranks a record's association by the ruleset its selector names at each forge of the association, without reloading" do
      LaForge.ruleset_selector = :region
      Place.update_precedence_order([cadastre], attribute: :place_categories, ruleset: 'north')
      cafe, bakery = %w[Café Bakery].map { |name| Category.create!(name: name) }
      north_place.record_data_entries({ place_categories: [{ category_id: cafe.id }] }, cadastre)
      north_place.record_data_entries({ place_categories: [{ category_id: bakery.id }] }, map_editor)
      north_place.forge_associations
      expect(north_place.place_categories.map(&:category)).to eq([cafe])

      north_place.region = 'south' # no rules there, so the base rules rank
      north_place.forge_associations
      expect(north_place.place_categories.reject(&:marked_for_destruction?).map(&:category)).to eq([bakery])
      expect(north_place.member_sources(:place_categories, category_id: bakery.id)[:membership]).to eq(map_editor)
      north_place.region = 'north' # back, without forging
      expect(north_place.member_sources(:place_categories, category_id: bakery.id)[:membership]).to be_nil # cadastre's list there leaves it out
    end

    it 'ranks a whole forge by the ruleset selected before it, even when the forge changes what the selector reads, as forge_diff previews' do
      LaForge.ruleset_selector = :region
      cafe, bakery = %w[Café Bakery].map { |name| Category.create!(name: name) }
      record_names(north_place)
      Place.update_precedence_order([cadastre], attribute: :name, ruleset: 'north')
      Place.update_precedence_order([cadastre], attribute: :place_categories, ruleset: 'north')
      north_place.record_data_entries({ place_categories: [{ category_id: cafe.id }] }, cadastre)
      north_place.record_data_entries({ place_categories: [{ category_id: bakery.id }], region: 'south' }, map_editor) # moves the place to south
      north_place.save!

      preview = north_place.forge_diff['place_categories']
      north_place.forge!

      expect(north_place.reload).to have_attributes(region: 'south', name: 'From Cadastre')
      expect(north_place.place_categories.map(&:category)).to eq([cafe]) # ranked by north, as the name was
      expect(preview[:added]).to eq([{ 'category_id' => cafe.id }])
    end

    it "evaluates each member's own selector when a tracked association's members are forged" do
      LaForge.ruleset_selector = ->(record) { record.try(:region) } # tenants have no region, so they rank by the base rules
      Tenant.update_precedence_order([cadastre], attribute: :name, ruleset: 'north')
      north_place.record_data_entries({ tenants: [{ external_id: 'T-1', name: 'Corner Café' }] }, cadastre)
      north_place.record_data_entries({ tenants: [{ external_id: 'T-1', name: 'Corner Café & Bakery' }] }, map_editor)
      north_place.forge!

      expect(Tenant.sole.name).to eq('Corner Café & Bakery')
      expect(forged_name(north_place)).to eq('From Cadastre')
    end
  end

  describe 'forking on first write' do
    before do
      record_names(north_place)
      LaForge.ruleset_selector = :region
      Place.update_precedence_order([business_directory, cadastre]) # a base order for every attribute
    end

    it 'keeps the ranking it forked with, except for the rule written, and ignores later changes to the base rules' do
      before_fork = order_of(north_place)
      Place.update_attribute_source_precedence(:name, business_registry, 5, ruleset: 'north')
      expect(order_of(north_place)).to eq([[business_registry, :attribute, 'north']] + before_fork.first(2).map { |source, level, _| [source, level, 'north'] })

      Place.update_precedence_order([cadastre]) # the base rules change after the fork
      cadastre.update!(precedence: 45)
      expect(order_of(north_place).map(&:first)).to eq([business_registry, business_directory, cadastre])
      expect(forged_name(south_place.tap { |place| record_names(place) })).to eq('From Cadastre')
    end

    it 'copies nothing when forked twice, and every write path forks first' do
      LaForge.fork_ruleset('north')
      copied = LaForge::PrecedenceRule.where(ruleset: 'north').count
      expect(copied).to eq(LaForge::PrecedenceRule.where(ruleset: '', record_id: 0).count)
      LaForge.fork_ruleset(:north)
      expect(LaForge::PrecedenceRule.where(ruleset: 'north').count).to eq(copied)

      { 'west' => -> { Place.update_source_precedence(cadastre, 9, ruleset: 'west') },
        'east' => -> { LaForge.update_precedence_order([cadastre], ruleset: 'east') },
        'south' => -> { LaForge.update_source_precedence(cadastre, 99, ruleset: 'south') } }.each do |ruleset, write|
        write.call
        expect(LaForge::PrecedenceRule.where(ruleset: ruleset).count).to be >= copied
      end
      expect(Place.source_precedences).to eq('' => { business_directory => 2, cadastre => 1 }) # the base rules are unchanged
      expect(LaForge::DataSource.maximum_precedence).to be < 99
    end

    it 'falls back within the ruleset when an order there is removed, never to the base rules' do
      Place.update_precedence_order([cadastre], attribute: :name, ruleset: 'north')
      Place.update_precedence_order([map_editor], ruleset: 'north') # the ruleset's order for every attribute
      Place.update_precedence_order([business_registry]) # the base's, which the ruleset no longer follows

      Place.update_precedence_order(nil, attribute: :name, ruleset: 'north')
      expect(forged_name(north_place)).to eq('From Map Editor')
      expect(order_of(north_place).first).to eq([map_editor, :model, 'north'])
    end

    it 'lists the rulesets in use, and resets one to the base rules' do
      Place.update_precedence_order([cadastre], attribute: :name, ruleset: 'north')
      LaForge.fork_ruleset('south')
      expect(LaForge.rulesets).to eq(%w[north south])
      expect(forged_name(north_place)).to eq('From Cadastre')

      LaForge.reset_ruleset('north')
      expect(LaForge.rulesets).to eq(['south'])
      expect(forged_name(north_place)).to eq('From Business Directory')
      expect(Place.source_precedences(ruleset: 'south')).to eq(Place.source_precedences)
    end
  end

  it 'caches each ruleset apart within one precedence cache block, and sees changes made in it' do
    LaForge.ruleset_selector = :region
    [north_place, south_place].each { |place| record_names(place) }
    Place.update_precedence_order([cadastre], attribute: :name, ruleset: 'north')
    Place.update_precedence_order([business_directory], attribute: :name, ruleset: 'south')

    LaForge.with_precedence_cache do
      expect([forged_name(north_place), forged_name(south_place)]).to eq(['From Cadastre', 'From Business Directory'])
      Place.update_precedence_order([map_editor], attribute: :name, ruleset: 'south')
      expect([forged_name(north_place), forged_name(south_place)]).to eq(['From Cadastre', 'From Map Editor'])
    end
  end

  it "ranks each ruleset by its own global order, which LaForge.update_precedence_order sets there and nowhere else, within one cache block" do
    LaForge.ruleset_selector = :region
    east_place, west_place = %w[east west].map { |region| Place.create!(name: 'Harbor Building', region: region).tap { |place| record_names(place) } }
    LaForge.update_precedence_order([cadastre], ruleset: 'east')
    LaForge.update_precedence_order([business_directory], ruleset: 'west')

    LaForge.with_precedence_cache do
      expect([forged_name(east_place), forged_name(west_place)]).to eq(['From Cadastre', 'From Business Directory'])
    end
    expect(cadastre.reload.precedence).to eq(42) # the base global order is unchanged
    expect(LaForge::DataSource.by_precedence.where(id: [cadastre, map_editor]).to_a).to eq([map_editor, cadastre])
  end

  it 'sets one global precedence with or without ruleset:, and never removes it' do
    LaForge.ruleset_selector = :region
    record_names(north_place)
    LaForge.update_source_precedence(map_editor, -5, ruleset: 'north')
    expect(forged_name(north_place)).to eq('From Business Directory')

    LaForge.update_source_precedence(business_directory, 50) # the base rules
    expect(business_directory.reload.precedence).to eq(50)
    expect { LaForge.update_source_precedence(business_directory, nil) }
      .to raise_error(ArgumentError, /a source keeps a global precedence, which keeps forging free of ties, so it cannot be removed. Pass a new number, or reorder the sources with LaForge.update_precedence_order\z/)
    expect { LaForge.update_source_precedence(map_editor, nil, ruleset: 'north') }
      .to raise_error(ArgumentError, /a source keeps a global precedence in ruleset "north".*LaForge.update_precedence_order\(..., ruleset:\); LaForge.reset_ruleset drops a whole ruleset/)
  end

  it "places a source created later at the bottom of each ruleset's global order, and deletes its rules there when destroyed" do
    LaForge.update_precedence_order([cadastre], ruleset: 'north')
    LaForge.fork_ruleset('south')
    business_registry.destroy!
    expect(LaForge::PrecedenceRule.where(source_id: business_registry.id)).to be_empty # in every ruleset

    lowest = %w[north south].map { |ruleset| LaForge::PrecedenceRule.global.in_ruleset(ruleset).minimum(:precedence) }
    registry = LaForge::DataSource.create!(name: 'Business Registry', precedence: 41)
    placed = -> { %w[north south].map { |ruleset| LaForge::PrecedenceRule.global.in_ruleset(ruleset).find_by!(source: registry).precedence } }
    expect(placed.call).to eq(lowest.map { |precedence| precedence - 1 })
    expect(registry.reload.precedence).to eq(41) # the base rules are as given

    LaForge.update_source_precedence(registry, 100, ruleset: 'north')
    LaForge.place_in_rulesets(registry)
    expect(placed.call).to eq([100, lowest.last - 1]) # a ruleset that has placed it is left alone
  end

  it 'forgets a fork or a reset that rolls back, inside one precedence cache block' do
    LaForge.ruleset_selector = :region
    record_names(north_place)
    Place.update_precedence_order([cadastre], attribute: :name, ruleset: 'south')

    LaForge.with_precedence_cache do
      ActiveRecord::Base.transaction do
        LaForge.fork_ruleset('north')
        expect(order_of(north_place).first).to eq([map_editor, :global, 'north'])
        raise ActiveRecord::Rollback
      end
      expect(order_of(north_place).first).to eq([map_editor, :global, nil])

      south_place.tap { |place| record_names(place) }
      ActiveRecord::Base.transaction do
        LaForge.reset_ruleset('south')
        expect(forged_name(south_place)).to eq('From Map Editor')
        raise ActiveRecord::Rollback
      end
      expect(forged_name(south_place)).to eq('From Cadastre')
    end
  end

  it 'selects the ruleset a value names with surrounding whitespace, as the methods that write rules store it' do
    LaForge.ruleset_selector = :region
    spaced_place = Place.create!(name: 'Harbor Building', region: ' north ').tap { |place| record_names(place) }
    Place.update_precedence_order([cadastre], attribute: :name, ruleset: spaced_place.region)

    expect(LaForge.rulesets).to eq(['north'])
    expect(forged_name(spaced_place)).to eq('From Cadastre')
  end

  it 'adds the ruleset column and indexes with the generated migration, and takes them away again' do
    migration_class_name = 'AddRulesetToLaforgePrecedenceRules'
    migration_version = "[#{ActiveRecord::VERSION::MAJOR}.#{ActiveRecord::VERSION::MINOR}]"
    template = File.read(File.expand_path('../../lib/generators/laforge/templates/rulesets_migration.rb.tt', __dir__))
    migration = Module.new.tap { |namespace| namespace.module_eval(ERB.new(template).result(binding)) }.const_get(migration_class_name)
    indexes = -> { ActiveRecord::Base.connection.indexes(:laforge_precedence_rules).to_h { |index| [index.name, index.columns] } }
    LaForge.fork_ruleset('north')

    ActiveRecord::Migration.suppress_messages { migration.migrate(:down) }
    LaForge::PrecedenceRule.reset_column_information
    expect(LaForge::PrecedenceRule.column_names).not_to include('ruleset')
    expect(indexes.call['index_laforge_precedence_rules_on_scope_and_source']).to eq(%w[record_type record_id attribute_name source_id])

    ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
    LaForge::PrecedenceRule.reset_column_information
    expect(indexes.call).to include('index_laforge_precedence_rules_on_scope_and_source' => %w[record_type record_id attribute_name source_id ruleset],
                                    'index_laforge_precedence_rules_on_ruleset_and_global_precedence' => %w[ruleset global_precedence])
    expect(LaForge.rulesets).to be_empty # going down deleted them
  ensure
    LaForge::PrecedenceRule.reset_column_information
  end

  it 'raises, saying what to pass, for a ruleset or selector it cannot use' do
    expect { Place.update_precedence_order([cadastre], ruleset: 5) }.to raise_error(ArgumentError, /Place.update_precedence_order: ruleset: must be a String or Symbol naming the ruleset, or nil for the base rules, not Integer 5/)
    expect { LaForge.fork_ruleset('x' * 101) }.to raise_error(ArgumentError, /is longer than 100 characters/)
    expect { LaForge.fork_ruleset(nil) }.to raise_error(ArgumentError, /LaForge.fork_ruleset: pass the name of a ruleset; the base rules are not one/)
    expect { north_place.update_precedence_order(:name, [cadastre], ruleset: 'north') }
      .to raise_error(ArgumentError, /Place#update_precedence_order sets this record's own rules, which apply whatever its ruleset, so it takes no ruleset:. Leave it out, or set the rule for every record in the ruleset with Place.update_precedence_order\(..., ruleset:\)/)
    expect { north_place.update_attribute_source_precedence(:name, cadastre, 5, ruleset: 'north') }.to raise_error(ArgumentError, /Place#update_attribute_source_precedence sets this record's own rules/)
    expect { LaForge.ruleset_selector = 'region' }.to raise_error(ArgumentError, /LaForge.ruleset_selector = takes a method name \(Symbol\) or a Proc given the record, or nil, not String "region"/)
    expect { Class.new(ActiveRecord::Base) { self.table_name = 'places'; def self.name = 'OtherPlace' }.laforged(ruleset_selector: 'region') }
      .to raise_error(ArgumentError, /OtherPlace laforged ruleset_selector: takes a method name \(Symbol\) or a Proc given the record, false for the base rules, or nil/)
    expect { LaForge::PrecedenceRule.create!(record_type: 'Place', source: cadastre, precedence: 1, ruleset: 'west') }
      .to raise_error(ArgumentError, /Ruleset "west" has no rules yet, and its first rule copies the base rules into it. Write it with Model.update_precedence_order\(..., ruleset:\)/)

    LaForge.ruleset_selector = :district
    record_names(north_place)
    expect { north_place.forge! }.to raise_error(ArgumentError, /LaForge.ruleset_selector names :district, which Place does not respond to. Define Place#district, or give Place a selector of its own with `laforged ruleset_selector:`/)
  end
end

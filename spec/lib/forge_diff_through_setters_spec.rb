require 'spec_helper'

# `forge_diff(through_setters: true)`, which reports what a forge would change once the model's writers have had the
# forged values. The tenants here are a model of their own, whose writers change what they are given.
describe 'forge_diff through setters' do
  include ActiveSupport::Testing::TimeHelpers

  before(:all) do
    ActiveRecord::Schema.define do
      create_table :listed_tenants, force: true do |t|
        t.string :name
        t.string :unit
        t.string :registration_number
        t.string :street
        t.string :postcode
        t.string :status, default: 'open', null: false
        t.date :registered_on
        t.boolean :accessible
        t.string :region
        t.timestamps null: false
      end
    end
  end

  before do
    AssociationCapabilities.setup!
    AssociationCapabilities.reset!
    ActiveRecord::Base.connection.execute('DELETE FROM listed_tenants')
    LaForge::PrecedenceRule.where.not(ruleset: LaForge::PrecedenceRule::BASE).delete_all
    define_tenant
  end

  after { LaForge::PrecedenceRule.where.not(ruleset: LaForge::PrecedenceRule::BASE).delete_all }

  let(:low) { LaForge::DataSource.create!(key: 'low', precedence: 11) }
  let(:high) { LaForge::DataSource.create!(key: 'high', precedence: 12) }
  let(:top) { LaForge::DataSource.create!(key: 'top', precedence: 13) }

  let(:tenant) { Tenant.create!(name: 'Corner Café', unit: '1A', street: '2 Harbor Road', postcode: '94107', registered_on: Date.new(2024, 5, 1), accessible: true) }

  # Defines a tenant whose writers strip a name, shorten a ZIP+4 postcode, default a missing status, and clear the
  # registration number when the unit is assigned. The body adds to it.
  def define_tenant(**laforged_options, &body)
    klass = Class.new(ActiveRecord::Base)
    stub_const('Tenant', klass)
    klass.class_eval do
      self.table_name = 'listed_tenants'

      def name=(value)
        super(value&.strip)
      end

      def postcode=(value)
        super(value&.slice(0, 5))
      end

      def status=(value)
        super(value.presence || 'open')
      end

      def unit=(value)
        super
        self.registration_number = nil
      end
    end
    klass.class_eval(&body) if body
    klass.laforged(**laforged_options)
  end

  # Returns what a forge changes on the tenant as it is saved, loaded for it, as Active Record reports the changes
  def forge_changes(**options) = Tenant.find(tenant.id).tap { |loaded| loaded.forge(**options) }.changes

  def writes
    statements = []
    counter = ->(*, payload) { statements << payload[:sql] if payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE)/i) }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { yield }
    statements
  end

  describe 'values a writer changes' do
    {
      'a date recorded as text' => [{ registered_on: '2024-05-01' }, { 'registered_on' => [Date.new(2024, 5, 1), '2024-05-01'] }],
      'a flag recorded as "1"' => [{ accessible: '1' }, { 'accessible' => [true, '1'] }],
      'a flag recorded as "true"' => [{ accessible: 'true' }, { 'accessible' => [true, 'true'] }],
      'a value a writer shortens' => [{ postcode: '94107-1234' }, { 'postcode' => ['94107', '94107-1234'] }],
      'a nil a writer turns into a default' => [{ status: nil }, { 'status' => ['open', nil] }],
      'text a writer strips' => [{ name: ' Corner Café ' }, { 'name' => ['Corner Café', ' Corner Café '] }]
    }.each do |title, (recorded, raw)|
      it "leaves out #{title} once it is forged and saved, which the raw comparison reports" do
        tenant.record_data_entries(recorded, low)
        tenant.forge!
        tenant.reload

        expect(tenant.forge_diff).to eq(raw)
        expect(tenant.forge_diff(through_setters: true)).to eq({})
        expect(forge_changes).to eq({})
      end
    end

    it 'leaves out all of them together' do
      tenant.record_data_entries({ registered_on: '2024-05-01', accessible: 'true', postcode: '94107-1234', status: nil, name: ' Corner Café ' }, low)
      tenant.forge!
      tenant.reload

      expect(tenant.forge_diff.keys).to match_array(%w[registered_on accessible postcode status name])
      expect(tenant.forge_diff(through_setters: true)).to eq({})
    end
  end

  describe 'changes a forge would make' do
    it 'reports a change both ways, with the forged value as the record would read it through setters' do
      tenant.record_data_entries({ name: ' Harbor Books ', registered_on: '2025-01-15', accessible: '0', postcode: '94110-0001', street: '2 Harbor Road' }, low)
      tenant.save!

      expect(tenant.forge_diff).to eq(
        'name' => ['Corner Café', ' Harbor Books '], 'registered_on' => [Date.new(2024, 5, 1), '2025-01-15'], 'accessible' => [true, '0'], 'postcode' => ['94107', '94110-0001']
      )
      expect(tenant.forge_diff(through_setters: true)).to eq(
        'name' => ['Corner Café', 'Harbor Books'], 'registered_on' => [Date.new(2024, 5, 1), Date.new(2025, 1, 15)], 'accessible' => [true, false], 'postcode' => ['94107', '94110']
      )
      expect(tenant.forge_diff(through_setters: true)).to eq(forge_changes)
    end

    it 'reports an attribute against the record as it is in memory, unsaved changes included' do
      tenant.record_data_entries({ name: 'Corner Café' }, low)
      tenant.name = 'Harbor Books'

      expect(tenant.forge_diff(through_setters: true)).to eq('name' => ['Harbor Books', 'Corner Café'])
    end

    it 'reports nothing for a record no source provides a value for' do
      expect(tenant.forge_diff(through_setters: true)).to eq({})
      expect(Tenant.new(name: 'Harbor Books').forge_diff(through_setters: true)).to eq({})
    end

    it 'works on a record that is not saved yet' do
      unsaved = Tenant.new(name: 'Corner Café')
      unsaved.record_data_entries({ name: ' Harbor Books ', postcode: '94110-0001' }, low)

      expect(unsaved.forge_diff(through_setters: true)).to eq('name' => ['Corner Café', 'Harbor Books'], 'postcode' => [nil, '94110'])
      expect(unsaved).to be_new_record
    end

    it 'reports a value that only a save callback would change, since no save runs' do
      define_tenant { before_save { self.unit = unit&.upcase } }
      tenant.record_data_entries({ unit: '2b' }, low)
      tenant.forge!
      tenant.reload
      expect(tenant.unit).to eq('2B')

      expect(tenant.forge_diff).to eq('unit' => %w[2B 2b])
      expect(tenant.forge_diff(through_setters: true)).to eq('unit' => %w[2B 2b])
    end
  end

  describe 'the order of assignment' do
    it 'assigns in the order a forge does, so a writer that resets another attribute gives what the forge gives' do
      tenant.update!(registration_number: 'R-1')
      tenant.record_data_entries({ unit: '2B' }, top)
      tenant.record_data_entries({ registration_number: 'R-10' }, low) # assigned after the unit, so it stays
      tenant.save!
      expect(tenant.forge_diff(through_setters: true)).to eq('unit' => %w[1A 2B], 'registration_number' => %w[R-1 R-10])
      expect(tenant.forge_diff(through_setters: true)).to eq(forge_changes)

      tenant.record_data_entries({ registration_number: 'R-10' }, top, precedence: 20) # assigned first, then cleared by the unit
      tenant.save!
      expect(tenant.forge_diff).to eq('unit' => %w[1A 2B], 'registration_number' => %w[R-1 R-10])
      expect(tenant.forge_diff(through_setters: true)).to eq('unit' => %w[1A 2B], 'registration_number' => ['R-1', nil])
      expect(tenant.forge_diff(through_setters: true)).to eq(forge_changes)
    end

    it 'reports an attribute a writer resets even when its own recorded value is the one the record has' do
      tenant.update!(registration_number: 'R-1')
      tenant.record_data_entries({ registration_number: 'R-1' }, top)
      tenant.record_data_entries({ unit: '1A' }, low) # nothing differs, but assigning the unit clears the number
      tenant.save!

      expect(tenant.forge_diff).to eq({})
      expect(tenant.forge_diff(through_setters: true)).to eq('registration_number' => ['R-1', nil])
      expect(tenant.forge_diff(through_setters: true)).to eq(forge_changes)
    end
  end

  describe 'the entries it reads' do
    before do
      tenant.record_data_entries({ name: ' From Low ', postcode: '10001-0001' }, low)
      tenant.record_data_entries({ name: ' From High ' }, high)
      tenant.save!
    end

    def through(**options) = tenant.reload.forge_diff(through_setters: true, **options)

    it 'takes the entries a forge takes, by precedence' do
      expect(through).to eq('name' => ['Corner Café', 'From High'], 'postcode' => %w[94107 10001])

      tenant.update_attribute_source_precedence(:name, low, 50)
      tenant.save!
      expect(through).to eq('name' => ['Corner Café', 'From Low'], 'postcode' => %w[94107 10001])
      expect(through).to eq(forge_changes)

      Tenant.update_precedence_order([low, high], attribute: :name)
      tenant.reload.update_attribute_source_precedence(:name, low, nil)
      tenant.save!
      expect(through['name']).to eq(['Corner Café', 'From Low'])
    end

    it 'leaves out an expired entry and an inactive source, as a forge does' do
      tenant.record_data_entries({ name: ' From Top ' }, top, expires_at: 1.day.from_now)
      tenant.save!
      expect(through['name']).to eq(['Corner Café', 'From Top'])

      travel_to(2.days.from_now) do
        expect(through['name']).to eq(['Corner Café', 'From High'])
        expect(through).to eq(forge_changes)
      end

      high.update!(active: false)
      expect(through).to eq('name' => ['Corner Café', 'From Top'], 'postcode' => %w[94107 10001])
      travel_to(2.days.from_now) { expect(through).to eq('name' => ['Corner Café', 'From Low'], 'postcode' => %w[94107 10001]) }
    end

    it 'takes attributes:, sources: and except_sources: as the raw comparison does' do
      expect(through(attributes: :postcode)).to eq('postcode' => %w[94107 10001])
      expect(through(attributes: :postcode)).to eq(forge_changes(attributes: :postcode))
      expect(through(sources: low)).to eq('name' => ['Corner Café', 'From Low'], 'postcode' => %w[94107 10001])
      expect(through(sources: low)).to eq(forge_changes(sources: low))
      expect(through(except_sources: high)).to eq('name' => ['Corner Café', 'From Low'], 'postcode' => %w[94107 10001])
      expect(through(except_sources: [low, high])).to eq({})

      %i[attributes sources except_sources].zip([:name, high, low]).each do |option, value|
        expect(through(option => value).keys).to eq(tenant.forge_diff(option => value).keys)
      end
    end

    it 'takes a group from one source, with nil for an attribute that source leaves out' do
      define_tenant(attribute_groups: { postal_address: %i[street postcode] })
      listed = Tenant.find(tenant.id) # low provides its postcode alone, recorded before the group was declared
      listed.record_data_entries({ street: ' 4 Quay Lane ', postcode: '20002-0002' }, high)
      listed.save!
      expect(listed.forge_diff(through_setters: true)).to eq('name' => ['Corner Café', 'From High'], 'street' => ['2 Harbor Road', ' 4 Quay Lane '], 'postcode' => %w[94107 20002])

      listed.update_attribute_source_precedence(:postal_address, low, 50) # low decides the group, and leaves the street out
      listed.save!
      expect(listed.forge_diff(through_setters: true)).to eq('name' => ['Corner Café', 'From High'], 'street' => ['2 Harbor Road', nil], 'postcode' => %w[94107 10001])
      expect(listed.forge_diff(through_setters: true).keys).to match_array(listed.forge_diff.keys)
      expect(listed.forge_diff(through_setters: true)).to eq(forge_changes)
      expect(listed.forge_diff(through_setters: true, attributes: :street)).to eq('street' => ['2 Harbor Road', nil], 'postcode' => %w[94107 10001])
    end

    it "ranks by the record's ruleset" do
      define_tenant(ruleset_selector: :region)
      Tenant.update_precedence_order([low], attribute: :name, ruleset: 'north')
      north = Tenant.create!(name: 'Corner Café', region: 'north')
      south = Tenant.create!(name: 'Corner Café', region: 'south')
      [north, south].each do |listed|
        listed.record_data_entries({ name: ' From Low ' }, low)
        listed.record_data_entries({ name: ' From High ' }, high)
      end

      expect(north.forge_diff(through_setters: true)).to eq('name' => ['Corner Café', 'From Low'])
      expect(south.forge_diff(through_setters: true)).to eq('name' => ['Corner Café', 'From High'])
    end
  end

  describe 'what it leaves alone' do
    it 'leaves the record, its entries, its rules and its pending writes as they were' do
      tenant.record_data_entries({ name: ' Harbor Books ', postcode: '94110-0001' }, low, precedence: 30)
      tenant.save!
      tenant.reload
      tenant.record_data_entries({ unit: '2B' }, high, precedence: 31) # unsaved, as an edit being previewed is
      tenant.street = '4 Quay Lane'
      entries = tenant.data_entries.to_a
      rules = tenant.precedence_rules.to_a
      state = lambda do
        [tenant.attributes, tenant.changes, tenant.readonly?, tenant.new_record?,
         tenant.data_entries.target.map { |entry| [entry.object_id, entry.attributes, entry.changed?, entry.new_record?, entry.marked_for_destruction?] },
         tenant.precedence_rules.target.map { |rule| [rule.object_id, rule.attributes, rule.changed?, rule.new_record?, rule.marked_for_destruction?] },
         tenant.laforge.instance_variable_get(:@pending_writes)]
      end
      before = state.()

      statements = writes { tenant.forge_diff(through_setters: true) }

      expect(statements).to eq([])
      expect(state.()).to eq(before)
      expect(tenant.data_entries.target).to eq(entries)
      expect(tenant.precedence_rules.target).to eq(rules)
      expect(Tenant.count).to eq(1)
      expect(Tenant.find(tenant.id).attributes).to include('name' => 'Corner Café', 'unit' => '1A', 'street' => '2 Harbor Road')
      expect(LaForge::DataEntry.count).to eq(2)
    end

    it 'neither validates nor saves the copy, and runs no save or commit callback' do
      calls = []
      define_tenant do
        validates :name, presence: true
        before_validation { calls << :validation }
        before_save { calls << :save }
        after_commit { calls << :commit }
        after_rollback { calls << :rollback }
      end
      tenant.record_data_entries({ name: nil, unit: '2B' }, low)
      tenant.save!(validate: false)
      calls.clear

      expect(tenant.forge_diff(through_setters: true)).to eq('name' => ['Corner Café', nil], 'unit' => %w[1A 2B])
      expect(calls).to eq([])
    end

    it "passes a tracked association's membership through as the raw comparison reports it, assigning no member" do
      place = Place.create!(name: 'Harbor Building')
      place.record_data_entries({ name: 'Harbor Hall', tenants: [{ name: 'Corner Café' }] }, low)
      place.save!
      place.reload

      diff = place.forge_diff(through_setters: true)

      expect(diff).to eq('name' => ['Harbor Building', 'Harbor Hall'], 'tenants' => { added: [{ 'name' => 'Corner Café' }], removed: [], changed: [] })
      expect(diff).to eq(place.forge_diff)
      expect(place.forge_diff(through_setters: true, attributes: :name).keys).to eq(['name'])
      expect(place.tenants.target).to eq([])
      expect(place.laforge.instance_variable_get(:@pending_writes)).to be_nil
      expect(Place.find(place.id).tenants.count).to eq(0)
    end
  end

  describe 'writers that write to the database' do
    # A tenant whose `category_name=` replaces the category of that name, as a writer that maintains another table does
    def define_categorizing_tenant(&body)
      define_tenant do
        attr_reader :category_name

        def category_name=(value)
          Category.where(name: value).destroy_all
          Category.create!(name: value)
          @category_name = value
        end
        class_eval(&body) if body
      end
    end

    it 'leaves no trace of what a writer wrote' do
      define_categorizing_tenant
      cafe = Category.create!(name: 'Café')
      tenant.record_data_entries({ category_name: 'Café', name: ' Harbor Books ' }, low)
      tenant.save!
      counts = -> { [Category.count, Tenant.count, LaForge::DataEntry.count, LaForge::PrecedenceRule.count] }
      before = counts.()

      statements = writes { expect(tenant.forge_diff(through_setters: true)).to eq('category_name' => [nil, 'Café'], 'name' => ['Corner Café', 'Harbor Books']) }

      expect(statements.size).to eq(2) # the writer's DELETE and INSERT ran, and were rolled back
      expect(counts.()).to eq(before)
      expect(Category.find_by(name: 'Café')).to eq(cafe)
      expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
    end

    it 'rolls back to a savepoint inside an outer transaction, which goes on' do
      define_categorizing_tenant
      tenant.record_data_entries({ category_name: 'Café' }, low)
      tenant.save!

      Tenant.transaction do
        Category.create!(name: 'Bakery')
        expect(tenant.forge_diff(through_setters: true)).to eq('category_name' => [nil, 'Café'])
        expect(ActiveRecord::Base.connection.open_transactions).to eq(1)
        Category.create!(name: 'Florist')
      end

      expect(Category.pluck(:name)).to match_array(%w[Bakery Florist])
    end

    it 'does not undo what a writer changes outside the database' do
      define_categorizing_tenant do
        cattr_accessor :assignments, default: []

        def unit=(value)
          assignments << value
          super
        end
      end
      tenant.record_data_entries({ unit: '2B' }, low)
      Tenant.assignments.clear

      tenant.forge_diff(through_setters: true)

      expect(Tenant.assignments).to eq(['2B'])
    end

    it 'raises, naming the attribute, when a writer saves the record, and leaves no transaction open' do
      define_categorizing_tenant do
        def unit=(value)
          super
          save!
        end
      end
      tenant.record_data_entries({ category_name: 'Café' }, top)
      tenant.record_data_entries({ unit: '2B' }, low)
      tenant.save!

      expect { tenant.forge_diff(through_setters: true) }.to raise_error(LaForge::WriterError) do |error|
        expect(error.errors.keys).to eq(['unit'])
        expect(error.errors['unit']).to be_a(ActiveRecord::ReadOnlyRecord)
        expect(error.message).to match(/Tenant#unit= given "2B" from low raised ActiveRecord::ReadOnlyRecord \(Tenant#unit= saved or destroyed the record while forge_diff\(through_setters: true\) assigned it to a read-only copy\. Compare Tenant#unit with forge_diff, or keep the writer from saving/)
      end
      expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
      expect(Category.count).to eq(0) # what the earlier writer wrote is rolled back too
      expect(Tenant.count).to eq(1)
      expect(tenant.reload.unit).to eq('1A')

      Tenant.transaction do
        Category.create!(name: 'Bakery')
        expect { tenant.forge_diff(through_setters: true) }.to raise_error(LaForge::WriterError)
        expect(ActiveRecord::Base.connection.open_transactions).to eq(1)
      end
      expect(Category.pluck(:name)).to eq(['Bakery'])
    end

    it 'gives a writer a copy with no id' do
      ids = []
      define_tenant do
        define_method(:unit=) do |value|
          ids << id
          super(value)
        end
      end
      tenant.record_data_entries({ unit: '2B' }, low)
      expect(tenant.id).to be_present
      ids.clear

      tenant.forge_diff(through_setters: true)

      expect(ids).to eq([nil])
    end
  end
end

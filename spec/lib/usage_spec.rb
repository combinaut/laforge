require 'spec_helper'

# Common ways of using LaForge to merge several data sources into one record, one group per intention. Association
# assignment by importers is in `association_importer_scenarios_spec.rb`.
describe 'Usage' do
  # Runs before the sources below are created
  before do
    LaForge::DataEntry.delete_all
    LaForge::PrecedenceRule.where.not(record_type: LaForge::PrecedenceRule::ANY_TYPE).delete_all
    LaForge::DataSource.where(name: ['Cadastre', 'Business Directory', 'Map Editor', 'Geocoder']).delete_all
  end

  # Two importers and a map editor whose edits outrank both
  let!(:cadastre) { LaForge::DataSource.create!(name: 'Cadastre', precedence: 31) }
  let!(:business_directory) { LaForge::DataSource.create!(name: 'Business Directory', precedence: 32) }
  let!(:map_editor) { LaForge::DataSource.create!(name: 'Map Editor', precedence: 33) }

  let(:record) { ActiveRecordMock.create!(name: 'Original', active: true, count: 1) }

  # A host model with a setter that is not a column, such as one that maintains an association from a single value
  let(:virtual_attribute_model) do
    Class.new(ActiveRecordMock) do
      attr_reader :phone_number

      def self.name = 'ActiveRecordMock'

      def phone_number=(number)
        @phone_number = number
      end
    end
  end

  # An importer records every attribute it assigns on its own source, forges once the row has been assigned, and saves
  # the record itself afterwards
  describe 'an importer recording each attribute it assigns' do
    it 'applies the winning value of each attribute and persists the entries with the record' do
      record.record_data_entries({ name: 'From Cadastre', count: 5 }, cadastre)
      record.record_data_entries({ name: 'From Map Editor' }, map_editor)
      record.forge
      record.save!

      expect(record.reload).to have_attributes(name: 'From Map Editor', count: 5)
      expect(record.data_entries.count).to eq(3)
    end

    it 'leaves attributes that have no entries as they are, such as columns the importer writes directly' do
      record.count = 9 # assigned directly by the importer, not recorded
      record.record_data_entries({ name: 'From Cadastre' }, cadastre)
      record.forge!

      expect(record.reload).to have_attributes(name: 'From Cadastre', count: 9)
    end

    it 'lets a higher source win over a value the importer assigned and recorded in the same run' do
      # Assign, then record what was assigned, then forge
      record.record_data_entries({ name: 'From Map Editor' }, map_editor)
      record.save!
      record.name = 'From Cadastre'
      record.record_data_entries(record.slice(:name), cadastre)
      record.forge

      expect(record.name).to eq('From Map Editor')
    end

    it 'returns the winning value of every recorded attribute, so changes can be tracked before saving' do
      record.record_data_entries({ name: 'From Cadastre', active: false }, cadastre)
      record.record_data_entries({ name: 'From Business Directory' }, business_directory)

      expect(record.forge_attributes).to eq('name' => 'From Business Directory', 'active' => false)
      expect(record.forge_diff).to eq('name' => ['Original', 'From Business Directory'], 'active' => [true, false])
    end

    it 'records and forges attributes that are setters rather than columns' do
      stub_const('PhoneRecord', virtual_attribute_model)
      phone_record = PhoneRecord.create!(name: 'Corner Café')

      phone_record.record_data_entries({ phone_number: '555-0100' }, cadastre)
      phone_record.forge

      expect(phone_record.phone_number).to eq('555-0100')
      expect(phone_record.forge_attributes).to include('phone_number' => '555-0100')
      expect(phone_record.forge_attributes.slice(*phone_record.attribute_names)).not_to include('phone_number')
    end

    it 'raises for an attribute the model cannot set' do
      expect { record.record_data_entries({ nonexistent: 1 }, cadastre) }.to raise_error(LaForge::InvalidAttributeName)
    end
  end

  # A map editor's edit is recorded on the highest-precedence source so it outranks importers and survives their later runs
  describe 'map editor overrides' do
    before do
      record.record_data_entries({ name: 'From Cadastre', count: 5 }, cadastre)
      record.forge!
    end

    it 'applies only the overridden attribute when forging it alone' do
      record.record_data_entries({ count: 6 }, cadastre) # pending from elsewhere, must not be applied
      record.record_data_entry(:name, 'From Map Editor', map_editor)
      record.forge(attributes: :name)

      expect(record).to have_attributes(name: 'From Map Editor', count: 5)
      expect(record.reload.name).to eq('From Cadastre')
    end

    it 'persists the override and its value together' do
      record.record_data_entry(:name, 'From Map Editor', map_editor)
      record.forge!(attributes: :name)

      expect(record.reload.name).to eq('From Map Editor')
      expect(record.data_entries.with_source(map_editor).with_attribute(:name)).to exist
    end

    it 'keeps the override through later importer runs' do
      record.record_data_entry(:name, 'From Map Editor', map_editor)
      record.forge!(attributes: :name)

      record.reload.record_data_entries({ name: 'Changed In Cadastre' }, cadastre)
      record.forge!

      expect(record.reload.name).to eq('From Map Editor')
    end

    it "falls back to the importer's latest value when the override's entries are destroyed" do
      record.record_data_entry(:name, 'From Map Editor', map_editor)
      record.forge!(attributes: :name)
      record.reload.record_data_entries({ name: 'Changed In Cadastre' }, cadastre)
      record.forge!

      record.data_entries.with_source(map_editor).with_attribute(:name).destroy_all
      record.data_entries.reset
      record.forge!(attributes: :name)

      expect(record.reload.name).to eq('Changed In Cadastre')
    end

    it "falls back to the importer's value when the override is removed inside forge!" do
      record.record_data_entry(:name, 'From Map Editor', map_editor)
      record.forge!

      record.forge!(attributes: :name) { record.remove_data_entries(attribute_names: :name, sources: map_editor) }

      expect(record.reload.name).to eq('From Cadastre')
      expect(record.reload.tap(&:forge).name).to eq('From Cadastre') # and the next forge agrees
    end

    it 'keeps a value recorded again after an unsaved removal of its entry' do
      record.record_data_entry(:name, 'From Map Editor', map_editor)
      record.forge!

      record.remove_data_entries(attribute_names: :name, sources: map_editor)
      record.record_data_entry(:name, 'Renamed In Map Editor', map_editor)
      record.forge!

      expect(record.reload.name).to eq('Renamed In Map Editor')
      expect(record.data_entries.with_source(map_editor).with_attribute(:name)).to exist
    end

    it 'blanks the attribute when the editor records nil' do
      record.record_data_entry(:name, 'From Map Editor', map_editor)
      record.forge!

      record.record_data_entry(:name, nil, map_editor)
      record.forge!

      expect(record.reload.name).to be_nil
    end

    it 'answers whether an attribute is overridden by querying the entries' do
      record.record_data_entry(:name, 'From Map Editor', map_editor)
      record.save!

      expect(record.data_entries.with_source(map_editor.name).with_attribute(:name)).to exist
      expect(record.data_entries.with_source(map_editor.name).with_attribute(:count)).not_to exist
    end

    it 'raises when a source is looked up by a name that has no row, which callers guard against' do
      expect { record.data_entries.with_source('No Such Source').to_a }.to raise_error(LaForge::DataSource::Invalid)
      expect(LaForge::DataSource.exists?(name: 'No Such Source')).to be(false)
    end
  end

  # A value already applied to the record some other way, such as an approved suggested edit, is recorded and saved without
  # forging
  describe 'recording without forging' do
    it 'persists the entries and leaves the record as it is' do
      record.update!(name: 'Approved')
      record.record_data_entries({ name: record.read_attribute(:name) }, map_editor)
      record.save!

      expect(record.reload.name).to eq('Approved')
      expect(record.data_entries.sole).to have_attributes(attribute_name: 'name', value: 'Approved', source_id: map_editor.id)
    end

    it 'updates the existing entry when a value from the same source is recorded for the attribute again' do
      record.record_data_entries({ name: 'First' }, map_editor)
      record.save!
      record.reload.record_data_entries({ name: 'Second' }, map_editor)
      record.save!

      expect(record.data_entries.reload.map(&:value)).to eq(['Second'])
    end

    it 'applies the recorded value at the next forge by any importer' do
      record.record_data_entries({ name: 'Approved' }, map_editor)
      record.save!

      record.reload.record_data_entries({ name: 'From Cadastre' }, cadastre)
      record.forge!

      expect(record.reload.name).to eq('Approved')
    end
  end

  # A record's own precedence for an attribute and source outranks the model-wide and global rules, so a source can be
  # authoritative for some attributes of a record regardless of its global precedence
  describe 'per-record precedence' do
    it 'lets an entry outrank a higher-precedence source' do
      record.record_data_entries({ name: 'From Map Editor' }, map_editor)
      record.record_data_entries({ name: 'From Business Directory' }, business_directory, precedence: 100)
      record.forge!

      expect(record.reload.name).to eq('From Business Directory')
    end

    it 'keeps the custom precedence when a value from the same source is recorded for the attribute again without one' do
      record.record_data_entries({ name: 'From Map Editor' }, map_editor)
      record.record_data_entries({ name: 'From Business Directory' }, business_directory, precedence: 100)
      record.forge!

      record.reload.record_data_entries({ name: 'From Business Directory Again' }, business_directory)
      record.forge!

      expect(record.reload.name).to eq('From Business Directory Again')
    end

    it "sets one record's precedence for one attribute and source" do
      record.record_data_entries({ name: 'From Cadastre' }, cadastre)
      record.record_data_entries({ name: 'From Business Directory' }, business_directory)
      record.save!

      record.update_attribute_source_precedence(:name, cadastre, 100)
      record.reload.forge

      expect(record.name).to eq('From Cadastre')
    end

    it 'can be set before the source has an entry for the attribute, and applies once it has one' do
      record.update_attribute_source_precedence(:name, cadastre, 100)
      record.record_data_entries({ name: 'From Map Editor' }, map_editor)
      record.forge!

      record.reload.record_data_entries({ name: 'From Cadastre' }, cadastre)
      record.forge!

      expect(record.reload.name).to eq('From Cadastre')
    end

    it 'is saved with a new record when given while recording' do
      new_record = ActiveRecordMock.new(name: 'New')
      new_record.record_data_entries({ name: 'From Cadastre' }, cadastre, precedence: 100)
      new_record.forge!

      expect(new_record.reload.source_precedences).to eq('name' => { cadastre => 100 })
    end

    it "survives the source's entries being destroyed by an orphan sweep" do
      record.record_data_entries({ name: 'From Cadastre' }, cadastre, precedence: 100)
      record.record_data_entries({ name: 'From Map Editor' }, map_editor)
      record.forge!
      record.data_entries.with_source(cadastre).destroy_all

      record.reload.record_data_entries({ name: 'Back In Cadastre' }, cadastre)
      record.forge!

      expect(record.reload.name).to eq('Back In Cadastre')
    end

    it 'is removed by recording again with a nil precedence' do
      record.record_data_entries({ name: 'From Cadastre' }, cadastre, precedence: 100)
      record.record_data_entries({ name: 'From Map Editor' }, map_editor)
      record.forge!

      record.reload.record_data_entries({ name: 'From Cadastre' }, cadastre, precedence: nil)
      record.forge!

      expect(record.reload.name).to eq('From Map Editor')
      expect(record.source_precedences).to be_empty
    end
  end

  # An importer wraps its run in `LaForge.with_precedence_cache` so that forging each row doesn't read the global and
  # model-wide rules again
  describe 'caching precedence for an import run' do
    let(:records) { Array.new(3) { |index| ActiveRecordMock.create!(name: "Row #{index}") } }

    def rule_queries(&block)
      queries = []
      counter = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?('laforge_precedence_rules') && !payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE)/i) }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &block)
      queries
    end

    def import(rows)
      rows.each do |row|
        label = "Row #{records.index(row)}"
        row.record_data_entries({ name: "#{label} From Cadastre" }, cadastre)
        row.record_data_entries({ name: "#{label} From Business Directory" }, business_directory)
        row.forge!
      end
    end

    it 'reads the global and model-wide rules once for the whole run' do
      records
      cached = rule_queries { LaForge.with_precedence_cache { import(records) } }
      uncached = rule_queries { import(records.map(&:reload)) }

      expect(cached.grep(/record_type`? = ''/).size).to eq(1)
      expect(uncached.grep(/record_type`? = ''/).size).to eq(records.size)
    end

    it 'sees precedence changed through LaForge during the run' do
      LaForge.with_precedence_cache do
        import(records.first(1))
        ActiveRecordMock.update_attribute_source_precedence(:name, cadastre, 100)
        import(records.last(1))
      end

      expect(records.first.reload.name).to eq('Row 0 From Business Directory')
      expect(records.last.reload.name).to eq('Row 2 From Cadastre')
    end

    it 'does not see precedence changed outside LaForge until the run ends' do
      LaForge.with_precedence_cache do
        import(records.first(1))
        LaForge::PrecedenceRule.where(source_id: cadastre.id).update_all(precedence: 100) # e.g. by SQL from another process
        import(records.last(1))
      end
      import(records.first(1).map(&:reload))

      expect(records.last.reload.name).to eq('Row 2 From Business Directory')
      expect(records.first.reload.name).to eq('Row 0 From Cadastre')
    end
  end

  describe 'model-wide precedence' do
    before do
      record.record_data_entries({ name: 'From Cadastre', count: 5 }, cadastre)
      record.record_data_entries({ name: 'From Business Directory', count: 7 }, business_directory)
      record.save!
    end

    it 'ranks a source for one attribute on every record of the model' do
      ActiveRecordMock.update_attribute_source_precedence(:count, cadastre, 100)
      record.reload.forge

      expect(record).to have_attributes(name: 'From Business Directory', count: 5)
    end

    it 'ranks a source for every attribute on every record of the model' do
      ActiveRecordMock.update_source_precedence(cadastre, 100)
      record.reload.forge

      expect(record).to have_attributes(name: 'From Cadastre', count: 5)
    end

    it "gives way to a record's own precedence" do
      ActiveRecordMock.update_source_precedence(cadastre, 100)
      record.update_attribute_source_precedence(:name, business_directory, 200)
      record.reload.forge

      expect(record).to have_attributes(name: 'From Business Directory', count: 5)
    end

    it 'lists the rules and removes them with a nil precedence' do
      ActiveRecordMock.update_attribute_source_precedence(:count, cadastre, 100)
      expect(ActiveRecordMock.source_precedences).to eq('count' => { cadastre => 100 })

      ActiveRecordMock.update_attribute_source_precedence(:count, cadastre, nil)
      expect(ActiveRecordMock.source_precedences).to be_empty
    end
  end

  describe 'a source that stops providing a record' do
    before do
      record.record_data_entries({ name: 'From Cadastre', count: 5 }, cadastre)
      record.record_data_entries({ name: 'From Business Directory', count: 7, active: false }, business_directory)
      record.forge!
    end

    it 'blanks the attributes the source was providing by recording nil, even where a lower source has a value' do
      record.record_data_entries({ name: nil, count: nil }, business_directory)
      record.forge!

      expect(record.reload).to have_attributes(name: nil, count: nil, active: false)
    end

    it "keeps a higher source's value while blanking the source's own" do
      record.record_data_entries({ name: 'From Map Editor' }, map_editor)
      record.forge!

      record.record_data_entries({ name: nil, count: nil }, business_directory)
      record.forge!

      expect(record.reload).to have_attributes(name: 'From Map Editor', count: nil)
    end

    it 'falls back to the lower source when the entries are removed, and keeps the value no other source has' do
      record.forge! { record.remove_data_entries(attribute_names: %i[name count active], sources: business_directory) }

      expect(record.reload).to have_attributes(name: 'From Cadastre', count: 5, active: false)
      expect(record.data_entries.with_source(business_directory)).not_to exist
      expect(record.tap(&:forge)).to have_attributes(name: 'From Cadastre', count: 5, active: false) # and the next forge agrees
    end

    it 'deletes entries without changing the attribute when they are removed outside forge and the record saved' do
      record.remove_data_entries(attribute_names: :active, sources: business_directory)
      record.update!(count: 0)

      expect(record.reload).to have_attributes(active: false, count: 0)
      expect(record.data_entries.with_source(business_directory).with_attribute(:active)).not_to exist
    end

    it 'tells whether any other source still has entries on the record, to decide whether to orphan it' do
      expect(record.data_entries.without_source('Business Directory')).not_to be_empty

      record.data_entries.with_source(cadastre).destroy_all
      expect(record.data_entries.without_source('Business Directory')).to be_empty
    end
  end

  # When an import no longer includes a record, drop the importer's entries and orphan the record unless a source other
  # than a neutral one still has entries on it
  describe 'an import orphan sweep' do
    let!(:geocoder) { LaForge::DataSource.create!(name: 'Geocoder', precedence: 34) }

    before do
      record.record_data_entries({ name: 'From Cadastre' }, cadastre)
      record.record_data_entries({ active: false }, geocoder)
      record.save!
    end

    def still_claimed?(record, source, neutral_sources)
      neutral_ids = LaForge::DataSource.where(name: neutral_sources).pluck(:id)
      record.data_entries.with_source(source).destroy_all
      record.data_entries.without_source(source).where.not(source_id: neutral_ids).exists?
    end

    it 'counts entries from any other source as a claim that the record exists' do
      expect(still_claimed?(record, cadastre.name, [])).to be(true)
    end

    it 'ignores sources that only provide attribute values' do
      expect(still_claimed?(record, cadastre.name, ['Geocoder'])).to be(false)
      expect(record.data_entries.reload.map(&:source)).to eq([geocoder])
    end

    it 'does not change the record, which keeps its values until it is next forged' do
      still_claimed?(record, cadastre.name, [])

      expect(record.reload.name).to eq('Original')
    end
  end

  describe 'inspecting where values came from' do
    before do
      record.record_data_entries({ name: 'From Cadastre', count: 5 }, cadastre)
      record.record_data_entries({ name: 'From Business Directory' }, business_directory, precedence: 100)
      record.save!
    end

    it "orders an attribute's entries by the precedence that decides them" do
      entries = record.data_entries.includes(:source).group_by(&:attribute_name)['name'].sort_by(&:effective_precedence).reverse

      expect(entries.map { |entry| [entry.source.name, entry.effective_precedence] }).to eq([['Business Directory', 100], ['Cadastre', 31]])
    end

    it 'ranks by precedence rules changed since the last forge once the record is reloaded' do
      record.update_attribute_source_precedence(:name, business_directory, nil)
      record.forge
      ActiveRecordMock.update_attribute_source_precedence(:name, cadastre, 200)
      record.reload

      entries = LaForge::DataEntry.in_precedence_order(record.data_entries.to_a, record: record)
      expect(entries.find { |entry| entry.attribute_name == 'name' }.source).to eq(cadastre)
    end

    it 'lists the sources a record or one attribute has entries from' do
      expect(record.data_source_names).to contain_exactly('Cadastre', 'Business Directory')
      expect(record.data_source_names(attributes: :count)).to eq(['Cadastre'])
      expect(record.data_source?(business_directory)).to be(true)
      expect(record.data_source?(map_editor)).to be(false)
    end

    it 'finds records by source' do
      other = ActiveRecordMock.create!(name: 'Other')
      other.record_data_entries({ name: 'Other' }, map_editor)
      other.save!

      expect(ActiveRecordMock.with_source(business_directory).distinct).to eq([record])
      expect(ActiveRecordMock.with_attribute_with_source(:name, map_editor).distinct).to eq([other])
    end
  end

  # Data migrations that delete a source's entries so that a value written to the column directly, or another source's
  # value, is not overwritten by the next forge
  describe "deleting a source's entries outside an import" do
    before do
      record.record_data_entries({ name: 'From Business Directory', count: 7 }, business_directory)
      record.record_data_entries({ name: 'From Cadastre' }, cadastre)
      record.forge!
    end

    it 'keeps applying stored entries at every forge until they are deleted' do
      record.update!(name: 'Written Directly')
      record.reload.forge!

      expect(record.reload.name).to eq('From Business Directory')
    end

    it 'lets a directly written value survive later forges once every entry for the attribute is deleted' do
      LaForge::DataEntry.where(record_type: 'ActiveRecordMock', record_id: record.id, attribute_name: 'count').delete_all
      record.update!(count: 0)
      record.reload.forge!

      expect(record.reload.count).to eq(0)
    end

    it "lets the next source's value win once the outranking source's entries are deleted" do
      LaForge::DataEntry.with_source('Business Directory').where(record_type: 'ActiveRecordMock', record_id: record.id, attribute_name: 'name').delete_all
      record.reload.forge!

      expect(record.reload.name).to eq('From Cadastre')
    end

    it 'finds every record with an entry from a source for an attribute in one query' do
      ids = LaForge::DataEntry.with_source(business_directory.name).with_attribute(:count).where(record_type: 'ActiveRecordMock').distinct.pluck(:record_id)

      expect(ids).to eq([record.id])
    end
  end

  # A belongs_to association is recorded by passing the record, or nil. It is stored as the foreign key, and as the
  # type too when polymorphic, so the link resolves across sources like any attribute and its entries tell which source
  # set it.
  describe 'a belongs_to association' do
    let(:parent) { ActiveRecordMock.create!(name: 'Parent') }
    let(:other_parent) { ActiveRecordMock.create!(name: 'Other Parent') }

    it 'records the foreign key and forges the association from the winning source' do
      record.record_data_entries({ parent: parent }, cadastre)
      record.record_data_entries({ parent: other_parent }, business_directory)
      record.forge!

      expect(record.reload.parent).to eq(other_parent)
      expect(record.data_entries.map(&:attribute_name).uniq).to eq(['parent_id'])
    end

    it 'records the type of a polymorphic association too' do
      record.record_data_entries({ subject: parent }, cadastre)
      record.forge!

      expect(record.reload.subject).to eq(parent)
      expect(record.data_entries.to_h { |entry| [entry.attribute_name, entry.value] }).to eq('subject_id' => parent.id, 'subject_type' => 'ActiveRecordMock')
    end

    it "records the key a polymorphic association's `primary_key:` names" do
      stub_const('CountedMock', Class.new(ActiveRecord::Base))
      CountedMock.table_name = 'active_record_mocks'
      CountedMock.belongs_to :subject, polymorphic: true, primary_key: :count, optional: true
      CountedMock.laforged
      counted = CountedMock.create!(name: 'Counted')
      parent.update!(count: 9_041)

      counted.record_data_entries({ subject: parent }, cadastre)
      counted.forge!

      expect(counted.data_entries.to_h { |entry| [entry.attribute_name, entry.value] }).to eq('subject_id' => 9_041, 'subject_type' => 'ActiveRecordMock')
      expect(counted.reload.subject).to eq(parent)
    end

    it 'clears the association when the winning source provides nil' do
      record.record_data_entries({ parent: parent }, cadastre)
      record.record_data_entries({ parent: nil }, business_directory)
      record.forge!

      expect(record.reload.parent).to be_nil
    end

    it 'raises for a record of the wrong class or one that is not saved' do
      expect { record.record_data_entries({ parent: LaForge::DataSource.first }, cadastre) }.to raise_error(LaForge::InvalidValue)
      expect { record.record_data_entries({ parent: ActiveRecordMock.new }, cadastre) }.to raise_error(LaForge::InvalidValue)
    end

    it 'tells whether the current link was set by an importer rather than an editor' do
      record.record_data_entries({ parent: parent }, cadastre)
      record.forge!

      importer_set_it = record.data_entries.with_attribute(:parent_id).where.not(source_id: map_editor.id).any? { |entry| entry.value == record.parent_id }
      expect(importer_set_it).to be(true)
    end

    it 'moves the link by replacing every other source entry for it with one from the source taking ownership' do
      record.record_data_entries({ parent: parent }, cadastre)
      record.record_data_entries({ parent: other_parent }, map_editor)
      record.forge!

      LaForge::DataEntry.where(record: record, attribute_name: 'parent_id').where.not(source_id: business_directory.id).delete_all
      record.reload.record_data_entries({ parent: parent }, business_directory)
      record.forge!

      expect(record.reload.parent).to eq(parent)
      expect(record.data_entries.map(&:source)).to eq([business_directory])
    end
  end

  describe 'values that cannot be stored' do
    it 'raises for a value that would not survive being stored as JSON, such as an object' do
      expect { record.record_data_entries({ name: Object.new }, cadastre) }.to raise_error(LaForge::InvalidValue)
      expect { record.record_data_entries({ name: { 'nested' => [Object.new] } }, cadastre) }.to raise_error(LaForge::InvalidValue)
    end

    it 'accepts strings, numbers, booleans, dates, nil, and arrays and hashes of those' do
      expect { record.record_data_entries({ name: 'Name', count: 1, active: false }, cadastre) }.not_to raise_error
      expect(LaForge::DataEntry.storable?([1, 'a', nil, { 'at' => Date.new(2026, 1, 1) }])).to be(true)
    end
  end

  describe 'forging a new record' do
    it 'inserts the forged values rather than the column defaults' do
      new_record = ActiveRecordMock.new(name: 'New')
      new_record.record_data_entries({ active: false }, business_directory)
      new_record.forge!

      expect(new_record.reload.active).to be(false)
      expect(new_record.data_entries.count).to eq(1)
    end

    it 'discards entries that were recorded and forged but not saved when the record is reloaded' do
      record.record_data_entries({ name: 'From Business Directory' }, business_directory)
      record.forge
      record.reload

      expect(record.name).to eq('Original')
      expect(record.data_entries).to be_empty
    end
  end

  # Attributes that must come from one source together, such as the lines of an address
  describe 'attribute groups' do
    let(:grouped_model) do
      Class.new(ActiveRecordMock) do
        def self.name = 'ActiveRecordMock'

        laforged attribute_groups: { listing: %i[name count] }
      end
    end
    let(:grouped) { grouped_model.create!(name: 'Original', count: 1) }

    it 'takes every attribute of the group from the source that ranks highest for any of them' do
      grouped.record_data_entries({ name: 'From Cadastre', count: 5 }, cadastre)
      grouped.record_data_entries({ name: 'From Map Editor', count: nil }, map_editor)
      grouped.forge!

      expect(grouped.reload).to have_attributes(name: 'From Map Editor', count: nil)
    end

    it 'blanks an attribute the winning source has no entry for' do
      grouped.record_data_entries({ name: 'From Cadastre', count: 5 }, cadastre)
      LaForge::DataEntry.create!(record: grouped, source: map_editor, attribute_name: 'name', value: 'From Map Editor') # recorded before the group was declared
      grouped.reload.forge!

      expect(grouped.reload).to have_attributes(name: 'From Map Editor', count: nil)
    end

    it 'raises when a source provides part of a group, naming what is missing' do
      expect { grouped.record_data_entries({ name: 'From Cadastre' }, cadastre) }
        .to raise_error(ArgumentError, /name, count are attribute group listing, which a source provides together \(missing: count\)/)
      expect { grouped.record_data_entry(:count, 5, cadastre) }.to raise_error(ArgumentError, /missing: name/)
    end

    it 'ranks the group by rules set on the group, and raises for a rule on one of its attributes' do
      grouped.record_data_entries({ name: 'From Cadastre', count: 5 }, cadastre)
      grouped.record_data_entries({ name: 'From Map Editor', count: 7 }, map_editor)
      grouped.update_attribute_source_precedence(:listing, cadastre, 1)
      grouped.forge!

      expect(grouped.reload).to have_attributes(name: 'From Cadastre', count: 5)
      expect { grouped.update_attribute_source_precedence(:count, cadastre, 1) }.to raise_error(ArgumentError, /ActiveRecordMock#count is in attribute group listing, which is ranked as a whole; set the precedence on listing/)
      expect { grouped_model.update_attribute_source_precedence(:name, cadastre, 1) }.to raise_error(ArgumentError, /set the precedence on listing/)
    end

    it 'gives a precedence passed while recording to the group' do
      grouped.record_data_entries({ name: 'From Cadastre', count: 5 }, cadastre, precedence: 1)
      grouped.record_data_entries({ name: 'From Map Editor', count: 7 }, map_editor)
      grouped.forge!

      expect(grouped.reload).to have_attributes(name: 'From Cadastre', count: 5)
      expect(grouped.source_precedences).to eq('listing' => { cadastre => 1 })
    end

    it 'removes and forges the whole group when given one of its attributes' do
      grouped.record_data_entries({ name: 'From Cadastre', count: 5 }, cadastre)
      grouped.record_data_entries({ name: 'From Map Editor', count: 7 }, map_editor)
      grouped.save!

      expect(grouped.forge_attributes(attributes: :name)).to eq('name' => 'From Map Editor', 'count' => 7)
      grouped.remove_data_entries(attribute_names: :name, sources: map_editor)
      grouped.save!

      expect(grouped.reload.data_entries.map(&:source)).to all(eq(cadastre))
    end

    it 'raises for a group it cannot use, saying why' do
      declare = ->(groups) { Class.new(ActiveRecordMock) { def self.name = 'ActiveRecordMock' }.laforged(attribute_groups: groups) }

      expect { declare.(listing: %i[name]) }.to raise_error(ArgumentError, /attribute group listing names 1 attribute; a group needs at least two/)
      expect { declare.(listing: %i[name count], tally: %i[count active]) }.to raise_error(ArgumentError, /ActiveRecordMock#count is in attribute groups listing and tally/)
      expect { declare.(name: %i[name count]) }.to raise_error(ArgumentError, /attribute group name is named like one of its attributes/)
    end
  end

  # A source the host stops using. Its values stop counting from each record's next forge, and its entries are kept.
  describe 'an inactive source' do
    before do
      record.record_data_entries({ name: 'From Cadastre', count: 5 }, cadastre)
      record.record_data_entries({ name: 'From Map Editor', count: 9 }, map_editor)
      record.forge!
    end

    it "falls back to the next source, and keeps a value no other source has, once the record is forged again" do
      record.update!(active: false)
      record.record_data_entries({ active: true }, map_editor) # an attribute only the map editor provides
      record.forge!
      map_editor.update!(active: false)

      expect(record.reload).to have_attributes(name: 'From Map Editor', count: 9, active: true) # nothing changes until the next forge
      record.forge!
      expect(record.reload).to have_attributes(name: 'From Cadastre', count: 5, active: true)
    end

    it 'keeps its entries and still records, so activating it again restores what it says' do
      map_editor.update!(active: false)
      record.reload.record_data_entries({ name: 'Renamed in the Map Editor' }, map_editor)
      record.forge!
      expect(record.reload.name).to eq('From Cadastre')

      map_editor.update!(active: true)
      record.forge!
      expect(record.reload.name).to eq('Renamed in the Map Editor')
    end

    it 'is seen as active again inside a precedence cache once deactivating it rolls back' do
      LaForge.with_precedence_cache do
        ActiveRecord::Base.transaction do
          map_editor.update!(active: false)
          record.reload.forge
          raise ActiveRecord::Rollback
        end
        record.reload.forge
        expect(record.name).to eq('From Map Editor')
      end
    end

    it 'is seen by a forge inside a precedence cache once it changes there' do
      LaForge.with_precedence_cache do
        record.reload.forge!
        map_editor.update!(active: false)
        record.reload.forge!
      end

      expect(record.reload.name).to eq('From Cadastre')
    end
  end

  # What would be forged without one source, such as the import value an edit replaced
  describe 'forging without a source' do
    it 'leaves out the given sources' do
      record.record_data_entries({ name: 'From Cadastre', count: 5 }, cadastre)
      record.record_data_entries({ name: 'From Map Editor' }, map_editor)

      expect(record.forge_attributes(attributes: :name, except_sources: map_editor)).to eq('name' => 'From Cadastre')
      expect(record.forge_attributes(except_sources: [map_editor, cadastre])).to eq({})
    end
  end

  # A host following what sources say, such as to notice that an import changed a value an editor replaced
  describe 'following changes to entries' do
    let(:events) { [] }

    around do |example|
      subscription = ActiveSupport::Notifications.subscribe(LaForge::DataEntry::CHANGED) { |*, payload| events << payload.except(:entry) }
      example.run
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it 'publishes an entry saved with a new or changed value, and an entry destroyed' do
      record.record_data_entries({ name: 'From Cadastre' }, cadastre)
      record.save!
      record.record_data_entries({ name: 'From Cadastre' }, cadastre) # the same value
      record.save!
      record.record_data_entries({ name: 'Renamed' }, cadastre)
      record.save!
      record.remove_data_entries(sources: cadastre)
      record.save!

      expected = { record_type: 'ActiveRecordMock', record_id: record.id, attribute_name: 'name', source_id: cadastre.id, expires_at: nil, expires_on_source_id: nil }
      expect(events).to eq([
        expected.merge(value_was: nil, value: 'From Cadastre', destroyed: false),
        expected.merge(value_was: 'From Cadastre', value: 'Renamed', destroyed: false),
        expected.merge(value_was: 'Renamed', value: nil, destroyed: true)
      ])
    end

    it 'publishes the values as they were saved, even when one is changed in place before the commit' do
      ActiveRecord::Base.transaction do
        record.record_data_entries({ name: ['From Cadastre'] }, cadastre)
        record.save!
        record.data_entries.sole.value << 'changed in place'
      end

      expect(events.map { |event| event[:value] }).to eq([['From Cadastre']])
    end

    it 'publishes once the write is committed, at once outside a transaction, and nothing for a write that rolls back' do
      record.record_data_entries({ name: 'From Cadastre' }, cadastre)
      record.save! # no explicit transaction
      expect(events.map { |event| event[:value] }).to eq(['From Cadastre'])

      ActiveRecord::Base.transaction do
        record.record_data_entries({ name: 'Renamed' }, cadastre)
        record.save!
        expect(events.size).to eq(1) # not committed yet
      end
      expect(events.map { |event| event[:value] }).to eq(['From Cadastre', 'Renamed'])

      ActiveRecord::Base.transaction do
        record.record_data_entries({ name: 'Renamed again' }, cadastre)
        record.forge!
        raise ActiveRecord::Rollback
      end
      expect(events.size).to eq(2)
    end
  end

  # The order of sources at each level, as a settings screen sets it, with LaForge choosing the numbers
  describe 'precedence orders' do
    before do
      record.record_data_entries({ name: 'From Cadastre', count: 5 }, cadastre)
      record.record_data_entries({ name: 'From Business Directory', count: 7 }, business_directory)
      record.record_data_entries({ name: 'From Map Editor', count: 9 }, map_editor)
      record.save!
    end

    it "sets one record's order for an attribute, saved with the record, ranking the sources it leaves out below" do
      record.update_precedence_order(:name, [cadastre])
      expect(record.precedence_rules.select(&:new_record?).size).to eq(1)
      record.forge!

      expect(record.reload).to have_attributes(name: 'From Cadastre', count: 9)
      expect(record.precedence_order(:name).map { |item| [item[:source], item[:level]] }.first(3))
        .to eq([[cadastre, :record], [map_editor, :global], [business_directory, :global]])
    end

    it 'replaces the order at that level, and removes it given nil' do
      record.update_precedence_order(:name, [cadastre, business_directory])
      record.update_precedence_order(:name, [business_directory])
      record.forge!
      expect(record.reload.name).to eq('From Business Directory')
      expect(record.source_precedences).to eq('name' => { business_directory => 1 })

      record.update_precedence_order(:name, nil)
      record.forge!
      expect(record.reload.name).to eq('From Map Editor')
    end

    it 'ranks a source added later below an order set at a more specific level, whatever its global precedence' do
      record.update_precedence_order(:name, [business_directory, cadastre])
      record.forge!
      geocoder = LaForge::DataSource.create!(name: 'Geocoder', precedence: 1000)
      record.reload.record_data_entries({ name: 'From Geocoder' }, geocoder)
      record.forge!

      expect(record.reload.name).to eq('From Business Directory')
    end

    it 'sets the order for one attribute, or every attribute, on every record of a model' do
      ActiveRecordMock.update_precedence_order([cadastre], attribute: :count)
      ActiveRecordMock.update_precedence_order([business_directory, cadastre])
      record.reload.forge

      expect(record).to have_attributes(name: 'From Business Directory', count: 5)
      expect(ActiveRecordMock.precedence_order(attribute: :count).map { |item| [item[:source], item[:level]] }.first(3))
        .to eq([[cadastre, :attribute], [business_directory, :model], [map_editor, :global]])
    end

    it 'lists the model-wide order as the model level when asked for no attribute' do
      ActiveRecordMock.update_source_precedence(cadastre, 5)

      expect(ActiveRecordMock.precedence_order.first).to eq(source: cadastre, level: :model, ruleset: nil)
      expect(ActiveRecordMock.precedence_order(attribute: :name).first).to eq(source: cadastre, level: :model, ruleset: nil)
    end

    it 'lists a source with no global precedence last, with no level' do
      # As for a source whose rules were deleted with it, while its entries, which have no foreign key, stayed
      LaForge::PrecedenceRule.global.where(source_id: cadastre.id).delete_all

      expect(ActiveRecordMock.precedence_order.last).to include(source: cadastre, level: nil)
    ensure
      cadastre.update!(precedence: 31) # specs in other files expect every source to have a global precedence
    end

    it 'sets the global order, renumbering every source and keeping those it leaves out below, in their order' do
      ActiveRecord::Base.transaction do
        LaForge.update_precedence_order([cadastre, map_editor])

        ranked = LaForge::DataSource.by_precedence.to_a
        expect(ranked.first(3)).to eq([cadastre, map_editor, business_directory])
        expect(ranked.map(&:precedence)).to eq((1..ranked.size).to_a.reverse)
        expect(record.reload.forge_attributes).to include('name' => 'From Cadastre')
        raise ActiveRecord::Rollback # leave the other specs' sources as they were
      end
    end

    it 'lists the records that have an order of their own' do
      record.update_precedence_order(:name, [cadastre])
      record.save!

      expect(LaForge::PrecedenceRule.for_records(ActiveRecordMock).pluck(:record_id, :attribute_name)).to eq([[record.id, 'name']])
    end
  end

  # An editor's change that should hold for a while, or until a source provides a different value, after which the
  # record goes back to what its sources say without it
  describe 'expiring a change' do
    include ActiveSupport::Testing::TimeHelpers

    before do
      record.record_data_entries({ name: 'From Cadastre', count: 5 }, cadastre)
      record.record_data_entries({ name: 'From Business Directory', count: 7 }, business_directory)
      record.forge!
    end

    it 'falls back to the next source once a value expires, from the next forge, and keeps the expired entry' do
      record.record_data_entries({ name: 'Renamed in the Map Editor' }, map_editor, expires_at: 1.week.from_now)
      record.forge!
      expect(record.reload.name).to eq('Renamed in the Map Editor')

      travel 8.days do
        expect(record.reload.name).to eq('Renamed in the Map Editor') # nothing changes until the next forge
        record.forge!
        expect(record.reload.name).to eq('From Business Directory')
        expect(record.data_entries.with_source(map_editor).sole).to have_attributes(value: 'Renamed in the Map Editor', expired?: true)
      end
    end

    it 'expires a value once the source it expires on provides a different value for the attribute' do
      record.record_data_entries({ name: 'Renamed in the Map Editor' }, map_editor, expires_on: cadastre)
      record.forge!
      record.reload.record_data_entries({ count: 6 }, cadastre) # another attribute
      record.forge!
      record.reload.record_data_entries({ name: 'From Cadastre' }, cadastre) # the same value, as an import that runs again
      record.forge!
      expect(record.reload.name).to eq('Renamed in the Map Editor')

      record.record_data_entries({ name: 'Corrected by Cadastre' }, cadastre)
      record.forge!

      expect(record.reload.name).to eq('From Business Directory')
      expect(record.data_entries.with_source(map_editor).sole).to have_attributes(expires_at: be_within(1.minute).of(Time.current), expires_on_source: cadastre)
    end

    it "compares the source's value with its own entry, not with the forged value" do
      record.record_data_entries({ name: 'Renamed in the Map Editor' }, map_editor, expires_on: cadastre)
      record.forge!

      record.reload.record_data_entries({ name: 'Renamed in the Map Editor' }, cadastre) # the forged value, but not cadastre's
      record.forge!

      expect(record.reload.name).to eq('From Business Directory')
    end

    it 'expires a value once the source it expires on provides the attribute for the first time' do
      record.record_data_entries({ active: false }, map_editor, expires_on: cadastre)
      record.forge!

      record.reload.record_data_entries({ active: false }, cadastre) # cadastre had no entry for it
      record.forge!

      expect(record.data_entries.with_source(map_editor).sole.expired?).to be(true)
    end

    it 'compares values as they are stored, so a symbol and its string are the same value' do
      record.record_data_entries({ name: 'Renamed in the Map Editor' }, map_editor, expires_on: cadastre)
      record.forge!

      record.reload.record_data_entries({ name: :'From Cadastre' }, cadastre)
      record.forge!

      expect(record.reload.name).to eq('Renamed in the Map Editor')
    end

    it 'counts a change not saved yet as made now, so only a later recording ends it' do
      travel_to(Time.current.change(usec: 0)) do # one instant for the whole save
        record.record_data_entries({ name: 'Renamed in the Map Editor' }, map_editor, expires_on: cadastre)
        record.record_data_entries({ name: 'From Cadastre' }, cadastre)
        record.forge!
      end
      expect(record.reload.name).to eq('Renamed in the Map Editor')

      record.record_data_entries({ name: 'Corrected by Cadastre' }, cadastre)
      record.forge!
      expect(record.reload.name).to eq('From Business Directory')
    end

    it "expires a record's precedence order, so the next level's order applies again" do
      record.update_precedence_order(:name, [cadastre], expires_at: 1.week.from_now)
      record.update_precedence_order(:count, [cadastre], expires_on: business_directory)
      record.forge!
      expect(record.reload).to have_attributes(name: 'From Cadastre', count: 5)

      record.record_data_entries({ count: 8 }, business_directory)
      record.forge!
      expect(record.reload).to have_attributes(name: 'From Cadastre', count: 8)

      travel 8.days do
        record.reload.forge!
        expect(record.reload.name).to eq('From Business Directory')
        expect(record.precedence_order(:name).first).to eq(source: map_editor, level: :global, ruleset: nil)
        expect(record.source_precedences).to eq({})
        expect(record.precedence_rules.size).to eq(2) # both expired rules are kept
      end
    end

    it 'expires a value and the precedence that keeps it on top together, set in one save' do
      record.record_data_entries({ name: 'Pinned by Cadastre' }, cadastre, precedence: 100, expires_on: business_directory)
      record.save!
      record.forge!
      expect(record.reload.name).to eq('Pinned by Cadastre')

      record.record_data_entries({ name: 'Renamed by Business Directory' }, business_directory)
      record.forge!

      expect(record.reload.name).to eq('Renamed by Business Directory')
      expect(LaForge::PrecedenceRule.for_records(ActiveRecordMock).expired.pluck(:source_id)).to eq([cadastre.id])
    end

    it 'replaces the expiry when the value is recorded or the order set again, and clears it when left out' do
      record.record_data_entries({ name: 'Renamed in the Map Editor' }, map_editor, expires_at: 1.week.from_now)
      record.update_precedence_order(:name, [map_editor], expires_on: cadastre)
      record.save!
      record.record_data_entries({ name: 'Renamed in the Map Editor' }, map_editor, expires_at: 2.weeks.from_now)
      record.update_precedence_order(:name, [map_editor])
      record.save!

      expect(record.data_entries.with_source(map_editor).sole.expires_at).to be_within(1.minute).of(2.weeks.from_now)
      expect(record.precedence_rules.sole).to have_attributes(expires_at: nil, expires_on_source_id: nil)

      record.record_data_entries({ name: 'Renamed in the Map Editor' }, map_editor)
      record.save!
      expect(record.data_entries.with_source(map_editor).sole.expires_at).to be_nil
    end

    it 'lists what expires before a time, so the application can forge those records on time and warn ahead of it' do
      record.record_data_entries({ name: 'Renamed in the Map Editor' }, map_editor, expires_at: 3.days.from_now)
      record.update_precedence_order(:count, [cadastre], expires_at: 10.days.from_now)
      record.save!

      expect(LaForge::DataEntry.expiring(before: 1.week.from_now).pluck(:record_id, :attribute_name)).to eq([[record.id, 'name']])
      expect(LaForge::PrecedenceRule.expiring(before: 1.week.from_now)).to be_empty
      expect(LaForge::PrecedenceRule.expiring(before: 2.weeks.from_now).pluck(:record_id)).to eq([record.id])
      travel 4.days do
        expect(LaForge::DataEntry.expired.count).to eq(1)
        expect(LaForge::DataEntry.unexpired.count).to eq(4)
      end
    end

    it 'publishes the expiry with the change it records, and an expiry changed alone, but nothing when it passes' do
      events = []
      subscription = ActiveSupport::Notifications.subscribe(LaForge::DataEntry::CHANGED) { |*, payload| events << payload.slice(:source_id, :value, :expires_at, :expires_on_source_id) }
      expires_at = 1.week.from_now
      record.record_data_entries({ name: 'Renamed in the Map Editor' }, map_editor, expires_at: expires_at)
      record.forge!
      record.record_data_entries({ name: 'Renamed in the Map Editor' }, map_editor) # the same value, its expiry cleared
      record.forge!
      record.record_data_entries({ name: 'Renamed in the Map Editor' }, map_editor, expires_at: 1.day.from_now)
      record.forge!

      travel 2.days do
        expect { record.reload.forge! }.not_to change(events, :size) # an expiry passing changes no entry
        expect(record.reload.name).to eq('From Business Directory')
      end

      renamed = { source_id: map_editor.id, value: 'Renamed in the Map Editor', expires_on_source_id: nil }
      expect(events).to match([renamed.merge(expires_at: be_within(1.second).of(expires_at)), renamed.merge(expires_at: nil),
                               renamed.merge(expires_at: be_within(1.minute).of(1.day.from_now))])
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it 'publishes the waiting entry when an expiry on a source fires and the entry is saved' do
      record.record_data_entries({ name: 'Renamed in the Map Editor' }, map_editor, expires_on: cadastre)
      record.forge!
      events = []
      subscription = ActiveSupport::Notifications.subscribe(LaForge::DataEntry::CHANGED) { |*, payload| events << payload.slice(:source_id, :value_was, :value, :expires_at, :expires_on_source_id) }

      record.record_data_entries({ name: 'Corrected by Cadastre' }, cadastre)
      record.forge!

      expect(events).to contain_exactly({ source_id: cadastre.id, value_was: 'From Cadastre', value: 'Corrected by Cadastre', expires_at: nil, expires_on_source_id: nil },
                                        { source_id: map_editor.id, value_was: 'Renamed in the Map Editor', value: 'Renamed in the Map Editor',
                                          expires_at: be_within(1.minute).of(Time.current), expires_on_source_id: cadastre.id })
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it 'expires a belongs_to association recorded as its foreign key' do
      parent = ActiveRecordMock.create!(name: 'Parent')
      record.record_data_entries({ parent: parent }, map_editor, expires_at: 1.week.from_now)
      record.forge!

      expect(record.reload.parent).to eq(parent)
      expect(record.data_entries.with_attribute(:parent_id).sole.expires_at).to be_within(1.second).of(1.week.from_now)
    end

    it 'applies an expiry on part of an attribute group to the whole group' do
      grouped_model = Class.new(ActiveRecordMock) do
        def self.name = 'ActiveRecordMock'

        laforged attribute_groups: { listing: %i[name count] }
      end
      grouped = grouped_model.find(record.id)
      grouped.record_data_entries({ name: 'From Map Editor', count: 9 }, map_editor)
      grouped.forge!
      grouped.data_entries.with_source(map_editor).with_attribute(:count).sole.update!(expires_at: 1.day.ago) # set on one attribute outside LaForge

      expect(grouped.reload.forge_attributes).to eq('name' => 'From Business Directory', 'count' => 7)
    end

    it 'expires an attribute group once the source it expires on provides a different value for any of its attributes' do
      grouped_model = Class.new(ActiveRecordMock) do
        def self.name = 'ActiveRecordMock'

        laforged attribute_groups: { listing: %i[name count] }
      end
      grouped = grouped_model.find(record.id)
      grouped.record_data_entries({ name: 'From Map Editor', count: 9 }, map_editor, expires_on: cadastre)
      grouped.forge!
      grouped.reload.record_data_entries({ name: 'From Cadastre', count: 5 }, cadastre) # the same values
      grouped.forge!
      expect(grouped.reload).to have_attributes(name: 'From Map Editor', count: 9)

      grouped.record_data_entries({ name: 'From Cadastre', count: 6 }, cadastre)
      grouped.forge!

      expect(grouped.reload).to have_attributes(name: 'From Business Directory', count: 7)
    end

    it 'raises for an expiry it cannot apply, saying what to pass' do
      expect { record.record_data_entries({ name: 'Renamed' }, map_editor, expires_at: '2030-01-01') }.to raise_error(ArgumentError, /expires_at: must be a time, such as 2.weeks.from_now, not "2030-01-01"/)
      expect { record.record_data_entries({ name: 'Renamed' }, map_editor, expires_on: map_editor) }.to raise_error(ArgumentError, /expires_on: names the source these values come from.*Pass another source, whose different values should end the change/)
      expect { record.update_precedence_order(:name, [], expires_at: 1.week.from_now) }.to raise_error(ArgumentError, /update_precedence_order\(:name\) with no sources removes it, so there is nothing to expire/)
      expect { record.update_attribute_source_precedence(:name, cadastre, nil, expires_on: map_editor) }.to raise_error(ArgumentError, /with a nil precedence removes it/)
      expect { LaForge::PrecedenceRule.create!(record_type: 'ActiveRecordMock', attribute_name: 'name', source: cadastre, precedence: 1, expires_at: 1.week.from_now) }
        .to raise_error(ArgumentError, /Only a precedence rule on one record can expire, and this is a model-wide rule on ActiveRecordMock/)
      expect { LaForge::PrecedenceRule.global.find_by!(source: cadastre).update!(expires_on_source: map_editor) }.to raise_error(ArgumentError, /this is a global rule/)
    end
  end

  describe 'data sources' do
    it 'requires a unique precedence and a case-insensitively unique name' do
      expect(LaForge::DataSource.new(name: 'Other', precedence: business_directory.precedence)).not_to be_valid
      expect(LaForge::DataSource.new(name: 'business directory', precedence: 99)).not_to be_valid
      expect(LaForge::DataSource.new(name: 'Other')).not_to be_valid
    end

    it 'stores the global precedence as a precedence rule, unique among global rules in the database too' do
      expect(LaForge::PrecedenceRule.global.find_by!(source: cadastre).precedence).to eq(31)
      expect { LaForge::PrecedenceRule.create!(source: map_editor, record_type: 'ActiveRecordMock', precedence: 31) }.not_to raise_error
      expect { LaForge::DataSource.new(name: 'Duplicate', precedence: 31).save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(LaForge::DataSource.exists?(name: 'Duplicate')).to be(false)
    end

    it 'reorders sources by updating their precedence' do
      expect(LaForge::DataSource.maximum_precedence).to be >= 33

      [cadastre, business_directory, map_editor].each { |source| source.update!(precedence: source.precedence + 1000) }

      expect(LaForge::DataSource.where(id: [cadastre, business_directory, map_editor]).by_precedence.map(&:precedence)).to eq([1033, 1032, 1031])
    end

    it 'accepts a source as a record, an id or a name wherever one is expected' do
      [business_directory, business_directory.id, 'Business Directory'].each_with_index do |source, index|
        record.record_data_entries({ count: index }, source)
      end

      expect(record.data_entries.map(&:source_id)).to eq([business_directory.id])
      expect(record.data_entries.first.value).to eq(2)
    end
  end
end

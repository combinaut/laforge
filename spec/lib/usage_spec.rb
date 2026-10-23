require 'spec_helper'

# Common ways of using LaForge to merge several data sources into one record, one group per intention.
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

    it 'reports the winning value of every recorded attribute, so changes can be tracked before saving' do
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

    it 'updates the existing entry when the same source records the attribute again' do
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

    it 'keeps the custom precedence when the same source records the attribute again without one' do
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

    it 'can be set before the source has recorded the attribute, and applies once it does' do
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

  describe 'a source that stops reporting a record' do
    before do
      record.record_data_entries({ name: 'From Cadastre', count: 5 }, cadastre)
      record.record_data_entries({ name: 'From Business Directory', count: 7, active: false }, business_directory)
      record.forge!
    end

    it 'blanks the attributes the source was supplying by recording nil, even where a lower source has a value' do
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

    it 'ignores sources that only supply attribute values' do
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

  # A reference to another record (a foreign key) is recorded like any attribute, and which source wrote it tells an
  # importer-made link from one an editor set
  describe 'a link recorded as an attribute' do
    it 'tells whether the current value was written by an importer rather than an editor' do
      record.record_data_entries({ count: 42 }, cadastre)
      record.forge!

      importer_wrote_it = record.data_entries.with_attribute('count').where.not(source_id: map_editor.id).any? { |entry| entry.value.to_s == record.count.to_s }
      expect(importer_wrote_it).to be(true)
    end

    it 'moves the link by replacing every other source entry for it with one from the source taking ownership' do
      record.record_data_entries({ count: 1 }, cadastre)
      record.record_data_entries({ count: 2 }, map_editor)
      record.forge!

      LaForge::DataEntry.where(record: record, attribute_name: 'count').where.not(source_id: business_directory.id).delete_all
      record.reload.record_data_entry('count', 3, business_directory)
      record.update!(count: 3)
      record.reload.forge!

      expect(record.reload.count).to eq(3)
      expect(record.data_entries.map(&:source)).to eq([business_directory])
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

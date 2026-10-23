require 'spec_helper'

describe 'ActiveRecordExtensions' do
  context 'querying' do
    let(:record) { ActiveRecordMock.create(name: "Post") }
    let(:record2) { ActiveRecordMock.create(name: "News") }
    let(:data_source) { LaForge::DataSource.find_or_create_by!(name: "bbc") { |source| source.precedence = 1 } }
    let(:data_source2) { LaForge::DataSource.find_or_create_by!(name: "guardian") { |source| source.precedence = 2 } }

    before(:each) do
      LaForge::DataEntry.destroy_all
      LaForge::DataEntry.create(source: data_source, record: record, attribute_name: "name", value: "Article")
      LaForge::DataEntry.create(source: data_source2, record: record2, attribute_name: "active", value: true)
    end

    describe "::with_source" do
      it 'returns all records from a given source' do
        expect(ActiveRecordMock.with_source(data_source)).to eq([record])
      end
    end

    describe "::without_source" do
      it 'returns all records without a given source' do
        expect(ActiveRecordMock.without_source(data_source)).to eq([record2])
      end
    end

    describe "::with_attribute" do
      it 'returns all records with a recorded attribute when a string is passed' do
        expect(ActiveRecordMock.with_attribute('name')).to eq([record])
      end

      it 'returns all records with a recorded attribute when a symbol is passed' do
        expect(ActiveRecordMock.with_attribute(:name)).to eq([record])
      end

      it 'returns all records with any of recorded attribute when an array is passed' do
        expect(ActiveRecordMock.with_attribute([:name, :active])).to eq([record, record2])
      end
    end

    describe "::without_attribute" do
      it 'returns all records without a recorded attribute when a string is passed' do
        expect(ActiveRecordMock.without_attribute('name')).to eq([record2])
      end

      it 'returns all records without a recorded attribute when a symbol is passed' do
        expect(ActiveRecordMock.without_attribute(:name)).to eq([record2])
      end

      it 'returns all records without any of recorded attribute when an array is passed' do
        expect(ActiveRecordMock.without_attribute([:name, :intger])).to eq([record2])
      end

      it 'returns an empty array when there are no records without any of recorded attribute when an array is passed' do
        expect(ActiveRecordMock.without_attribute([:name, :active])).to eq([])
      end
    end

    describe "::with_attribute_with_source" do
      it 'returns all records from a given source with a recorded attribute' do
        expect(ActiveRecordMock.with_attribute_with_source('name', data_source)).to eq([record])
      end

      it 'does not return records from a given source but without the recorded attribute' do
        expect(ActiveRecordMock.with_attribute_with_source('active', data_source)).not_to include(record)
      end

      it 'does not return records from a different source but with the recorded attribute' do
        expect(ActiveRecordMock.with_attribute_with_source('name', data_source2)).not_to include(record)
      end
    end

    describe "::with_attribute_without_source" do
      it 'returns all records with recorded attribute not from the given source' do
        expect(ActiveRecordMock.with_attribute_without_source('active', data_source)).to eq([record2])
      end

      it 'returns all records of any recorded attributes not from the given source' do
        expect(ActiveRecordMock.with_attribute_without_source(['active', 'name'], data_source)).to eq([record2])
      end

      xit 'returns records with all recorded attributes from the given source when chained'
    end

    describe "::without_attribute_with_source" do
      it 'returns all records without recorded attribute from the given source' do
        expect(ActiveRecordMock.without_attribute_with_source('active', data_source)).to eq([record])
      end

      it 'returns all records without any recorded attributes from the given source' do
        expect(ActiveRecordMock.without_attribute_with_source(['active', 'integer'], data_source)).to eq([record])
      end

      it 'returns an empty array when there are no records without any recorded attributes from the given source' do
        expect(ActiveRecordMock.without_attribute_with_source(['active', 'name'], data_source)).to eq([])
      end

      xit 'returns records without any of the recorded attributes from the given source when chained'
    end
  end

  describe '#forge!' do
    let(:record) { ActiveRecordMock.create(name: "Post", active: true) }
    let(:data_source) { LaForge::DataSource.find_or_create_by!(name: "bbc") { |source| source.precedence = 1 } }
    let(:data_entry) { LaForge::DataEntry.new(record: record, source_id: data_source.id) }

    it 'changes the database record' do
      data_entry.update(attribute_name: "name", value: "Article")

      expect { record.forge! }.to change { record.name }.from("Post").to("Article")
    end

    it 'changes the database record when a block is passed that creates data entries' do
      expect { record.forge! { record.record_data_entries({name: "Article"}, data_source.name) }}.to change { record.reload.name }.from("Post").to("Article")
    end

    it 'keeps the attribute when a block is passed that removes the only data entry with that attribute' do
      data_entry.update(attribute_name: "name", value: "Article")
      record.update!(name: "Post")

      expect { record.forge! { record.remove_data_entries(sources: data_source.name) }}.not_to change { record.reload.name }
      expect(record.data_entries).to be_empty
    end

    it 'falls back to the next source when a block is passed that removes the winning data entry' do
      LaForge::DataEntry.create!(record: record, source_id: data_source.id, attribute_name: "name", value: "Article")
      higher = LaForge::DataSource.find_or_create_by!(name: "guardian") { |source| source.precedence = 2 }
      LaForge::DataEntry.create!(record: record, source_id: higher.id, attribute_name: "name", value: "Story")
      record.reload.forge!

      expect { record.forge! { record.remove_data_entries(sources: higher.name) }}.to change { record.reload.name }.from("Story").to("Article")
    end

    it 'blanks the attribute when a block is passed that records nil for it' do
      data_entry.update(attribute_name: "name", value: "Post")

      expect { record.forge! { record.record_data_entries({ name: nil }, data_source.name) }}.to change { record.reload.name }.from("Post").to(nil)
    end

    it 'does not change the attribute when the only data_entry with that attribute is destroyed outside of the block' do
      data_entry.update(attribute_name: "name", value: "Post")
      record.remove_data_entries(sources: data_source.name)

      expect { record.forge! }.not_to change { record.reload.name }
    end
  end

  describe '#forge' do
    let(:record) { ActiveRecordMock.create(name: "Post", active: true) }
    let(:data_source) { LaForge::DataSource.find_or_create_by!(name: "bbc") { |source| source.precedence = 1 } }
    let(:data_entry) { LaForge::DataEntry.new(record: record, source_id: data_source.id) }

    let(:preceding_data_source) { LaForge::DataSource.find_or_create_by!(name: "guardian") { |source| source.precedence = 2 } }
    let(:preceding_data_entry) { LaForge::DataEntry.new(record: record, source_id: preceding_data_source.id) }

    it 'ranks an entry whose source has no global precedence below every source that has one, a negative one included' do
      # Entries an upgrade kept from a source deleted before the precedence rules migration have no global rule
      negative_source = LaForge::DataSource.find_or_create_by!(name: "negative") { |source| source.precedence = -5 }
      LaForge::DataEntry.create!(record: record, source_id: negative_source.id, attribute_name: "name", value: "Ranked")
      LaForge::DataEntry.create!(record: record, source_id: data_source.id, attribute_name: "name", value: "Unranked")
      LaForge::PrecedenceRule.global.where(source_id: data_source.id).delete_all

      record.reload.forge

      expect(record.name).to eq("Ranked")
    ensure
      data_source.update!(precedence: 1) # other examples expect every source to have a global precedence
      LaForge::DataEntry.where(source_id: negative_source.id).delete_all
      negative_source.destroy! # and a precedence of their own choosing free
    end

    it 'sets the record attributes from the data entries' do
      data_entry.update(attribute_name: "name", value: "Article")
      expect { record.forge }.to change { record.name }.from("Post").to("Article")
    end

    it 'does not change the database record' do
      data_entry.update(attribute_name: "name", value: "Article")
      expect { record.forge }.not_to change { record.reload.name }
    end

    it 'ignores data_entries when the attribute_name does not have a setter' do
      data_entry.update(attribute_name: "name_invalid")
      expect { record.forge }.not_to change { record.changes }
    end

    it 'merges data_entries from multiple sources' do
      data_entry.update(attribute_name: "name", value: "Article")
      preceding_data_entry.update(attribute_name: "active", value: false)

      expect { record.forge }.to change { record.changes }.to eq({"name"=>["Post", "Article"], "active"=>[true, false]})
    end

    it "ranks values by the record's precedence for the attribute and source" do
      data_entry.update(attribute_name: "name", value: "Higher Precedence")
      preceding_data_entry.update(attribute_name: "name", value: "Lower Precedence")
      record.update_attribute_source_precedence(:name, data_source, 5)
      record.update_attribute_source_precedence(:name, preceding_data_source, 3)

      expect { record.forge }.to change { record.name }.from("Post").to("Higher Precedence")
    end

    it 'breaks a tie in effective precedence by the higher source precedence' do
      data_entry.update(attribute_name: "name", value: "From the lower source")
      preceding_data_entry.update(attribute_name: "name", value: "From the higher source")
      record.update_attribute_source_precedence(:name, data_source, 2)

      expect { record.forge }.to change { record.name }.from("Post").to("From the higher source")
    end

    it 'applies the most recently recorded entry when two entries from one source share an attribute' do
      LaForge::DataEntry.create!(record: record, source_id: data_source.id, attribute_name: "name", value: "Older")
      LaForge::DataEntry.create!(record: record, source_id: data_source.id, attribute_name: "name", value: "Newer")

      expect(record.reload.forge_attributes).to eq({ "name" => "Newer" })
    end

    it 'resolves the same winner whatever order the entries are loaded in' do
      data_entry.update(attribute_name: "name", value: "From the lower source")
      preceding_data_entry.update(attribute_name: "name", value: "From the higher source")
      record.update_attribute_source_precedence(:name, data_source, 2)
      entries = record.data_entries.to_a

      expect([entries, entries.reverse].map { |list| LaForge::DataEntry.in_precedence_order(list, record: record).first.value })
        .to eq(["From the higher source", "From the higher source"])
    end

    it "ranks values by the source's global precedence when the record has no precedence for the attribute" do
      data_entry.update(attribute_name: "name", value: "Lower Precedence")
      preceding_data_entry.update(attribute_name: "name", value: "Higher Precedence")

      expect { record.forge }.to change { record.name }.from("Post").to("Higher Precedence")
    end
  end

  describe '#forge_attributes' do
    let(:data_source) { LaForge::DataSource.find_or_create_by!(name: "bbc") { |source| source.precedence = 1 } }
    let(:record) { ActiveRecordMock.create(name: "Post", active: true) }
    let!(:data_entry) { LaForge::DataEntry.create!(record: record, attribute_name: "name", value: "Article", source_id: data_source.id) }

    it 'returns a hash of the attributes generated the data entries' do
      expect(record.forge_attributes).to eq({"name"=> 'Article'})
    end

    it 'excludes data_entries when the attribute_name does not have a setter' do
      data_entry.update_column(:attribute_name, "name_invalid")
      expect(record.forge_attributes).to eq({})
    end

    it 'applies the most recently built of two unsaved entries from one source, before and after saving' do
      record.data_entries.build(attribute_name: "count", value: 1, source_id: data_source.id)
      record.data_entries.build(attribute_name: "count", value: 2, source_id: data_source.id)
      before_save = record.forge_attributes["count"]
      record.save!

      expect([before_save, record.reload.forge_attributes["count"]]).to eq([2, 2])
    end

    it 'lists attributes in the order forge calls the setters when every entry shares a precedence' do
      record.record_data_entries({active: false}, data_source.name)
      record.record_data_entries({count: 3}, data_source.name)

      expect(record.forge_attributes.keys).to eq(%w[count active name])
    end

    it 'lists attributes highest precedence first, whichever entry wins each' do
      higher_source = LaForge::DataSource.find_or_create_by!(name: "guardian") { |source| source.precedence = 2 }
      record.record_data_entries({count: 3}, higher_source.name)

      expect(record.forge_attributes.keys.first).to eq("count")
    end
  end

  describe '#record_data_entries' do
    let(:data_source) { LaForge::DataSource.find_or_create_by!(name: "bbc") { |source| source.precedence = 1 } }
    let(:record) { ActiveRecordMock.create(name: "Post") }

    it 'builds a data_entry for an attribute passed' do
      expect { record.record_data_entries({name: "Article"}, data_source.name) }
        .to change { record.data_entries.size }
        .by(1)
    end

    it 'does not create a new data_entry until save is called' do
      expect { record.record_data_entries({name: "Article"}, data_source.name) }
        .not_to change { record.data_entries.count }
    end

    it 'raises an error when the record does not have a setter method for the attribute_name' do
      expect { record.record_data_entries({name2: "Article"}, data_source.name) }.to raise_exception(LaForge::InvalidAttributeName)
    end

    it 'sets the source_id when a source_name is passed in' do
      expect { record.record_data_entries({name: "Article"}, data_source.name) }
        .to change { record.data_entries.last&.source_id }
        .to(data_source.id)
    end

    it 'sets the source_id when a source_id is passed in' do
      expect { record.record_data_entries({name: "Article"}, data_source.id) }
        .to change { record.data_entries.last&.source_id }
        .to(data_source.id)
    end

    it 'sets the source_id when a source object is passed in' do
      expect { record.record_data_entries({name: "Article"}, data_source) }
        .to change { record.data_entries.last&.source_id }
        .to(data_source.id)
    end

    it 'raises an error when an invalid source name is passed in' do
      expect { record.record_data_entries({name: "Article"}, "#{data_source.name}_test") }.to raise_exception(LaForge::DataSource::Invalid)
    end

    it 'raises an error when an invalid source type is passed in' do
      expect { record.record_data_entries({name: "Article"}, {test: 'name'}) }.to raise_exception(LaForge::DataSource::Invalid)
    end

    it 'raises an error when an nil is passed in as the source type' do
      expect { record.record_data_entries({name: "Article"}, nil) }.to raise_exception(LaForge::DataSource::Invalid)
    end

    it 'sets the precedence for the attribute and source on the record when passed' do
      expect { record.record_data_entries({name: "Article"}, data_source.name, precedence: 20) }
        .to change { record.source_precedences }
        .to("name" => { data_source => 20 })
    end

    it 'can set an attribute to a string value' do
      expect { record.record_data_entries({name: "Article"}, data_source.name) }
        .to change { record.data_entries.last&.value }
        .to("Article")
    end

    it 'can set an attribute to an integer value' do
      expect { record.record_data_entries({count: 5}, data_source.name) }
        .to change { record.data_entries.last&.value }
        .to(5)
    end

    it 'can set an attribute to true' do
      expect { record.record_data_entries({active: true}, data_source.name) }
        .to change { record.data_entries.last&.value }
        .to(true)
    end

    it 'can set an attribute to false' do
      expect { record.record_data_entries({active: false}, data_source.name) }
        .to change { record.data_entries.last&.value }
        .to(false)
    end

    it 'keeps the precedence for the attribute and source when re-recorded without one' do
      record.record_data_entries({name: "Article"}, data_source.name, precedence: 20)
      record.record_data_entries({name: "Article 2"}, data_source.name)

      expect(record.data_entries.map(&:value)).to eq(["Article 2"])
      expect(record.source_precedences).to eq("name" => { data_source => 20 })
    end

    it 'removes the precedence for the attribute and source when re-recorded with a nil precedence' do
      record.record_data_entries({name: "Article"}, data_source.name, precedence: 20)
      record.record_data_entries({name: "Article 2"}, data_source.name, precedence: nil)

      expect(record.source_precedences).to be_empty
    end

    it 'updates a data_entry for the same attribute from the same source' do
      record.record_data_entries({name: "Article"}, data_source.name)
      expect { record.record_data_entries({name: "Article 2"}, data_source.name) }
      .not_to change { record.data_entries.pluck(:id) }
    end
  end

  describe '#data_sources' do
    let(:data_source) { LaForge::DataSource.find_or_create_by!(name: "bbc") { |source| source.precedence = 1 } }
    let(:data_source2) { LaForge::DataSource.find_or_create_by!(name: "guardian") { |source| source.precedence = 2 } }
    let(:record) { ActiveRecordMock.create(name: "Post") }

    before do
      record.record_data_entries({name: "Article", active: true}, data_source.name)
      record.record_data_entries({count: 5}, data_source2.name)
      record.save!
    end

    it 'returns each source that supplied a data_entry, once' do
      expect(record.reload.data_sources).to contain_exactly(data_source, data_source2)
    end

    it 'can be preloaded' do
      expect(ActiveRecordMock.preload(:data_sources).find(record.id).data_sources).to contain_exactly(data_source, data_source2)
    end

    it 'can be joined in a query' do
      other_record = ActiveRecordMock.create!(name: "Other")
      other_record.record_data_entries({name: "Other"}, data_source.name)
      other_record.save!

      expect(ActiveRecordMock.where(id: [record.id, other_record.id]).joins(:data_sources).where(laforge_data_sources: { name: "guardian" }))
        .to eq([record])
    end
  end

  describe '#data_source?' do
    let(:data_source) { LaForge::DataSource.find_or_create_by!(name: "bbc") { |source| source.precedence = 1 } }
    let(:record) { ActiveRecordMock.create(name: "Post") }

    it 'returns true when the record has a data_entry from the source' do
      record.record_data_entries({name: "Article"}, data_source.name)
      expect(record.data_source?(data_source.name)).to be true
    end

    it 'returns false when the record does not have a data_entry from the source' do
      expect(record.data_source?(data_source.name)).to be false
    end
  end

  describe '#data_source_names' do
    let(:data_source) { LaForge::DataSource.find_or_create_by!(name: "bbc") { |source| source.precedence = 1 } }
    let(:data_source2) { LaForge::DataSource.find_or_create_by!(name: "guardian") { |source| source.precedence = 2 } }
    let(:record) { ActiveRecordMock.create(name: "Post") }

    it 'returns a list of sources for the data_entries' do
      record.record_data_entries({name: "Article"}, data_source.name)
      record.record_data_entries({active: true}, data_source2.name)

      expect(record.data_source_names).to eq([data_source.name, data_source2.name])
    end

    it 'returns a list of sources for the data_entries when an attribute is passed' do
      record.record_data_entries({name: "Article"}, data_source.name)
      record.record_data_entries({active: true}, data_source2.name)

      expect(record.data_source_names(attributes: :name)).to eq([data_source.name])
    end
  end
end

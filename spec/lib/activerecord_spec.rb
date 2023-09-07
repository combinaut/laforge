require 'spec_helper'

describe 'ActiveRecordExtensions' do
  context 'querying' do
    let(:record) { ActiveRecordMock.create(name: "Post") }
    let(:record2) { ActiveRecordMock.create(name: "News") }
    let(:data_source) { LaForge::DataSource.find_or_create_by(name: "bbc", priority: 1) }
    let(:data_source2) { LaForge::DataSource.find_or_create_by(name: "gaurdian", priority: 2) }

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
    let(:data_source) { LaForge::DataSource.find_or_create_by(name: "bbc", priority: 1) }
    let(:data_entry) { LaForge::DataEntry.new(record: record, source_id: data_source.id) }

    it 'changes the database record' do
      data_entry.update_attributes(attribute_name: "name", value: "Article")

      expect { record.forge! }.to change { record.name }.from("Post").to("Article")
    end

    it 'changes the database record when a block is passed that creates data entries' do
      expect { record.forge! { record.record_data_entries({name: "Article"}, data_source.name) }}.to change { record.reload.name }.from("Post").to("Article")
    end

    it 'nils out the attribute when a block is passed that destroys the only data entry with that attribute' do
      data_entry.update_attributes(attribute_name: "name", value: "Post")

      expect { record.forge! { record.remove_data_entries(sources: data_source.name) }}.to change { record.reload.name }.from("Post").to(nil)
    end

    it 'does not change the attribute when the only data_entry with that attribute is destroyed outside of the block' do
      data_entry.update_attributes(attribute_name: "name", value: "Post")
      record.remove_data_entries(sources: data_source.name)

      expect { record.forge! }.not_to change { record.reload.name }
    end
  end

  describe '#forge' do
    let(:record) { ActiveRecordMock.create(name: "Post", active: true) }
    let(:data_source) { LaForge::DataSource.find_or_create_by(name: "bbc", priority: 1) }
    let(:data_entry) { LaForge::DataEntry.new(record: record, source_id: data_source.id) }

    let(:prioritized_data_source) { LaForge::DataSource.find_or_create_by(name: "gaurdian", priority: 2) }
    let(:prioritized_data_entry) { LaForge::DataEntry.new(record: record, source_id: prioritized_data_source.id) }

    it 'sets the record attributes from the data entries' do
      data_entry.update_attributes(attribute_name: "name", value: "Article")
      expect { record.forge }.to change { record.name }.from("Post").to("Article")
    end

    it 'does not change the database record' do
      data_entry.update_attributes(attribute_name: "name", value: "Article")
      expect { record.forge }.not_to change { record.reload.name }
    end

    it 'ignores data_entries with an invalid attribute name' do
      data_entry.update_attributes(attribute_name: "name_invalid")
      expect { record.forge }.not_to change { record.changes }
    end

    it 'merges data_entries from multiple sources' do
      data_entry.update_attributes(attribute_name: "name", value: "Article")
      prioritized_data_entry.update_attributes(attribute_name: "active", value: false)

      expect { record.forge }.to change { record.changes }.to eq({"name"=>["Post", "Article"], "active"=>[true, false]})
    end

    it 'prioritizes based on the data_entry priority' do
      data_entry.update_attributes(attribute_name: "name", value: "Higher Priority", priority: 5)
      prioritized_data_entry.update_attributes(attribute_name: "name", value: "Lower Priority", priority: 3)

      expect { record.forge }.to change { record.name }.from("Post").to("Higher Priority")
    end

    it 'prioritizes based on the data_source priority when priority is not set on the data_entry' do
      data_entry.update_attributes(attribute_name: "name", value: "Lower Prioirty")
      prioritized_data_entry.update_attributes(attribute_name: "name", value: "Higher Priority")

      expect { record.forge }.to change { record.name }.from("Post").to("Higher Priority")
    end
  end

  describe '#forge_attributes' do
    let(:data_source) { LaForge::DataSource.find_or_create_by(name: "bbc", priority: 1) }
    let(:record) { ActiveRecordMock.create(name: "Post", active: true) }
    let!(:data_entry) { LaForge::DataEntry.create!(record: record, attribute_name: "name", value: "Article", source_id: data_source.id) }

    it 'returns a hash of the attributes generated the data entries' do
      expect(record.forge_attributes).to eq({"name"=> 'Article'})
    end

    it 'removes data_entries for invalid columns' do
      data_entry.update_column(:attribute_name, "name_invalid")
      expect(record.forge_attributes).to eq({})
    end
  end

  describe '#record_data_entries' do
    let(:data_source) { LaForge::DataSource.find_or_create_by(name: "bbc", priority: 1) }
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

    it 'sets the priority when passed' do
      expect { record.record_data_entries({name: "Article"}, data_source.name, priority: 20) }
        .to change { record.data_entries.last&.priority }
        .to(20)
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

    it 'updates a data_entry for the same attribute from the same source' do

      record.record_data_entries({name: "Article"}, data_source.name)
      expect { record.record_data_entries({name: "Article 2"}, data_source.name) }
      .not_to change { record.data_entries.pluck(:id) }
    end
  end
end

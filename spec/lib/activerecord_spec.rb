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


  describe '#record_data_entries' do
    let(:data_source) { LaForge::DataSource.find_or_create_by(name: "bbc", priority: 1) }
    let(:record) { ActiveRecordMock.create(name: "Post") }

    it 'creates a data_entry for an attribute passed' do
      expect { record.record_data_entries({name: "Article"}, data_source.name) }
        .to change { record.data_entries.count }
        .by(1)
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

    it 'destroys data_entries from the same source' do
      record.record_data_entries({name: "Article"}, data_source.name)
      expect { record.record_data_entries({name: "Article 2"}, data_source.name) }
        .not_to change { record.data_entries.count }
    end

    it 'does not destroy data_entries from the same source when the replace is false' do
      record.record_data_entries({name: "Article"}, data_source.name)
      expect { record.record_data_entries({name: "Article 2"}, data_source.name, replace: false) }
        .to change { record.data_entries.count }
        .from(1).to(2)
    end
  end

  describe '#forge' do
    let(:data_source) { LaForge::DataSource.find_or_create_by(name: "bbc", priority: 1) }
    let(:prioritized_data_source) { LaForge::DataSource.find_or_create_by(name: "gaurdian", priority: 2) }
    let(:record) { ActiveRecordMock.create(name: "Post", active: true) }

    it 'sets the record attributes from the data entries' do
      record.record_data_entries({name: "Article"}, data_source.name)
      expect { record.forge }.to change { record.name }.from("Post").to("Article")
    end

    it 'does not change the database record' do
      record.record_data_entries({name: "Article"}, data_source.name)
      expect { record.forge }.not_to change { record.reload.name }
    end

    it 'merges data_entries from multiple sources' do
      record.record_data_entries({name: "Article"}, data_source.name)
      record.record_data_entries({active: false}, prioritized_data_source.name)

      expect { record.forge }.to change { record.changes }.to eq({"name"=>["Post", "Article"], "active"=>[true, false]})
    end

    it 'prioritizes based on the data_entry priority' do
      record.record_data_entries({name: "#{prioritized_data_source} Article"}, prioritized_data_source.name, priority: 3)
      record.record_data_entries({name: "#{data_source.name} Article"}, data_source.name, priority: 5)

      expect { record.forge }.to change { record.name }.from("Post").to("#{data_source.name} Article")
    end

    it 'prioritizes based on the data_source priority when priority is not set on the data_entry' do
      record.record_data_entries({name: "#{prioritized_data_source} Article"}, prioritized_data_source.name)
      record.record_data_entries({name: "#{data_source.name} Article"}, data_source.name)

      expect { record.forge }.to change { record.name }.from("Post").to("#{prioritized_data_source} Article")
    end
  end

  describe '#forge!' do
    it 'generates the record from the data entries' do

    end
  end
end

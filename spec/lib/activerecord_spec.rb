require 'spec_helper'

describe 'ActiveRecordExtensions' do
  describe '#record_data_entries' do
    let(:data_source) { LaForge::DataSource.find_or_create_by(name: "bbc", priority: 1) }
    let(:record) { ActiveRecordMock.create(name: "Post") }

    it 'creates a data_entry for an attribute passed' do
      expect { record.record_data_entries({name: "Article"}, data_source.name) }.to change { record.data_entries.count }.by(1)
    end

    it 'sets the source_id' do
      expect { record.record_data_entries({name: "Article"}, data_source.name) }.to change { record.data_entries.last&.source_id }.to(data_source.id)
    end

    it 'sets the priority when passed' do
      expect { record.record_data_entries({name: "Article"}, data_source.name, priority: 20) }.to change { record.data_entries.last&.priority }.to(20)
    end

    it 'destroys data_entries from the same source' do
      record.record_data_entries({name: "Article"}, data_source.name)
      expect { record.record_data_entries({name: "Article 2"}, data_source.name) }.not_to change { record.data_entries.count }
    end

    it 'does not destroy data_entries from the same source when the replace is false' do
      record.record_data_entries({name: "Article"}, data_source.name)
      expect { record.record_data_entries({name: "Article 2"}, data_source.name, replace: false) }.to change { record.data_entries.count }.from(1).to(2)
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

      expect { record.forge }.to change { record.changed_attributes.keys }.to eq(["name", "active"])
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

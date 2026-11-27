require 'spec_helper'

describe LaForge::DataSource do
  describe '::normalize_source_id' do
    let!(:data_source) { described_class.find_or_create_by!(key: "channel_2") { |source| source.precedence = 7 } }

    it 'resolves a key containing a digit by key' do
      expect(described_class.normalize_source_id("channel_2")).to eq(data_source.id)
    end

    it 'resolves an all-digit string as an id' do
      expect(described_class.normalize_source_id(data_source.id.to_s)).to eq(data_source.id)
    end

    it 'resolves an integer as an id' do
      expect(described_class.normalize_source_id(data_source.id)).to eq(data_source.id)
    end

    it 'resolves a DataSource to its id' do
      expect(described_class.normalize_source_id(data_source)).to eq(data_source.id)
    end

    it 'raises for a key with no matching source, naming the key' do
      expect { described_class.normalize_source_id("channel_3") }
        .to raise_exception(described_class::Invalid, /Could not find a DataSource with the key "channel_3"\. Create it with LaForge::DataSource\.create!\(key: "channel_3"/)
    end

    it 'resolves a Symbol as its String' do
      expect(described_class.normalize_source_id(:channel_2)).to eq(data_source.id)
      expect(described_class.normalize_source_id(data_source.id.to_s.to_sym)).to eq(data_source.id)
      expect { described_class.normalize_source_id(:channel_3) }.to raise_exception(described_class::Invalid, /the key "channel_3"/)
    end

    it 'raises for a value that is not a source, its id or its key' do
      expect { described_class.normalize_source_id(1.5) }.to raise_exception(described_class::Invalid, /Could not find a DataSource from 1\.5, a Float\. Pass a DataSource, its id, or its key/)
    end
  end

  describe 'without the key column' do
    let(:connection) { ActiveRecord::Base.connection }

    around do |example|
      connection.rename_column(:laforge_data_sources, :key, :name)
      described_class.reset_column_information
      example.run
    ensure
      connection.rename_column(:laforge_data_sources, :name, :key)
      described_class.reset_column_information
    end

    it 'raises on a lookup by key, naming the generator that renames name to key' do
      expect { described_class.normalize_source_id('cadastre') }
        .to raise_exception(ActiveRecord::MigrationError, /laforge_data_sources has no key column\. Run `rails generate laforge:source_key` and `rails db:migrate`, which rename its name column to key/)
    end
  end
end

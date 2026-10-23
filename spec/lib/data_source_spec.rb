require 'spec_helper'

describe LaForge::DataSource do
  describe '::normalize_source_id' do
    let!(:data_source) { described_class.find_or_create_by!(name: "Channel 2") { |source| source.precedence = 7 } }

    it 'resolves a name containing a digit by name' do
      expect(described_class.normalize_source_id("Channel 2")).to eq(data_source.id)
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

    it 'raises for a name with no matching source' do
      expect { described_class.normalize_source_id("Channel 3") }.to raise_exception(described_class::Invalid)
    end
  end
end

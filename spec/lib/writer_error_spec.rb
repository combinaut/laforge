require 'spec_helper'

# What a forge does when a writer of the record raises for the value it is assigned
describe 'Writers that raise during a forge' do
  before do
    LaForge::DataEntry.delete_all
    LaForge::PrecedenceRule.where.not(record_type: LaForge::PrecedenceRule::ANY_TYPE).delete_all
    LaForge::DataSource.where(name: ['Cadastre', 'Business Directory']).delete_all
  end

  let!(:cadastre) { LaForge::DataSource.create!(name: 'Cadastre', precedence: 31) }
  let!(:business_directory) { LaForge::DataSource.create!(name: 'Business Directory', precedence: 32) }

  # A model whose writers refuse a blank name and a negative count
  let(:model) do
    Class.new(ActiveRecordMock) do
      def self.name = 'ActiveRecordMock'

      def name=(value)
        raise ArgumentError, 'name must not be blank' if value.blank?

        super
      end

      def count=(value)
        raise ArgumentError, 'count must not be negative' if value.to_i.negative?

        super
      end
    end
  end

  let(:record) { model.create!(name: 'Original', active: true, count: 1) }

  def raised
    yield
    nil
  rescue LaForge::WriterError => error
    error
  end

  it 'raises one error naming the writer, the value, its source and what the writer raised, after assigning the other attributes' do
    record.record_data_entries({ name: 'Harbor Building', count: -1, active: false }, cadastre)

    error = raised { record.forge }

    expect(error.message).to eq(
      'A writer of ActiveRecordMock ' + record.id.to_s + ' raised while a forge assigned the forged values: ' \
      'ActiveRecordMock#count= given -1 from Cadastre raised ArgumentError (count must not be negative). ' \
      'Record a value the writer takes, or rescue LaForge::WriterError and read its errors'
    )
    expect(error.record).to be(record)
    expect(error.errors.keys).to eq(['count'])
    expect(error.errors['count']).to be_a(ArgumentError).and have_attributes(message: 'count must not be negative')
    expect(error.values).to eq('count' => -1)
    expect(error.sources).to eq('count' => cadastre)
    expect(record.attributes).to include('name' => 'Harbor Building', 'active' => false, 'count' => 1)
  end

  it 'names every writer that raised, each with the source its value came from' do
    record.record_data_entries({ count: -1, active: false }, cadastre)
    record.record_data_entries({ name: '' }, business_directory)

    error = raised { record.forge }

    expect(error.message).to start_with("2 writers of ActiveRecordMock #{record.id} raised while a forge assigned the forged values: ")
    expect(error.message).to include('ActiveRecordMock#name= given "" from Business Directory raised ArgumentError (name must not be blank)')
    expect(error.message).to include('ActiveRecordMock#count= given -1 from Cadastre raised ArgumentError (count must not be negative)')
    expect(error.errors.keys).to eq(%w[name count]) # in the order the forge assigned them
    expect(error.sources).to eq('name' => business_directory, 'count' => cadastre)
    expect(record.attributes).to include('name' => 'Original', 'active' => false, 'count' => 1)
  end

  it 'saves nothing when `forge!` raises it' do
    error = raised { record.forge! { record.record_data_entries({ name: 'Harbor Building', count: -1 }, cadastre) } }

    expect(error.errors.keys).to eq(['count'])
    expect(model.find(record.id).attributes).to include('name' => 'Original', 'count' => 1)
    expect(LaForge::DataEntry.count).to eq(0)
  end

  it 'names the field for an importer, where a writer such as an enum raises for a value outside it' do
    stub_const('Landmark', Class.new(ActiveRecordMock))
    Landmark.enum :name, { lighthouse: 'lighthouse', pier: 'pier' }
    landmark = Landmark.create!(name: 'lighthouse')
    landmark.record_data_entries({ name: 'windmill', count: 4 }, cadastre)

    expect { landmark.forge! }.to raise_error(LaForge::WriterError, /Landmark#name= given "windmill" from Cadastre raised ArgumentError \('windmill' is not a valid name\)/)
    expect(landmark.reload.count).to be_nil
  end

  it 'raises the same error from `forge_diff(through_setters: true)`, and leaves the record as it was' do
    record.record_data_entries({ count: -1, active: false }, cadastre)
    record.record_data_entries({ name: '' }, business_directory)

    error = raised { record.forge_diff(through_setters: true) }

    expect(error.message).to start_with("2 writers of ActiveRecordMock #{record.id} raised while a forge assigned the forged values: ")
    expect(error.errors.transform_values(&:message)).to eq('name' => 'name must not be blank', 'count' => 'count must not be negative')
    expect(error.record).to be(record)
    expect(record.attributes).to include('name' => 'Original', 'active' => true, 'count' => 1)
    expect(record).not_to be_changed
    expect(ActiveRecord::Base.connection.open_transactions).to eq(0)
    expect(record.forge_diff).to eq('name' => ['Original', ''], 'count' => [1, -1], 'active' => [true, false]) # the raw comparison assigns nothing
  end

  it 'names the source that decided the group for an attribute that source leaves out' do
    grouped = Class.new(model) { laforged attribute_groups: { occupancy: %i[name count] } }
    listed = grouped.create!(name: 'Original', count: 1)
    listed.record_data_entries({ name: nil, count: 3 }, cadastre)

    error = raised { listed.forge }

    expect([error.values, error.sources]).to eq([{ 'name' => nil }, { 'name' => cadastre }])
    expect(listed.count).to eq(3)
  end

  it 'lets through what is not a StandardError, and an error raised outside a writer' do
    interrupting = Class.new(model) do
      def active=(_value)
        raise NotImplementedError, 'no writer yet'
      end
    end
    listed = interrupting.create!(name: 'Original', count: 1)
    listed.record_data_entries({ active: false, count: -1 }, cadastre)

    expect { listed.forge }.to raise_error(NotImplementedError, 'no writer yet')
    expect { record.record_data_entries({ missing: 1 }, cadastre) }.to raise_error(LaForge::InvalidAttributeName)
  end
end

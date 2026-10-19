require 'spec_helper'

# Association assignment as importers drive it, run end to end across several import runs.
#
# Every run records everything the source currently says about a record, including whole association lists, then
# forges. A tenant's attributes, reported in the place's list, are recorded on the tenant itself. An orphan sweep destroys a source's entries for records it no longer reports, without forging, and closes a
# record only when no other source still has entries on it. Map editor edits are recorded on the highest-precedence source.
#
# Sources, lowest to highest: cadastre, business directory, business registry, map editor.
#
# Uses the association API from association_capabilities_spec.rb.
describe 'Association assignment by importers' do
  before do
    AssociationCapabilities.setup!
    AssociationCapabilities.reset!
    LaForge::DataSource.where(name: ['cadastre', 'business directory', 'business registry', 'map editor']).delete_all
  end

  let!(:cadastre) { LaForge::DataSource.create!(name: 'cadastre', precedence: 21) }
  let!(:business_directory) { LaForge::DataSource.create!(name: 'business directory', precedence: 22) }
  let!(:business_registry) { LaForge::DataSource.create!(name: 'business registry', precedence: 23) }
  let!(:map_editor) { LaForge::DataSource.create!(name: 'map editor', precedence: 24) }

  let(:place) { Place.create!(name: 'Harbor Building') }

  let(:cafe) { Category.create!(name: 'Café') }
  let(:bakery) { Category.create!(name: 'Bakery') }
  let(:bookstore) { Category.create!(name: 'Bookstore') }
  let(:florist) { Category.create!(name: 'Florist') }

  let(:lot_12) { Parcel.create!(name: 'Lot 12') }
  let(:lot_14) { Parcel.create!(name: 'Lot 14') }
  let(:occupies) { ParcelLinkType.create!(key: 'occupies') }
  let(:leases) { ParcelLinkType.create!(key: 'leases') }
  let(:computed) { ParcelLinkType.create!(key: 'computed') }

  # One importer run for one record: record everything the source says, then forge and save
  def import(record, source, **data)
    record.record_data_entries(data, source)
    record.forge!
    record
  end

  # An orphan sweep: withdraw the source without forging; close the record only when no other source has entries on it or
  # reports it in a list
  def sweep(record, source)
    record.withdraw_source(source)
    record.update!(status: 'closed') if record.has_attribute?(:status) && (record.data_source_names - [source.name]).empty?
  end

  def categories(*list) = list.map { |category| { category_id: category.id } }
  def categories_of(record) = record.reload.place_categories.map(&:category)
  def parcel_link(parcel, type, **fields) = { parcel_id: parcel.id, parcel_link_type_id: type.id, **fields }
  def parcel_links_of(record) = record.reload.parcel_links.order(:id).map { |row| [row.parcel, row.parcel_link_type, row.active, row.external_id] }
  # The importer finds a tenant it reported before by its own identifier and names it by id; otherwise it is new
  def tenant(external_id, **fields)
    existing = Tenant.find_by(external_id: external_id)
    { **(existing ? { id: existing.id } : {}), external_id: external_id, name: "Tenant #{external_id}", **fields }
  end
  def tenants_of(record) = record.reload.tenants.order(:external_id).pluck(:external_id, :name, :unit)

  describe 'a single importer reporting a category list each run' do
    it 'adds, removes, re-adds and reorders categories as the list changes from run to run' do
      import(place, cadastre, place_categories: categories(cafe, bakery))
      expect(categories_of(place)).to eq([cafe, bakery])

      import(place.reload, cadastre, place_categories: categories(cafe))
      expect(categories_of(place)).to eq([cafe])

      import(place.reload, cadastre, place_categories: categories(bakery, cafe, bookstore))
      expect(categories_of(place)).to eq([bakery, cafe, bookstore])
      expect(place.place_categories.map(&:position)).to eq([0, 1, 2])
      expect(PlaceCategory.count).to eq(3)
    end

    it 'keeps the existing join row for a category that stays in the list' do
      import(place, cadastre, place_categories: categories(cafe, bakery))
      cafe_row = place.place_categories.find_by!(category: cafe)

      import(place.reload, cadastre, place_categories: categories(bookstore, cafe))

      expect(place.reload.place_categories.find_by!(category: cafe).id).to eq(cafe_row.id)
    end

    it 'clears every category when the source reports none' do
      import(place, cadastre, place_categories: categories(cafe, bakery))
      import(place.reload, cadastre, place_categories: [])

      expect(categories_of(place)).to be_empty
      expect(PlaceCategory.count).to eq(0)
    end
  end

  describe 'two importers reporting categories for the same place' do
    before do
      import(place, cadastre, place_categories: categories(cafe, bakery, bookstore))
      import(place.reload, business_directory, place_categories: categories(cafe, florist))
    end

    it "uses the higher-precedence importer's list, whichever runs last" do
      import(place.reload, cadastre, place_categories: categories(cafe, bakery, bookstore))

      expect(categories_of(place)).to eq([cafe, florist])
    end

    it "falls back to the lower importer's list on the next forge after the higher one stops reporting the place" do
      sweep(place.reload, business_directory)
      expect(categories_of(place)).to eq([cafe, florist]) # the sweep does not forge

      import(place.reload, cadastre, place_categories: categories(cafe, bakery, bookstore))
      expect(categories_of(place)).to eq([cafe, bakery, bookstore])
    end

    it "still records the lower importer's changes while its list is outranked" do
      import(place.reload, cadastre, place_categories: categories(bakery))
      expect(categories_of(place)).to eq([cafe, florist])

      sweep(place.reload, business_directory)
      place.reload.forge!
      expect(categories_of(place)).to eq([bakery])
    end
  end

  describe 'a map editor overriding an imported category list' do
    before do
      import(place, cadastre, place_categories: categories(cafe, bakery))
      import(place.reload, map_editor, place_categories: categories(cafe, bookstore))
    end

    it "keeps the map editor's list through later imports, while still recording what the importer says" do
      import(place.reload, cadastre, place_categories: categories(cafe, bakery, florist))

      expect(categories_of(place)).to eq([cafe, bookstore])
      expect(place.source_values(:place_categories)[cadastre].map { |member| member['category_id'] }).to eq([cafe.id, bakery.id, florist.id])
    end

    it "reverts to the importer's latest list when the map editor's override is removed" do
      import(place.reload, cadastre, place_categories: categories(cafe, bakery, florist))

      place.withdraw_source(map_editor)
      place.forge!(attributes: :place_categories)

      expect(categories_of(place)).to eq([cafe, bakery, florist])
    end

    it 'lets an importer outrank the map editor for one place with a per-record precedence' do
      import(place.reload, cadastre, place_categories: categories(cafe, bakery))
      place.update_attribute_source_precedence(:place_categories, cadastre, 100)
      place.reload.forge!

      expect(categories_of(place)).to eq([cafe, bakery])
    end
  end

  describe 'a parcel links importer' do
    let!(:computed_row) { place.parcel_links.create!(parcel: lot_14, parcel_link_type: computed) }

    it 'adds, updates in place and removes parcel links without touching computed ones' do
      import(place.reload, cadastre, reported_parcel_links: [parcel_link(lot_12, occupies, external_id: 'E-1'), parcel_link(lot_14, leases)])
      occupies_row = place.parcel_links.find_by!(parcel: lot_12, parcel_link_type: occupies)

      import(place.reload, cadastre, reported_parcel_links: [parcel_link(lot_12, occupies, external_id: 'E-2', active: false)])

      expect(parcel_links_of(place)).to eq([[lot_14, computed, true, nil], [lot_12, occupies, false, 'E-2']])
      expect(place.parcel_links.find_by!(parcel: lot_12, parcel_link_type: occupies).id).to eq(occupies_row.id)
      expect(computed_row.reload).to be_persisted
    end

    it 'replaces the row when only the link type changes, since the type is part of the identity' do
      import(place.reload, cadastre, reported_parcel_links: [parcel_link(lot_12, occupies, external_id: 'E-1')])
      import(place.reload, cadastre, reported_parcel_links: [parcel_link(lot_12, leases, external_id: 'E-1')])

      expect(parcel_links_of(place)).to eq([[lot_14, computed, true, nil], [lot_12, leases, true, 'E-1']])
    end

    it "keeps a map editor's attribute on a parcel link the importer keeps reporting" do
      import(place.reload, cadastre, reported_parcel_links: [parcel_link(lot_12, occupies, active: true)])
      import(place.reload, map_editor, reported_parcel_links: [parcel_link(lot_12, occupies, active: false)])
      import(place.reload, cadastre, reported_parcel_links: [parcel_link(lot_12, occupies, active: true, external_id: 'E-3')])

      expect(parcel_links_of(place).last).to eq([lot_12, occupies, false, 'E-3'])
    end
  end

  describe 'tenants listed by a business directory and enriched by a business registry' do
    # The business registry records on the tenant itself, and is authoritative for its registration number regardless
    # of source precedence
    def register(tenant, registration_number, **fields)
      tenant.record_data_entries({ registration_number: registration_number }, business_registry, precedence: 100)
      tenant.record_data_entries(fields, business_registry) if fields.any?
      tenant.forge!
    end

    before do
      import(place, business_directory, tenants: [tenant('T-1', unit: '1A'), tenant('T-2', unit: '1A')])
    end

    let(:t1) { place.tenants.find_by!(external_id: 'T-1') }

    it "keeps the business registry's attributes on a tenant through later business directory imports" do
      register(t1, 'R-10', name: 'Harbor Café')

      import(place.reload, business_directory, tenants: [tenant('T-1', unit: '2B'), tenant('T-2', unit: '1A')])

      expect(t1.reload).to have_attributes(registration_number: 'R-10', name: 'Harbor Café', unit: '2B')
    end

    it "clears the registration number and restores the importer's unit once the business registry stops reporting the business" do
      register(t1, 'R-10', unit: '3C')

      # Blank what the business registry supplied, then keep the tenant only if another source still reports it
      t1.reload.forge! { t1.remove_data_entries(attribute_names: %i[registration_number unit], sources: business_registry) }
      expect(t1.reload).to have_attributes(registration_number: nil, unit: nil)
      expect(t1.data_source_names).to include(business_directory.name)

      import(place.reload, business_directory, tenants: [tenant('T-1', unit: '1A'), tenant('T-2', unit: '1A')])
      expect(t1.reload).to have_attributes(registration_number: nil, unit: '1A')
    end

    it 'keeps a tenant the business directory still lists when the business registry sweeps it' do
      register(t1, 'R-10')
      sweep(t1.reload, business_registry)

      expect(t1.reload.status).to eq('open')
    end

    it 'removes a tenant, including the registration number the business registry recorded on it, when the business directory drops it' do
      register(t1, 'R-10')

      import(place.reload, business_directory, tenants: [tenant('T-2', unit: '1A')])

      expect(tenants_of(place)).to eq([['T-2', 'Tenant T-2', '1A']])
      expect(LaForge::DataEntry.where(record_type: 'Tenant', record_id: t1.id)).to be_empty # noted: deleted with the tenant (dependent: :destroy)
    end

    it 'does not bring back a closed tenant when the business registry or the importer re-forges it' do
      t1.update!(status: 'closed')
      register(t1.reload, 'R-10')
      import(place.reload, business_directory, tenants: [tenant('T-1', unit: '1A'), tenant('T-2', unit: '1A')])

      expect(t1.reload.status).to eq('closed')
    end

    it 'adds new tenants and nested opening hours, and drops opening hours the importer stops sending' do
      week = (1..5).map { |day| { day: day, opens_at: '08:00' } }
      import(place.reload, business_directory, tenants: [tenant('T-1', opening_hours: week), tenant('T-3', opening_hours: week.first(1))])
      expect(tenants_of(place).map(&:first)).to eq(%w[T-1 T-3])

      import(place.reload, business_directory, tenants: [tenant('T-1', opening_hours: week.first(2)), tenant('T-3', opening_hours: week.first(1))])

      expect(place.reload.tenants.find_by!(external_id: 'T-1').opening_hours.pluck(:day)).to eq([1, 2])
    end
  end

  describe 'a nightly import that names the tenants it created before by id' do
    it 'keeps the same tenants, and what other sources recorded on them, from night to night' do
      import(place, business_directory, tenants: [tenant('T-1', unit: '1A'), tenant('T-2', unit: '2A')])
      corner_cafe, harbor_books = %w[T-1 T-2].map { |external_id| Tenant.find_by!(external_id: external_id) }
      corner_cafe.forge! { corner_cafe.record_data_entries({ unit: '1B' }, map_editor) }

      import(place.reload, business_directory, tenants: [tenant('T-1', unit: '1A'), tenant('T-2', unit: '2C')])

      expect(place.reload.tenants.pluck(:id)).to contain_exactly(corner_cafe.id, harbor_books.id)
      expect(corner_cafe.reload.unit).to eq('1B') # the map editor's correction survives
      expect(harbor_books.reload.unit).to eq('2C') # the new night's attributes are recorded
    end

    it 'creates a new tenant once when two nights are recorded before a forge' do
      2.times { place.reload.record_data_entries({ tenants: [tenant('T-1')] }, business_directory).then { place.save! } }
      place.reload.forge!

      expect(tenants_of(place)).to eq([['T-1', 'Tenant T-1', nil]])
    end
  end

  describe 'a map editor removing one imported tenant' do
    before do
      import(place, business_directory, tenants: [tenant('T-1'), tenant('T-2')])
      place.reload.record_data_entries({ tenants: { exclude: [{ id: Tenant.find_by!(external_id: 'T-2').id }] } }, map_editor, mode: :edit)
      place.forge!
    end

    it 'destroys the tenant and keeps it out of later imports that report it again as new, while new tenants still arrive' do
      expect(tenants_of(place).map(&:first)).to eq(%w[T-1]) # noted: destroyed per `dependent: :destroy`
      expect(place.reload.data_entries.tombstones(:tenants).map { |tombstone| [tombstone.source, tombstone.attributes['name']] }).to eq([[map_editor, 'Tenant T-2']])

      2.times { import(place.reload, business_directory, tenants: [tenant('T-1'), tenant('T-2'), tenant('T-3')]) }

      expect(tenants_of(place).map(&:first)).to eq(%w[T-1 T-3])
    end

    it "brings the tenant back on the importer's next run once the editor forgets the removal" do
      place.reload.record_data_entries({ tenants: { forget: [place.data_entries.tombstones(:tenants).sole] } }, map_editor, mode: :edit)
      place.save!

      import(place.reload, business_directory, tenants: [tenant('T-1'), tenant('T-2')])

      expect(tenants_of(place).map(&:first)).to eq(%w[T-1 T-2])
      expect(place.data_entries.tombstones(:tenants)).to be_empty
    end

    it 'lets a source that outranks the editor for tenants add the tenant again' do
      place.reload.update_attribute_source_precedence(:tenants, business_directory, 100)

      import(place.reload, business_directory, tenants: [tenant('T-1'), tenant('T-2')])

      expect(tenants_of(place).map(&:first)).to eq(%w[T-1 T-2])
      expect(place.data_entries.tombstones(:tenants)).to be_empty # the tenant has a row again
    end
  end

  describe 'an importer that creates tenants itself, one row at a time' do
    # Builds and saves each tenant directly, as many importers do, checking tombstones before saving a new one
    def import_row(record, source, external_id)
      tenant = record.tenants.find_by(external_id: external_id) || record.tenants.build(external_id: external_id)
      tenant.record_data_entries({ name: "Tenant #{external_id}" }, source)
      tenant.forge
      return :skipped if tenant.new_record? && LaForge.tombstone_blocking(tenant, source)

      tenant.save!
      :saved
    end

    before do
      %w[T-1 T-2].each { |external_id| import_row(place, business_directory, external_id) }
      place.reload.record_data_entries({ tenants: { exclude: [{ id: Tenant.find_by!(external_id: 'T-2').id }] } }, map_editor, mode: :edit)
      place.forge!
    end

    it 'skips a new tenant that a removal by a higher-precedence source matches, and creates it for a source that outranks it' do
      expect(import_row(place.reload, business_directory, 'T-2')).to eq(:skipped)
      expect(import_row(place.reload, business_directory, 'T-3')).to eq(:saved)

      place.update_attribute_source_precedence(:tenants, business_directory, 100)
      expect(import_row(place.reload, business_directory, 'T-2')).to eq(:saved)
      expect(tenants_of(place).map(&:first)).to eq(%w[T-1 T-2 T-3])
    end
  end

  describe 'a map editor removing one imported tenant, where tenants declare the identifier every source shares as their key' do
    before do
      stub_const('ListedPlace', Class.new(ActiveRecord::Base))
      ListedPlace.table_name = 'places'
      ListedPlace.has_many :tenants, as: :occupiable, dependent: :destroy
      ListedPlace.laforged(associations: { tenants: { key: :external_id } })

      import(listed_place, business_directory, tenants: [listed('T-1'), listed('T-2')])
      listed_place.reload.record_data_entries({ tenants: { exclude: [{ external_id: 'T-2' }] } }, map_editor, mode: :edit)
      listed_place.forge!
    end

    let(:listed_place) { ListedPlace.create!(name: 'Harbor Building') }

    def listed(external_id) = { external_id: external_id, name: "Tenant #{external_id}" }

    it 'keeps the tenant removed through later imports that still list it, while new tenants still arrive' do
      import(listed_place.reload, business_directory, tenants: [listed('T-1'), listed('T-2'), listed('T-3')])

      expect(tenants_of(listed_place).map(&:first)).to eq(%w[T-1 T-3])
    end

    it "restores the tenant on the importer's next run after the editor forgets the removal" do
      listed_place.reload.record_data_entries({ tenants: { forget: [{ external_id: 'T-2' }] } }, map_editor, mode: :edit)
      listed_place.forge!
      expect(tenants_of(listed_place).map(&:first)).to eq(%w[T-1]) # the list names T-2, but its name was destroyed with it when the editor removed it

      import(listed_place.reload, business_directory, tenants: [listed('T-1'), listed('T-2')])
      expect(tenants_of(listed_place).map(&:first)).to eq(%w[T-1 T-2])
    end
  end

  describe 'an importer that reports only the tenants it knows about' do
    before do
      import(place, business_directory, tenants: [tenant('T-1')])
      place.reload.record_data_entries({ tenants: [tenant('T-9', unit: '9Z')] }, business_registry, mode: :partial)
      place.forge!
    end

    it 'adds its tenants alongside the full list, and removes them when its next run no longer includes them' do
      expect(tenants_of(place)).to eq([['T-1', 'Tenant T-1', nil], ['T-9', 'Tenant T-9', '9Z']])

      place.reload.record_data_entries({ tenants: [] }, business_registry, mode: :partial)
      place.forge!

      expect(tenants_of(place).map(&:first)).to eq(%w[T-1])
    end

    it 'removes its tenants when an orphan sweep withdraws it from the record' do
      place.reload.withdraw_source(business_registry)
      place.forge!

      expect(tenants_of(place).map(&:first)).to eq(%w[T-1])
    end
  end

  describe 'an importer run that fails part way' do
    it 'leaves associations, attributes and entries as they were when a member is invalid' do
      import(place, business_directory, place_categories: categories(cafe), tenants: [tenant('T-1')])

      expect {
        import(place.reload, business_directory, name: 'Renamed', place_categories: categories(bakery), tenants: [tenant('T-1', name: nil)])
      }.to raise_error(ActiveRecord::RecordInvalid)

      expect(place.reload.name).to eq('Harbor Building')
      expect(categories_of(place)).to eq([cafe])
      expect(tenants_of(place)).to eq([['T-1', 'Tenant T-1', nil]])
      expect(place.source_values(:place_categories)[business_directory].map { |member| member['category_id'] }).to eq([cafe.id])
    end
  end

  describe 'a dry run that reports changes before applying them (change tracking)' do
    it 'reports the categories and parcel links an import would add, remove and change' do
      import(place, cadastre, place_categories: categories(cafe, bakery), reported_parcel_links: [parcel_link(lot_12, occupies)])

      place.reload.record_data_entries({ place_categories: categories(cafe, bookstore), reported_parcel_links: [parcel_link(lot_12, occupies, external_id: 'E-1')] }, cadastre)
      diff = place.forge_diff

      expect(diff['place_categories']).to include(added: [{ 'category_id' => bookstore.id }], removed: [{ 'category_id' => bakery.id }])
      expect(diff['reported_parcel_links'][:changed]).to eq([{ 'parcel_id' => lot_12.id, 'parcel_link_type_id' => occupies.id, 'external_id' => [nil, 'E-1'] }])
      expect(categories_of(place)).to eq([cafe, bakery])
    end
  end
end

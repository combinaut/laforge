require 'spec_helper'

# What association tracking does, capability by capability.
#
# The API is experimental: `laforged associations:`, association names as keys in `record_data_entries`,
# `source_values`, `member_sources`. The behaviour is the point; the names can change.
#
# Model:
# - Recording never touches an association; forging resolves its final state and assigns it.
# - Membership: each source records a report for an association, either its complete member list or a partial one
#   (members it includes or excludes). A report names members by key. Membership is decided per member by the
#   highest-precedence report with an opinion on it; a complete list excludes every member it doesn't list. A partial
#   source's report remembers the members it stopped including, which are removed unless another source includes them.
#   Rows no source has ever reported are left alone.
# - Member attributes: a member in a report is a hash of its key and what the source says about it, or a saved record.
#   Forging the owner records the hash's attributes on the member as that source's entries, as if the source had
#   recorded them on the member directly, and forges the member. Attributes for a member that membership excludes are
#   discarded, and nothing is created for it. A member's attributes are resolved on the member alone, under its
#   precedence rules, and stay there when a source's list drops it while another source keeps it.
# - A member that membership includes but that doesn't exist is created from its key when the forge has no attributes
#   for it, unless it is invalid with its key alone; then the forge skips it and logs a warning until a source reports
#   it with its attributes.
#
# Removal: forge has exactly the effect of assigning the resolved collection to the association, nothing more.
# Destroying records is otherwise out of scope. Every place a row is deleted, noted for later consideration:
# - Owned records (e.g. tenants) that membership no longer includes are removed per the association's `dependent:`
#   option, as `place.tenants = [...]` would: destroyed for `:destroy` (as the spec model's tenants are), deleted for
#   `:delete_all`, FK nullified otherwise. Any attribute entries other sources recorded on them (e.g. a registration number
#   another system recorded) go with them.
# - Join rows (e.g. place categories) that membership no longer includes are removed the same way, along with any
#   attribute entries other sources recorded on those rows.
# - A member whose referenced record has been deleted is dropped from the resolved collection (C30), so its join row
#   is removed too.
# - A record destroyed by another mechanism is recreated by the next forge if membership still includes it, from its key
#   or from what sources then report about it. Attribute entries never resurrect a record by themselves.
#
# Every example carries a `capability:` id. Retired ids (C09 C10 C11 C23 C35 C48 C66 C67) are not reused.
describe 'Association tracking capabilities' do
  include ActiveSupport::Testing::TimeHelpers

  before do
    AssociationCapabilities.setup!
    AssociationCapabilities.reset!
  end

  # Sources are mechanically identical; only their precedence differs. Precedences stay clear of the other specs' sources.
  let(:low) { LaForge::DataSource.create!(name: 'low', precedence: 11) }
  let(:high) { LaForge::DataSource.create!(name: 'high', precedence: 12) }
  let(:top) { LaForge::DataSource.create!(name: 'top', precedence: 13) }

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

  def categories(*list) = list.map { |category| { category_id: category.id } }
  def categories_of(record) = record.reload.place_categories.map(&:category)
  def parcel_link(parcel, type, **fields) = { parcel_id: parcel.id, parcel_link_type_id: type.id, **fields }
  def parcel_link_row(record, parcel, type) = record.reload.parcel_links.find_by(parcel_id: parcel.id, parcel_link_type_id: type.id)

  def tenant(external_id, **attributes) = { external_id: external_id, **attributes }
  def week(opens_at, days: 1..5) = days.map { |day| { day: day, opens_at: opens_at } }

  def count_queries(&block)
    count = 0
    counter = lambda do |*, payload|
      count += 1 unless payload[:name] == 'SCHEMA' || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record', &block)
    count
  end

  describe 'deferral until forge' do
    it 'leaves the association and the database untouched when association data is recorded', capability: 'C01' do
      place.record_data_entries({ place_categories: categories(cafe) }, low)

      expect(place.place_categories).to be_empty
      expect(PlaceCategory.count).to eq(0)
      expect(LaForge::DataEntry.count).to eq(0)
    end

    it 'applies recorded association data on forge!', capability: 'C02' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.forge!

      expect(categories_of(place)).to eq([cafe, bakery])
    end

    it 'assigns associations in memory on forge without writing until save', capability: 'C03' do
      place.record_data_entries({ place_categories: categories(cafe) }, low)
      place.forge

      expect(place.place_categories.map(&:category)).to eq([cafe])
      expect(PlaceCategory.count).to eq(0)

      place.save!
      expect(PlaceCategory.count).to eq(1)
    end

    it 'creates the owner and its association rows when forging a new record', capability: 'C04' do
      new_place = Place.new(name: 'New')
      new_place.record_data_entries({ place_categories: categories(cafe) }, low)
      new_place.forge!

      expect(new_place).to be_persisted
      expect(categories_of(new_place)).to eq([cafe])
    end

    it 'does not touch existing rows when re-forging unchanged data', capability: 'C05' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.forge!
      before_reforge = PlaceCategory.order(:id).pluck(:id, :updated_at)

      travel 1.minute do
        place.reload.forge!
      end

      expect(PlaceCategory.order(:id).pluck(:id, :updated_at)).to eq(before_reforge)
    end
  end

  describe 'membership' do
    it 'takes the member list from the highest-precedence source that recorded one', capability: 'C06' do
      place.record_data_entries({ place_categories: categories(cafe, bakery, bookstore) }, low)
      place.record_data_entries({ place_categories: categories(bakery, bookstore, florist) }, high)
      place.forge!

      expect(categories_of(place)).to contain_exactly(bakery, bookstore, florist)
    end

    it "replaces a source's previous list when that source records again", capability: 'C07' do
      place.record_data_entries({ place_categories: categories(cafe) }, low)
      place.record_data_entries({ place_categories: categories(bakery, bookstore, florist) }, high)
      place.forge!

      place.record_data_entries({ place_categories: categories(bakery) }, high)
      place.forge!

      expect(categories_of(place)).to eq([bakery])
    end

    it "falls back to the next source's list when the winning source's entry is removed", capability: 'C08' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.record_data_entries({ place_categories: categories(florist) }, high)
      place.forge!

      # Destroyed rather than marked, as removing a map editor's override does: a marked entry forges as an
      # empty value (C38), a missing one falls back
      place.data_entries.with_source(high).with_attribute(:place_categories).destroy_all
      place.data_entries.reset
      place.forge!

      expect(categories_of(place)).to eq([cafe, bakery])
    end

    it "creates a join row from its key when a lower-precedence source's list takes over, and its columns with that source's next report", capability: 'C46' do
      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_14, occupies, active: false)] }, low)
      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies)] }, high)
      place.forge!

      place.data_entries.with_source(high).with_attribute(:reported_parcel_links).destroy_all
      place.reload.forge!
      expect(parcel_link_row(place, lot_14, occupies)).to have_attributes(active: true) # the excluded row's columns were discarded

      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_14, occupies, active: false)] }, low)
      place.forge!
      expect(parcel_link_row(place, lot_14, occupies)).to have_attributes(active: false)
    end

    it "skips an owned record a lower-precedence source's list includes once it takes over, if it is invalid with its key alone, until the source reports it again", capability: 'C47' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: '1A')] }, low)
      place.record_data_entries({ tenants: [tenant('T-2', name: 'Harbor Books')] }, high)
      place.forge!
      expect(Tenant.pluck(:external_id)).to eq(['T-2'])

      place.data_entries.with_source(high).with_attribute(:tenants).destroy_all
      place.reload
      expect(place.forge_diff['tenants']).to eq(added: [], removed: [{ 'external_id' => 'T-2' }], changed: [], skipped: [{ 'external_id' => 'T-1' }])
      log = StringIO.new
      allow(place).to receive(:logger).and_return(Logger.new(log))
      place.forge!
      expect(place.reload.tenants).to be_empty # noted: T-2 destroyed per `dependent: :destroy`; T-1 skipped
      expect(log.string).to include(%(LaForge skipped the Tenant with external_id "T-1" in Place #{place.id}'s tenants)).and include("Name can't be blank")

      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: '1A')] }, low)
      place.forge!
      expect(place.reload.tenants.map { |record| [record.external_id, record.name, record.unit] }).to eq([['T-1', 'Corner Café', '1A']])
    end

    it 'treats an empty list as a value that wins like any other', capability: 'C12' do
      place.record_data_entries({ place_categories: categories(cafe) }, low)
      place.record_data_entries({ place_categories: [] }, high)
      place.forge!

      expect(categories_of(place)).to be_empty
      expect(place.source_values(:place_categories)).to eq(low => [{ 'category_id' => cafe.id }], high => [])
    end

    it "resolves a member's own tracked associations the same way, recorded on the member", capability: 'C13' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', opening_hours: week('08:00'))] }, low)
      place.record_data_entries({ tenants: [tenant('T-1', opening_hours: week('09:00', days: [1]))] }, high)
      place.forge!

      expect(place.reload.tenants.first.opening_hours.pluck(:day, :opens_at)).to eq([[1, '09:00']])
    end
  end

  describe 'partial reports' do
    it "keeps every member that partial reports include, the highest-precedence report's members first", capability: 'C49' do
      place.record_data_entries({ place_categories: categories(cafe) }, low, partial: true)
      place.record_data_entries({ place_categories: categories(bakery) }, high, partial: true)
      place.forge!

      expect(categories_of(place)).to eq([bakery, cafe])
    end

    it 'lets a higher-precedence source exclude one member that a lower source includes, and forget the exclusion', capability: 'C50' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.exclude_association_member(:place_categories, { category_id: cafe.id }, top)
      place.forge!
      expect(categories_of(place)).to eq([bakery])

      place.forget_association_member(:place_categories, { category_id: cafe.id }, top)
      place.forge!
      expect(categories_of(place)).to eq([cafe, bakery])
    end

    it 'removes a member a partial source stops including, unless another source still includes it', capability: 'C51' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low, partial: true)
      place.record_data_entries({ place_categories: categories(bakery) }, high, partial: true)
      place.forge!

      place.record_data_entries({ place_categories: [] }, low, partial: true)
      place.forge!

      expect(categories_of(place)).to eq([bakery])
    end

    it 'lets a complete list exclude what lower partial reports include, but not what higher ones include', capability: 'C52' do
      place.record_data_entries({ place_categories: categories(florist) }, low, partial: true)
      place.record_data_entries({ place_categories: categories(cafe) }, high)
      place.record_data_entries({ place_categories: categories(bookstore) }, top, partial: true)
      place.forge!

      expect(categories_of(place)).to eq([bookstore, cafe])
    end

    it 'leaves rows that no source has reported alone when only partial reports exist', capability: 'C53' do
      place.place_categories.create!(category: bookstore)
      place.record_data_entries({ place_categories: categories(cafe) }, low, partial: true)
      place.forge!

      expect(categories_of(place)).to eq([cafe, bookstore])
    end

    it 'withdraws everything a source reported when it stops reporting the record, keeping what others include', capability: 'C54' do
      place.record_data_entries({ name: 'From Low', tenants: [tenant('T-1', name: 'Corner Café')] }, low, partial: true)
      place.record_data_entries({ tenants: [tenant('T-2', name: 'Harbor Books')] }, high, partial: true)
      place.forge!

      place.withdraw_source(low)
      expect(place.reload.data_entries.with_source(low).pluck(:attribute_name)).to eq(['tenants'])

      place.forge!
      expect(place.reload.tenants.pluck(:external_id)).to eq(['T-2'])
    end

    it 'adds members one at a time to a report without replacing the rest of it', capability: 'C55' do
      place.record_data_entries({ place_categories: categories(cafe) }, low)
      place.include_association_member(:place_categories, { category_id: florist.id }, top)
      place.include_association_member(:place_categories, { category_id: bakery.id }, top)
      place.forge!

      expect(categories_of(place)).to eq([florist, bakery, cafe])
    end

    it 'includes some members and excludes others in one partial report', capability: 'C75' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.record_data_entries({ place_categories: { include: categories(florist), exclude: categories(cafe) } }, high, partial: true)
      place.forge!

      expect(categories_of(place)).to eq([florist, bakery])
    end

    it 'reports which sources include and which exclude a member', capability: 'C56' do
      place.record_data_entries({ place_categories: categories(cafe) }, low)
      place.exclude_association_member(:place_categories, { category_id: cafe.id }, top)

      expect(place.member_sources(:place_categories, category_id: cafe.id)).to include(membership: nil, listed_by: [low], excluded_by: [top])
    end
  end

  describe 'member attributes' do
    it 'applies join model attributes', capability: 'C14' do
      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies, active: false, external_id: 'CR-1')] }, low)
      place.forge!

      expect(parcel_link_row(place, lot_12, occupies)).to have_attributes(active: false, external_id: 'CR-1')
    end

    it 'resolves each attribute of a member independently, including from sources whose list did not win', capability: 'C15' do
      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies, active: false, external_id: 'L-1')] }, low)
      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies, external_id: 'H-1')] }, high)
      place.forge!

      expect(parcel_link_row(place, lot_12, occupies)).to have_attributes(active: false, external_id: 'H-1')
    end

    it 'treats an omitted attribute as no opinion and an explicit nil as a value', capability: 'C16' do
      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies, active: false, external_id: 'L-1')] }, low)
      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies, external_id: nil)] }, high)
      place.forge!

      expect(parcel_link_row(place, lot_12, occupies)).to have_attributes(active: false, external_id: nil)
    end

    it 'updates existing join rows in place rather than recreating them', capability: 'C17' do
      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies)] }, low)
      place.forge!
      original_id = parcel_link_row(place, lot_12, occupies).id

      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies, external_id: 'H-1')] }, high)
      place.forge!

      expect(parcel_link_row(place, lot_12, occupies).id).to eq(original_id)
    end

    it 'identifies 3-way join members by every foreign key other than the owner', capability: 'C18' do
      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies), parcel_link(lot_12, leases)] }, low)
      place.forge!
      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies, external_id: 'L-1'), parcel_link(lot_12, leases)] }, low)
      place.forge!

      expect(place.reload.parcel_links.count).to eq(2)
      expect(parcel_link_row(place, lot_12, occupies).external_id).to eq('L-1')
      expect(parcel_link_row(place, lot_12, leases).external_id).to be_nil
    end

    it "resolves a member's attributes on the member, from the source that listed it and from any other", capability: 'C41' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: '1A')] }, low)
      place.forge!

      corner_cafe = place.tenants.first
      corner_cafe.record_data_entries({ name: 'Elm Street Café' }, high) # e.g. another system that doesn't list tenants
      corner_cafe.forge!
      place.reload.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: '1A')] }, low)
      place.forge!
      expect(corner_cafe.reload).to have_attributes(name: 'Elm Street Café', unit: '1A')

      corner_cafe.update_attribute_source_precedence(:name, low, 50)
      corner_cafe.forge!
      expect(corner_cafe.reload.name).to eq('Corner Café')
    end

    it "keeps a source's attributes on a member after its list drops it while another source keeps it, until the source withdraws them", capability: 'C62' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: '1A')] }, low)
      place.record_data_entries({ tenants: [tenant('T-1', unit: '2B')] }, high, partial: true)
      place.forge!
      expect(place.reload.tenants.first.unit).to eq('2B')

      place.record_data_entries({ tenants: [] }, high, partial: true)
      place.forge!
      corner_cafe = place.reload.tenants.first
      expect(corner_cafe.unit).to eq('2B')

      corner_cafe.withdraw_source(high)
      corner_cafe.forge!
      expect(corner_cafe.reload.unit).to eq('1A')
    end
  end

  describe 'ordering' do
    it 'orders members as the winning list orders them', capability: 'C19' do
      place.record_data_entries({ place_categories: categories(cafe, bakery, bookstore) }, low)
      place.record_data_entries({ place_categories: categories(bookstore, bakery, florist) }, high)
      place.forge!

      expect(categories_of(place)).to eq([bookstore, bakery, florist])
      expect(place.place_categories.map(&:position)).to eq([0, 1, 2])
    end
  end

  describe 'precedence' do
    it 'lets one record take an association from a lower-precedence source', capability: 'C45' do
      other = Place.create!(name: 'Other')
      [place, other].each do |record|
        record.record_data_entries({ place_categories: categories(florist) }, high)
      end
      place.record_data_entries({ place_categories: categories(cafe) }, low, precedence: 50)
      other.record_data_entries({ place_categories: categories(cafe) }, low)
      [place, other].each(&:forge!)

      expect(categories_of(place)).to eq([cafe])
      expect(categories_of(other)).to eq([florist])
    end

    it "ranks membership, not the members' attributes, by a precedence given while recording a list", capability: 'C61' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'From Low'), tenant('T-2', name: 'Only Low')] }, low, precedence: 50)
      place.record_data_entries({ tenants: [tenant('T-1', name: 'From High')] }, high)
      place.forge!

      expect(place.reload.tenants.order(:external_id).pluck(:external_id, :name)).to eq([['T-1', 'From High'], ['T-2', 'Only Low']])
    end

    it 'keeps a custom precedence when the same source records again without one', capability: 'C42' do
      place.record_data_entries({ place_categories: categories(florist) }, high)
      place.record_data_entries({ place_categories: categories(cafe) }, low, precedence: 50)
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.forge!

      expect(categories_of(place)).to eq([cafe, bakery])
    end

    it 'applies a model-wide attribute × source precedence', capability: 'C43' do
      Tenant.update_attribute_source_precedence(:unit, low, 50)
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: '1A')] }, low)
      place.forge!
      corner_cafe = place.tenants.first
      corner_cafe.record_data_entries({ unit: '2B' }, high)
      corner_cafe.forge!

      expect(corner_cafe.reload.unit).to eq('1A')
    end

    it 'breaks precedence ties deterministically, regardless of the order entries were recorded in', capability: 'C44' do
      first = Place.create!(name: 'First')
      second = Place.create!(name: 'Second')
      first.record_data_entries({ place_categories: categories(cafe) }, low, precedence: high.precedence)
      first.record_data_entries({ place_categories: categories(florist) }, high)
      second.record_data_entries({ place_categories: categories(florist) }, high)
      second.record_data_entries({ place_categories: categories(cafe) }, low, precedence: high.precedence)
      [first, second].each(&:forge!)

      expect(categories_of(first)).to eq(categories_of(second))
    end
  end

  describe 'owned records' do
    it 'creates owned records and updates the same row when a source reports the same key again', capability: 'C20' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!
      tenant_id = place.reload.tenants.first.id

      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Bakery')] }, low)
      place.forge!

      expect(place.reload.tenants.map { |a| [a.id, a.name] }).to eq([[tenant_id, 'Corner Bakery']])
    end

    it 'tracks associations of owned records, forging them through the owner', capability: 'C21' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', opening_hours: week('08:00', days: [1]))] }, low)
      place.forge!

      expect(place.reload.tenants.first.opening_hours.pluck(:day, :opens_at)).to eq([[1, '08:00']])
    end

    it "removes owned records that drop out of the winning list as the association's dependent option dictates", capability: 'C22' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café'), tenant('T-2', name: 'Corner Bakery')] }, low)
      place.forge!

      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!

      expect(Tenant.pluck(:external_id)).to eq(['T-1']) # Place declares has_many :tenants, dependent: :destroy
    end

    it 'keeps an edit made directly on an owned record when its owner is forged', capability: 'C24' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!

      corner_cafe = place.tenants.first
      corner_cafe.record_data_entries({ name: 'Edited' }, top)
      corner_cafe.forge!

      place.reload.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!

      expect(corner_cafe.reload.name).to eq('Edited')
    end

    it "reports edits made directly on an owned record in the owner's per-source values", capability: 'C25' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!

      corner_cafe = place.tenants.first
      corner_cafe.record_data_entries({ name: 'Edited' }, top)
      corner_cafe.forge!

      expect(place.reload.source_values(:tenants)).to eq(low => [{ 'external_id' => 'T-1', 'name' => 'Corner Café' }], top => [{ 'external_id' => 'T-1', 'name' => 'Edited' }])
    end

    it "counts a source among an owned record's sources only when it records on the record, while the owner reports every source that lists it", capability: 'C68' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!
      place.include_association_member(:tenants, { external_id: 'T-1' }, top) # listed by key only
      place.save!

      corner_cafe = place.reload.tenants.first
      expect(corner_cafe.data_source_names).to eq(['low'])
      expect(corner_cafe.data_source?(top)).to be(false)
      expect(place.member_sources(:tenants, external_id: 'T-1')).to eq(membership: top, listed_by: [top, low], excluded_by: [], attributes: { 'name' => low })

      # An orphan check for low: nothing else records on the tenant, but top still lists it
      corner_cafe.withdraw_source(low)
      expect(corner_cafe.data_entries.without_source(low)).to be_empty
      expect(place.member_sources(:tenants, external_id: 'T-1')[:listed_by] - [low]).to eq([top])
    end

    it 'leaves rows without a key value alone, even when a complete list excludes every other member, and rejects blank keys', capability: 'C69' do
      place.tenants.create!(name: 'Added By Hand')
      place.tenants.create!(name: 'Also Added By Hand')

      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      expect(place.forge_diff['tenants']).to include(removed: [])
      place.forge!

      expect(place.reload.tenants.pluck(:name)).to contain_exactly('Added By Hand', 'Also Added By Hand', 'Corner Café')
      expect(place.source_values(:tenants)[low]).to eq([{ 'external_id' => 'T-1', 'name' => 'Corner Café' }])
      expect { place.record_data_entries({ tenants: [{ external_id: nil }] }, low) }.to raise_error(ArgumentError, /value for each key column/)
      expect { place.record_data_entries({ tenants: [place.tenants.first] }, low) }.to raise_error(ArgumentError, /value for each key column/)
    end

    it "records a member's attributes on the member as the source's entries, keeping only its key in the list", capability: 'C63' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', opening_hours: week('08:00', days: [1]))] }, low)
      place.forge!

      corner_cafe = place.reload.tenants.first
      expect(place.data_entries.find_by!(attribute_name: 'tenants').value).to eq([{ 'external_id' => 'T-1' }])
      expect(corner_cafe.data_entries.where(source: low).pluck(:attribute_name, :value)).to contain_exactly(['name', 'Corner Café'], ['opening_hours', [{ 'day' => 1 }]])
      expect(corner_cafe.opening_hours.first.data_entries.pluck(:attribute_name, :value)).to eq([%w[opens_at 08:00]])
    end

    it 'creates nothing for a member, and records none of its attributes, while membership excludes it', capability: 'C64' do
      place.exclude_association_member(:tenants, { external_id: 'T-1' }, top)
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!

      expect(Tenant.count).to eq(0)
      expect(LaForge::DataEntry.where(record_type: 'Tenant')).to be_empty
    end

    it "forges the members it records on, leaving the others to their own forge", capability: 'C65' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café'), tenant('T-2', name: 'Harbor Books')] }, low)
      place.forge!
      harbor_books = place.tenants.find_by!(external_id: 'T-2')
      harbor_books.record_data_entries({ name: 'Harbor Books & Maps' }, top)
      harbor_books.save! # recorded but not yet forged

      place.reload.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Bakery'), { external_id: 'T-2' }] }, low)
      place.forge!

      expect(place.reload.tenants.order(:external_id).pluck(:name)).to eq(['Corner Bakery', 'Harbor Books'])
    end

    it 'lists a saved record by its key, raising for an unsaved one', capability: 'C71' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!
      corner_cafe = place.tenants.first

      place.record_data_entries({ tenants: [corner_cafe] }, high)
      place.forge!
      expect(place.reload.member_sources(:tenants, external_id: 'T-1')).to include(membership: high, listed_by: [high, low], attributes: { 'name' => low })

      expect { place.record_data_entries({ tenants: [Tenant.new(external_id: 'T-2', name: 'Harbor Books')] }, low) }.to raise_error(LaForge::InvalidValue, /Cannot list an unsaved Tenant in Place#tenants; save it first, or pass its attributes as a hash/)
      expect { place.record_data_entries({ tenants: [Marker.create!(label: 'Pin')] }, low) }.to raise_error(LaForge::InvalidValue, /must be Tenant records/)
    end

    it 'raises when an owner is saved with member attributes recorded but not forged', capability: 'C72' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      expect { place.save! }.to raise_error(LaForge::NotForged, /tenants have member attributes recorded but not forged/)

      place.forge!
      expect(place.reload.tenants.count).to eq(1)
      place.record_data_entries({ tenants: [{ external_id: 'T-1' }] }, high) # a key alone can be saved and forged later
      place.save!
    end

    it 'raises for a member listed twice, and for rows sharing a key, rather than choosing one', capability: 'C73' do
      expect { place.record_data_entries({ tenants: [tenant('T-1', name: 'A'), tenant('T-1', name: 'B')] }, low) }.to raise_error(ArgumentError, /lists the same member more than once \(external_id "T-1"\)/)

      place.tenants.create!(external_id: 'T-1', name: 'Corner Café')
      place.tenants.create!(external_id: 'T-1', name: 'Corner Café Copy')
      place.record_data_entries({ tenants: [tenant('T-2', name: 'Harbor Books')] }, low)

      expect { place.forge! }.to raise_error(LaForge::DuplicateMemberKey, /tenants has several Tenant rows with the same key: external_id "T-1"/)
      expect(place.reload.tenants.count).to eq(2)
    end

    it 'treats a row whose key was edited as a different member', capability: 'C76' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!
      place.tenants.first.update!(external_id: 'T-1-edited')

      place.reload.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!

      expect(place.reload.tenants.pluck(:external_id)).to eq(['T-1']) # noted: the edited row is destroyed as unlisted
    end

    it "gives the new owner a new row when a source moves a member, removing the old row with what was recorded on it", capability: 'C77' do
      other = Place.create!(name: 'Other')
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!
      old_row = place.tenants.first
      old_row.record_data_entries({ unit: '1A' }, high)
      old_row.forge!

      other.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      other.forge!
      place.reload.record_data_entries({ tenants: [] }, low)
      place.forge!

      expect(other.reload.tenants.map { |row| [row.id == old_row.id, row.unit] }).to eq([[false, nil]])
      expect(Tenant.exists?(old_row.id)).to be(false) # noted: destroyed per `dependent: :destroy`, with the unit high recorded
    end

    it 'rejects the order column and validates nested lists when recording', capability: 'C74' do
      expect { place.record_data_entries({ place_categories: [{ category_id: cafe.id, position: 3 }] }, low) }.to raise_error(ArgumentError, /LaForge writes it from the order of the list/)
      expect { place.record_data_entries({ tenants: [tenant('T-1', opening_hours: [{ opens_at: '08:00' }])] }, low) }.to raise_error(ArgumentError, /must include their key \(day missing\)/)
      expect { place.exclude_association_member(:tenants, tenant('T-1', name: 'Corner Café'), top) }.to raise_error(ArgumentError, /named here by key only/)
    end
  end

  describe 'has_one' do
    it 'forges the single member from every source that reports it, updating the same row on later runs', capability: 'C57' do
      place.record_data_entries({ marker: { label: 'Harbor', icon: 'pin' } }, low)
      place.record_data_entries({ marker: { label: 'Harbor Building' } }, high)
      place.forge!
      marker_id = place.reload.marker.id
      expect(place.marker).to have_attributes(label: 'Harbor Building', icon: 'pin')

      place.record_data_entries({ marker: { label: 'Harbor', icon: 'star' } }, low)
      place.forge!

      expect(place.reload.marker).to have_attributes(id: marker_id, label: 'Harbor Building', icon: 'star')
    end

    it 'removes the member when the winning source reports none, writing nothing until the owner is saved', capability: 'C58' do
      place.record_data_entries({ marker: { label: 'Harbor' } }, low)
      place.forge!

      place.record_data_entries({ marker: nil }, high)
      place.forge
      expect(place.marker).to be_nil
      expect(Marker.count).to eq(1)

      place.save!
      expect(Marker.count).to eq(0) # noted: destroyed per `dependent: :destroy`
    end

    it 'rejects more than one member and partial reports', capability: 'C59' do
      expect { place.record_data_entries({ marker: [{}, {}] }, low) }.to raise_error(ArgumentError)
      expect { place.record_data_entries({ marker: { label: 'A' } }, low, partial: true) }.to raise_error(ArgumentError)
    end

    it 'creates the member when forging a new owner', capability: 'C60' do
      new_place = Place.new(name: 'New')
      new_place.record_data_entries({ marker: { label: 'New' } }, low)
      new_place.forge!

      expect(new_place.reload.marker.label).to eq('New')
    end
  end

  describe 'boundaries' do
    it 'never touches rows outside the scope of a tracked scoped association', capability: 'C26' do
      computed_row = place.parcel_links.create!(parcel: lot_14, parcel_link_type: computed)

      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies)] }, low)
      place.forge!

      expect(computed_row.reload).to have_attributes(active: true)
      expect(place.reload.parcel_links.count).to eq(2)
    end

    it "builds new members with the tracked association's scope attributes, so they stay in the association", capability: 'C70' do
      stub_const('ScopedPlace', Class.new(ActiveRecord::Base))
      ScopedPlace.table_name = 'places'
      ScopedPlace.has_many :closed_tenants, -> { where(status: 'closed') }, as: :occupiable, class_name: 'Tenant', dependent: :destroy
      ScopedPlace.laforged(associations: { closed_tenants: { key: :external_id } })
      scoped_place = ScopedPlace.create!(name: 'Scoped')

      2.times do
        scoped_place.reload.record_data_entries({ closed_tenants: [tenant('T-1', name: 'Former Café')] }, low)
        scoped_place.forge!
      end

      expect(Tenant.pluck(:external_id, :status)).to eq([%w[T-1 closed]])
    end

    it 'rejects member fields that are not attributes of the member model', capability: 'C27' do
      expect {
        place.record_data_entries({ place_categories: [{ category_id: cafe.id, name: 'Coffee Shop' }] }, low)
      }.to raise_error(LaForge::InvalidAttributeName)
    end

    it 'rejects associations that are not declared as tracked', capability: 'C28' do
      expect {
        place.record_data_entries({ parcel_links: [parcel_link(lot_14, computed)] }, low)
      }.to raise_error(LaForge::InvalidAttributeName)
    end

    it 'rejects members whose referenced record does not exist', capability: 'C29' do
      expect {
        place.record_data_entries({ place_categories: [{ category_id: 0 }] }, low)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it 'skips members whose referenced record was deleted after it was recorded', capability: 'C30' do
      place.record_data_entries({ place_categories: categories(cafe, florist) }, low)
      place.forge!
      florist.delete

      place.reload.forge!

      expect(PlaceCategory.pluck(:category_id)).to eq([cafe.id])
    end
  end

  describe 'inspection (data hub)' do
    it "returns each source's members for a record", capability: 'C31' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.record_data_entries({ place_categories: categories(bakery, florist) }, high)
      place.forge!

      values = place.reload.source_values(:place_categories)

      expect(values.transform_values { |members| members.map { |member| member['category_id'] } })
        .to eq(low => [cafe.id, bakery.id], high => [bakery.id, florist.id])
    end

    it "returns each source's members for many records in a constant number of queries", capability: 'C32' do
      places = Array.new(6) { |i| Place.create!(name: "Place #{i}") }
      places.each do |record|
        record.record_data_entries({ place_categories: categories(cafe) }, low)
        record.record_data_entries({ place_categories: categories(bakery) }, high)
        record.forge!
      end

      few = count_queries { Place.source_values(:place_categories, records: places.first(2)) }
      many = count_queries { Place.source_values(:place_categories, records: places) }

      expect(many).to eq(few)
      expect(Place.source_values(:place_categories, records: places).keys).to match_array(places.map(&:id))
    end

    it 'reports which list decided a membership and which source supplied each member attribute', capability: 'C33' do
      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies, active: false)] }, low)
      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies, external_id: 'H-1')] }, high)
      place.forge!

      provenance = place.member_sources(:reported_parcel_links, parcel_id: lot_12.id, parcel_link_type_id: occupies.id)

      expect(provenance[:membership]).to eq(high)
      expect(provenance[:listed_by]).to contain_exactly(low, high)
      expect(provenance[:attributes]).to eq('active' => low, 'external_id' => high)
    end

    it 'reports added, removed and changed members in forge_diff without writing', capability: 'C34' do
      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies, active: false), parcel_link(lot_14, occupies)] }, low)
      place.forge!

      place.reload.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies, active: false, external_id: 'H-1'), parcel_link(lot_12, leases)] }, low)
      diff = place.forge_diff['reported_parcel_links']

      expect(diff[:added]).to eq([{ 'parcel_id' => lot_12.id, 'parcel_link_type_id' => leases.id }])
      expect(diff[:removed]).to eq([{ 'parcel_id' => lot_14.id, 'parcel_link_type_id' => occupies.id }])
      expect(diff[:changed]).to eq([{ 'parcel_id' => lot_12.id, 'parcel_link_type_id' => occupies.id, 'external_id' => [nil, 'H-1'] }])
      expect(place.reported_parcel_links.flat_map { |row| row.data_entries.target }.map { |entry| [entry.attribute_name, entry.value, entry.changed?] }).to eq([['active', false, false]])
      expect(place.reload.parcel_links.count).to eq(2)
    end
  end

  describe 'integration with attribute tracking' do
    it 'forges attributes and associations in one transaction, rolling back everything if a member is invalid', capability: 'C36' do
      place.record_data_entries({ name: 'Renamed', tenants: [tenant('T-1', name: nil)] }, low)

      expect { place.forge! }.to raise_error(ActiveRecord::RecordInvalid)
      expect(place.reload.name).to eq('Harbor Building')
      expect(Tenant.count).to eq(0)
      expect(LaForge::DataEntry.count).to eq(0)
    end

    it 'limits forging to the given associations', capability: 'C37' do
      place.record_data_entries({ name: 'Renamed', place_categories: categories(cafe) }, low)
      place.forge!(attributes: [:place_categories])

      expect(categories_of(place)).to eq([cafe])
      expect(place.name).to eq('Harbor Building')
    end

    it 'removes association entries by attribute name and source', capability: 'C38' do
      place.record_data_entries({ name: 'Renamed', place_categories: categories(cafe) }, low)
      place.forge!

      place.remove_data_entries(attribute_names: :place_categories, sources: low)
      place.forge!

      expect(categories_of(place)).to be_empty
      expect(place.name).to eq('Renamed')
    end
  end

  describe 'declaration' do
    it 'derives join model keys from the association reflection', capability: 'C39' do
      expect(Place.laforged_association(:place_categories).key).to eq(%w[category_id])
      expect(Place.laforged_association(:reported_parcel_links).key).to eq(%w[parcel_id parcel_link_type_id])
    end

    it 'requires a key for owned records, which have none to derive', capability: 'C40' do
      stub_const('KeylessPlace', Class.new(ActiveRecord::Base))
      KeylessPlace.table_name = 'places'
      KeylessPlace.has_many :tenants, as: :occupiable

      expect { KeylessPlace.laforged(associations: { tenants: {} }) }.to raise_error(ArgumentError, /key/)
    end
  end
end

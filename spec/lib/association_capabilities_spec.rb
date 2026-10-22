require 'spec_helper'

# What association tracking does, capability by capability.
#
# The API is experimental: `laforged associations:`, association names as keys in `record_data_entries`,
# `source_values`, `member_sources`. The behaviour is the point; the names can change.
#
# Model:
# - Recording never touches an association; forging resolves its final state and assigns it.
# - Membership: each source records a report for an association, either its complete member list or a partial one
#   (members it includes or excludes). A report names members by key: the records a join row references, `key:` columns,
#   or else the primary key, where a member named without an id is new and named by a placeholder until it is created
#   and the owner saved. An id must be one of the owner's members. An explicitly excluded member keyed by id is destroyed,
#   and its exclusion keeps a tombstone, which `tombstone_matcher:` recognises in what sources report later.
#   Membership is decided per member by the highest-precedence report with an opinion on it; a complete list excludes
#   every member some report named that it doesn't list. A report remembers the members it stopped including, which
#   are removed unless another source includes them. Rows no report has named, such as ones from before the association
#   was tracked, are left alone by every report, and destroying a report forgets what it named; withdrawing a source
#   retracts it.
# - Member attributes: a member in a report is a hash of its key and what the source says about it, or a saved record.
#   The hash's attributes are kept in the report as pending until a forge of the owner includes the member; that forge
#   records them on the member as that source's entries, as if the source had recorded them on the member directly, and
#   forges the member. Nothing is created for a member that membership excludes; its attributes wait in the report until
#   membership includes it, or the source's next report replaces them. A member's attributes are resolved on the member
#   alone, under its precedence rules. When a source's report drops a member another source keeps, the forge withdraws
#   the source from the member, down its own lists; an attribute no other source has an entry for keeps its value.
#   Withdrawn keys are dropped once a forge settles them, and an emptied partial report with them. An attribute the
#   member has a newer value for from the same source is not recorded.
# - A member that membership includes but that doesn't exist is created from its key when no report has attributes for
#   it, unless it is invalid with its key alone; then the forge skips it and logs a warning until a source reports it
#   with its attributes. A member named by an id that is no longer one of the owner's is skipped the same way.
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
# - A record keyed by `key:` columns and destroyed by another mechanism is recreated by the next forge if membership
#   still includes it, from its key or from what sources then report about it. One keyed by primary key is not; a source
#   reporting it without its id creates a new one. Attribute entries never resurrect a record by themselves.
#
# Every example carries a `capability:` id. Retired ids (C09 C10 C11 C23 C35 C48 C66 C67 C76 C82 C83 C84) are not reused.
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

  # How an importer names a tenant: by id once it exists, found by an identifier of its own, otherwise as a new tenant
  def tenant(external_id, **attributes)
    existing = Tenant.find_by(external_id: external_id)
    { **(existing ? { id: existing.id } : {}), external_id: external_id, **attributes }
  end
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

    it "falls back to the next source's list when the winning source is withdrawn, and keeps the members only it named when its entry is destroyed", capability: 'C08' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.record_data_entries({ place_categories: categories(florist) }, high)
      place.forge!

      place.withdraw_source(high)
      place.forge!
      expect(categories_of(place)).to eq([cafe, bakery])

      place.record_data_entries({ place_categories: categories(florist) }, high)
      place.forge!
      place.data_entries.with_source(high).with_attribute(:place_categories).destroy_all # stops tracking what high said
      place.data_entries.reset
      place.forge!
      expect(categories_of(place)).to eq([cafe, bakery, florist]) # no report names florist, so it is left alone, like a row from before tracking
    end

    it "creates a join row with its columns when a lower-precedence source's list takes over", capability: 'C46' do
      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_14, occupies, active: false)] }, low)
      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies)] }, high)
      place.forge!
      expect(parcel_link_row(place, lot_14, occupies)).to be_nil

      place.data_entries.with_source(high).with_attribute(:reported_parcel_links).destroy_all
      place.reload.forge!
      expect(parcel_link_row(place, lot_14, occupies)).to have_attributes(active: false) # kept in the low report until now
    end

    it "creates an owned record with the attributes a lower-precedence source's list gave it once that list takes over, and skips one named by an id that no longer exists", capability: 'C47' do
      harbor_books = place.tenants.create!(external_id: 'T-3', name: 'Harbor Books')
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: '1A', opening_hours: week('08:00')), tenant('T-3')] }, low)
      place.record_data_entries({ tenants: [tenant('T-2', name: 'Harbor Maps')] }, high)
      place.forge!
      expect(Tenant.pluck(:external_id)).to eq(['T-2']) # noted: T-3 destroyed per `dependent: :destroy`, as high's list leaves it out
      harbor_maps = Tenant.find_by!(external_id: 'T-2')

      place.withdraw_source(high)
      place.reload
      expect(place.forge_diff['tenants']).to eq(
        added: [{ 'external_id' => 'T-1', 'name' => 'Corner Café', 'unit' => '1A', 'opening_hours' => week('08:00').map(&:stringify_keys) }],
        removed: [{ 'id' => harbor_maps.id }], changed: [], skipped: [{ 'id' => harbor_books.id }]
      )
      log = StringIO.new
      allow(place).to receive(:logger).and_return(Logger.new(log))
      place.forge!

      corner_cafe = place.reload.tenants.sole # noted: T-2 destroyed per `dependent: :destroy`
      expect([corner_cafe.external_id, corner_cafe.name, corner_cafe.unit]).to eq(['T-1', 'Corner Café', '1A'])
      expect(corner_cafe.opening_hours.pluck(:day, :opens_at)).to eq(week('08:00').map(&:values))
      expect(log.string).to include(%(LaForge skipped Tenant #{harbor_books.id} in Place #{place.id}'s tenants: membership includes it, but it is no longer one of them))
    end

    it 'skips a member named by key alone that is invalid with its key alone, until a source reports it with its attributes', capability: 'C80' do
      corner_cafe = place.tenants.create!(name: 'Corner Café')
      corner_cafe.record_data_entries({ opening_hours: [{ day: 1 }] }, low)
      log = StringIO.new
      allow(corner_cafe).to receive(:logger).and_return(Logger.new(log))
      OpeningHour.validates :opens_at, presence: true
      corner_cafe.forge!

      expect(corner_cafe.reload.opening_hours).to be_empty
      expect(log.string).to include(%(LaForge skipped the OpeningHour with day 1 in Tenant #{corner_cafe.id}'s opening_hours)).and include("Opens at can't be blank")
    ensure
      OpeningHour.clear_validators!
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
      place.forge!
      place.record_data_entries({ tenants: [tenant('T-1', opening_hours: week('09:00', days: [1]))] }, high)
      place.forge!

      expect(place.reload.tenants.first.opening_hours.pluck(:day, :opens_at)).to eq([[1, '09:00']])
    end
  end

  describe 'partial reports' do
    it "keeps every member that partial reports include, the highest-precedence report's members first", capability: 'C49' do
      place.record_data_entries({ place_categories: categories(cafe) }, low, mode: :partial)
      place.record_data_entries({ place_categories: categories(bakery) }, high, mode: :partial)
      place.forge!

      expect(categories_of(place)).to eq([bakery, cafe])
    end

    it 'lets a higher-precedence source exclude one member that a lower source includes, and forget the exclusion', capability: 'C50' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.record_data_entries({ place_categories: { exclude: [{ category_id: cafe.id }] } }, top, mode: :edit)
      place.forge!
      expect(categories_of(place)).to eq([bakery])

      place.record_data_entries({ place_categories: { forget: [{ category_id: cafe.id }] } }, top, mode: :edit)
      place.forge!
      expect(categories_of(place)).to eq([cafe, bakery])
    end

    it 'removes a member a partial source stops including, unless another source still includes it', capability: 'C51' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low, mode: :partial)
      place.record_data_entries({ place_categories: categories(bakery) }, high, mode: :partial)
      place.forge!

      place.record_data_entries({ place_categories: [] }, low, mode: :partial)
      place.forge!

      expect(categories_of(place)).to eq([bakery])
    end

    it 'lets a complete list exclude what lower partial reports include, but not what higher ones include', capability: 'C52' do
      place.record_data_entries({ place_categories: categories(florist) }, low, mode: :partial)
      place.record_data_entries({ place_categories: categories(cafe) }, high)
      place.record_data_entries({ place_categories: categories(bookstore) }, top, mode: :partial)
      place.forge!

      expect(categories_of(place)).to eq([bookstore, cafe])
    end

    it 'leaves rows that no source has reported alone when only partial reports exist', capability: 'C53' do
      place.place_categories.create!(category: bookstore)
      place.record_data_entries({ place_categories: categories(cafe) }, low, mode: :partial)
      place.forge!

      expect(categories_of(place)).to eq([cafe, bookstore])
    end

    it 'withdraws everything a source reported when it stops reporting the record, keeping what others include', capability: 'C54' do
      place.record_data_entries({ name: 'From Low', tenants: [tenant('T-1', name: 'Corner Café')] }, low, mode: :partial)
      place.record_data_entries({ tenants: [tenant('T-2', name: 'Harbor Books')] }, high, mode: :partial)
      place.forge!

      place.withdraw_source(low)
      expect(place.reload.data_entries.with_source(low).pluck(:attribute_name)).to eq(['tenants'])

      place.forge!
      expect(place.reload.tenants.pluck(:external_id)).to eq(['T-2'])
    end

    it 'adds members one at a time to a report without replacing the rest of it', capability: 'C55' do
      place.record_data_entries({ place_categories: categories(cafe) }, low)
      place.record_data_entries({ place_categories: { include: [{ category_id: florist.id }] } }, top, mode: :edit)
      place.record_data_entries({ place_categories: { include: [{ category_id: bakery.id }] } }, top, mode: :edit)
      place.forge!

      expect(categories_of(place)).to eq([florist, bakery, cafe])
    end

    it 'includes some members and excludes others in one partial report', capability: 'C75' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.record_data_entries({ place_categories: { include: categories(florist), exclude: categories(cafe) } }, high, mode: :partial)
      place.forge!

      expect(categories_of(place)).to eq([florist, bakery])
    end

    it 'applies edits to only the members they name, at every nested level, keeping the rest of the report', capability: 'C87' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', opening_hours: week('08:00', days: [1, 2]))] }, low)
      place.forge!
      corner_cafe = place.tenants.sole

      place.record_data_entries({ tenants: { include: [{ id: corner_cafe.id, opening_hours: { include: [{ day: 3, opens_at: '10:00' }], exclude: [{ day: 2 }] } }] } }, top, mode: :edit)
      place.record_data_entries({ tenants: [{ id: corner_cafe.id, unit: '9Z' }, { name: 'Harbor Books' }] }, top, mode: :edit) # a second edit before forging
      place.forge!

      expect(corner_cafe.reload).to have_attributes(name: 'Corner Café', unit: '9Z')
      expect(corner_cafe.opening_hours.pluck(:day, :opens_at)).to eq([[1, '08:00'], [3, '10:00']])
      expect(place.tenants.pluck(:name)).to contain_exactly('Corner Café', 'Harbor Books')

      place.record_data_entries({ tenants: { exclude: [{ id: corner_cafe.id }] } }, top, mode: :edit)
      place.forge!
      expect(place.reload.tenants.pluck(:name)).to eq(['Harbor Books'])
    end

    it 'rejects edits that are not a list or { include:, exclude:, forget: }, and unknown modes', capability: 'C88' do
      expect { place.record_data_entries({ tenants: { add: [] } }, top, mode: :edit) }.to raise_error(ArgumentError, /edits are a list of members, or \{ include:, exclude:, forget: \}, not add/)
      expect { place.record_data_entries({ tenants: [{ name: 'Corner Café', opening_hours: { add: [] } }] }, top, mode: :edit) }.to raise_error(ArgumentError, /opening_hours edits are/)
      expect { place.record_data_entries({ tenants: [] }, top, mode: :edits) }.to raise_error(ArgumentError, /Unknown mode :edits; pass :complete, :partial or :edit/)
    end

    it 'reports which sources include and which exclude a member', capability: 'C56' do
      place.record_data_entries({ place_categories: categories(cafe) }, low)
      place.record_data_entries({ place_categories: { exclude: [{ category_id: cafe.id }] } }, top, mode: :edit)

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

    it "withdraws a source's attributes from a member when its partial report stops including it while another source keeps it", capability: 'C62' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: '1A')] }, low)
      place.forge!
      place.record_data_entries({ tenants: [tenant('T-1', unit: '2B')] }, high, mode: :partial)
      place.forge!
      corner_cafe = place.reload.tenants.sole
      expect(corner_cafe.unit).to eq('2B')

      place.record_data_entries({ tenants: [] }, high, mode: :partial)
      place.forge!

      expect(corner_cafe.reload.unit).to eq('1A')
      expect(corner_cafe.data_source?(high)).to be(false)
      expect(place.reload.data_source?(high)).to be(false) # its report, settled and empty, is gone
    end

    it "withdraws a source from a member its complete list leaves out while another source keeps it, including the member's own lists", capability: 'C85' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: '1A', opening_hours: week('08:00', days: [1]))] }, low)
      place.forge!
      corner_cafe = place.tenants.sole
      place.record_data_entries({ tenants: { include: [{ id: corner_cafe.id, name: 'Corner Café' }] } }, top, mode: :edit)
      place.forge!

      place.record_data_entries({ tenants: [] }, low)
      expect(place.forge_diff['tenants']).to include(removed: [])
      place.forge!

      expect(corner_cafe.reload).to have_attributes(name: 'Corner Café', unit: '1A') # no other source has a unit, so it stays, as withdraw_source leaves it
      expect(corner_cafe.opening_hours).to be_empty
      expect(corner_cafe.data_source?(low)).to be(false)
      expect(LaForge::DataEntry.where(record_type: 'OpeningHour')).to be_empty # noted: the opening hour was destroyed per `dependent: :destroy`
    end

    it 'withdraws a source from the members it reported when it is withdrawn from the owner, and drops its settled reports', capability: 'C86' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: '1A')] }, low)
      place.forge!
      corner_cafe = place.tenants.sole
      place.record_data_entries({ tenants: { include: [{ id: corner_cafe.id, name: 'Corner Café' }] } }, top, mode: :edit)
      place.forge!

      place.withdraw_source(low)
      place.forge!

      expect(corner_cafe.reload.data_entries.pluck(:attribute_name)).to eq(['name']) # top's
      expect(corner_cafe.data_source?(low)).to be(false)
      expect(place.reload.data_source?(low)).to be(false)
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

    it 'gives a precedence passed with a list to everything the payload says, and only membership to members passed as records', capability: 'C61' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'From Low')] }, low)
      place.forge!
      corner_cafe = place.tenants.sole
      place.record_data_entries({ tenants: [tenant('T-1', name: 'From Low', opening_hours: week('08:00', days: [1])), tenant('T-2', name: 'Only Low')] }, low, precedence: 50)
      place.record_data_entries({ tenants: [tenant('T-1', name: 'From High', opening_hours: week('09:00', days: [1]))] }, high)
      place.forge!

      expect(place.reload.tenants.order(:external_id).pluck(:external_id, :name)).to eq([['T-1', 'From Low'], ['T-2', 'Only Low']])
      expect(corner_cafe.reload.opening_hours.pluck(:opens_at)).to eq(['08:00']) # nested lists get it too
      expect(corner_cafe.source_precedences['name']).to eq(low => 50)

      harbor_books = place.tenants.find_by!(external_id: 'T-2')
      place.record_data_entries({ tenants: [corner_cafe, harbor_books] }, top, precedence: 5)
      place.save!
      expect(place.reload.source_precedences['tenants']).to include(top => 5)
      expect(harbor_books.reload.source_precedences.values.flat_map(&:keys)).not_to include(top) # a record says nothing about its attributes
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

      expect(place.reload.source_values(:tenants)).to eq(
        low => [{ 'id' => corner_cafe.id, 'external_id' => 'T-1', 'name' => 'Corner Café' }],
        top => [{ 'id' => corner_cafe.id, 'name' => 'Edited' }]
      )
    end

    it "counts a source among an owned record's sources only when it records on the record, while the owner reports every source that lists it", capability: 'C68' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!
      corner_cafe = place.tenants.first
      place.record_data_entries({ tenants: { include: [{ id: corner_cafe.id }] } }, top, mode: :edit) # listed by key only
      place.save!

      expect(corner_cafe.data_source_names).to contain_exactly('low')
      expect(corner_cafe.data_source?(top)).to be(false)
      expect(place.reload.member_sources(:tenants, id: corner_cafe.id)).to eq(membership: top, listed_by: [top, low], excluded_by: [], attributes: { 'external_id' => low, 'name' => low })

      # An orphan check for low: nothing else records on the tenant, but top still lists it
      corner_cafe.withdraw_source(low)
      expect(corner_cafe.data_entries.without_source(low)).to be_empty
      expect(place.member_sources(:tenants, id: corner_cafe.id)[:listed_by] - [low]).to eq([top])
    end

    it 'leaves rows no report has named alone, even when a complete list leaves them out, and removes a member a complete list stops naming', capability: 'C69' do
      added_by_hand = place.tenants.create!(name: 'Added By Hand') # as rows from before the association was tracked are
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café'), tenant('T-2', name: 'Harbor Books')] }, low)
      expect(place.forge_diff['tenants']).to include(removed: [])
      place.forge!
      expect(place.reload.tenants.pluck(:name)).to contain_exactly('Added By Hand', 'Corner Café', 'Harbor Books')

      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      expect(place.forge_diff['tenants']).to include(removed: [{ 'id' => Tenant.find_by!(external_id: 'T-2').id }])
      place.forge!
      expect(place.reload.tenants.pluck(:name)).to contain_exactly('Added By Hand', 'Corner Café') # noted: Harbor Books destroyed per `dependent: :destroy`

      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café'), { id: added_by_hand.id }] }, low)
      place.forge!
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!
      expect(place.reload.tenants.pluck(:name)).to eq(['Corner Café']) # once a report names a row, a complete list can remove it
    end

    it "records a member's attributes on the member as the source's entries, keeping only its key in the list", capability: 'C63' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', opening_hours: week('08:00', days: [1]))] }, low)
      place.forge!

      corner_cafe = place.reload.tenants.first
      expect(place.data_entries.find_by!(attribute_name: 'tenants').value).to eq([{ 'id' => corner_cafe.id }])
      expect(corner_cafe.data_entries.where(source: low).pluck(:attribute_name, :value)).to contain_exactly(['external_id', 'T-1'], ['name', 'Corner Café'], ['opening_hours', [{ 'day' => 1 }]])
      expect(corner_cafe.opening_hours.first.data_entries.pluck(:attribute_name, :value)).to eq([%w[opens_at 08:00]])
    end

    it 'creates nothing for a member, and records none of its attributes, while membership excludes it', capability: 'C64' do
      place.record_data_entries({ tenants: [] }, top)
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

      place.reload.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Bakery'), { id: harbor_books.id }] }, low)
      place.forge!

      expect(place.reload.tenants.order(:external_id).pluck(:name)).to eq(['Corner Bakery', 'Harbor Books'])
    end

    it 'lists a saved record by its key, raising for an unsaved one', capability: 'C71' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!
      corner_cafe = place.tenants.first

      place.record_data_entries({ tenants: [corner_cafe] }, high)
      place.forge!
      expect(place.reload.member_sources(:tenants, id: corner_cafe.id)).to include(membership: high, listed_by: [high, low], attributes: { 'external_id' => low, 'name' => low })

      expect { place.record_data_entries({ tenants: [Tenant.new(external_id: 'T-2', name: 'Harbor Books')] }, low) }.to raise_error(LaForge::InvalidValue, /Cannot list an unsaved Tenant in Place#tenants; save it first, or pass its attributes as a hash/)
      expect { place.record_data_entries({ tenants: [Marker.create!(label: 'Pin')] }, low) }.to raise_error(LaForge::InvalidValue, /must be Tenant records/)
    end

    it 'keeps member attributes in the report until a forge records them, so the owner can be saved and forged later', capability: 'C72' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.save!
      report = place.data_entries.with_source(low).with_attribute(:tenants).sole.value
      expect(report).to match(
        'include' => [{ 'new' => String }], # a placeholder until the tenant exists
        'pending' => [{ 'key' => { 'new' => report['include'].first['new'] }, 'attributes' => { 'external_id' => 'T-1', 'name' => 'Corner Café' }, 'recorded_at' => String }]
      )

      place.reload.forge!
      corner_cafe = place.reload.tenants.sole
      expect([corner_cafe.external_id, corner_cafe.name]).to eq(['T-1', 'Corner Café'])
      expect(place.data_entries.with_source(low).with_attribute(:tenants).sole.value).to eq([{ 'id' => corner_cafe.id }])
    end

    it 'creates a new member once when it is forged twice before the owner is saved, and names it by id once saved', capability: 'C81' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge
      place.forge
      expect(place.tenants.size).to eq(1)

      place.save!
      expect(place.reload.tenants.pluck(:name)).to eq(['Corner Café'])
      expect(place.data_entries.with_source(low).with_attribute(:tenants).sole.value).to eq([{ 'id' => place.tenants.sole.id }])
    end

    it 'raises for a member named by an id that is not one of the owner members, rather than move it from another owner', capability: 'C77' do
      other = Place.create!(name: 'Other')
      other_cafe = other.tenants.create!(name: 'Corner Café')

      expect { place.record_data_entries({ tenants: [{ id: other_cafe.id, name: 'Corner Café' }] }, low) }.to raise_error(LaForge::InvalidValue, /Tenant #{other_cafe.id} is not one of Place #{place.id}'s tenants. LaForge does not move records between owners/)
      expect { place.record_data_entries({ tenants: { include: [other_cafe] } }, low, mode: :edit) }.to raise_error(LaForge::InvalidValue, /is not one of Place #{place.id}'s tenants/)
      expect { Place.new.record_data_entries({ tenants: [{ id: other_cafe.id }] }, low) }.to raise_error(LaForge::InvalidValue, /is not one of Place nil's tenants/)
      expect { place.record_data_entries({ tenants: [{ id: 0 }] }, low) }.to raise_error(LaForge::InvalidValue, /Tenant 0 is not one of/)
    end

    it 'keeps what a report says about a member while membership excludes it, until the source reports it again or is withdrawn', capability: 'C78' do
      harbor_books = place.tenants.create!(external_id: 'T-2', name: 'Harbor Books')
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café'), tenant('T-2', name: 'Harbor Books')] }, low)
      place.record_data_entries({ tenants: [tenant('T-2')] }, high)
      place.forge!
      pending = -> { LaForge::MemberList.new(place.reload.data_entries.with_source(low).with_attribute(:tenants).sole.value).pending }
      expect(pending.().map { |item| item['attributes'] }).to eq([{ 'external_id' => 'T-1', 'name' => 'Corner Café' }]) # T-2's attributes are on T-2 now

      place.record_data_entries({ tenants: { include: [{ id: harbor_books.id, name: 'Harbor Books Ltd' }] } }, high, mode: :edit)
      place.save!
      expect(LaForge::MemberList.new(place.reload.data_entries.with_source(high).with_attribute(:tenants).sole.value).pending.map { |item| item['attributes'] }).to eq([{ 'name' => 'Harbor Books Ltd' }])

      place.record_data_entries({ tenants: [{ id: harbor_books.id }] }, low) # its next report no longer lists T-1
      place.save!
      expect(pending.()).to be_empty

      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.save!
      place.withdraw_source(low)
      expect(pending.()).to be_empty
    end

    it 'does not let what an older report says about a member undo a newer value from the same source', capability: 'C79' do
      corner_cafe = travel_to(Time.utc(2025, 12, 1)) { place.tenants.create!(name: 'Corner Café') }

      travel_to(Time.utc(2026, 1, 1)) do # recorded, and the place saved without forging
        place.record_data_entries({ tenants: [{ id: corner_cafe.id, name: 'Corner Café', unit: '1A' }] }, low)
        place.save!
      end

      travel_to(Time.utc(2026, 2, 1)) do # the same source then names the tenant directly
        corner_cafe.forge! { corner_cafe.record_data_entries({ name: 'Corner Café & Co' }, low) }
      end

      place.reload.forge!
      expect(place.reload.tenants.pluck(:name, :unit)).to eq([['Corner Café & Co', '1A']])
    end

    it 'raises for a member listed twice, and for rows sharing a declared key, rather than choosing one', capability: 'C73' do
      corner_cafe = place.tenants.create!(name: 'Corner Café')
      expect { place.record_data_entries({ tenants: [{ id: corner_cafe.id, name: 'A' }, { id: corner_cafe.id, name: 'B' }] }, low) }.to raise_error(ArgumentError, /lists the same member more than once \(id #{corner_cafe.id}\)/)

      corner_cafe.opening_hours.create!(day: 1, opens_at: '08:00')
      corner_cafe.opening_hours.create!(day: 1, opens_at: '09:00')
      corner_cafe.record_data_entries({ opening_hours: week('10:00', days: [2]) }, low)

      expect { corner_cafe.forge! }.to raise_error(LaForge::DuplicateMemberKey, /opening_hours has several OpeningHour rows with the same key: day 1/)
      expect(corner_cafe.reload.opening_hours.count).to eq(2)
    end

    it 'rejects the order column and validates nested lists when recording', capability: 'C74' do
      expect { place.record_data_entries({ place_categories: [{ category_id: cafe.id, position: 3 }] }, low) }.to raise_error(ArgumentError, /LaForge writes it from the order of the list/)
      expect { place.record_data_entries({ tenants: [tenant('T-1', opening_hours: [{ opens_at: '08:00' }])] }, low) }.to raise_error(ArgumentError, /must include their key \(day missing\)/)
      expect { place.record_data_entries({ tenants: { exclude: [place.tenants.create!(name: 'Corner Café').attributes.slice('id', 'name')] } }, top, mode: :edit) }.to raise_error(ArgumentError, /named here by key only \(id\), not name/)
      expect { place.record_data_entries({ tenants: { exclude: [{ name: 'Corner Café' }] } }, top, mode: :edit) }.to raise_error(ArgumentError, /named here by id, which a new member does not have yet/)
    end
  end

  describe 'Rails form payloads' do
    it 'records nested attributes as a form submits them, multiple levels deep, as edits', capability: 'C89' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', opening_hours: week('08:00', days: [1, 2])), tenant('T-2', name: 'Harbor Books')] }, low)
      place.forge!
      corner_cafe, harbor_books = place.tenants.order(:external_id).to_a
      tuesday = corner_cafe.opening_hours.find_by!(day: 2)

      params = ActionController::Parameters.new(
        'name' => 'Harbor Hall',
        'tenants_attributes' => {
          '0' => { 'id' => corner_cafe.id.to_s, 'unit' => '2B', 'opening_hours_attributes' => { '0' => { 'id' => tuesday.id.to_s, '_destroy' => '1' }, '1' => { 'day' => '3', 'opens_at' => '10:00' } } },
          '1' => { 'id' => harbor_books.id.to_s, '_destroy' => 'true' },
          '2' => { 'name' => 'Florist', '_destroy' => '0' }
        }
      ).permit!
      place.record_data_entries(params, top, mode: :edit)
      place.forge!

      expect(place.reload.name).to eq('Harbor Hall')
      expect(place.tenants.pluck(:name)).to contain_exactly('Corner Café', 'Florist')
      expect(corner_cafe.reload.unit).to eq('2B')
      expect(corner_cafe.opening_hours.pluck(:day, :opens_at)).to eq([[1, '08:00'], [3, '10:00']])
    end

    it 'records *_ids as edits that include the ids checked and exclude the current members left unchecked', capability: 'C90' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.forge!

      place.record_data_entries({ category_ids: ['', cafe.id.to_s, florist.id.to_s] }, top, mode: :edit)
      place.forge!
      expect(categories_of(place)).to eq([cafe, florist])

      place.record_data_entries({ place_categories: categories(cafe, bakery, bookstore) }, low) # an import adding a category the form never showed
      place.forge!
      expect(categories_of(place)).to eq([cafe, florist, bookstore])
    end

    it 'raises for form payloads of associations that are not tracked, and for form payloads in another mode', capability: 'C91' do
      expect { place.record_data_entries({ parcel_links_attributes: [{ parcel_id: lot_12.id }] }, top, mode: :edit) }.to raise_error(LaForge::InvalidAttributeName, /Cannot record Place#parcel_links_attributes: parcel_links is not a tracked association/)
      expect { place.record_data_entries({ parcel_link_ids: [] }, top, mode: :edit) }.to raise_error(LaForge::InvalidAttributeName, /Cannot record Place#parcel_link_ids/)
      expect { place.record_data_entries({ tenants_attributes: [] }, top) }.to raise_error(ArgumentError, /record it with mode: :edit/)
      expect { place.record_data_entries({ tenants: [{ name: 'Florist', opening_hours_attributes: [] }] }, top) }.to raise_error(ArgumentError, /Tenant#opening_hours_attributes describes edits/)
    end
  end

  describe 'tombstones' do
    def exclude_corner_cafe
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café'), tenant('T-2', name: 'Harbor Books')] }, low)
      place.forge!
      place.record_data_entries({ tenants: { exclude: [{ id: Tenant.find_by!(name: 'Corner Café').id }] } }, top, mode: :edit)
      place.forge!
    end

    it 'destroys an excluded member and keeps a tombstone that keeps it out when a lower source reports it again', capability: 'C92' do
      exclude_corner_cafe
      expect(Tenant.pluck(:name)).to eq(['Harbor Books'])
      tombstone = place.reload.data_entries.tombstones(:tenants).sole
      expect([tombstone.source, tombstone.attributes['name'], tombstone.excluded_at]).to match([top, 'Corner Café', be_within(1.minute).of(Time.current)])

      place.record_data_entries({ tenants: [{ name: 'Corner Café', unit: '1A' }, tenant('T-2', name: 'Harbor Books')] }, low)
      expect(place.forge_diff['tenants']).to include(added: [], removed: [])
      place.forge!

      expect(place.reload.tenants.pluck(:name)).to eq(['Harbor Books'])
    end

    it 'keeps a tombstone through the excluding source\'s later partial reports, and drops it when the source is withdrawn', capability: 'C93' do
      exclude_corner_cafe
      place.reload.record_data_entries({ tenants: [tenant('T-2')] }, top, mode: :partial)
      place.forge!
      expect(place.reload.data_entries.tombstones(:tenants).size).to eq(1)

      place.withdraw_source(top)
      expect(place.reload.data_entries.tombstones(:tenants)).to be_empty
    end

    it 'can only be forgotten, by the tombstone or its to_h', capability: 'C94' do
      exclude_corner_cafe
      tombstone = place.reload.data_entries.tombstones(:tenants).sole

      expect { place.record_data_entries({ tenants: { include: [tombstone] } }, top, mode: :edit) }.to raise_error(ArgumentError, /can only be forgotten, which lets sources add the member again/)
      place.record_data_entries({ tenants: { forget: [tombstone.to_h] } }, top, mode: :edit)
      place.save!
      expect(place.reload.data_entries.tombstones(:tenants)).to be_empty
    end

    it 'raises, saying what to declare, for an exclusion that could not outlast its row', capability: 'C95' do
      stub_const('UnmatchedPlace', Class.new(ActiveRecord::Base))
      UnmatchedPlace.table_name = 'places'
      UnmatchedPlace.has_many :tenants, as: :occupiable, dependent: :destroy
      UnmatchedPlace.laforged(associations: { tenants: {} })
      unmatched_place = UnmatchedPlace.create!(name: 'Harbor Building')
      corner_cafe = unmatched_place.tenants.create!(name: 'Corner Café')

      message = /Cannot exclude Tenant #{corner_cafe.id} from UnmatchedPlace #{unmatched_place.id}'s tenants: excluding it destroys it.*Declare tombstone_matcher: on UnmatchedPlace's tenants.*tombstone_matcher: ->\(tenant, tombstones\)/
      expect { unmatched_place.record_data_entries({ tenants: { exclude: [corner_cafe] } }, top, mode: :edit) }.to raise_error(ArgumentError, message)
      expect { unmatched_place.record_data_entries({ tenants: { exclude: [corner_cafe] } }, top, mode: :partial) }.to raise_error(ArgumentError, message)
      expect { unmatched_place.record_data_entries({ tenants_attributes: [{ id: corner_cafe.id, _destroy: '1' }] }, top, mode: :edit) }.to raise_error(ArgumentError, message)
    end

    it 'rejects tombstone_matcher: where it could never run, or is not callable', capability: 'C96' do
      matcher = ->(*) {}
      expect { LaForge::AssociationConfig.new(Place, :place_categories, tombstone_matcher: matcher) }.to raise_error(ArgumentError, /Place#place_categories does not use a tombstone_matcher: its members are keyed by category_id, so an exclusion names something that outlasts the row. Remove tombstone_matcher:/)
      expect { LaForge::AssociationConfig.new(Place, :marker, tombstone_matcher: matcher) }.to raise_error(ArgumentError, /Place#marker does not use a tombstone_matcher: it is a has_one/)
      expect { LaForge::AssociationConfig.new(Place, :tenants, tombstone_matcher: :name) }.to raise_error(ArgumentError, /tombstone_matcher: must respond to call/)
    end

    it 'tells code that creates members itself whether a tombstone keeps a new member out, raising when it cannot check', capability: 'C97' do
      exclude_corner_cafe
      place.reload

      expect(LaForge.tombstone_blocking(place.tenants.build(name: 'Corner Café'), low)).to have_attributes(source: top)
      expect(LaForge.tombstone_blocking(place.tenants.build(name: 'Florist'), low)).to be_nil
      expect(LaForge.tombstone_blocking(place.tenants.build(name: 'Corner Café'), top)).to be_nil # the source that excluded it may add it again

      expect { LaForge.tombstone_blocking(place.tenants.first, low) }.to raise_error(ArgumentError, /already exists; tombstone_blocking checks a new member before it is created/)
      expect { LaForge.tombstone_blocking(Tenant.new(name: 'Corner Café'), low) }.to raise_error(ArgumentError, /Tenant is not a member of an association LaForge tracks \(checked occupiable, which is not set\)/)

      allow(Place.laforged_association(:tenants)).to receive(:tombstone_matcher).and_return(->(_tenant, _tombstones) { Tenant.new })
      expect { LaForge.tombstone_blocking(place.tenants.build(name: 'Corner Café'), low) }.to raise_error(ArgumentError, /Place#tenants tombstone_matcher: returned .* which is not one of the tombstones it was given/)
    end
  end

  describe 'merging duplicates' do
    let(:duplicate) { Place.create!(name: 'Harbor Bldg') }

    it 'moves attribute entries, keeping the duplicate\'s on a conflict with merge and the survivor\'s with reverse_merge', capability: 'C99' do
      other_survivor = Place.create!(name: 'Harbor Building')
      other_duplicate = Place.create!(name: 'Harbor Bldg')
      [[place, duplicate], [other_survivor, other_duplicate]].each do |survivor, copy|
        survivor.forge! { survivor.record_data_entries({ name: 'Harbor Building' }, low) }
        copy.forge! { copy.record_data_entries({ name: 'Harbor Bldg' }, low) }
      end

      report = LaForge.merge(place, duplicate)
      expect(report).to include(entries_moved: 0, entries_conflicting: [{ attribute: 'name', source: low, kept: :duplicate }])
      expect(place.data_entries.sole.value).to eq('Harbor Bldg')
      expect(duplicate.data_entries).to be_empty # left for the application to archive

      LaForge.reverse_merge(other_survivor, other_duplicate)
      expect(other_survivor.data_entries.sole.value).to eq('Harbor Building')
    end

    it 'moves per-record precedence rules the same way', capability: 'C100' do
      place.update_attribute_source_precedence(:name, low, 10)
      duplicate.update_attribute_source_precedence(:name, low, 50)
      duplicate.update_attribute_source_precedence(:name, high, 5)

      report = LaForge.merge(place, duplicate)

      expect(report).to include(precedence_rules_moved: 1, precedence_rules_conflicting: [{ attribute: 'name', source: low, kept: :duplicate }])
      expect(place.source_precedences['name']).to eq(low => 50, high => 5)
    end

    it 'moves owned members with their ids and what was recorded on them, combining each source\'s reports and tombstones', capability: 'C101' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!
      duplicate.record_data_entries({ tenants: [tenant('T-2', name: 'Harbor Books', opening_hours: week('08:00', days: [1])), { name: 'Florist' }] }, low)
      duplicate.forge!
      harbor_books = duplicate.tenants.find_by!(name: 'Harbor Books')
      duplicate.record_data_entries({ tenants: { exclude: [{ id: duplicate.tenants.find_by!(name: 'Florist').id }] } }, top, mode: :edit)
      duplicate.forge!

      report = LaForge.merge(place, duplicate)

      expect(report[:members_moved]).to eq('tenants' => [harbor_books.id])
      low_report = LaForge::MemberList.new(place.data_entries.with_source(low).with_attribute(:tenants).sole.value)
      expect(low_report.include.filter_map { |member| member['id'] }).to contain_exactly(place.tenants.find_by!(name: 'Corner Café').id, harbor_books.id)
      place.forge!
      expect(place.reload.tenants.pluck(:name)).to contain_exactly('Corner Café', 'Harbor Books')
      expect(harbor_books.reload.opening_hours.pluck(:day)).to eq([1])
      expect(place.data_entries.tombstones(:tenants).map { |tombstone| tombstone.attributes['name'] }).to eq(['Florist'])

      place.record_data_entries({ tenants: [{ name: 'Florist' }] }, low, mode: :partial)
      place.forge!
      expect(place.reload.tenants.pluck(:name)).not_to include('Florist') # the duplicate's removal still holds
    end

    it 'merges a join row both records have into the survivor\'s, and moves the rest', capability: 'C102' do
      place.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies, external_id: 'P-1')] }, low)
      place.forge!
      duplicate.record_data_entries({ reported_parcel_links: [parcel_link(lot_12, occupies, external_id: 'D-1'), parcel_link(lot_14, leases)] }, low)
      duplicate.forge!
      kept = parcel_link_row(place, lot_12, occupies)
      removed = parcel_link_row(duplicate, lot_12, occupies)

      report = LaForge.merge(place, duplicate)
      place.forge!

      expect(report[:members_merged]).to eq('reported_parcel_links' => [{ kept: kept.id, removed: removed.id }])
      expect(place.reload.parcel_links.map { |row| [row.parcel, row.parcel_link_type, row.external_id] }).to contain_exactly([lot_12, occupies, 'D-1'], [lot_14, leases, nil])
      expect(ParcelLink.exists?(removed.id)).to be(false) # noted: the duplicate's row is destroyed once merged
      expect(duplicate.reload.parcel_links).to be_empty
    end

    it 'raises, saying why, for records it cannot merge', capability: 'C103' do
      expect { LaForge.merge(place, Tenant.create!(name: 'Corner Café')) }.to raise_error(ArgumentError, /merges two records of the same model, not Place #{place.id} and Tenant/)
      expect { LaForge.merge(place, place) }.to raise_error(ArgumentError, /Cannot merge Place #{place.id} into itself/)
      expect { LaForge.merge(place, Place.new(name: 'New')) }.to raise_error(ArgumentError, /Cannot merge an unsaved Place; save it first/)
      expect { LaForge.merge(cafe, bakery) }.to raise_error(ArgumentError, /Cannot merge Category records: Category is not declared with `laforged`/)

      duplicate.record_data_entries({ name: 'Harbor Bldg' }, low)
      expect { LaForge.merge(place, duplicate) }.to raise_error(ArgumentError, /Place #{duplicate.id} has unsaved data entries or precedence rules; save it, or forge! it, before merging/)
    end
  end

  describe 'attribute groups and inactive sources on members' do
    it 'checks and resolves an attribute group on members as on the record', capability: 'C104' do
      expect { place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', street: '1 Quay')] }, low) }
        .to raise_error(ArgumentError, /Tenant members of Place#tenants: street, postcode are attribute group postal_address, which a source records together \(missing: postcode\)/)

      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', street: '1 Quay', postcode: 'H1')] }, low)
      place.forge!
      place.record_data_entries({ tenants: [tenant('T-1', street: '9 Pier', postcode: nil)] }, high, mode: :partial)
      place.forge!

      expect(Tenant.sole).to have_attributes(name: 'Corner Café', street: '9 Pier', postcode: nil)
    end

    it "leaves an inactive source's members alone and lets its exclusions stop applying, until it is active again", capability: 'C105' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.record_data_entries({ tenants: [tenant('T-2', name: 'Harbor Books')] }, high, mode: :partial)
      place.forge!
      place.record_data_entries({ tenants: { exclude: [{ id: Tenant.find_by!(name: 'Corner Café').id }] } }, top, mode: :edit)
      place.forge!
      place.reload.record_data_entries({ tenants: [{ name: 'Corner Café' }] }, low)
      place.forge!
      expect(Tenant.pluck(:name)).to eq(['Harbor Books'])

      high.update!(active: false)
      top.update!(active: false)
      place.reload.forge!
      expect(place.reload.tenants.pluck(:name)).to contain_exactly('Harbor Books', 'Corner Café') # high's tenant stays, unnamed; top's tombstone stops blocking

      top.update!(active: true) # its exclusion applies again, to the tenant created meanwhile
      place.reload.forge!
      expect(place.reload.tenants.pluck(:name)).to eq(['Harbor Books'])
      expect(place.data_entries.tombstones(:tenants).map(&:source)).to eq([top])
    end

    it 'publishes the entries a forge withdraws from members as destroyed', capability: 'C106' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!
      place.reload.record_data_entries({ tenants: [tenant('T-1', unit: '1A')] }, high, mode: :partial)
      place.forge!
      events = []
      subscription = ActiveSupport::Notifications.subscribe(LaForge::DataEntry::CHANGED) { |*, payload| events << payload.slice(:attribute_name, :source_id, :destroyed) }
      place.reload.record_data_entries({ tenants: [] }, high, mode: :partial)
      place.forge!

      expect(events).to include({ attribute_name: 'unit', source_id: high.id, destroyed: true })
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
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
      expect { place.record_data_entries({ marker: { label: 'A' } }, low, mode: :partial) }.to raise_error(ArgumentError)
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
      ScopedPlace.laforged(associations: { closed_tenants: {} })
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

    it 'raises for a method the model already defines that laforged would replace, and lets one defined after it wrap LaForge\'s', capability: 'C98' do
      stub_const('CollidingPlace', Class.new(ActiveRecord::Base))
      CollidingPlace.table_name = 'places'
      CollidingPlace.define_method(:source_values) { |*| :own }
      CollidingPlace.define_singleton_method(:source_precedences) { :own }
      expect { CollidingPlace.laforged }.to raise_error(ArgumentError, /CollidingPlace already defines #source_values, .source_precedences, which `laforged` would replace. Rename CollidingPlace's methods, or, to wrap LaForge's and call super, define them after `laforged`/)

      stub_const('WrappingPlace', Class.new(ActiveRecord::Base))
      WrappingPlace.table_name = 'places'
      WrappingPlace.laforged
      WrappingPlace.define_method(:forge) { |**options| super(**options).tap { @wrapped = true } }
      wrapping_place = WrappingPlace.create!(name: 'Harbor Building')
      wrapping_place.forge
      expect(wrapping_place.instance_variable_get(:@wrapped)).to be(true)
      expect { WrappingPlace.laforged }.not_to raise_error # declaring again finds LaForge's own methods
    end

    it 'keys owned records by primary key unless key: names other columns', capability: 'C40' do
      expect(Place.laforged_association(:tenants).key).to eq(%w[id])
      expect(Tenant.laforged_association(:opening_hours).key).to eq(%w[day])
      expect(Place.laforged_association(:marker).key).to eq([]) # a has_one's single member
    end

    it 'never derives an order column that identifies the member or its owner, so forging keeps their ids', capability: 'C107' do
      stub_const('LinkedPlace', Class.new(ActiveRecord::Base))
      LinkedPlace.table_name = 'places'
      LinkedPlace.has_many :parcel_links, -> { order(:id) }, foreign_key: :place_id # keyed by parcel and type, ordered by id
      LinkedPlace.laforged(associations: { parcel_links: {} })
      linked_place = LinkedPlace.create!(name: 'Harbor Building')
      ParcelLink.create!(place: Place.create!(name: 'Other Building'), parcel: lot_12, parcel_link_type: leases) # holds a low id
      links = [lot_12, lot_14].map { |parcel| ParcelLink.create!(place_id: linked_place.id, parcel: parcel, parcel_link_type: occupies) }

      expect(LinkedPlace.laforged_association(:parcel_links).order_column).to be_nil
      linked_place.record_data_entries({ parcel_links: [parcel_link(lot_12, occupies), parcel_link(lot_14, occupies)] }, low)
      expect { linked_place.forge! }.not_to raise_error
      expect(ParcelLink.where(place_id: linked_place.id).order(:id).ids).to eq(links.map(&:id))
    end

    it 'writes member order to order_column: when given, which a scope ordering by an expression needs, and none for false', capability: 'C108' do
      stub_const('ListedPlace', Class.new(ActiveRecord::Base))
      ListedPlace.table_name = 'places'
      ListedPlace.has_many :place_categories, -> { order(Arel.sql('position IS NULL, position')) }, foreign_key: :place_id
      ListedPlace.laforged(associations: { place_categories: { order_column: :position } })
      listed_place = ListedPlace.create!(name: 'Harbor Building')
      listed_place.record_data_entries({ place_categories: categories(bakery, cafe) }, low)
      listed_place.forge!
      expect(PlaceCategory.where(place_id: listed_place.id).order(:position).map(&:category)).to eq([bakery, cafe])

      expect(LaForge::AssociationConfig.new(Place, :place_categories, order_column: false).order_column).to be_nil
      expect(LaForge::AssociationConfig.new(Place, :place_categories).order_column).to eq('position')
      expect { LaForge::AssociationConfig.new(Place, :place_categories, order_column: :rank) }
        .to raise_error(ArgumentError, /Place#place_categories order_column: "rank" is not a column of place_categories; name an integer column to write member order to, or pass false for none/)
      expect { LaForge::AssociationConfig.new(Place, :parcel_links, order_column: :external_id) }.to raise_error(ArgumentError, /order_column: "external_id" is a string column/)
      expect { LaForge::AssociationConfig.new(Place, :place_categories, order_column: :category_id) }
        .to raise_error(ArgumentError, /order_column: "category_id" identifies the member or its owner, so writing order to it would change which record it is/)
    end
  end
end

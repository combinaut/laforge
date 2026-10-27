require 'spec_helper'

# What association tracking does, one capability per example. Its vocabulary (member list, member, membership,
# tombstone) is in `.ai/language.md`, and is defined in code on `LaForge::MemberList`, `LaForge::TrackedAssociation`
# and `LaForge::Tombstone`.
#
# The API is experimental. These names can change while the behavior stays:
# - `laforged associations:`
# - association names as keys in `record_data_entries`
# - `source_values`
# - `member_sources`
#
# A forge removes a row only where assigning the resolved collection to the association would. A comment starting
# `noted:` marks an example's line that checks a removed row. The rows removed are:
# - owned records (tenants) that membership no longer includes, per the association's `dependent:` option, as
#   `place.tenants = [...]` would. They are destroyed for `:destroy`, as the spec model's tenants are, deleted for
#   `:delete_all`, and have their foreign key nullified otherwise. Other sources' entries on them go with them.
# - join rows (place categories) that membership no longer includes, the same way, with the entries recorded on them.
# - the join row of a member whose referenced record was deleted, since the forge drops the member (C30).
# - the duplicate's join row that `LaForge.merge` merges into the survivor's (C102).
#
# A record keyed by `key:` columns and destroyed some other way is recreated by the next forge while membership includes
# it. One keyed by primary key is not, and a source listing it without its id creates a new one. Entries alone never
# recreate a record.
#
# Every example carries a `capability:` id. Retired ids (C09 C10 C11 C23 C35 C48 C66 C67 C76 C82 C83 C84) are not reused.
describe 'Association tracking capabilities' do
  include ActiveSupport::Testing::TimeHelpers

  before do
    AssociationCapabilities.setup!
    AssociationCapabilities.reset!
  end

  # The sources differ only in precedence, numbered clear of the other specs' sources.
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

  # Names a tenant as an importer does, by id once a tenant with the `external_id` exists, otherwise as a new tenant
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
    it 'takes the member list from the highest-precedence source that has one', capability: 'C06' do
      place.record_data_entries({ place_categories: categories(cafe, bakery, bookstore) }, low)
      place.record_data_entries({ place_categories: categories(bakery, bookstore, florist) }, high)
      place.forge!

      expect(categories_of(place)).to contain_exactly(bakery, bookstore, florist)
    end

    it "replaces a source's previous list when a list from that source is recorded again", capability: 'C07' do
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
      place.data_entries.with_source(high).with_attribute(:place_categories).destroy_all
      place.data_entries.reset
      place.forge!
      expect(categories_of(place)).to eq([cafe, bakery, florist]) # no member list names florist, so it is left alone, like a row from before tracking
    end

    it "creates a join row with its columns when a lower-precedence source's list takes over", capability: 'C46' do
      place.record_data_entries({ provided_parcel_links: [parcel_link(lot_14, occupies, active: false)] }, low)
      place.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies)] }, high)
      place.forge!
      expect(parcel_link_row(place, lot_14, occupies)).to be_nil

      place.data_entries.with_source(high).with_attribute(:provided_parcel_links).destroy_all
      place.reload.forge!
      expect(parcel_link_row(place, lot_14, occupies)).to have_attributes(active: false) # from the attributes low's member list kept pending
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

    it 'skips a member named by key alone that is invalid with its key alone, until a source lists it with its attributes', capability: 'C80' do
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

  describe 'partial lists' do
    it "keeps every member that partial lists include, the highest-precedence list's members first", capability: 'C49' do
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

    it 'lets a complete list exclude what lower partial lists include, but not what higher ones include', capability: 'C52' do
      place.record_data_entries({ place_categories: categories(florist) }, low, mode: :partial)
      place.record_data_entries({ place_categories: categories(cafe) }, high)
      place.record_data_entries({ place_categories: categories(bookstore) }, top, mode: :partial)
      place.forge!

      expect(categories_of(place)).to eq([bookstore, cafe])
    end

    it 'leaves alone the rows no source has listed, when only partial lists exist', capability: 'C53' do
      place.place_categories.create!(category: bookstore)
      place.record_data_entries({ place_categories: categories(cafe) }, low, mode: :partial)
      place.forge!

      expect(categories_of(place)).to eq([cafe, bookstore])
    end

    it 'withdraws everything a source listed when it stops providing the record, keeping what others include', capability: 'C54' do
      place.record_data_entries({ name: 'From Low', tenants: [tenant('T-1', name: 'Corner Café')] }, low, mode: :partial)
      place.record_data_entries({ tenants: [tenant('T-2', name: 'Harbor Books')] }, high, mode: :partial)
      place.forge!

      place.withdraw_source(low)
      expect(place.reload.data_entries.with_source(low).pluck(:attribute_name)).to eq(['tenants'])

      place.forge!
      expect(place.reload.tenants.pluck(:external_id)).to eq(['T-2'])
    end

    it 'keeps the withdrawal of a member forgotten twice before a forge', capability: 'C159' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, high, mode: :partial)
      place.forge!

      2.times { place.record_data_entries({ place_categories: { forget: categories(cafe) } }, high, mode: :edit) }
      place.forge!

      expect(categories_of(place)).to eq([bakery])
    end

    it 'removes a member a complete list excludes, when excluded twice before a forge or created outside tracking', capability: 'C160' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.forge!

      2.times { place.record_data_entries({ place_categories: { exclude: categories(cafe) } }, low, mode: :edit) }
      place.forge!
      expect(categories_of(place)).to eq([bakery])

      place.place_categories.create!(category: florist)
      place.record_data_entries({ place_categories: { exclude: categories(florist) } }, low, mode: :edit)
      place.forge!
      expect(categories_of(place)).to eq([bakery])
    end

    it 'withdraws what a removed complete list included, keeping the members another source includes', capability: 'C161' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.record_data_entries({ place_categories: categories(cafe, florist) }, high)
      place.forge!

      place.forge! { place.remove_data_entries(attribute_names: :place_categories, sources: high) }

      expect(categories_of(place)).to eq([cafe, bakery])
    end

    it "withdraws a removed member list's members when a new member list from the source is recorded before the forge", capability: 'C162' do
      place.record_data_entries({ place_categories: categories(cafe) }, low)
      place.forge!

      place.remove_data_entries(attribute_names: :place_categories, sources: low)
      place.record_data_entries({ place_categories: categories(bakery) }, low)
      place.forge!

      expect(categories_of(place)).to eq([bakery])
    end

    it 'destroys a partial list left with nothing in it, as when its last exclusion is forgotten', capability: 'C163' do
      place.record_data_entries({ place_categories: categories(cafe) }, low)
      place.record_data_entries({ place_categories: { exclude: categories(cafe) } }, top, mode: :edit)
      place.forge!

      place.record_data_entries({ place_categories: { forget: categories(cafe) } }, top, mode: :edit)
      place.forge!
      expect(place.reload.data_entries.with_source(top)).to be_empty

      place.record_data_entries({ tenants: [{ name: 'Florist' }] }, high) # only a new member, which withdrawing leaves out
      place.save!
      place.withdraw_source(high)
      place.forge!
      expect(place.reload.data_entries.with_source(high)).to be_empty
    end

    it 'includes members one edit at a time, without replacing the rest of the member list', capability: 'C55' do
      place.record_data_entries({ place_categories: categories(cafe) }, low)
      place.record_data_entries({ place_categories: { include: [{ category_id: florist.id }] } }, top, mode: :edit)
      place.record_data_entries({ place_categories: { include: [{ category_id: bakery.id }] } }, top, mode: :edit)
      place.forge!

      expect(categories_of(place)).to eq([florist, bakery, cafe])
    end

    it 'includes some members and excludes others in one partial list', capability: 'C75' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.record_data_entries({ place_categories: { include: categories(florist), exclude: categories(cafe) } }, high, mode: :partial)
      place.forge!

      expect(categories_of(place)).to eq([florist, bakery])
    end

    it 'applies edits to only the members they name, at every nested level, keeping the rest of the member list', capability: 'C87' do
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

    it 'rejects a partial list given as a hash with keys other than include: and exclude:', capability: 'C168' do
      expect { place.record_data_entries({ place_categories: { include: categories(cafe), forget: categories(bakery) } }, low, mode: :partial) }
        .to raise_error(ArgumentError, /Place#place_categories: a partial list is given as a list of members or as \{ include:, exclude: \}, not with forget. To forget a member, record it with mode: :edit/)
      expect { place.record_data_entries({ place_categories: { 'includes' => categories(cafe) } }, low, mode: :partial) }.to raise_error(ArgumentError, /not with includes\./)
    end

    it 'shows which sources include and which exclude a member', capability: 'C56' do
      place.record_data_entries({ place_categories: categories(cafe) }, low)
      place.record_data_entries({ place_categories: { exclude: [{ category_id: cafe.id }] } }, top, mode: :edit)

      expect(place.member_sources(:place_categories, category_id: cafe.id)).to include(membership: nil, listed_by: [low], excluded_by: [top])
    end
  end

  describe 'member attributes' do
    it 'applies join model attributes', capability: 'C14' do
      place.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies, active: false, external_id: 'CR-1')] }, low)
      place.forge!

      expect(parcel_link_row(place, lot_12, occupies)).to have_attributes(active: false, external_id: 'CR-1')
    end

    it 'resolves each attribute of a member independently, including from sources whose list did not win', capability: 'C15' do
      place.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies, active: false, external_id: 'L-1')] }, low)
      place.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies, external_id: 'H-1')] }, high)
      place.forge!

      expect(parcel_link_row(place, lot_12, occupies)).to have_attributes(active: false, external_id: 'H-1')
    end

    it 'treats an omitted attribute as not provided and an explicit nil as a value', capability: 'C16' do
      place.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies, active: false, external_id: 'L-1')] }, low)
      place.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies, external_id: nil)] }, high)
      place.forge!

      expect(parcel_link_row(place, lot_12, occupies)).to have_attributes(active: false, external_id: nil)
    end

    it 'updates existing join rows in place rather than recreating them', capability: 'C17' do
      place.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies)] }, low)
      place.forge!
      original_id = parcel_link_row(place, lot_12, occupies).id

      place.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies, external_id: 'H-1')] }, high)
      place.forge!

      expect(parcel_link_row(place, lot_12, occupies).id).to eq(original_id)
    end

    it 'identifies 3-way join members by every foreign key other than the owner', capability: 'C18' do
      place.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies), parcel_link(lot_12, leases)] }, low)
      place.forge!
      place.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies, external_id: 'L-1'), parcel_link(lot_12, leases)] }, low)
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

    it "withdraws a source's attributes from a member when its partial list stops including it while another source includes it", capability: 'C62' do
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
      expect(place.reload.data_source?(high)).to be(false) # the forge emptied its member list and destroyed it
    end

    it "withdraws a source from a member its complete list leaves out while another source includes it, including the member's own member lists", capability: 'C85' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: '1A', opening_hours: week('08:00', days: [1]))] }, low)
      place.forge!
      corner_cafe = place.tenants.sole
      place.record_data_entries({ tenants: { include: [{ id: corner_cafe.id, name: 'Corner Café' }] } }, top, mode: :edit)
      place.forge!

      place.record_data_entries({ tenants: [] }, low)
      expect(place.forge_diff['tenants']).to include(removed: [])
      place.forge!

      expect(corner_cafe.reload).to have_attributes(name: 'Corner Café', unit: '1A') # no other source has a unit, so it stays, as `withdraw_source` leaves it
      expect(corner_cafe.opening_hours).to be_empty
      expect(corner_cafe.data_source?(low)).to be(false)
      expect(LaForge::DataEntry.where(record_type: 'OpeningHour')).to be_empty # noted: the opening hour was destroyed per `dependent: :destroy`
    end

    it 'withdraws a source from the members it listed when it is withdrawn from the owner, and destroys its member lists the forge empties', capability: 'C86' do
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

    it "writes member order over a position recorded on the member, when the owner's member list also gives it attributes", capability: 'C165' do
      stub_const('ListingMock', Class.new(ActiveRecord::Base))
      ListingMock.table_name = 'active_record_mocks'
      ListingMock.has_many :children, -> { order(:count) }, class_name: 'ActiveRecordMock', foreign_key: :parent_id
      ListingMock.laforged(associations: { children: { key: :name } })
      listing = ListingMock.create!(name: 'Harbor Building')
      ActiveRecordMock.where(parent_id: listing.id).delete_all # rows other specs left pointing at this id
      listing.record_data_entries({ children: [{ name: 'Corner Café' }, { name: 'Harbor Books' }] }, low)
      listing.forge!

      harbor_books = listing.children.find_by!(name: 'Harbor Books')
      harbor_books.record_data_entry(:count, 0, top) # a position recorded on the member itself
      harbor_books.save!
      listing.record_data_entries({ children: [{ name: 'Corner Café' }, { name: 'Harbor Books', active: true }] }, low)
      listing.forge!

      expect(listing.reload.children.map { |child| [child.name, child.count] }).to eq([['Corner Café', 0], ['Harbor Books', 1]])
    end

    it 'writes member order in the direction the association scope orders by', capability: 'C117' do
      stub_const('DescendingPlace', Class.new(ActiveRecord::Base))
      DescendingPlace.table_name = 'places'
      DescendingPlace.has_many :place_categories, -> { order(position: :desc) }, foreign_key: :place_id
      DescendingPlace.laforged(associations: { place_categories: {} })
      descending_place = DescendingPlace.create!(name: 'Harbor Building')
      descending_place.record_data_entries({ place_categories: categories(cafe, bakery, bookstore) }, low)
      descending_place.forge!

      expect(descending_place.reload.place_categories.map(&:category)).to eq([cafe, bakery, bookstore])
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

    it 'keeps a custom precedence when values from the same source are recorded again without one', capability: 'C42' do
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

    it "breaks a tie at the most specific level by the sources' own precedence, not by a less specific rule", capability: 'C114' do
      place.record_data_entries({ name: 'From Low' }, low, precedence: 5)
      place.record_data_entries({ name: 'From High' }, high, precedence: 5)
      Place.update_attribute_source_precedence(:name, low, 1) # less specific than the tied rules on the place
      place.forge!

      expect(place.reload.name).to eq('From High')
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
    it 'deletes a removed member without callbacks for dependent: :delete_all, as assigning the collection would', capability: 'C120' do
      stub_const('DeletingPlace', Class.new(ActiveRecord::Base))
      DeletingPlace.table_name = 'places'
      DeletingPlace.has_many :tenants, as: :occupiable, dependent: :delete_all
      DeletingPlace.laforged(associations: { tenants: {} })
      deleting_place = DeletingPlace.create!(name: 'Harbor Building')
      deleting_place.record_data_entries({ tenants: [{ name: 'Corner Café' }, { name: 'Harbor Books' }] }, low)
      deleting_place.forge!
      corner_cafe = Tenant.find_by!(name: 'Corner Café')
      corner_cafe.opening_hours.create!(day: 1)

      deleting_place.reload.record_data_entries({ tenants: [{ id: Tenant.find_by!(name: 'Harbor Books').id }] }, low)
      deleting_place.forge!

      expect(Tenant.exists?(corner_cafe.id)).to be(false) # noted: the removed tenant is deleted
      expect(OpeningHour.where(tenant_id: corner_cafe.id).count).to eq(1) # its own dependents are not destroyed, as delete_all skips callbacks
      expect(deleting_place.tenants.map(&:name)).to eq(['Harbor Books'])
    end

    it "keeps the owner's counter cache current when it deletes a removed member for dependent: :delete_all", capability: 'C164' do
      stub_const('CountingMock', Class.new(ActiveRecord::Base))
      CountingMock.table_name = 'active_record_mocks'
      CountingMock.has_many :tenants, as: :occupiable, dependent: :delete_all, counter_cache: :count
      CountingMock.laforged(associations: { tenants: {} })
      counting = CountingMock.create!(name: 'Harbor Building')
      counting.record_data_entries({ tenants: [{ name: 'Corner Café' }, { name: 'Harbor Books' }] }, low)
      counting.forge!
      counting.update_column(:count, 2)
      corner_cafe, harbor_books = ['Corner Café', 'Harbor Books'].map { |name| Tenant.find_by!(name: name) }
      corner_cafe.opening_hours.create!(day: 1)

      counting.reload.record_data_entries({ tenants: [{ id: harbor_books.id }] }, low)
      counting.forge!

      expect(Tenant.exists?(corner_cafe.id)).to be(false) # noted: the removed tenant is deleted
      expect(counting.reload.count).to eq(1)
      expect(OpeningHour.where(tenant_id: corner_cafe.id).count).to eq(1) # deleting still skips callbacks
    end

    it 'discards a collection member a forge built, not saved yet, when a later forge before the save removes it', capability: 'C166' do
      stub_const('DetachingPlace', Class.new(ActiveRecord::Base))
      DetachingPlace.table_name = 'places'
      DetachingPlace.has_many :place_categories, foreign_key: :place_id # no `dependent:`, so removal nullifies
      DetachingPlace.laforged(associations: { place_categories: {} })
      detaching_place = DetachingPlace.create!(name: 'Harbor Building')

      detaching_place.record_data_entries({ place_categories: categories(cafe) }, low)
      detaching_place.forge # builds the row, unsaved
      detaching_place.record_data_entries({ place_categories: [] }, low)
      detaching_place.forge!
      expect(PlaceCategory.count).to eq(0)

      detaching_place.record_data_entries({ place_categories: categories(bakery) }, low)
      detaching_place.forge
      detaching_place.record_data_entries({ place_categories: [] }, low)
      detaching_place.forge
      detaching_place.record_data_entries({ place_categories: categories(bakery) }, low) # includes the discarded row again
      detaching_place.forge!
      expect(PlaceCategory.pluck(:place_id, :category_id)).to eq([[detaching_place.id, bakery.id]])
    end

    it 'detaches a removed member without validating it, as assigning the collection would', capability: 'C122' do
      stub_const('DetachingPlace', Class.new(ActiveRecord::Base))
      DetachingPlace.table_name = 'places'
      DetachingPlace.has_many :parcel_links, foreign_key: :place_id # no `dependent:`, so removal nullifies the `place_id` that `ParcelLink` requires
      DetachingPlace.laforged(associations: { parcel_links: {} })
      detaching_place = DetachingPlace.create!(name: 'Harbor Building')
      detaching_place.record_data_entries({ parcel_links: [parcel_link(lot_12, occupies), parcel_link(lot_14, occupies)] }, low)
      detaching_place.forge!
      removed = ParcelLink.find_by!(parcel: lot_14)

      detaching_place.reload.record_data_entries({ parcel_links: [parcel_link(lot_12, occupies)] }, low)
      expect { detaching_place.forge! }.not_to raise_error

      expect(removed.reload.place_id).to be_nil
      expect(detaching_place.parcel_links.map(&:parcel)).to eq([lot_12])
    end

    it 'removes a member that an earlier unsaved forge removed, when the owner is forged again with the same member list', capability: 'C124' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.forge!
      place.reload.record_data_entries({ place_categories: categories(cafe) }, low)
      place.forge
      place.forge!

      expect(categories_of(place)).to eq([cafe])
    end

    it 'keeps a partial list that an earlier unsaved forge emptied, once the source includes a member again', capability: 'C126' do
      place.record_data_entries({ place_categories: categories(cafe) }, low, mode: :partial)
      place.forge!
      place.reload.record_data_entries({ place_categories: [] }, low, mode: :partial)
      place.forge # withdraws the café and marks the emptied member list for destruction, unsaved
      place.record_data_entries({ place_categories: categories(bakery) }, low, mode: :partial)
      place.forge!

      expect(categories_of(place)).to eq([bakery])
      expect(place.data_entries.with_attribute(:place_categories)).to exist
    end

    it 'keeps a member that an earlier unsaved forge removed, once a forge includes it again', capability: 'C121' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.forge!
      place.reload.record_data_entries({ place_categories: categories(cafe) }, low)
      place.forge # marks the bakery's row for destruction, unsaved
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.forge!

      expect(categories_of(place)).to contain_exactly(cafe, bakery)

      place.reload.record_data_entries({ marker: { label: 'Harbor Building' } }, low)
      place.forge!
      marker = place.reload.marker
      place.record_data_entries({ marker: nil }, low)
      place.forge # takes the marker out, to be removed on save
      place.record_data_entries({ marker: { label: 'Harbor Building' } }, low)
      place.forge!
      expect(place.reload.marker).to eq(marker) # the same row, not a replacement
    end

    it 'creates owned records and updates the same row when a source lists the same key again', capability: 'C20' do
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

      expect(Tenant.pluck(:external_id)).to eq(['T-1']) # noted: T-2 destroyed per `dependent: :destroy`
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

    it "shows edits made directly on an owned record in the owner's per-source values", capability: 'C25' do
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

    it "counts a source among an owned record's sources only when it has entries on the record, while the owner shows every source that lists it", capability: 'C68' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!
      corner_cafe = place.tenants.first
      place.record_data_entries({ tenants: { include: [{ id: corner_cafe.id }] } }, top, mode: :edit) # listed by key only
      place.save!

      expect(corner_cafe.data_source_names).to contain_exactly('low')
      expect(corner_cafe.data_source?(top)).to be(false)
      expect(place.reload.member_sources(:tenants, id: corner_cafe.id)).to eq(membership: top, listed_by: [top, low], excluded_by: [], attributes: { 'external_id' => low, 'name' => low })

      # As an orphan check for low sees it, no other source has entries on the tenant, but top still lists it
      corner_cafe.withdraw_source(low)
      expect(corner_cafe.data_entries.without_source(low)).to be_empty
      expect(place.member_sources(:tenants, id: corner_cafe.id)[:listed_by] - [low]).to eq([top])
    end

    it 'leaves alone the rows no member list has named, even when a complete list leaves them out, and removes a member a complete list stops naming', capability: 'C69' do
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
      expect(place.reload.tenants.pluck(:name)).to eq(['Corner Café']) # once a member list names a row, a complete list can remove it
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

    it 'keeps member attributes in the member list until a forge records them, so the owner can be saved and forged later', capability: 'C72' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.save!
      member_list = place.data_entries.with_source(low).with_attribute(:tenants).sole.value
      expect(member_list).to match(
        'include' => [{ 'new' => String }], # a placeholder until the tenant exists
        'pending' => [{ 'key' => { 'new' => member_list['include'].first['new'] }, 'attributes' => { 'external_id' => 'T-1', 'name' => 'Corner Café' }, 'recorded_at' => String }]
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

    it "raises for a member named by an id that is not one of the owner's members, rather than move it from another owner", capability: 'C77' do
      other = Place.create!(name: 'Other')
      other_cafe = other.tenants.create!(name: 'Corner Café')

      expect { place.record_data_entries({ tenants: [{ id: other_cafe.id, name: 'Corner Café' }] }, low) }.to raise_error(LaForge::InvalidValue, /Tenant #{other_cafe.id} is not one of Place #{place.id}'s tenants. LaForge does not move records between owners/)
      expect { place.record_data_entries({ tenants: { include: [other_cafe] } }, low, mode: :edit) }.to raise_error(LaForge::InvalidValue, /is not one of Place #{place.id}'s tenants/)
      expect { Place.new.record_data_entries({ tenants: [{ id: other_cafe.id }] }, low) }.to raise_error(LaForge::InvalidValue, /is not one of Place nil's tenants/)
      expect { place.record_data_entries({ tenants: [{ id: 0 }] }, low) }.to raise_error(LaForge::InvalidValue, /Tenant 0 is not one of/)
    end

    it 'keeps what a member list says about a member while membership excludes it, until the source lists it again or is withdrawn', capability: 'C78' do
      harbor_books = place.tenants.create!(external_id: 'T-2', name: 'Harbor Books')
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café'), tenant('T-2', name: 'Harbor Books')] }, low)
      place.record_data_entries({ tenants: [tenant('T-2')] }, high)
      place.forge!
      pending = -> { LaForge::MemberList.new(place.reload.data_entries.with_source(low).with_attribute(:tenants).sole.value).pending }
      expect(pending.().map { |item| item['attributes'] }).to eq([{ 'external_id' => 'T-1', 'name' => 'Corner Café' }]) # T-2's attributes are on T-2 now

      place.record_data_entries({ tenants: { include: [{ id: harbor_books.id, name: 'Harbor Books Ltd' }] } }, high, mode: :edit)
      place.save!
      expect(LaForge::MemberList.new(place.reload.data_entries.with_source(high).with_attribute(:tenants).sole.value).pending.map { |item| item['attributes'] }).to eq([{ 'name' => 'Harbor Books Ltd' }])

      place.record_data_entries({ tenants: [{ id: harbor_books.id }] }, low) # its next member list no longer includes T-1
      place.save!
      expect(pending.()).to be_empty

      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.save!
      place.withdraw_source(low)
      expect(pending.()).to be_empty
    end

    it 'does not let what an older member list says about a member undo a newer value from the same source', capability: 'C79' do
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

    it 'raises for forgetting a member of a complete list, which would exclude it rather than leave it to other sources', capability: 'C116' do
      place.record_data_entries({ place_categories: categories(cafe) }, low)
      place.record_data_entries({ place_categories: categories(cafe) }, high)
      place.forge!

      expect { place.reload.record_data_entries({ place_categories: { forget: categories(cafe) } }, high, mode: :edit) }
        .to raise_error(ArgumentError, /Place#place_categories: the source has a complete list, which covers every member, so forgetting category_id #{cafe.id} would exclude it rather than leave it to other sources. Record the member list with mode: :partial first, or exclude the member/)
      place.record_data_entries({ place_categories: { forget: categories(cafe) } }, top, mode: :edit) # a source with no member list, or a partial one, can
    end
  end

  describe 'Rails form payloads' do
    # Returns a place model accepting nested attributes for its tenants and marker with the given options
    def form_place_model(**options, &body)
      stub_const('FormPlace', Class.new(ActiveRecord::Base))
      FormPlace.table_name = 'places'
      FormPlace.has_many :tenants, as: :occupiable
      FormPlace.has_one :marker, as: :markable
      FormPlace.accepts_nested_attributes_for :tenants, :marker, **options
      FormPlace.class_eval(&body) if body
      FormPlace.laforged(associations: { tenants: { tombstone_matcher: ->(tenant, tombstones) { tombstones.find { |tombstone| tombstone.name == tenant.name } } }, marker: {} })
      FormPlace
    end

    it "applies the owner's reject_if: and allow_destroy: to a form's rows, as Rails assigning them would", capability: 'C111' do
      form_place = form_place_model(reject_if: :all_blank, allow_destroy: false).create!(name: 'Harbor Building')
      corner_cafe = form_place.tenants.create!(name: 'Corner Café')

      form_place.record_data_entries({ tenants_attributes: { '0' => { 'name' => '', 'unit' => '' }, '1' => { 'id' => corner_cafe.id.to_s, '_destroy' => '1' } } }, top, mode: :edit)
      form_place.forge!

      expect(form_place.reload.tenants).to eq([corner_cafe]) # the blank template row is left out, and _destroy ignored

      form_place.record_data_entries({ marker_attributes: { 'label' => '', 'icon' => '' } }, top, mode: :edit) # a has_one's blank row
      expect(form_place.data_entries.map(&:attribute_name)).not_to include('marker')
    end

    it 'checks reject_if: on existing rows too but never on a row being destroyed, and on the new owner itself', capability: 'C112' do
      model = form_place_model(reject_if: ->(attributes) { attributes['unit'] == 'skip' }, allow_destroy: true)
      form_place = model.create!(name: 'Harbor Building')
      corner_cafe, harbor_books = ['Corner Café', 'Harbor Books'].map { |name| form_place.tenants.create!(name: name) }
      form_place.record_data_entries({ tenants_attributes: [{ id: corner_cafe.id, name: 'Renamed', unit: 'skip' }, { id: harbor_books.id, unit: 'skip', _destroy: '1' }] }, top, mode: :edit)
      form_place.forge!
      expect(form_place.reload.tenants.pluck(:name)).to eq(['Corner Café'])

      model = form_place_model(reject_if: :closed_tenant?) { def closed_tenant?(attributes) = attributes[:name].start_with?(name) }
      new_place = model.new(name: 'Closed')
      new_place.record_data_entries({ tenants_attributes: [{ name: 'Closed Bakery' }, { name: 'Florist' }] }, top, mode: :edit)
      new_place.forge!
      expect(new_place.reload.tenants.pluck(:name)).to eq(['Florist']) # checked on the new place itself, whose name is Closed
    end

    it "ignores a has_one's row being destroyed with no id, and raises for one whose id is not the current member's", capability: 'C156' do
      form_place = form_place_model(allow_destroy: true).create!(name: 'Harbor Building')
      form_place.record_data_entries({ marker: { label: 'Harbor' } }, low)
      form_place.forge!
      marker = form_place.reload.marker

      form_place.record_data_entries({ marker_attributes: { label: 'New', _destroy: '1' } }, top, mode: :edit) # a new row being destroyed, which Rails ignores
      form_place.forge!
      expect(form_place.reload.marker).to eq(marker)

      expect { form_place.record_data_entries({ marker_attributes: { id: marker.id + 1, _destroy: '1' } }, top, mode: :edit) }.to raise_error(ActiveRecord::RecordNotFound, /Couldn't find Marker #{marker.id + 1} among FormPlace#marker/)

      form_place.record_data_entries({ marker_attributes: { id: marker.id, _destroy: '1' } }, top, mode: :edit)
      form_place.forge!
      expect(form_place.reload.marker).to be_nil
    end

    it 'raises for a row whose id names no current member, where members are keyed by other columns', capability: 'C157' do
      place.record_data_entries({ place_categories: categories(cafe) }, low)
      place.forge!

      expect { place.record_data_entries({ place_categories_attributes: [{ id: 0, category_id: bakery.id }] }, top, mode: :edit) }.to raise_error(ActiveRecord::RecordNotFound, /Couldn't find PlaceCategory 0 among Place#place_categories/)
    end

    it "checks reject_if: against a form row's values with their settings taken off", capability: 'C151' do
      model = form_place_model(reject_if: :closed_tenant?) { def closed_tenant?(attributes) = attributes[:name].start_with?('Closed') }
      form_place = model.create!(name: 'Harbor Building')
      form_place.record_data_entries({ tenants_attributes: [{ name: LaForge.with_settings('Closed Bakery', expires_at: 1.week.from_now) },
                                                            { name: LaForge.with_settings('Florist', expires_at: 1.week.from_now) }] }, top, mode: :edit)
      form_place.forge!

      expect(form_place.reload.tenants.pluck(:name)).to eq(['Florist'])
    end

    it 'raises for accepts_nested_attributes_for options it does not apply, saying what to do', capability: 'C113' do
      expect { form_place_model(limit: 5).create!(name: 'Harbor Building').record_data_entries({ tenants_attributes: [{ name: 'Florist' }] }, top, mode: :edit) }
        .to raise_error(ArgumentError, /FormPlace accepts nested attributes for tenants with limit:, which LaForge does not apply when recording tenants_attributes. Remove it from accepts_nested_attributes_for, or check the rows in the controller/)
      expect { form_place_model(update_only: true).create!(name: 'Harbor Building').record_data_entries({ tenants_attributes: [{ name: 'Florist' }] }, top, mode: :edit) }
        .to raise_error(ArgumentError, /with update_only:/)
    end

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

    it 'records a single entry as record_data_entries does, so form payloads need mode: :edit there too', capability: 'C125' do
      corner_cafe = place.tenants.create!(name: 'Corner Café')

      expect { place.record_data_entry(:tenant_ids, [corner_cafe.id], top) }.to raise_error(ArgumentError, /Place#tenant_ids describes edits, as a Rails form submits them; record it with mode: :edit/)
      expect { place.record_data_entry(:tenants_attributes, [{ id: corner_cafe.id }], top) }.to raise_error(ArgumentError, /record it with mode: :edit/)
      expect(place.data_entries).to be_empty

      place.record_data_entry(:tenants, [{ name: 'Harbor Books' }], top) # a tracked association is recorded as a member list
      place.forge!
      expect(place.reload.tenants.pluck(:name)).to contain_exactly('Corner Café', 'Harbor Books')
    end
  end

  describe 'tombstones' do
    def exclude_corner_cafe
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café'), tenant('T-2', name: 'Harbor Books')] }, low)
      place.forge!
      place.record_data_entries({ tenants: { exclude: [{ id: Tenant.find_by!(name: 'Corner Café').id }] } }, top, mode: :edit)
      place.forge!
    end

    it 'destroys an excluded member and keeps a tombstone that keeps it out when a lower source lists it again', capability: 'C92' do
      exclude_corner_cafe
      expect(Tenant.pluck(:name)).to eq(['Harbor Books'])
      tombstone = place.reload.data_entries.tombstones(:tenants).sole
      expect([tombstone.source, tombstone.attributes['name'], tombstone.excluded_at]).to match([top, 'Corner Café', be_within(1.minute).of(Time.current)])

      place.record_data_entries({ tenants: [{ name: 'Corner Café', unit: '1A' }, tenant('T-2', name: 'Harbor Books')] }, low)
      expect(place.forge_diff['tenants']).to include(added: [], removed: [])
      place.forge!

      expect(place.reload.tenants.pluck(:name)).to eq(['Harbor Books'])
    end

    it 'keeps a tombstone through the excluding source\'s later partial lists, and drops it when the source is withdrawn', capability: 'C93' do
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

      message = /Cannot exclude Tenant #{corner_cafe.id} from UnmatchedPlace #{unmatched_place.id}'s tenants: excluding it removes it per `dependent:`.*Declare tombstone_matcher: on UnmatchedPlace's tenants.*tombstone_matcher: ->\(tenant, tombstones\)/
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

      allow(Place.laforge.association(:tenants)).to receive(:tombstone_matcher).and_return(->(_tenant, _tombstones) { Tenant.new })
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

      result = LaForge.merge(place, duplicate)
      expect(result).to include(entries_moved: 0, entries_conflicting: [{ attribute: 'name', source: low, kept: :duplicate }])
      expect(place.data_entries.sole.value).to eq('Harbor Bldg')
      expect(duplicate.data_entries).to be_empty # left for the application to archive

      LaForge.reverse_merge(other_survivor, other_duplicate)
      expect(other_survivor.data_entries.sole.value).to eq('Harbor Building')
    end

    it 'moves per-record precedence rules the same way', capability: 'C100' do
      place.update_attribute_source_precedence(:name, low, 10)
      duplicate.update_attribute_source_precedence(:name, low, 50)
      duplicate.update_attribute_source_precedence(:name, high, 5)

      result = LaForge.merge(place, duplicate)

      expect(result).to include(precedence_rules_moved: 1, precedence_rules_conflicting: [{ attribute: 'name', source: low, kept: :duplicate }])
      expect(place.source_precedences['name']).to eq(low => 50, high => 5)
    end

    it 'moves owned members with their ids and what was recorded on them, combining each source\'s member lists and tombstones', capability: 'C101' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!
      duplicate.record_data_entries({ tenants: [tenant('T-2', name: 'Harbor Books', opening_hours: week('08:00', days: [1])), { name: 'Florist' }] }, low)
      duplicate.forge!
      harbor_books = duplicate.tenants.find_by!(name: 'Harbor Books')
      duplicate.record_data_entries({ tenants: { exclude: [{ id: duplicate.tenants.find_by!(name: 'Florist').id }] } }, top, mode: :edit)
      duplicate.forge!

      result = LaForge.merge(place, duplicate)

      expect(result[:members_moved]).to eq('tenants' => [harbor_books.id])
      low_list = LaForge::MemberList.new(place.data_entries.with_source(low).with_attribute(:tenants).sole.value)
      expect(low_list.include.filter_map { |member| member['id'] }).to contain_exactly(place.tenants.find_by!(name: 'Corner Café').id, harbor_books.id)
      place.forge!
      expect(place.reload.tenants.pluck(:name)).to contain_exactly('Corner Café', 'Harbor Books')
      expect(harbor_books.reload.opening_hours.pluck(:day)).to eq([1])
      expect(place.data_entries.tombstones(:tenants).map { |tombstone| tombstone.attributes['name'] }).to eq(['Florist'])

      place.record_data_entries({ tenants: [{ name: 'Florist' }] }, low, mode: :partial)
      place.forge!
      expect(place.reload.tenants.pluck(:name)).not_to include('Florist') # the duplicate's removal still holds
    end

    it 'merges a join row both records have into the survivor\'s, and moves the rest', capability: 'C102' do
      place.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies, external_id: 'P-1')] }, low)
      place.forge!
      duplicate.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies, external_id: 'D-1'), parcel_link(lot_14, leases)] }, low)
      duplicate.forge!
      kept = parcel_link_row(place, lot_12, occupies)
      removed = parcel_link_row(duplicate, lot_12, occupies)

      result = LaForge.merge(place, duplicate)
      place.forge!

      expect(result[:members_merged]).to eq('provided_parcel_links' => [{ kept: kept.id, removed: removed.id }])
      expect(place.reload.parcel_links.map { |row| [row.parcel, row.parcel_link_type, row.external_id] }).to contain_exactly([lot_12, occupies, 'D-1'], [lot_14, leases, nil])
      expect(ParcelLink.exists?(removed.id)).to be(false) # noted: the duplicate's row is destroyed once merged
      expect(duplicate.reload.parcel_links).to be_empty
    end

    it 'raises before moving anything when both records have a has_one member and their keys differ', capability: 'C128' do
      stub_const('LabelledPlace', Class.new(ActiveRecord::Base))
      LabelledPlace.table_name = 'places'
      LabelledPlace.has_one :marker, as: :markable, dependent: :destroy
      LabelledPlace.laforged(associations: { marker: { key: :label } })
      survivor, copy = ['Harbor Building', 'Harbor Bldg'].map { |name| LabelledPlace.create!(name: name) }
      survivor.forge! { survivor.record_data_entries({ marker: { label: 'Harbor' } }, low) }
      copy.forge! { copy.record_data_entries({ name: 'Harbor Bldg', marker: { label: 'Quay' } }, low) }

      expect { LaForge.merge(survivor, copy) }.to raise_error(ArgumentError, /Cannot merge LabelledPlace #{copy.id} into LabelledPlace #{survivor.id}: both have a marker, with label "Harbor" and label "Quay", and LabelledPlace#marker holds one. Remove one of them, or give them the same key so the merge combines them, then merge again/)
      expect(copy.reload.marker.label).to eq('Quay')
      expect(copy.data_entries.count).to eq(2)
      expect(Marker.where(markable_type: 'LabelledPlace', markable_id: survivor.id).count).to eq(1)
    end

    it "raises before moving anything when a source's unforged member lists for a has_one on both records name different members", capability: 'C158' do
      stub_const('LabelledPlace', Class.new(ActiveRecord::Base))
      LabelledPlace.table_name = 'places'
      LabelledPlace.has_one :marker, as: :markable, dependent: :destroy
      LabelledPlace.laforged(associations: { marker: { key: :label } })
      survivor, copy = ['Harbor Building', 'Harbor Bldg'].map { |name| LabelledPlace.create!(name: name) }
      survivor.record_data_entries({ marker: { label: 'Harbor' } }, low)
      survivor.save!
      copy.record_data_entries({ marker: { label: 'Quay' } }, low)
      copy.save!

      expect { LaForge.merge(survivor, copy) }.to raise_error(ArgumentError, /Cannot merge LabelledPlace #{copy.id} into LabelledPlace #{survivor.id}: low's member lists for their marker name label "Quay" and label "Harbor", and LabelledPlace#marker holds one. Remove one of the member lists, or give the members the same key so the merge combines them, then merge again/)
      expect(copy.data_entries.reload.count).to eq(1)
      expect(survivor.data_entries.reload.count).to eq(1)
    end

    it "moves a member to the survivor's `primary_key:` column", capability: 'C173' do
      stub_const('NumberedPlace', Class.new(ActiveRecord::Base))
      NumberedPlace.table_name = 'places'
      NumberedPlace.has_many :tenants, as: :occupiable, primary_key: :number, dependent: :destroy
      NumberedPlace.laforged(associations: { tenants: { key: :external_id } })
      survivor = NumberedPlace.create!(name: 'Harbor Building', number: 9_001)
      copy = NumberedPlace.create!(name: 'Harbor Bldg', number: 9_002)
      copy.forge! { copy.record_data_entries({ tenants: [{ external_id: 'T-1', name: 'Corner Café' }] }, low) }

      LaForge.merge(survivor, copy)

      expect(survivor.reload.tenants.pluck(:external_id)).to eq(['T-1'])
      expect(copy.reload.tenants).to be_empty
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
        .to raise_error(ArgumentError, /Tenant members of Place#tenants: street, postcode are attribute group postal_address, which a source provides together \(missing: postcode\)/)

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
      expect(place.reload.tenants.pluck(:name)).to contain_exactly('Harbor Books', 'Corner Café') # high's tenant stays though unnamed, and top's tombstone stops blocking

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

    it 'publishes nothing for entries a forge withdraws from members when the forge rolls back', capability: 'C110' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!
      place.reload.record_data_entries({ tenants: [tenant('T-1', unit: '1A')] }, high, mode: :partial)
      place.forge!
      events = []
      subscription = ActiveSupport::Notifications.subscribe(LaForge::DataEntry::CHANGED) { |*, payload| events << payload.slice(:attribute_name, :source_id, :destroyed) }

      ActiveRecord::Base.transaction do
        place.reload.record_data_entries({ tenants: [] }, high, mode: :partial)
        place.forge!
        raise ActiveRecord::Rollback
      end

      expect(events).to be_empty
      expect(Tenant.sole.data_entries.with_source(high).with_attribute(:unit)).to exist
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
  end

  describe 'expiring member lists' do
    it 'leaves an expired member list out of the next forge, so a member only it named stays, as a row no member list names', capability: 'C181' do
      place.record_data_entries({ place_categories: categories(cafe) }, low)
      place.record_data_entries({ place_categories: categories(bakery) }, high, mode: :partial, expires_at: 1.week.from_now)
      place.forge!
      expect(categories_of(place)).to contain_exactly(cafe, bakery)

      travel 8.days do
        place.reload.forge!
        place.reload.forge!
      end

      expect(categories_of(place)).to contain_exactly(cafe, bakery)
      expect(place.data_entries.with_source(high).sole.value).to include('include' => categories(bakery).map(&:stringify_keys))
    end

    it 'removes a member another member list excludes once the expired one no longer includes it', capability: 'C182' do
      place.record_data_entries({ place_categories: categories(bakery) }, low, mode: :partial)
      place.record_data_entries({ place_categories: categories(cafe) }, high) # a complete list, which excludes the bakery
      place.record_data_entries({ place_categories: categories(bakery) }, top, mode: :partial, expires_at: 1.week.from_now)
      place.forge!
      expect(categories_of(place)).to contain_exactly(cafe, bakery)

      travel 8.days do
        place.reload.forge!
        expect(categories_of(place)).to eq([cafe])

        place.reload.record_data_entries({ place_categories: categories(florist) }, top, mode: :edit) # an edit to an expired member list starts afresh
        place.forge!
      end

      expect(categories_of(place)).to contain_exactly(cafe, florist)
    end

    it 'lets an expired tombstone and exclusion stop counting, so a source can bring the member back', capability: 'C183' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café'), tenant('T-2', name: 'Harbor Books')] }, low)
      place.forge!
      place.record_data_entries({ tenants: { exclude: [{ id: Tenant.find_by!(name: 'Corner Café').id }] } }, top, mode: :edit, expires_at: 1.week.from_now)
      place.forge!
      place.reload.record_data_entries({ tenants: [{ name: 'Corner Café' }, tenant('T-2')] }, low)
      place.forge!
      expect(Tenant.pluck(:name)).to eq(['Harbor Books'])

      travel 8.days do
        place.reload
        expect(LaForge.tombstone_blocking(place.tenants.build(name: 'Corner Café'), low)).to be_nil
        place.reload.forge!
        expect(place.reload.tenants.pluck(:name)).to contain_exactly('Harbor Books', 'Corner Café')
        expect(place.data_entries.tombstones(:tenants)).to be_empty
        expect(place.data_entries.membership_expiries(:tenants)) # the expired exclusion is kept, and names the tenant created again
          .to match([include(source_id: top.id, key: { 'id' => Tenant.find_by!(name: 'Corner Café').id }, expires_at: be_within(1.second).of(1.day.ago))])
      end
    end

    it 'expires a member list the next time the association is recorded from the source it expires on, whatever that source provides', capability: 'C184' do
      place.record_data_entries({ place_categories: categories(bakery) }, low, mode: :partial)
      place.record_data_entries({ place_categories: categories(cafe) }, high)
      place.record_data_entries({ place_categories: categories(bakery) }, top, mode: :partial, expires_on: high)
      place.forge!
      place.reload.record_data_entries({ name: 'Harbor Building' }, high) # another attribute
      place.forge!
      expect(categories_of(place)).to contain_exactly(cafe, bakery)

      place.reload.record_data_entries({ place_categories: categories(cafe) }, high) # the same list
      place.forge!

      expect(categories_of(place)).to eq([cafe])
      expect(place.data_entries.with_source(top).sole).to have_attributes(expires_at: be_within(1.minute).of(Time.current), expires_on_source: high)
    end

    it 'records what an expiring member list says about members with its expiry, so their attributes fall back with it', capability: 'C129' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!
      place.reload.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café & Bakery')] }, high, mode: :partial, expires_at: 1.week.from_now)
      place.forge!
      expect(Tenant.sole.name).to eq('Corner Café & Bakery')
      expect(Tenant.sole.data_entries.with_source(high).with_attribute(:name).sole.expires_at).to be_within(1.second).of(1.week.from_now)

      travel 8.days do
        Tenant.sole.forge!
      end

      expect(Tenant.sole.name).to eq('Corner Café')
      expect(Tenant.sole.data_entries.with_source(high).with_attribute(:name).sole.value).to eq('Corner Café & Bakery')
    end

    it "gives an edit's precedence and expiry to what it says about members and to its rule for the association, even when it edits no member", capability: 'C131' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!
      expires_at = 1.week.from_now
      place.reload.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café & Bakery')] }, high, mode: :edit, precedence: 5, expires_at: expires_at)
      place.forge!

      name = Tenant.sole.data_entries.with_source(high).with_attribute(:name).sole
      expect(name).to have_attributes(value: 'Corner Café & Bakery', expires_at: be_within(1.second).of(expires_at))
      expect(Tenant.sole.precedence_rules.find_by!(attribute_name: 'name')).to have_attributes(source_id: high.id, precedence: 5, expires_at: be_within(1.second).of(expires_at))
      expect(place.precedence_rules.find_by!(attribute_name: 'tenants')).to have_attributes(source_id: high.id, precedence: 5, expires_at: be_within(1.second).of(expires_at))
      expect(place.data_entries.with_source(high).sole.expires_at).to be_nil # the member list itself does not expire

      place.reload.record_data_entries({ place_categories: { include: [] } }, top, mode: :edit, precedence: 7, expires_on: low)
      expect(place.source_precedences['place_categories']).to eq(top => 7)
      expect(place.precedence_rules.find { |rule| rule.attribute_name == 'place_categories' }.expires_on_source_id).to eq(low.id)
    end

    it "gives a complete or partial list's precedence and expiry to the rules it sets on members", capability: 'C132' do
      expires_at = 1.week.from_now
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low, precedence: 5, expires_at: expires_at)
      place.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies, external_id: 'P-1')] }, high, mode: :partial, precedence: 6, expires_at: expires_at)
      place.forge!

      expect(Tenant.sole.precedence_rules.find_by!(attribute_name: 'name')).to have_attributes(source_id: low.id, precedence: 5, expires_at: be_within(1.second).of(expires_at))
      expect(parcel_link_row(place, lot_12, occupies).precedence_rules.find_by!(attribute_name: 'external_id'))
        .to have_attributes(source_id: high.id, precedence: 6, expires_at: be_within(1.second).of(expires_at))
    end

    it 'expires a change on a source at a recording from it made after the change, kept pending or not, but not at one made before', capability: 'C133' do
      renamed = -> { Tenant.sole.data_entries.with_source(top).sole }
      travel_to(Time.utc(2026, 1, 1)) { place.forge! { place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low) } }
      travel_to(Time.utc(2026, 2, 1)) { place.reload.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Cafe')] }, low) && place.save! } # kept pending
      travel_to(Time.utc(2026, 3, 1)) { Tenant.sole.then { |corner_cafe| corner_cafe.forge! { corner_cafe.record_data_entries({ name: 'Corner Café (renamed)' }, top, expires_on: low) } } }
      travel_to(Time.utc(2026, 4, 1)) { place.reload.forge! } # records the member list's pending items on the tenant

      expect(Tenant.sole.reload.name).to eq('Corner Café (renamed)')
      expect(renamed.call.expires_at).to be_nil

      travel_to(Time.utc(2026, 5, 1)) { place.reload.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Cafe')] }, low) && place.save! } # after the change
      travel_to(Time.utc(2026, 6, 1)) { place.reload.forge! }

      expect(Tenant.sole.reload.name).to eq('Corner Cafe')
      expect(renamed.call).to have_attributes(expires_at: Time.utc(2026, 5, 1), expires_on_source: low)
    end

    it 'keeps the unexpired entry when merging, and adds nothing from an expired member list', capability: 'C130' do
      duplicate = Place.create!(name: 'Harbor Bldg')
      place.forge! { place.record_data_entries({ name: 'Harbor Building', place_categories: categories(cafe) }, low) }
      duplicate.forge! { duplicate.record_data_entries({ name: 'Harbor Bldg', place_categories: categories(bakery) }, low, expires_at: 1.week.from_now) }

      travel 8.days do
        result = LaForge.merge(place, duplicate)
        expect(result[:entries_conflicting]).to eq([{ attribute: 'name', source: low, kept: :survivor }])
        place.forge!
      end

      expect(place.reload.name).to eq('Harbor Building')
      expect(categories_of(place)).to contain_exactly(cafe, bakery) # the duplicate's row moved, and no member list names it
      expect(place.data_entries.with_attribute(:place_categories).sole).to have_attributes(value: categories(cafe).map(&:stringify_keys), expires_at: nil)
    end
  end

  describe 'expiring members of edits' do
    def tenant_names = place.reload.tenants.pluck(:name)

    it "keeps each edited member's expiry apart, so editing another member leaves it, and expires each on its own", capability: 'C134' do
      import = -> { place.reload.forge! { place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café'), tenant('T-2', name: 'Harbor Books'), tenant('T-3', name: 'Florist')] }, low) } }
      travel_to(Time.utc(2026, 1, 1)) { import.call }
      corner_cafe = Tenant.find_by!(name: 'Corner Café')

      travel_to(Time.utc(2026, 1, 2)) { place.reload.forge! { place.record_data_entries({ tenants: { exclude: [corner_cafe] } }, top, mode: :edit, expires_at: Time.utc(2026, 3, 1)) } }
      travel_to(Time.utc(2026, 1, 3)) { place.reload.forge! { place.record_data_entries({ tenants: [tenant('T-2', unit: '2B')] }, top, mode: :edit) } } # permanent
      expect(place.reload.data_entries.membership_expiries(:tenants).map { |item| item[:expires_at] }).to eq([Time.utc(2026, 3, 1)])

      travel_to(Time.utc(2026, 1, 4)) { place.reload.forge! { place.record_data_entries({ tenants: [{ name: 'Bakery Pop-up' }] }, top, mode: :edit, expires_at: Time.utc(2026, 2, 1)) } }
      expect(tenant_names).to contain_exactly('Harbor Books', 'Florist', 'Bakery Pop-up')
      expect(place.data_entries.with_source(top).sole.expires_at).to be_nil # an edit's expiry is its members', not the member list's

      travel_to(Time.utc(2026, 2, 2)) { import.call }
      expect(tenant_names).to contain_exactly('Harbor Books', 'Florist') # the pop-up's inclusion has expired, so low's complete list excludes it
      expect(Tenant.find_by!(name: 'Harbor Books').unit).to eq('2B')

      travel_to(Time.utc(2026, 3, 2)) { import.call }
      expect(tenant_names).to contain_exactly('Corner Café', 'Harbor Books', 'Florist')
    end

    it "expires a member's inclusion or exclusion on the next recording from a source, and replaces or clears it when the member is edited again", capability: 'C135' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low, mode: :partial)
      place.record_data_entries({ place_categories: { exclude: categories(bakery), include: categories(florist) } }, top, mode: :edit, expires_on: low)
      place.save!
      place.forge!
      expect(categories_of(place)).to contain_exactly(cafe, florist)

      place.reload.record_data_entries({ place_categories: categories(cafe, bakery) }, low, mode: :partial) # the same member list, after the edit
      place.forge!
      expect(categories_of(place)).to contain_exactly(cafe, bakery, florist) # no member list includes the florist, and none excludes it
      expect(place.data_entries.membership_expiries(:place_categories).map { |item| item[:expires_at] }).to all(be_within(1.minute).of(Time.current))

      place.reload.record_data_entries({ place_categories: { exclude: categories(bakery) } }, top, mode: :edit, expires_at: 1.week.from_now)
      place.record_data_entries({ place_categories: { exclude: categories(bakery) } }, top, mode: :edit) # again, permanently
      place.forge!
      travel 8.days do
        place.reload.forge!
      end
      expect(categories_of(place)).to contain_exactly(cafe, florist)
      expect(place.data_entries.membership_expiries(:place_categories).map { |item| item[:key] }).to eq([{ 'category_id' => florist.id }])
    end

    it 'records nothing an expired inclusion said about a member, and keeps it pending in the member list', capability: 'C140' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!
      place.reload.record_data_entries({ tenants: [tenant('T-1', unit: '1A')] }, top, mode: :edit, expires_at: 1.week.from_now)
      place.save! # not forged before it expires

      travel 8.days do
        place.reload.forge!
      end

      expect(Tenant.sole.data_entries.with_source(top)).to be_empty
      expect(place.data_entries.with_source(top).sole.value['pending'].sole['attributes']).to include('unit' => '1A')
    end

    it "keeps a member's expiry when merging the member list it is in", capability: 'C142' do
      duplicate = Place.create!(name: 'Harbor Bldg')
      place.forge! { place.record_data_entries({ place_categories: categories(cafe, bakery) }, low, mode: :partial) }
      duplicate.forge! { duplicate.record_data_entries({ place_categories: { exclude: categories(bakery) } }, low, mode: :edit, expires_at: 1.week.from_now) }

      LaForge.merge(place, duplicate)

      expect(place.data_entries.membership_expiries(:place_categories)).to match([include(key: { 'category_id' => bakery.id }, expires_at: be_within(1.second).of(1.week.from_now))])
      place.forge!
      expect(categories_of(place)).to eq([cafe])
    end

    it "keeps a newer recording's expiry when a forge records the same value from an older member list kept pending on the owner", capability: 'C144' do
      travel_to(Time.utc(2026, 1, 1)) { place.forge! { place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low) } }
      corner_cafe = Tenant.sole
      travel_to(Time.utc(2026, 1, 2)) { place.reload.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low) && place.save! } # kept pending
      travel_to(Time.utc(2026, 1, 3)) { corner_cafe.reload.record_data_entries({ name: 'Corner Café' }, low, expires_at: Time.utc(2026, 6, 1)) && corner_cafe.save! }
      travel_to(Time.utc(2026, 1, 4)) { place.reload.forge! }

      expect(corner_cafe.reload.data_entries.with_source(low).with_attribute(:name).sole.expires_at).to eq(Time.utc(2026, 6, 1))
    end

    it 'counts a saved change made again, not saved yet, as made now, so a recording in the same save does not end it', capability: 'C145' do
      travel_to(Time.utc(2026, 1, 1)) { place.record_data_entries({ name: 'Harbor Hall' }, top, expires_on: low) && place.save! }
      travel_to(Time.utc(2026, 1, 2)) do
        place.record_data_entries({ name: 'Harbor Hall, renamed' }, top, expires_on: low) # made again
        place.record_data_entries({ name: 'Harbor Building' }, low) # at the same instant
        place.save!
      end

      expect(place.reload.data_entries.with_source(top).sole.expires_at).to be_nil
    end

    it "expires a member's saved exclusion on a source's member list though another member of the list was edited since", capability: 'C146' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low, mode: :partial)
      place.record_data_entries({ place_categories: { exclude: categories(bakery) } }, top, mode: :edit, expires_on: low)
      place.save!
      place.record_data_entries({ place_categories: categories(florist) }, top, mode: :edit) # another member, not saved yet
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low, mode: :partial)
      place.forge!

      expect(categories_of(place)).to contain_exactly(cafe, bakery, florist)
    end

    it 'gives a Rails form row its own settings when it is wrapped, included or destroyed', capability: 'C147' do
      corner_cafe, harbor_books = ['Corner Café', 'Harbor Books'].map { |name| place.tenants.create!(name: name) }
      expires_at = 1.week.from_now
      place.record_data_entries({ tenants_attributes: [LaForge.with_settings({ id: corner_cafe.id, unit: '2B' }, expires_at: expires_at),
                                                       LaForge.with_settings({ id: harbor_books.id, _destroy: '1' }, expires_at: expires_at)] }, top, mode: :edit)
      place.forge!

      expect(place.data_entries.membership_expiries(:tenants).map { |item| item[:key] }).to contain_exactly({ 'id' => corner_cafe.id }, { 'tombstone' => anything })
      expect(corner_cafe.reload.data_entries.with_source(top).with_attribute(:unit).sole.expires_at).to be_within(1.second).of(expires_at)
    end

    it 'counts a saved change renewed with only a new expiry, not saved yet, as made now', capability: 'C148' do
      corner_cafe = place.tenants.create!(name: 'Corner Café')
      travel_to(Time.utc(2026, 1, 1)) do
        corner_cafe.record_data_entries({ name: 'Corner Café' }, top, expires_on: low, expires_at: Time.utc(2026, 2, 1))
        corner_cafe.update_precedence_order(:name, [top], expires_on: low, expires_at: Time.utc(2026, 2, 1))
        corner_cafe.save!
      end
      travel_to(Time.utc(2026, 1, 15)) do
        corner_cafe.record_data_entries({ name: 'Corner Café' }, top, expires_on: low, expires_at: Time.utc(2026, 3, 1)) # renewed
        corner_cafe.update_precedence_order(:name, [top], expires_on: low, expires_at: Time.utc(2026, 3, 1))
        corner_cafe.record_data_entries({ name: 'Corner Café' }, low) # at the same instant
        corner_cafe.save!
      end

      expect([corner_cafe.data_entries.with_source(top).sole.expires_at, corner_cafe.precedence_rules.sole.expires_at]).to eq([Time.utc(2026, 3, 1)] * 2)
    end

    it 'counts a saved change recorded again as it was saved, after its expiry on a source fired and before the save, as made now', capability: 'C176' do
      corner_cafe = place.tenants.create!(name: 'Corner Café')
      travel_to(Time.utc(2026, 1, 1)) do
        corner_cafe.record_data_entries({ name: 'Corner Café' }, top, precedence: 100, expires_on: low)
        corner_cafe.save!
      end
      travel_to(Time.utc(2026, 1, 15)) do
        corner_cafe.record_data_entries({ name: 'Corner Cafe' }, low) # fires the expiries, not saved yet
        corner_cafe.record_data_entries({ name: 'Corner Café' }, top, precedence: 100, expires_on: low) # renewed, as saved
        corner_cafe.record_data_entries({ name: 'Corner Cafe' }, low) # at the same instant
        corner_cafe.save!
      end

      expect([corner_cafe.data_entries.with_source(top).sole.expires_at, corner_cafe.precedence_rules.sole.expires_at]).to eq([nil, nil])
    end

    it "expires a change recorded from a member list's pending items on the source's later list, both replayed by one forge", capability: 'C149' do
      travel_to(Time.utc(2026, 1, 1)) { place.forge! { place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low) } }
      travel_to(Time.utc(2026, 1, 2)) { place.reload.record_data_entries({ tenants: [tenant('T-1', unit: LaForge.with_settings('1A', expires_on: low))] }, high, mode: :partial) && place.save! }
      travel_to(Time.utc(2026, 1, 3)) { place.reload.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: '2B')] }, low) && place.save! }
      travel_to(Time.utc(2026, 1, 4)) { place.reload.forge! }

      expect(Tenant.sole.data_entries.with_source(high).with_attribute(:unit).sole.expires_at).to eq(Time.utc(2026, 1, 3))
      expect(Tenant.sole.unit).to eq('2B')
    end

    it "expires a precedence recorded from a member list's pending items on the source's later list, both replayed by one forge", capability: 'C152' do
      travel_to(Time.utc(2026, 1, 1)) { place.forge! { place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low) } }
      travel_to(Time.utc(2026, 1, 2)) { place.reload.record_data_entries({ tenants: [tenant('T-1', unit: LaForge.with_settings('1A', precedence: 100, expires_on: low))] }, high, mode: :partial) && place.save! }
      travel_to(Time.utc(2026, 1, 3)) { place.reload.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: '2B')] }, low) && place.save! }
      travel_to(Time.utc(2026, 1, 4)) { place.reload.forge! }

      expect(Tenant.sole.precedence_rules.find_by!(attribute_name: 'unit', source: high).expires_at).to eq(Time.utc(2026, 1, 3))
    end

    it "expires a saved member list on a recording from the source it expires on, though an unsaved forge since cleared what it kept pending", capability: 'C154' do
      travel_to(Time.utc(2026, 1, 1)) { place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, high, expires_on: low) && place.save! }
      travel_to(Time.utc(2026, 1, 2)) do
        place.reload.forge # records Corner Café's pending item on the tenant and clears it from the member list, without saving
        place.record_data_entries({ tenants: [tenant('T-2', name: 'Harbor Books')] }, low)
        place.forge!
      end

      expect(place.data_entries.with_source(high).sole.expires_at).to eq(Time.utc(2026, 1, 2))
      expect(place.reload.tenants.map(&:name)).to include('Harbor Books') # high's complete list has expired, so it does not exclude it
    end

    it "expires a change recorded from a member list's pending items, and saved, on the source's list made after it and replayed by a later forge", capability: 'C155' do
      travel_to(Time.utc(2026, 1, 1)) { place.forge! { place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low) } }
      travel_to(Time.utc(2026, 1, 2)) { place.reload.record_data_entries({ tenants: [tenant('T-1', unit: LaForge.with_settings('1A', expires_on: low))] }, high, mode: :partial) && place.save! }
      travel_to(Time.utc(2026, 1, 3)) { place.reload.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: '2B')] }, low) && place.save! }
      travel_to(Time.utc(2026, 1, 4)) do
        low.update!(active: false)
        place.reload.forge! # records high's unit, made January 2
      end
      travel_to(Time.utc(2026, 1, 5)) do
        low.update!(active: true)
        place.reload.forge! # records low's member list of January 3
      end

      expect(Tenant.sole.data_entries.with_source(high).with_attribute(:unit).sole.expires_at).to eq(Time.utc(2026, 1, 3))
      expect(Tenant.sole.unit).to eq('2B')
    end

    it "expires a precedence recorded from a member list's pending items, and saved, on the source's list made after it and replayed by a later forge", capability: 'C174' do
      travel_to(Time.utc(2026, 1, 1)) { place.forge! { place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low) } }
      travel_to(Time.utc(2026, 1, 2)) { place.reload.record_data_entries({ tenants: [tenant('T-1', unit: LaForge.with_settings('1A', precedence: 100, expires_on: low))] }, high, mode: :partial) && place.save! }
      travel_to(Time.utc(2026, 1, 3)) { place.reload.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: '2B')] }, low) && place.save! }
      travel_to(Time.utc(2026, 1, 4)) do
        low.update!(active: false)
        place.reload.forge! # records high's unit and precedence, made January 2
      end
      travel_to(Time.utc(2026, 1, 5)) do
        low.update!(active: true)
        place.reload.forge! # records low's member list of January 3
      end

      expect(Tenant.sole.data_entries.with_source(high).with_attribute(:unit).sole.expires_at).to eq(Time.utc(2026, 1, 3))
      expect(Tenant.sole.precedence_rules.find_by!(attribute_name: 'unit', source: high)).to have_attributes(recorded_at: Time.utc(2026, 1, 2), expires_at: Time.utc(2026, 1, 3))
    end

    it "expires a change recorded from a member list's pending items on a recording from the source on the member, made after the list and saved before the forge", capability: 'C177' do
      travel_to(Time.utc(2026, 1, 1)) { place.forge! { place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: '1A')] }, low) } }
      corner_cafe = Tenant.sole
      travel_to(Time.utc(2026, 1, 2)) do
        until_low = ->(value) { LaForge.with_settings(value, precedence: 100, expires_on: low) }
        place.reload.record_data_entries({ tenants: [tenant('T-1', unit: until_low.('1B'), opening_hours: until_low.([]))] }, high, mode: :edit)
        place.save! # kept pending
      end
      travel_to(Time.utc(2026, 1, 3)) { corner_cafe.forge! { corner_cafe.record_data_entries({ unit: '2B', opening_hours: week('08:00', days: [1]) }, low) } }
      travel_to(Time.utc(2026, 1, 4)) { place.reload.forge! } # records high's unit, made January 2

      expect(corner_cafe.reload.data_entries.with_source(high).with_attribute(:unit).sole.expires_at).to eq(Time.utc(2026, 1, 3))
      expect(corner_cafe.precedence_rules.where(source: high).pluck(:attribute_name, :expires_at)).to contain_exactly(['unit', Time.utc(2026, 1, 3)], ['opening_hours', Time.utc(2026, 1, 3)])
      expect(corner_cafe.unit).to eq('2B')
      expect(corner_cafe.data_entries.with_source(low).with_attribute(:unit).sole).to have_attributes(value: '2B', recorded_at: Time.utc(2026, 1, 3))
    end

    it "expires a saved exclusion on a recording from the source it expires on, though an unsaved forge since renamed its member to a tombstone", capability: 'C178' do
      travel_to(Time.utc(2026, 1, 1)) { place.forge! { place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low) } }
      travel_to(Time.utc(2026, 1, 2)) { place.reload.record_data_entries({ tenants: { exclude: [Tenant.sole] } }, top, mode: :edit, expires_on: low) && place.save! }
      travel_to(Time.utc(2026, 1, 3)) do
        place.reload.forge # destroys the tenant on save and names it by a tombstone, without saving
        place.record_data_entries({ tenants: [tenant('T-2', name: 'Harbor Books')] }, low)
        place.forge!
      end

      expect(place.reload.data_entries.membership_expiries(:tenants)).to match([include(key: { 'tombstone' => anything }, expires_at: Time.utc(2026, 1, 3))])
    end

    it "raises at recording for settings around a nested member's key, and takes them around a nested list or its members", capability: 'C179' do
      expires_at = 1.week.from_now
      keyed = [{ day: LaForge.with_settings(1, expires_at: expires_at), opens_at: '08:00' }]
      %i[complete edit].each do |mode|
        expect { place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', opening_hours: keyed)] }, low, mode: mode) }
          .to raise_error(ArgumentError, /LaForge.with_settings around day, part of a member's key, which cannot carry settings/)
      end

      hours = [LaForge.with_settings({ day: 1, opens_at: '08:00' }, expires_at: expires_at), { day: 2, opens_at: LaForge.with_settings('09:00', expires_at: expires_at) }]
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', opening_hours: hours), tenant('T-2', name: 'Harbor Books', opening_hours: LaForge.with_settings(week('10:00'), expires_at: expires_at))] }, low)
      place.forge!
      expect(Tenant.find_by!(external_id: 'T-1').opening_hours.pluck(:day, :opens_at)).to eq([[1, '08:00'], [2, '09:00']])
    end

    it "forges a member list's pending items whose expiry names a source deleted since, keeping the expiry at a time", capability: 'C180' do
      geocoder = LaForge::DataSource.create!(name: 'geocoder', precedence: 5)
      expires_at = 1.week.from_now
      unit = LaForge.with_settings('1A', precedence: 100, expires_on: geocoder, expires_at: expires_at)
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: unit)] }, top, expires_on: geocoder)
      place.save! # kept pending
      geocoder.destroy!

      place.reload.forge!

      corner_cafe = Tenant.sole
      expect(corner_cafe.data_entries.with_source(top).pluck(:attribute_name, :expires_at, :expires_on_source_id))
        .to contain_exactly(['external_id', nil, nil], ['name', nil, nil], ['unit', be_within(1.second).of(expires_at), nil])
      expect(corner_cafe.precedence_rules.sole).to have_attributes(precedence: 100, expires_at: be_within(1.second).of(expires_at), expires_on_source_id: nil)
    end

    it "expires the precedence of a nested list edit recorded from a member list's pending items, empty or not, on the source's later list, both replayed by one forge", capability: 'C175' do
      travel_to(Time.utc(2026, 1, 1)) { place.forge! { place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café'), tenant('T-2', name: 'Harbor Books')] }, low) } }
      travel_to(Time.utc(2026, 1, 2)) do
        hours = ->(list) { LaForge.with_settings(list, precedence: 100, expires_on: low) }
        place.reload.record_data_entries({ tenants: [tenant('T-1', opening_hours: hours.(week('09:00', days: [1]))), tenant('T-2', opening_hours: hours.([]))] }, high, mode: :edit)
        place.save!
      end
      travel_to(Time.utc(2026, 1, 3)) do
        place.reload.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', opening_hours: week('08:00')), tenant('T-2', name: 'Harbor Books', opening_hours: week('08:00'))] }, low)
        place.save!
      end
      travel_to(Time.utc(2026, 1, 4)) { place.reload.forge! }

      rules = Tenant.order(:external_id).map { |member| member.precedence_rules.find_by!(attribute_name: 'opening_hours', source: high) }
      expect(rules.map(&:expires_at)).to eq([Time.utc(2026, 1, 3)] * 2)
    end

    it 'raises for settings given to ids inside a *_ids field, which the field takes as a whole', capability: 'C150' do
      expect { place.record_data_entries({ category_ids: [LaForge.with_settings(cafe.id, expires_at: 1.week.from_now)] }, top, mode: :edit) }
        .to raise_error(ArgumentError, /Recording Place#category_ids: LaForge.with_settings can wrap an attribute's whole value, a member or a nested list, not part of a value/)
      expect { place.record_data_entries({ category_ids: LaForge.with_settings([cafe.id], expires_at: 1.week.from_now) }, top, mode: :edit) }.not_to raise_error
    end

    it 'raises for an exclusion with an expiry from a source with a complete list', capability: 'C136' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)

      expect { place.record_data_entries({ place_categories: { exclude: categories(bakery) } }, low, mode: :edit, expires_at: 1.week.from_now) }
        .to raise_error(ArgumentError, /the source has a complete list, which excludes category_id #{bakery.id} by leaving it out, and leaving a member out cannot expire. Record the member list with mode: :partial/)
    end
  end

  describe 'settings for part of a payload' do
    let(:other_place) { Place.create!(name: 'Harbor Building') }

    def snapshot(record)
      record.reload
      rows = ->(entries) { entries.map { |entry| [entry.attribute_name, entry.source_id, entry.expires_at, entry.expires_on_source_id] }.sort_by(&:to_s) }
      tenants = record.tenants.order(:name).map { |member| [member.name, member.unit, rows.(member.data_entries)] }
      expiries = record.data_entries.membership_expiries(:tenants).map { |item| [item[:source_id], item[:expires_at], item[:expires_on_source_id]] }.sort_by(&:to_s)
      [record.name, tenants, rows.(record.data_entries), expiries]
    end

    it 'records one call with mixed settings as the same calls split by settings would', capability: 'C137' do
      x = Time.utc(2026, 3, 1)
      y = Time.utc(2026, 2, 1)
      travel_to(Time.utc(2026, 1, 1)) do
        [[place, 'P'], [other_place, 'O']].each do |record, prefix|
          record.forge! { record.record_data_entries({ tenants: [{ external_id: "#{prefix}-1", name: 'Corner Café' }, { external_id: "#{prefix}-2", name: 'Harbor Books' }] }, low) }
        end
        corner_cafe, harbor_books = place.reload.tenants.order(:external_id).to_a
        place.forge! do
          place.record_data_entries({ name: LaForge.with_settings('Harbor Building (temporary)', expires_on: low),
                                      tenants: { include: [{ id: harbor_books.id, unit: '2B' }, LaForge.with_settings({ name: 'Bakery Pop-up' }, expires_at: y)],
                                                 exclude: [LaForge.with_settings({ id: corner_cafe.id }, expires_at: x)] } }, top, mode: :edit)
        end

        corner_cafe, harbor_books = other_place.reload.tenants.order(:external_id).to_a
        other_place.forge! do
          other_place.record_data_entries({ name: 'Harbor Building (temporary)' }, top, expires_on: low)
          other_place.record_data_entries({ tenants: [{ id: harbor_books.id, unit: '2B' }] }, top, mode: :edit)
          other_place.record_data_entries({ tenants: [{ name: 'Bakery Pop-up' }] }, top, mode: :edit, expires_at: y)
          other_place.record_data_entries({ tenants: { exclude: [{ id: corner_cafe.id }] } }, top, mode: :edit, expires_at: x)
        end
      end

      expect(snapshot(place)).to eq(snapshot(other_place))
      expect(snapshot(place).last.map(&:second)).to contain_exactly(x, y)
    end

    it 'gives a nested list and a member attribute their own settings, through the member list kept pending on the owner', capability: 'C138' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', unit: LaForge.with_settings('1A', expires_at: 1.week.from_now),
                                                   opening_hours: LaForge.with_settings(week('08:00', days: [1]), expires_on: high))] }, low)
      place.save!
      expect(place.data_entries.sole.value['pending'].sole['attributes']['unit']).to include('_laforge_settings', 'value' => '1A') # kept with its settings, in a form JSON can hold
      place.forge!
      corner_cafe = Tenant.sole

      expect(corner_cafe.data_entries.with_attribute(:unit).sole.expires_at).to be_within(1.second).of(1.week.from_now)
      expect(corner_cafe.data_entries.with_attribute(:name).sole.expires_at).to be_nil
      expect(corner_cafe.data_entries.with_attribute(:opening_hours).sole.expires_on_source).to eq(high)
    end

    it 'gives a member of a list recorded whole an expiry of its own, after which a complete list excludes it', capability: 'C141' do
      place.record_data_entries({ place_categories: [*categories(cafe), LaForge.with_settings({ category_id: bakery.id }, expires_at: 1.week.from_now)] }, low)
      place.forge!
      expect(categories_of(place)).to contain_exactly(cafe, bakery)
      expect(place.data_entries.sole.expires_at).to be_nil

      travel 8.days do
        place.reload.forge!
      end

      expect(categories_of(place)).to eq([cafe])
    end

    it 'raises, saying where, for settings it cannot give', capability: 'C139' do
      corner_cafe = place.tenants.create!(name: 'Corner Café')
      later = 1.week.from_now

      expect { place.record_data_entries({ tenants: { exclude: [LaForge.with_settings({ id: corner_cafe.id }, precedence: 9)] } }, top, mode: :edit) }
        .to raise_error(ArgumentError, /Place#tenants: LaForge.with_settings\(precedence:\) around id #{corner_cafe.id}, which has no attributes, would rank the source for the whole association/)
      expect { place.record_data_entries({ tenants: [{ name: 'Florist', street: LaForge.with_settings('1 Quay', expires_at: later), postcode: 'H1' }] }, top, mode: :edit) }
        .to raise_error(ArgumentError, /Tenant members of Place#tenants: street, postcode are attribute group postal_address, whose values from a source are recorded together with the same settings/)
      expect { place.record_data_entries({ place_categories: [{ category_id: LaForge.with_settings(cafe.id, expires_at: later) }] }, top) }
        .to raise_error(ArgumentError, /Place#place_categories: LaForge.with_settings around category_id, part of a member's key, which cannot carry settings; wrap the whole member instead/)
      expect { place.record_data_entries({ name: ['Harbor', LaForge.with_settings('Building', expires_at: later)] }, top) }
        .to raise_error(ArgumentError, /Recording Place#name: LaForge.with_settings can wrap an attribute's whole value, a member or a nested list, not part of a value/)
      expect { place.record_data_entries({ name: LaForge.with_settings('Harbor Building', expires_on: top) }, top) }
        .to raise_error(ArgumentError, /Recording Place: LaForge.with_settings\(expires_on:\) names the source this value comes from/)
      expect { place.record_data_entries({ tenants: { include: LaForge.with_settings([{ name: 'Florist' }], expires_at: later) } }, top, mode: :edit) }
        .to raise_error(ArgumentError, /Place#tenants: LaForge.with_settings can wrap each member, or the association's whole value, not the include list/)
      expect { place.record_data_entries({ tenants: { forget: [LaForge.with_settings({ id: corner_cafe.id }, expires_at: later)] } }, top, mode: :edit) }
        .to raise_error(ArgumentError, /forgetting a member takes no settings/)
      expect { LaForge.with_settings(LaForge.with_settings('Harbor Building'), expires_at: later) }.to raise_error(ArgumentError, /already wrapped/)
      expect { LaForge.with_settings('Harbor Building', expires_at: '2030-01-01') }.to raise_error(ArgumentError, /LaForge.with_settings: expires_at: must be a time/)
    end

    it "raises for a recorded hash using the key LaForge reserves for settings in a member list's pending items", capability: 'C153' do
      reserved = { '_laforge_settings' => {}, 'value' => 'Harbor Hall', 'other' => 1 }

      expect { place.record_data_entry(:name, reserved, top) }.to raise_error(ArgumentError, /Recording Place: _laforge_settings is a key LaForge reserves/)
      expect { place.record_data_entries({ name: { 'names' => [{ _laforge_settings: 1 }] } }, top) }.to raise_error(ArgumentError, /Recording Place: _laforge_settings is a key LaForge reserves/)
      expect { place.record_data_entries({ tenants: [tenant('T-1', name: reserved)] }, low) }.to raise_error(ArgumentError, /Recording Place: _laforge_settings is a key LaForge reserves/)
      expect(place.data_entries).to be_empty
    end
  end

  describe 'has_one' do
    it 'forges the single member from every source that lists it, updating the same row on later runs', capability: 'C57' do
      place.record_data_entries({ marker: { label: 'Harbor', icon: 'pin' } }, low)
      place.record_data_entries({ marker: { label: 'Harbor Building' } }, high)
      place.forge!
      marker_id = place.reload.marker.id
      expect(place.marker).to have_attributes(label: 'Harbor Building', icon: 'pin')

      place.record_data_entries({ marker: { label: 'Harbor', icon: 'star' } }, low)
      place.forge!

      expect(place.reload.marker).to have_attributes(id: marker_id, label: 'Harbor Building', icon: 'star')
    end

    it 'removes the member when the winning source lists none, writing nothing until the owner is saved', capability: 'C58' do
      place.record_data_entries({ marker: { label: 'Harbor' } }, low)
      place.forge!

      place.record_data_entries({ marker: nil }, high)
      place.forge
      expect(place.marker).to be_nil
      expect(Marker.count).to eq(1)

      place.save!
      expect(Marker.count).to eq(0) # noted: destroyed per `dependent: :destroy`
    end

    it 'discards a member a forge built, not saved yet, when a later forge before the save removes it', capability: 'C127' do
      stub_const('DetachingPlace', Class.new(ActiveRecord::Base))
      DetachingPlace.table_name = 'places'
      DetachingPlace.has_one :marker, as: :markable # no `dependent:`, so removal nullifies
      DetachingPlace.laforged(associations: { marker: {} })
      detaching_place = DetachingPlace.create!(name: 'Harbor Building')

      detaching_place.record_data_entries({ marker: { label: 'Harbor' } }, low)
      detaching_place.forge # builds the marker, unsaved
      detaching_place.record_data_entries({ marker: nil }, low)
      detaching_place.forge!

      expect(Marker.count).to eq(0)
      expect(detaching_place.reload.marker).to be_nil
    end

    it 'validates the member when the owner is saved, as Rails does for an autosaved has_one', capability: 'C167' do
      stub_const('LeasedPlace', Class.new(ActiveRecord::Base))
      LeasedPlace.table_name = 'places'
      LeasedPlace.has_one :tenant, as: :occupiable # Tenant validates its name
      LeasedPlace.laforged(associations: { tenant: { key: :external_id } })
      leased_place = LeasedPlace.create!(name: 'Harbor Building')

      leased_place.record_data_entries({ tenant: { external_id: 'T-1', name: '' } }, low)

      expect { leased_place.forge! }.to raise_error(ActiveRecord::RecordInvalid, /Tenant name can't be blank/)
      expect(Tenant.count).to eq(0)
    end

    it 'rejects more than one member and partial lists', capability: 'C59' do
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

      place.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies)] }, low)
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

    it 'rejects a has_and_belongs_to_many at declaration, as its members are linked through a join table', capability: 'C123' do
      stub_const('ListedPlace', Class.new(ActiveRecord::Base))
      ListedPlace.table_name = 'places'
      ListedPlace.has_and_belongs_to_many :categories, join_table: 'place_categories', foreign_key: :place_id

      expect { ListedPlace.laforged(associations: { categories: {} }) }
        .to raise_error(ArgumentError, /ListedPlace#categories must be a has_many or has_one without :through; track its join association instead/)
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

  describe 'inspection' do
    it "returns each source's members for a record", capability: 'C31' do
      place.record_data_entries({ place_categories: categories(cafe, bakery) }, low)
      place.record_data_entries({ place_categories: categories(bakery, florist) }, high)
      place.forge!

      values = place.reload.source_values(:place_categories)

      expect(values.transform_values { |members| members.map { |member| member['category_id'] } })
        .to eq(low => [cafe.id, bakery.id], high => [bakery.id, florist.id])
    end

    it "returns only members the tracked association's scope includes", capability: 'C118' do
      link = ParcelLink.create!(place: place, parcel: lot_12, parcel_link_type: computed) # outside provided_parcel_links
      link.record_data_entries({ external_id: 'C-1' }, low)
      link.save!

      expect(place.source_values(:provided_parcel_links)).to eq({})
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

    it "shows which source's member list decided a member's membership, and which source provided each member attribute", capability: 'C33' do
      place.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies, active: false)] }, low)
      place.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies, external_id: 'H-1')] }, high)
      place.forge!

      provenance = place.member_sources(:provided_parcel_links, parcel_id: lot_12.id, parcel_link_type_id: occupies.id)

      expect(provenance[:membership]).to eq(high)
      expect(provenance[:listed_by]).to contain_exactly(low, high)
      expect(provenance[:attributes]).to eq('active' => low, 'external_id' => high)
    end

    it 'shows added, removed and changed members in forge_diff without writing', capability: 'C34' do
      place.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies, active: false), parcel_link(lot_14, occupies)] }, low)
      place.forge!

      place.reload.record_data_entries({ provided_parcel_links: [parcel_link(lot_12, occupies, active: false, external_id: 'H-1'), parcel_link(lot_12, leases)] }, low)
      diff = place.forge_diff['provided_parcel_links']

      expect(diff[:added]).to eq([{ 'parcel_id' => lot_12.id, 'parcel_link_type_id' => leases.id }])
      expect(diff[:removed]).to eq([{ 'parcel_id' => lot_14.id, 'parcel_link_type_id' => occupies.id }])
      expect(diff[:changed]).to eq([{ 'parcel_id' => lot_12.id, 'parcel_link_type_id' => occupies.id, 'external_id' => [nil, 'H-1'] }])
      expect(place.provided_parcel_links.flat_map { |row| row.data_entries.target }.map { |entry| [entry.attribute_name, entry.value, entry.changed?] }).to eq([['active', false, false]])
      expect(place.reload.parcel_links.count).to eq(2)
    end
  end

  describe 'integration with attribute tracking' do
    it "leaves no precedence rule behind on a member after forge_diff previews a member list's precedence", capability: 'C109' do
      place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
      place.forge!
      place.reload.record_data_entries({ tenants: [tenant('T-1', unit: '2B')] }, low, precedence: 50)

      place.forge_diff
      place.update!(name: 'Harbor Building, renamed') # a save without forging
      expect(LaForge::PrecedenceRule.where(record_type: 'Tenant')).to be_empty

      place.forge!
      expect(LaForge::PrecedenceRule.where(record_type: 'Tenant').pluck(:attribute_name, :precedence)).to include(['unit', 50])
      expect(Tenant.sole.unit).to eq('2B')
    end

    it 'previews only the associations forge_diff is given, as forge forges only those', capability: 'C115' do
      place.record_data_entries({ name: 'Harbor Hall', place_categories: categories(cafe) }, low)

      expect(place.forge_diff(attributes: :name).keys).to eq(['name'])
      expect(place.forge_diff(attributes: :place_categories).keys).to eq(['place_categories'])
    end

    it "leaves a member's waiting expiries as they were after forge_diff previews a member list from the source they expire on", capability: 'C143' do
      travel_to(Time.utc(2026, 1, 1)) { place.forge! { place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low) } }
      travel_to(Time.utc(2026, 1, 2)) do
        corner_cafe = Tenant.sole
        corner_cafe.record_data_entries({ name: 'Corner Café (renamed)' }, top, expires_on: low)
        corner_cafe.update_precedence_order(:name, [top], expires_on: low)
        corner_cafe.save!
      end
      waiting = -> { [Tenant.sole.data_entries.with_source(top).sole.expires_at, Tenant.sole.precedence_rules.sole.expires_at] }

      travel_to(Time.utc(2026, 1, 3)) do
        place.reload.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café')] }, low)
        place.forge_diff
        place.update!(name: 'Harbor Building, renamed') # a save without forging
        expect(waiting.call).to eq([nil, nil])

        place.forge!
        expect(waiting.call).to eq([Time.utc(2026, 1, 3), Time.utc(2026, 1, 3)])
      end
    end

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
    describe 'an owner key other than id' do
      # Returns a place model whose tenants and marker point at its `number` rather than its id. The marker's model
      # declares the same `primary_key:`, as Rails needs for its save to keep the link.
      def numbered_place_model
        stub_const('NumberedMarker', Class.new(ActiveRecord::Base))
        NumberedMarker.table_name = 'markers'
        NumberedMarker.belongs_to :markable, polymorphic: true, primary_key: :number
        stub_const('NumberedPlace', Class.new(ActiveRecord::Base))
        NumberedPlace.table_name = 'places'
        NumberedPlace.has_many :tenants, as: :occupiable, primary_key: :number, dependent: :destroy
        NumberedPlace.has_one :marker, as: :markable, primary_key: :number, class_name: 'NumberedMarker', dependent: :destroy
        NumberedPlace.laforged(associations: { tenants: { key: :external_id }, marker: {} })
        NumberedPlace
      end

      let(:numbered_place) { numbered_place_model.create!(name: 'Harbor Building', number: 9_001) }

      it "links a has_one member a forge builds to the owner's `primary_key:` column", capability: 'C169' do
        numbered_place.record_data_entries({ marker: { label: 'Harbor' } }, low)
        numbered_place.forge

        expect(numbered_place.marker.markable_id).to eq(9_001)
        numbered_place.save!
        expect(numbered_place.reload.marker.label).to eq('Harbor')
      end

      it "forges a has_many whose members point at the owner's `primary_key:` column", capability: 'C170' do
        numbered_place.record_data_entries({ tenants: [{ external_id: 'T-1', name: 'Corner Café' }, { external_id: 'T-2', name: 'Harbor Books' }] }, low)
        numbered_place.forge!
        numbered_place.record_data_entries({ tenants: [{ external_id: 'T-2', name: 'Harbor Books' }] }, low)
        numbered_place.forge!

        expect(Tenant.where(occupiable_type: 'NumberedPlace', occupiable_id: 9_001).pluck(:external_id)).to eq(['T-2'])
        expect(numbered_place.reload.tenants.pluck(:external_id)).to eq(['T-2'])
      end

      it "reads members by the owner's `primary_key:` column in source_values and member_sources", capability: 'C171' do
        numbered_place.record_data_entries({ tenants: [{ external_id: 'T-1', name: 'Corner Café' }] }, low)
        numbered_place.forge!
        corner_cafe = numbered_place.tenants.sole
        corner_cafe.record_data_entries({ unit: '2B' }, high) # a source with entries on the member and no member list
        corner_cafe.save!

        values = numbered_place.reload.source_values(:tenants)
        expect(values[low]).to eq([{ 'external_id' => 'T-1', 'name' => 'Corner Café' }])
        expect(values[high]).to eq([{ 'external_id' => 'T-1', 'unit' => '2B' }])
        expect(numbered_place.member_sources(:tenants, external_id: 'T-1')).to include(membership: low, listed_by: [low], attributes: { 'name' => low, 'unit' => high })
      end

      it 'raises for a composite owner key, naming the association and the option', capability: 'C172' do
        stub_const('CompositePlace', Class.new(ActiveRecord::Base))
        CompositePlace.table_name = 'places'
        CompositePlace.has_many :tenants, as: :occupiable, primary_key: %i[id number], foreign_key: %i[occupiable_id external_id]

        expect { CompositePlace.laforged(associations: { tenants: {} }) }
          .to raise_error(ArgumentError, /CompositePlace#tenants links its members by a composite key \(primary_key: \[:id, :number\]\), which LaForge does not track. Track an association linked by one owner column/)
      end
    end

    it 'derives join model keys from the association reflection', capability: 'C39' do
      expect(Place.laforge.association(:place_categories).key).to eq(%w[category_id])
      expect(Place.laforge.association(:provided_parcel_links).key).to eq(%w[parcel_id parcel_link_type_id])
    end

    it 'raises for a method the model already defines that would hide LaForge\'s, and lets one defined after it wrap LaForge\'s', capability: 'C98' do
      stub_const('CollidingPlace', Class.new(ActiveRecord::Base))
      CollidingPlace.table_name = 'places'
      CollidingPlace.define_method(:source_values) { |*| :own }
      CollidingPlace.define_singleton_method(:source_precedences) { :own }
      expect { CollidingPlace.laforged }.to raise_error(ArgumentError, /CollidingPlace already defines #source_values, .source_precedences, which would hide LaForge's of the same name. Rename CollidingPlace's methods, or, to wrap LaForge's and call super, define them after `laforged`/)

      stub_const('WrappingPlace', Class.new(ActiveRecord::Base))
      WrappingPlace.table_name = 'places'
      WrappingPlace.laforged
      WrappingPlace.define_method(:forge) { |**options| super(**options).tap { @wrapped = true } }
      wrapping_place = WrappingPlace.create!(name: 'Harbor Building')
      wrapping_place.forge
      expect(wrapping_place.instance_variable_get(:@wrapped)).to be(true)
      wrapping_place.remove_instance_variable(:@wrapped)
      wrapping_place.forge!
      expect(wrapping_place.instance_variable_get(:@wrapped)).to be(true)
      expect { WrappingPlace.laforged }.not_to raise_error # declaring again finds LaForge's own methods
    end

    it "keys a join member by a polymorphic reference's type as well as its id", capability: 'C119' do
      stub_const('PinnedPlace', Class.new(ActiveRecord::Base))
      PinnedPlace.table_name = 'places'
      PinnedPlace.has_many :pins, class_name: 'ActiveRecordMock', foreign_key: :parent_id # each pin references a subject of any model
      PinnedPlace.laforged(associations: { pins: {} })
      pinned_place = PinnedPlace.create!(name: 'Harbor Building')
      ActiveRecordMock.where(parent_id: pinned_place.id).delete_all # rows other specs left pointing at this id

      expect(PinnedPlace.laforge.association(:pins).key).to eq(%w[subject_id subject_type])
      pinned_place.record_data_entries({ pins: [{ subject_id: 1, subject_type: 'Category' }, { subject_id: 1, subject_type: 'Parcel' }] }, low)
      pinned_place.forge!
      expect(ActiveRecordMock.where(parent_id: pinned_place.id).pluck(:subject_type, :subject_id)).to contain_exactly(['Category', 1], ['Parcel', 1])
    end

    it 'keys owned records by primary key unless key: names other columns', capability: 'C40' do
      expect(Place.laforge.association(:tenants).key).to eq(%w[id])
      expect(Tenant.laforge.association(:opening_hours).key).to eq(%w[day])
      expect(Place.laforge.association(:marker).key).to eq([]) # a has_one's single member
    end

    it 'never derives an order column that identifies the member or its owner, so forging keeps their ids', capability: 'C107' do
      stub_const('LinkedPlace', Class.new(ActiveRecord::Base))
      LinkedPlace.table_name = 'places'
      LinkedPlace.has_many :parcel_links, -> { order(:id) }, foreign_key: :place_id # keyed by parcel and type, ordered by id
      LinkedPlace.laforged(associations: { parcel_links: {} })
      linked_place = LinkedPlace.create!(name: 'Harbor Building')
      ParcelLink.create!(place: Place.create!(name: 'Other Building'), parcel: lot_12, parcel_link_type: leases) # holds a low id
      links = [lot_12, lot_14].map { |parcel| ParcelLink.create!(place_id: linked_place.id, parcel: parcel, parcel_link_type: occupies) }

      expect(LinkedPlace.laforge.association(:parcel_links).order_column).to be_nil
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

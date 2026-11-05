require 'spec_helper'

# A change on a member's attribute can be recorded in two ways: on the owner's member list, as a pending item a forge
# of the owner replays onto the member, or on the member directly. Each example runs both ways, with the same recordings
# from the `expires_on:` source on the member before the owner's forge. Replay should give what recording directly
# gives, and `pending` marks where it doesn't yet (see "Recordings on a member before its owner is forged" in the
# README). Dates are in January 2026.
describe 'Recordings on a member before its owner is forged' do
  include ActiveSupport::Testing::TimeHelpers

  # Defines an example for each way of recording the change. `replay_gap` names what replay gets wrong.
  def self.each_way(description, replay_gap: nil, &body)
    %i[replayed direct].each do |how|
      it "#{description}, #{how}" do
        pending(replay_gap) if replay_gap && how == :replayed
        instance_exec(how, &body)
      end
    end
  end

  before do
    AssociationCapabilities.setup!
    AssociationCapabilities.reset!
  end

  let(:low) { LaForge::DataSource.create!(name: 'low', precedence: 11) }
  let(:high) { LaForge::DataSource.create!(name: 'high', precedence: 12) }
  let(:place) { Place.create!(name: 'Harbor Building') }

  def jan(day) = Time.utc(2026, 1, day)

  # Names a tenant as an importer does, by id once a tenant with the `external_id` exists, otherwise as a new tenant
  def tenant(external_id, **attributes)
    existing = Tenant.find_by(external_id: external_id)
    { **(existing ? { id: existing.id } : {}), external_id: external_id, **attributes }
  end

  def hours(days) = days.map { |day| { day: day, opens_at: '09:00' } }
  def member = Tenant.find_by!(external_id: 'T-1')
  def correction = member.data_entries.with_source(high).with_attribute(:name).sole
  def membership_expiry(owner, name) = owner.reload.data_entries.membership_expiries(name).find { |item| item[:source_id] == high.id }

  def provide_name(name) = travel_to(jan(1)) { place.forge! { place.record_data_entries({ tenants: [tenant('T-1', name: name)] }, low) } }
  def provide_hours = travel_to(jan(1)) { place.forge! { place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café', opening_hours: hours(1..2))] }, low) } }

  # Records the map editor's correction of the member's name on January 2
  def correct_name(how, value, **settings)
    travel_to(jan(2)) do
      next member.then { |tenant| tenant.record_data_entries({ name: value }, high, expires_on: low, **settings) && tenant.save! } if how == :direct

      place.reload.record_data_entries({ tenants: [tenant('T-1', name: LaForge.with_settings(value, expires_on: low, **settings))] }, high, mode: :partial)
      place.save!
    end
  end

  def record_on_member(day, values, **options) = travel_to(jan(day)) { member.then { |tenant| tenant.record_data_entries(values, low, **options) && tenant.save! } }
  def forge_on(day) = travel_to(jan(day)) { place.reload.forge! }

  value_unchanged = 'replay reads recorded_at, not whether the value changed'
  first_unknown = "replay sees only the source's latest recording"
  member_expiries_ignored = "replay never fires a member's own expiry"

  describe 'when the value did not change' do
    each_way('leaves :changes on the same value with only a new expires_at', replay_gap: value_unchanged) do |how|
      provide_name('Harbor Cafe')
      correct_name(how, 'Harbor Books')
      record_on_member(3, { name: 'Harbor Cafe' }, expires_at: jan(1) + 1.year)
      forge_on(4)

      expect(correction.expires_at).to be_nil
    end
  end

  describe "a member's expiry on the owner" do
    before { travel_to(jan(1)) { place.forge! { place.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café'), tenant('T-2', name: 'Harbor Books')] }, low) } } }

    # Edits the member on January 2, then records a member list from the source that adds another member, and forges
    def edit_then_list_another(how, edit)
      travel_to(jan(2)) do
        place.reload.record_data_entries({ tenants: edit }, high, mode: :edit, expires_on: low)
        how == :direct ? place.forge! : place.save!
      end
      travel_to(jan(3)) { place.reload.record_data_entries({ tenants: [tenant('T-1', name: 'Corner Café'), tenant('T-2', name: 'Harbor Books'), tenant('T-3', name: 'Bay Books')] }, low) && place.save! }
      forge_on(4)
    end

    each_way('stays on an exclusion when the source changes only another member') do |how|
      edit_then_list_another(how, { exclude: [{ id: member.id }] })

      expect(membership_expiry(place, :tenants)).to include(expires_at: nil)
    end

    each_way('stays on an inclusion when the source changes only another member') do |how|
      edit_then_list_another(how, { include: [{ id: member.id }] })

      expect(membership_expiry(place, :tenants)).to include(expires_at: nil)
    end
  end

  describe "a nested member's expiry" do
    before { provide_hours }

    def edit_hours(how)
      edit = { include: [{ day: 1, opens_at: '10:00' }] }
      travel_to(jan(2)) do
        next member.then { |tenant| tenant.record_data_entries({ opening_hours: edit }, high, mode: :edit, expires_on: low) && tenant.save! } if how == :direct

        place.reload.record_data_entries({ tenants: { include: [tenant('T-1', opening_hours: edit)] } }, high, mode: :edit, expires_on: low)
        place.save!
      end
    end

    # Gives day 1 an expiry of its own, in a member list that expires on the source too
    def wrap_hours(how)
      wrapped = LaForge.with_settings({ day: 1, opens_at: '10:00' }, expires_on: low, expires_at: jan(20))
      travel_to(jan(2)) do
        next member.then { |tenant| tenant.record_data_entries({ opening_hours: [wrapped] }, high, expires_on: low) && tenant.save! } if how == :direct

        place.reload.record_data_entries({ tenants: [tenant('T-1', opening_hours: [wrapped])] }, high, mode: :partial, expires_on: low)
        place.save!
      end
    end

    each_way('stays when the source changes only another member') do |how|
      edit_hours(how)
      record_on_member(3, { opening_hours: hours(1..3) })
      forge_on(4)

      expect(membership_expiry(member, :opening_hours)).to include(expires_at: nil)
    end

    each_way('ends when the source stops covering the member', replay_gap: member_expiries_ignored) do |how|
      edit_hours(how)
      record_on_member(3, { opening_hours: hours(2..2) })
      forge_on(4)

      expect(membership_expiry(member, :opening_hours)).to include(expires_at: jan(3))
    end

    each_way('stays while its member list ends, when the source changes only another member') do |how|
      wrap_hours(how)
      record_on_member(3, { opening_hours: hours(1..3) })
      forge_on(4)

      expect(member.data_entries.with_source(high).with_attribute(:opening_hours).sole.expires_at).to eq(jan(3))
      expect(membership_expiry(member, :opening_hours)).to include(expires_at: jan(20))
    end

    each_way('ends with its member list when the source stops covering the member', replay_gap: member_expiries_ignored) do |how|
      wrap_hours(how)
      record_on_member(3, { opening_hours: hours(2..2) })
      forge_on(4)

      expect(membership_expiry(member, :opening_hours)).to include(expires_at: jan(3))
    end
  end

  describe 'with several recordings before the forge' do
    each_way('ends :changes at the first different value', replay_gap: first_unknown) do |how|
      provide_name('Harbor Cafe')
      correct_name(how, 'Harbor Books')
      record_on_member(3, { name: 'Harbor Diner' })
      record_on_member(5, { name: 'Harbor Inn' })
      forge_on(6)

      expect(correction.expires_at).to eq(jan(3))
    end

    each_way('ends :changes at the first different value when the source changes back', replay_gap: first_unknown) do |how|
      provide_name('Harbor Cafe')
      correct_name(how, 'Harbor Books')
      record_on_member(3, { name: 'Harbor Diner' })
      record_on_member(4, { name: 'Harbor Cafe' })
      forge_on(5)

      expect(correction.expires_at).to eq(jan(3))
    end
  end
end

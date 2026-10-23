# Schema and models for `association_capabilities_spec.rb` and `association_importer_scenarios_spec.rb`.
#
# `setup!` is called from a `before` hook, since `laforged` reads a model's columns when it is declared.
module AssociationCapabilities
  TABLES = %w[places categories place_categories parcels parcel_link_types parcel_links tenants opening_hours markers].freeze

  def self.setup!
    create_tables unless @tables_created
    define_models
  end

  def self.reset!
    TABLES.each { |table| ActiveRecord::Base.connection.execute("DELETE FROM #{table}") }
    LaForge::DataEntry.delete_all
    LaForge::PrecedenceRule.where.not(record_type: LaForge::PrecedenceRule::ANY_TYPE).delete_all
    LaForge::DataSource.where(name: %w[low high top]).delete_all # their global precedence rules go with them
  end

  def self.create_tables
    ActiveRecord::Schema.define do
      create_table :places, force: true do |t|
        t.string :name
        t.bigint :number # an owner key other than id, for associations declared with `primary_key:`
        t.string :region # selects a place's ruleset in the ruleset specs
        t.timestamps null: false
      end

      # Records a place references and never owns
      create_table :categories, force: true do |t|
        t.string :name
      end

      create_table :parcels, force: true do |t|
        t.string :name
      end

      create_table :parcel_link_types, force: true do |t|
        t.string :key
      end

      # A plain `has_many :through` join with an order column
      create_table :place_categories, force: true do |t|
        t.bigint :place_id
        t.bigint :category_id
        t.integer :position
        t.timestamps null: false
      end

      # A three-way join with columns of its own
      create_table :parcel_links, force: true do |t|
        t.bigint :place_id
        t.bigint :parcel_id
        t.bigint :parcel_link_type_id
        t.boolean :active, default: true, null: false
        t.string :external_id
        t.timestamps null: false
      end

      # Owned records, polymorphically owned, with their own nested children
      create_table :tenants, force: true do |t|
        t.string :occupiable_type
        t.bigint :occupiable_id
        t.string :external_id
        t.string :name
        t.string :unit
        t.string :street
        t.string :postcode
        t.string :registration_number
        t.string :status, default: 'open', null: false
        t.timestamps null: false
      end

      # A has_one owned record with no key of its own, so every source describes the place's single marker
      create_table :markers, force: true do |t|
        t.string :markable_type
        t.bigint :markable_id
        t.string :label
        t.string :icon
        t.timestamps null: false
      end

      create_table :opening_hours, force: true do |t|
        t.bigint :tenant_id
        t.integer :day
        t.string :opens_at
      end
    end

    @tables_created = true
  end

  def self.define_models
    define(:Category) {}
    define(:Parcel) {}
    define(:ParcelLinkType) {}

    define(:PlaceCategory) do
      belongs_to :place
      belongs_to :category
    end

    define(:ParcelLink) do
      belongs_to :place
      belongs_to :parcel
      belongs_to :parcel_link_type
    end

    define(:OpeningHour) do
      belongs_to :tenant
    end

    define(:Marker) do
      belongs_to :markable, polymorphic: true
    end

    define(:Tenant) do
      belongs_to :occupiable, polymorphic: true
      has_many :opening_hours, -> { order(:day) }, dependent: :destroy

      validates :name, presence: true

      # A tenant's address comes from one source, its street and postcode together
      laforged associations: { opening_hours: { key: :day } }, attribute_groups: { postal_address: %i[street postcode] }
    end

    define(:Place) do
      has_many :place_categories, -> { order(:position) }, dependent: :destroy
      has_many :categories, through: :place_categories

      has_many :parcel_links, dependent: :destroy
      # Leaves out computed links, which another process derives from parcel geometry, so forging never touches them
      has_many :reported_parcel_links,
               -> { where.not(parcel_link_type_id: ParcelLinkType.where(key: 'computed').select(:id)) },
               class_name: 'ParcelLink'

      has_many :tenants, as: :occupiable, dependent: :destroy
      has_one :marker, as: :markable, dependent: :destroy

      validates :name, presence: true

      laforged associations: {
        place_categories: {},          # key derived from the reflection, `category_id`
        reported_parcel_links: {},     # key derived, `parcel_id` and `parcel_link_type_id`
        # Tenants are keyed by primary key. An excluded tenant is destroyed, and recognised by its name when a source
        # reports it again.
        tenants: { tombstone_matcher: ->(tenant, tombstones) { tombstones.find { |tombstone| tombstone.name == tenant.name } } },
        marker: {}                      # a has_one with no key, as there is only ever one
      }
    end
  end

  # Defines the model `name` with the given body, unless it is already defined. The constant is assigned before the body
  # runs so that association macros can infer names from the class, and removed again when the body raises.
  def self.define(name, &body)
    return if Object.const_defined?(name, false)

    klass = Class.new(ActiveRecord::Base)
    Object.const_set(name, klass)
    begin
      klass.class_eval(&body)
    rescue StandardError, ScriptError # ScriptError covers NotImplementedError
      Object.send(:remove_const, name)
      raise
    end
  end
end

# LaForge [![Gem Version](https://badge.fury.io/rb/laforge.svg)](https://badge.fury.io/rb/laforge)

By [Combinaut](http://www.combinaut.com).

**LaForge** is a gem that makes it easy to build records using data from several data sources. It aims to facilitate
management of which data sources a record is assembled from, and to perform the actual data assembly in order to output
a record.

Key features:

- Allows published content to be edited without those changes immediately being seen by visitors
- Can selectively update content without needing to sync the entire database with production

## Setup
1. Add **Laforge** to your Gemfile:

  ```ruby
  gem 'laforge', github: 'combinaut/laforge'
  ```

2. Create the tables:

  ```bash
    rails generate laforge:install
    rails db:migrate
  ```

  Upgrading from a version that stored `priority` on sources and entries? `rails generate laforge:precedence_rules` creates a migration that moves both into the precedence rules table (see [Precedence](#precedence)).

3. Add laforge to your model.

  ```ruby
    # In your model
    class MyModel < ApplicationModel
      laforged
    end
  ```

## Usage

1. Create some sources and rank them, giving higher precedence to sources whose attributes should override those
   same attributes from lower precedence sources. Each source needs a unique name and a unique precedence.

  ```ruby
    source1 = LaForge::DataSource.create(name: 'Encyclopedia Britannica', precedence: 2)
    source2 = LaForge::DataSource.create(name: 'Wikipedia', precedence: 1)
  ```

2. Build a new model, or update an existing one with data from any of your sources.

  ```ruby
    foo = MyModel.new
    foo.record_data_entries({ height: 20, width: 5 }, source1)
    foo.record_data_entries({ height: 19, name: 'El Capitan' }, source2)
    foo.forge! # => Saves the model with the attributes { height: 20, width: 5, name: 'El Capitan' }
  ```

**Note:** Calling `record_data_entries` builds the Data Entries, but they are not persisted and the record's attributes not updated until `forge!` is called (or the record is saved).

3. Remove data for an existing model from any of your sources.
  ```ruby
    foo.forge! { foo.remove_data_entries(sources: source1) }
    # => Saves the model with the attributes { height: nil, width: nil, name: 'El Capitan' }
  ```

**Note:** calling `remove_data_entries` marks the Data Entries for destruction, but they are not destroyed and the removed attributes not nullified until `forge!` is called. A marked entry still takes part in the forge as a `nil` value, so the attribute is blanked rather than falling back to a lower precedence source. See [Falling back to the next source](#falling-back-to-the-next-source).

A source can be given as a `LaForge::DataSource`, its id, or its name. Looking a source up by a name that has no row raises `LaForge::DataSource::Invalid`.

### Precedence

A source's precedence ranks its values everywhere, unless a more specific rule applies. Rules are kept in the `laforge_precedence_rules` table at four levels, and the most specific one that matches decides:

| Level | Set with |
|---|---|
| One attribute of one record | `record.update_attribute_source_precedence(:height, source2, 3)`, or `precedence:` when recording |
| One attribute of every record of a model | `MyModel.update_attribute_source_precedence(:height, source2, 3)` |
| Every attribute of every record of a model | `MyModel.update_source_precedence(source2, 3)` |
| Everything (the source's own precedence) | `source2.update!(precedence: 3)` |

  ```ruby
    foo = MyModel.new
    foo.record_data_entries({ height: 20, width: 5 }, source1)
    foo.record_data_entries({ height: 19 }, source2, precedence: 3) # Rank source2's height above source1 on this record
    foo.forge! # => Saves the model with the attributes { height: 19, width: 5 }
  ```

A record's precedence for an attribute is kept when the source records the attribute again without passing one, and removed by passing `precedence: nil`. It does not depend on the source's entries: it can be set before the source has recorded the attribute, and it survives the source's entries being destroyed. Pass `nil` to any of the setters above to remove a rule.

  ```ruby
    foo.record_data_entries({ height: 18 }, source2) # Still precedence 3
    foo.record_data_entries({ height: 18 }, source2, precedence: nil) # Back to source2's own precedence

    foo.update_attribute_source_precedence(:height, source2, 10)
    foo.source_precedences     # => { 'height' => { source2 => 10 } }
    MyModel.source_precedences # => the model-wide rules, '' standing for every attribute
  ```

Each forge reads the global and model-wide rules. To read them once for a whole import run, wrap it in `LaForge.with_precedence_cache`. Rules changed through LaForge inside the block take effect immediately; rules changed by SQL or another process are seen once the block ends.

  ```ruby
    LaForge.with_precedence_cache do
      rows.each { |row| import(row) } # each import records entries and forges
    end
  ```

Equal precedences are broken by the sources' own precedence. To reorder sources, update their precedence; `LaForge::DataSource.by_precedence` lists them highest first and `LaForge::DataSource.maximum_precedence` returns the highest.

### Querying
  ```ruby
    foo.data_sources # => The sources that supplied at least one of foo's data entries, each listed once
    MyModel.joins(:data_sources).where(laforge_data_sources: { name: 'Wikipedia' }) # => Records with an entry from Wikipedia

    MyModel.with_source(source1) # => All records from source1
    MyModel.without_source(source1) # => All records not from source1

    MyModel.with_attribute(:height) # => All records with a recorded height attribute from any source
    MyModel.without_attribute(:height) # => All records without a recorded height attribute from any source

    MyModel.with_attribute_with_source(:height, source1) # => All records with a recorded height attribute from source1
    MyModel.with_attribute_with_source([:height, :width], source1) # => All records with a recorded height or width attribute from source1

    MyModel.with_attribute_without_source(:height, source1) # => All records with a recorded height not from source1
    MyModel.with_attribute_without_source([:height, :width], source1) # => All records with a recorded height or width attribute not from source1
    MyModel.with_attribute_with_source(:height, source1).with_attribute_with_source(:width, source1) # => All records with both a recorded height and width attribute from source1

    MyModel.without_attribute_with_source(:height, source1) # => All records without a recorded height attribute from source1
    MyModel.without_attribute_with_source([:height, :width], source1) # => All records missing a recorded height or missing a recorded width from source1
    MyModel.without_attribute_with_source(:height, source1).without_attribute_with_source(:width, source1) # => All records without both a recorded height and width attribute from source1
  ```

The same scopes are available on a record's entries and on `LaForge::DataEntry`:

  ```ruby
    foo.data_entries.with_source(source1).with_attribute(:height).exists?
    LaForge::DataEntry.with_source(source1).with_attribute(:height).where(record_type: 'MyModel').pluck(:record_id)
  ```

## Examples

These cover common ways of merging several feeds and manual edits into one record, and are covered by `spec/lib/usage_spec.rb`. They follow a map that places entities from several sources: a cadastre supplying land records, a business directory that outranks it, a map editor whose edits outrank both, and a geocoder that only adds coordinates:

  ```ruby
    cadastre = LaForge::DataSource.create!(name: 'Cadastre', precedence: 1)
    business_directory = LaForge::DataSource.create!(name: 'Business Directory', precedence: 2)
    map_editor = LaForge::DataSource.create!(name: 'Map Editor', precedence: 3)
    geocoder = LaForge::DataSource.create!(name: 'Geocoder', precedence: 0)
  ```

### Importing

Each import run records everything the source currently says about a record, then forges. Attributes no source has recorded are left as they are, so an importer can still write some columns directly.

  ```ruby
    place.record_data_entries({ land_use: 'Commercial', floor_area: 420 }, cadastre)
    place.notes = 'Entrance on 2nd Ave' # written directly, never recorded
    place.forge!
  ```

To report what an import would change before saving, use `forge_attributes` (the winning value of every recorded attribute) or `forge_diff` (only those that differ from the record):

  ```ruby
    place.record_data_entries({ land_use: 'Mixed Use' }, cadastre)
    place.forge_diff # => { 'land_use' => ['Commercial', 'Mixed Use'] }
  ```

Recorded attributes do not have to be columns. Any attribute with a setter can be recorded and forged, such as a `phone_number=` that maintains a phone number association. Values are stored as JSON, so record strings, numbers, booleans, dates, `nil`, or arrays and hashes of those; anything else, such as an object, raises `LaForge::InvalidValue` rather than coming back as something different.

### Editor overrides

An edit made in the map editor is recorded on the highest precedence source, so it wins over every importer and survives their later runs. Pass `attributes:` to forge only the edited attribute.

  ```ruby
    place.record_data_entry(:name, 'Harbor Building', map_editor)
    place.forge!(attributes: :name)

    place.record_data_entries({ name: 'Harbour Bldg' }, business_directory) # a later import run
    place.forge! # => name stays 'Harbor Building'
  ```

A value that was applied some other way, such as an approved suggested edit, can be recorded and saved without forging. The record is left as it is, and the entry takes part in every later forge.

  ```ruby
    place.record_data_entries({ name: place.name }, map_editor)
    place.save!
  ```

### Falling back to the next source

To drop an override so the next source's value takes over, destroy its entries rather than marking them with `remove_data_entries`, which would blank the attribute.

  ```ruby
    place.data_entries.with_source(map_editor).with_attribute(:name).destroy_all
    place.data_entries.reset
    place.forge!(attributes: :name) # => name is the business directory's latest value
  ```

Entries keep being applied at every forge until they are deleted. To make a value written directly to a column stick, or to let a lower source's value win, delete the outranking entries:

  ```ruby
    LaForge::DataEntry.with_source(business_directory).where(record_type: 'Place', record_id: place_ids, attribute_name: 'name').delete_all
  ```

### Authoritative sources

A source can be made authoritative for some attributes regardless of its own precedence, for every place or for one:

  ```ruby
    Place.update_attribute_source_precedence(:parcel_number, cadastre, 100) # outranks the map editor on every place

    place.record_data_entries({ land_use: 'Commercial' }, cadastre, precedence: 100) # on this place only
    place.forge!
  ```

### When a source stops reporting a record

To blank what the source supplied, remove its entries inside the `forge!` block. Attributes a higher source supplies are unaffected, and once the marked entries are gone the next forge falls back to lower sources.

  ```ruby
    place.forge! { place.remove_data_entries(attribute_names: %i[name phone_number], sources: business_directory) }
  ```

For columns that cannot be blank, remove the entries outside `forge!` and save an explicit value. The entries are deleted on save without the attribute being forged.

  ```ruby
    place.remove_data_entries(attribute_names: :listed, sources: business_directory)
    place.update!(listed: false)
  ```

Whether another source still has entries on the record tells whether anything else still claims it exists. A source that only supplies values, such as the geocoder, can be left out of that check. For a member of a tracked association, also check the sources that list it (see [Inspecting associations](#inspecting-associations)):

  ```ruby
    place.data_entries.with_source(business_directory).destroy_all
    place.archive! if place.data_entries.without_source([business_directory, geocoder]).empty?
  ```

### Inspecting where values came from

  ```ruby
    place.data_source_names                              # => ['Cadastre', 'Business Directory']
    place.data_source_names(attributes: :parcel_number)  # => ['Cadastre']
    place.data_source?(map_editor)                       # => false

    # An attribute's entries, winning entry first
    place.data_entries.includes(:source).select { |entry| entry.attribute_name == 'name' }.sort_by(&:effective_precedence).reverse
  ```

A source that lists a member of a tracked association without saying anything about it has no entries on the member, so it isn't among the member's sources; `member_sources` on the owner reports it (see [Inspecting associations](#inspecting-associations)).

### Pitfalls

- Recorded entries are unsaved until the record is saved. Reloading the record before saving discards them, along with any forged values.
- `forge` applies every stored entry, so stopping recording an attribute is not enough to stop forging it; its existing entries must be deleted.

## Associations (experimental)

LaForge can track associations alongside attributes. The API is experimental and may change.

Recording never touches an association. Each source's report is stored as a data entry on the owner, and only `forge` resolves the reports into the association's final state and assigns it, as assigning the collection yourself would.

### belongs_to

A `belongs_to` association needs no declaration: record the associated record, or `nil`, and it is stored as the foreign key (and the type, when polymorphic), resolved across sources like any attribute. The associated record must already be saved.

  ```ruby
    tenant.record_data_entries({ occupiable: place }, business_directory) # stored as occupiable_id and occupiable_type
  ```

### Declaring has_many and has_one associations

Tracking a `has_many` or `has_one` association is about membership: which records belong to it. Every member is identified by a key, which must identify it across every source:

- The rows of a join model, such as those behind a `has_many :through`, are identified by the records they reference. LaForge derives that key from the association's reflection.
- Other records need a `key:` naming the columns that identify them, such as an external id every source shares.
- A `has_one` with no key has a single member, which every source reports.

  ```ruby
    class Place < ApplicationRecord
      has_many :place_categories, -> { order(:position) }, dependent: :destroy
      has_many :categories, through: :place_categories
      has_many :parcel_links
      has_many :tenants, as: :occupiable, dependent: :destroy
      has_one :marker, as: :markable, dependent: :destroy

      laforged associations: {
        place_categories: {},           # identified by category_id; ordered by position
        parcel_links: {},               # identified by parcel_id + parcel_link_type_id
        tenants: { key: :external_id },
        marker: {}                      # a has_one: recorded as one member, or nil for none
      }
    end

    class Tenant < ApplicationRecord
      has_many :opening_hours, dependent: :destroy

      laforged associations: { opening_hours: { key: :day } }
    end
  ```

Track the join association, not the `has_many :through` itself. `has_and_belongs_to_many` and `has_one :through` are not supported.

### Recording a source's members

A source reports an association's members as a list of hashes. Each hash holds the member's key and whatever the source says about the member, including the member's own tracked associations. By default the list is complete: the source says these are all the members, which excludes every member it doesn't list.

  ```ruby
    # A business directory run
    place.record_data_entries({
      tenants: [{ external_id: 'T-1', name: 'Corner Café', opening_hours: [{ day: 1, opens_at: '08:00' }] }],
      place_categories: [{ category_id: cafe.id }]
    }, business_directory)
    place.forge!
  ```

The report stored on the place holds only the members' keys. Forging the place records each member's attributes on the member itself as that source's entries, exactly as if the source had recorded them on the member directly. It then forges the member, which applies the member's own tracked associations in turn. So:

- A member's attributes are resolved on the member, with every other source's entries on it, under its precedence rules.
- Nothing is created for a member that membership excludes, and the attributes reported for it are discarded.
- A new member is built as the association's own `build` would, with the association scope's attributes.
- The owner's forge forges only the members it records attributes on. A member edited in some other way is forged on its own.
- Members appear in the order of the highest precedence list that includes them. If the association's scope orders by an integer column, LaForge writes the order there, so lists cannot set that column.

A member can also be listed as a saved record, which contributes only its key. This suits a member created or edited on its own:

  ```ruby
    tenant = place.tenants.create!(external_id: 'T-2', name: 'Harbor Books')
    place.record_data_entries({ tenants: [tenant] }, map_editor, partial: true)
  ```

Listing an unsaved record raises: save it first, or pass its attributes as a hash.

Saving the owner after recording member attributes but before forging raises `LaForge::NotForged`, since the attributes are applied only by forging the owner. A list of keys alone can be saved and forged later.

### Partial reports and single-member edits

A source that knows only some of the members records a partial report. It includes, or excludes, the members it names and leaves the rest to other sources. When its next report no longer includes a member, that member is removed unless another source includes it.

  ```ruby
    # A business registry that knows only the businesses it has registered
    place.record_data_entries({ tenants: [{ external_id: 'T-9', registration_number: 'R-10' }] }, business_registry, partial: true)

    # Including some members and excluding others
    place.record_data_entries({ tenants: { include: [{ external_id: 'T-9' }], exclude: [{ external_id: 'T-4' }] } }, business_registry, partial: true)

    # A map editor removing one imported tenant, and later undoing it
    place.exclude_association_member(:tenants, { external_id: 'T-2' }, map_editor)
    place.forget_association_member(:tenants, { external_id: 'T-2' }, map_editor)

    # A map editor adding one category without restating the rest
    place.include_association_member(:place_categories, { category_id: landmark.id }, map_editor)
  ```

Exclusions name members by key only.

### How membership is decided

Membership is decided member by member. The highest precedence report with an opinion on a member decides it: a complete list has an opinion on every member, and a partial report only on the members it names. So a complete list from a higher precedence source excludes members that lower partial reports add, and a source that only adds members needs to rank above the complete lists it adds to.

Rows that no source has ever reported, such as ones created before an association was tracked, are left alone by partial reports. A complete list excludes them like any other member it doesn't list.

A `precedence:` given while recording a list ranks that report's say on membership only. The attributes in the list are recorded at the source's usual precedence. To make a source authoritative for a member attribute, give it a model-wide or per-record precedence on the member's model:

  ```ruby
    Tenant.update_attribute_source_precedence(:registration_number, business_registry, 100)
  ```

### Keys

- Every member a report names needs a value for each key column, and a report cannot name the same member twice.
- A current row missing a key value, such as a tenant added by hand without an `external_id`, cannot be identified across sources, so forging leaves it alone, even when a complete list excludes every other member. Remove such rows yourself if a complete list should replace them.
- Forging raises `LaForge::DuplicateMemberKey` when several current rows share a key, since LaForge cannot tell which one a source means. A unique index on the owner and key columns prevents this.
- Keys must be stable. A row whose key is edited becomes a different member: a source reporting the old key gets a new row, and a complete list removes the edited one.
- A member belongs to one owner. When a source starts reporting a member under another owner, the new owner gets a new row, built from what the source reports, and the old owner's row is removed when its sources stop including it, along with everything else recorded on it.

### When a member can't be created

When membership includes a member that does not exist and the forge has no attributes for it, because the source that reported them was outranked when it recorded them, the forge builds the member from its key alone. If that member is invalid, as a tenant without a name is, the forge skips it, logs a warning and lists it under `skipped:` in `forge_diff`, until a source reports it again with its attributes.

### When a source stops reporting

A member that membership no longer includes is removed the way assigning the collection without it would remove it, following the association's `dependent:` option: destroyed for `:destroy`, deleted for `:delete_all`, and detached by nullifying its foreign key otherwise. Everything recorded on a destroyed member goes with it.

A source's attributes on a member stay there when its list drops the member but another source keeps it. Withdraw the source from the member when its attributes should go too:

  ```ruby
    tenant.withdraw_source(business_registry)
    tenant.forge!
  ```

When an import no longer reports a record at all, choose between two things, as for attributes:

- **Retract what the source said:** `withdraw_source` destroys the source's attribute entries and withdraws every member it reported, so the next forge removes those members unless another source includes them.
- **Stop tracking what the source said:** destroying the source's entries leaves the association as it is. The members the source added stay, as attribute values stay when their entries are destroyed, and are treated from then on as rows no source has reported: left alone by partial reports, removed by a complete list that doesn't include them.

  ```ruby
    place.withdraw_source(business_registry)
    place.forge!
  ```

### Inspecting associations

  ```ruby
    place.source_values(:tenants)        # => { business_directory => [{ 'external_id' => 'T-1', 'name' => 'Corner Café' }], ... }
    Place.source_values(:tenants, records: places)                  # the same for many records, in a constant number of queries
    place.member_sources(:tenants, external_id: 'T-1')
    # => { membership: map_editor, listed_by: [map_editor, business_directory], excluded_by: [],
    #      attributes: { 'name' => business_directory } }
    place.forge_diff['tenants']          # => { added: [...], removed: [...], changed: [...] }, and skipped: when any would be
  ```

A member's own `data_source_names` and `data_source?` count only the sources with entries on the member. A source that lists the member without saying anything about it, such as a map editor including it by key, is not among them; `member_sources` on the owner reports it. So an orphan check that asks whether another source still claims a member should check both:

  ```ruby
    tenant.withdraw_source(business_registry)
    listed_by = place.member_sources(:tenants, external_id: 'T-1')[:listed_by] - [business_registry]
    tenant.archive! if listed_by.empty? && tenant.data_entries.without_source(business_registry).empty?
  ```

`spec/lib/association_importer_scenarios_spec.rb` walks through these cases over several import runs, and `spec/lib/association_capabilities_spec.rb` covers each capability.

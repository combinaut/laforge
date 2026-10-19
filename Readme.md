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

  Upgrading an existing install? See [Upgrading](#upgrading).

  Upgrading from a version without `recorded_at` on data entries? `rails generate laforge:recorded_at` creates a migration that adds it, filled from `updated_at`.

3. Add laforge to your model.

  ```ruby
    # In your model
    class MyModel < ApplicationModel
      laforged
    end
  ```

## Upgrading

### Upgrading from 0.0.1.alpha to 1.0

1.0 requires Rails 7.0 or later.

1. Move precedence into the precedence rules table. The migration moves each source's `priority` and each entry's `priority` into precedence rules and drops both columns. Before changing anything, it checks that every source has its own priority, that entries for the same record, attribute and source agree, and that every entry with a priority belongs to an existing source. It is reversible (see [Precedence](#precedence)).

  ```bash
    rails generate laforge:precedence_rules
    rails db:migrate
  ```

2. Rename `priority` to `precedence` where you call LaForge. There are no aliases.

  | Before | After |
  |---|---|
  | `DataSource.create!(name:, priority:)`, `source.priority` | `DataSource.create!(name:, precedence:)`, `source.precedence` |
  | `record_data_entries(…, priority:)`, `record_data_entry(…, priority:)` | `record_data_entries(…, precedence:)`, `record_data_entry(…, precedence:)` |
  | `record.update_attribute_source_priority` | `record.update_attribute_source_precedence`, which also works before the source has recorded the attribute |
  | `DataEntry#priority_with_fallback`, `DataEntry#source_priority` | `DataEntry#effective_precedence`, `DataEntry#source_precedence` |

3. Record `nil` where a removal was meant to blank an attribute. Removing entries inside `forge!` used to blank the removed attributes for that forge, and the next forge then fell back to lower sources. A forge now leaves removed entries out, so each attribute falls back to the next source straight away, or keeps its value where no other source has one (see [When a source stops reporting a record](#when-a-source-stops-reporting-a-record)). Where a source should blank what it supplied, record `nil` for those attributes instead.

  ```ruby
    # Before
    place.forge! { place.remove_data_entries(attribute_names: %i[name phone_number], sources: business_directory) }

    # After
    place.record_data_entries({ name: nil, phone_number: nil }, business_directory)
    place.forge!
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
    # => Saves the model with the attributes { height: 19, width: 5, name: 'El Capitan' }
  ```

**Note:** calling `remove_data_entries` marks the Data Entries for destruction, and they are destroyed when the record is saved. A forge leaves marked entries out, so each removed attribute falls back to the next source, and an attribute no other source has an entry for keeps its value. In the example, `height` falls back to source2 and `width` keeps its value.

4. Blank data by recording `nil` for it. The source's `nil` outranks lower precedence sources as any value would, and keeps doing so at every later forge.
  ```ruby
    foo.record_data_entries({ height: nil, width: nil }, source1)
    foo.forge! # => Saves the model with the attributes { height: nil, width: nil, name: 'El Capitan' }
  ```

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

A record's precedence for an attribute is kept when the source records the attribute again without passing one, and removed by passing `precedence: nil`. It does not depend on the source's entries, so it can be set before the source has recorded the attribute, and it survives the source's entries being destroyed. Pass `nil` to any of the setters above to remove a rule.

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

A controller action that updates a record can do the same, which helps when it forges more than once, as when it shows the `forge_diff` of an edit and then saves it with `forge!`.

  ```ruby
    class PlacesController < ApplicationController
      around_action(only: :update) { |_controller, action| LaForge.with_precedence_cache(&action) }
    end
  ```

Sources never tie in the global order, since a unique index keeps each source's own precedence unique. Two sources can share a precedence at a more specific level, such as two model-wide rules of 3 for the same attribute, and are then ranked by their own precedence. To reorder sources, update their precedence; `LaForge::DataSource.by_precedence` lists them highest first and `LaForge::DataSource.maximum_precedence` returns the highest.

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

The same scopes are available on a record's entries and on `LaForge::DataEntry`.

  ```ruby
    foo.data_entries.with_source(source1).with_attribute(:height).exists?
    LaForge::DataEntry.with_source(source1).with_attribute(:height).where(record_type: 'MyModel').pluck(:record_id)
  ```

## Examples

These cover common ways of merging several feeds and manual edits into one record, and are covered by `spec/lib/usage_spec.rb`. They follow a map that places entities from several sources: a cadastre supplying land records, a business directory that outranks it, a map editor whose edits outrank both, and a geocoder that only adds coordinates.

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

To report what an import would change before saving, use `forge_attributes` (the winning value of every recorded attribute) or `forge_diff` (only those that differ from the record).

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

To drop an override so the next source's value takes over, remove its entries.

  ```ruby
    place.forge!(attributes: :name) { place.remove_data_entries(attribute_names: :name, sources: map_editor) }
    # => name is the business directory's latest value
  ```

Destroying the entries, as `place.data_entries.with_source(map_editor).with_attribute(:name).destroy_all`, has the same effect from the next forge.

Entries keep being applied at every forge until they are deleted. To make a value written directly to a column stick, or to let a lower source's value win, delete the outranking entries.

  ```ruby
    LaForge::DataEntry.with_source(business_directory).where(record_type: 'Place', record_id: place_ids, attribute_name: 'name').delete_all
  ```

### Per-entry precedence

A source's value for an attribute of one record can outrank sources with a higher precedence. Pass `precedence:` when recording it, and the precedence is kept for that attribute and record, as described in [Precedence](#precedence).

  ```ruby
    place.record_data_entries({ land_use: 'Commercial' }, cadastre, precedence: 100) # outranks the map editor's land use on this place
    place.forge!
  ```

### When a source stops reporting a record

To blank what the source supplied, record `nil` for it. Attributes a higher source supplies are unaffected.

  ```ruby
    place.record_data_entries({ name: nil, phone_number: nil }, business_directory)
    place.forge!
  ```

To stop applying what the source supplied instead, remove its entries. Each attribute falls back to the next source, or keeps its value where no other source has one.

  ```ruby
    place.forge! { place.remove_data_entries(attribute_names: %i[name phone_number], sources: business_directory) }
  ```

To save an explicit value instead, such as for a column that cannot be blank, remove the entries outside `forge!` and save the value. The entries are deleted on save without the attribute being forged.

  ```ruby
    place.remove_data_entries(attribute_names: :listed, sources: business_directory)
    place.update!(listed: false)
  ```

Whether another source still has entries on the record tells whether anything else still claims it exists. A source that only supplies values, such as the geocoder, can be left out of that check. For a member of a tracked association, also check the sources that list it (see [Inspecting associations](#inspecting-associations)).

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

Tracking a `has_many` or `has_one` association is about membership: which records belong to it. Every member is identified by a key:

- The rows of a join model, such as those behind a `has_many :through`, are identified by the records they reference. LaForge derives that key from the association's reflection: every `belongs_to` on the member other than the one pointing back at the owner.
- Other records, such as tenants, are identified by their primary key. A source names an existing member by its `id`, and a new member by its attributes alone (see [Naming members](#naming-members)).
- `key:` names other columns instead, for a natural key such as a weekday, or an identifier every source shares. It also overrides a derived key, as `key: :id` does for an owned model that happens to belong to another record.
- A `has_one` with no key has a single member, which every source reports.

  ```ruby
    class Place < ApplicationRecord
      has_many :place_categories, -> { order(:position) }, dependent: :destroy
      has_many :categories, through: :place_categories
      has_many :parcel_links
      has_many :tenants, as: :occupiable, dependent: :destroy
      has_one :marker, as: :markable, dependent: :destroy

      laforged associations: {
        place_categories: {}, # identified by category_id; ordered by position
        parcel_links: {},     # identified by parcel_id + parcel_link_type_id
        tenants: {},          # identified by id
        marker: {}            # a has_one: recorded as one member, or nil for none
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
    # A business directory run. The importer finds the tenants it reported before by its own means, and names them by id.
    tenants = feed['tenants'].map do |row|
      attributes = { name: row['name'], opening_hours: row['hours'].map { |hours| { day: hours['day'], opens_at: hours['opens'] } } }
      existing = place.tenants.find_by(external_id: row['id'])
      existing ? attributes.merge(id: existing.id) : attributes.merge(external_id: row['id'])
    end

    place.record_data_entries({ tenants: tenants, place_categories: [{ category_id: cafe.id }] }, business_directory)
    place.forge!
  ```

The report stored on the place lists the members by key, and keeps what the source says about each one until a forge of the place includes that member. That forge records the member's attributes on the member itself as that source's entries, exactly as if the source had recorded them on the member directly, and removes them from the report. It then forges the member, which applies the member's own tracked associations in turn. So:

- A member's attributes are resolved on the member, with every other source's entries on it, under its precedence rules.
- Nothing is created for a member that membership excludes. What the source said about it waits in the source's report, and is used if membership later includes it, until the source's next report replaces it.
- The owner can be saved after recording and forged later: nothing is lost in between.
- An attribute the member already has a newer value for from the same source, recorded on the member directly, is not overwritten by an older report. An entry's `recorded_at` is when its value was recorded; `updated_at` keeps its usual meaning.
- A new member is built as the association's own `build` would, with the association scope's attributes.
- The owner's forge forges only the members it records attributes on. A member edited in some other way is forged on its own.
- Members appear in the order of the highest precedence list that includes them. If the association's scope orders by an integer column, LaForge writes the order there, so lists cannot set that column.

### Naming members

A member keyed by primary key can be named four ways:

| Passed | Meaning |
|---|---|
| `{ id: 7, name: 'Corner Café' }` | Tenant 7 is a member, and the source says these attributes about it |
| `{ name: 'Corner Café' }` | A new member with these attributes |
| a saved `Tenant` | Tenant 7 is a member; the source says nothing about its attributes |
| an unsaved `Tenant` | Raises: LaForge cannot tell which of its attributes came from the source, so pass a hash |

A saved record suits a member created or edited on its own:

  ```ruby
    tenant = place.tenants.create!(name: 'Harbor Books')
    place.record_data_entries({ tenants: [tenant] }, map_editor, partial: true)
  ```

Until a forge creates a new member, its source's report names it by a placeholder. Once the owner is saved, the placeholder is replaced by the new row's `id`. Forging again before saving reuses the member already built, rather than building another.

Sources rarely know the host application's ids, so an importer finds each record it reported before by its own means, such as the identifier its feed uses, and names it by `id`. Recording twice before a forge creates the member once, since a source's report replaces its previous one. A new member is created twice only when:

- an importer doesn't find a member it reported before, so it reports it as new again. A complete list then also removes the old row, along with everything else recorded on it;
- two sources each report the same new member before either has been forged. LaForge cannot know they mean the same record, so the second source should find the member the first created;
- a source adds the same new member twice in single-member edits before a forge.

An `id` must be one of the owner's current members. LaForge does not move a record from one owner to another, nor create a record with a given `id`, so naming a record that belongs to another owner, or that does not exist, raises `LaForge::InvalidValue`. Move it outside LaForge, by saving its foreign key, before an import names it under its new owner.

### Partial reports and single-member edits

A source that knows only some of the members records a partial report. It includes, or excludes, the members it names and leaves the rest to other sources. When its next report no longer includes a member, that member is removed unless another source includes it.

  ```ruby
    # A business registry that knows only the businesses it has registered
    place.record_data_entries({ tenants: [{ id: harbor_books.id, registration_number: 'R-10' }] }, business_registry, partial: true)

    # Including some members and excluding others
    place.record_data_entries({ tenants: { include: [harbor_books], exclude: [corner_cafe] } }, business_registry, partial: true)

    # A map editor removing one imported tenant, and later undoing it
    place.exclude_association_member(:tenants, corner_cafe, map_editor)
    place.forget_association_member(:tenants, corner_cafe, map_editor)

    # A map editor adding one category without restating the rest
    place.include_association_member(:place_categories, { category_id: landmark.id }, map_editor)
  ```

Exclusions name members by key only, so a member keyed by primary key can be excluded only once it exists.

An exclusion names a row, so it lasts only as long as the row is one of the owner's members. Once the exclusion removes it, a source that still reports it no longer finds it among the owner's members, reports it as new, and it comes back. Where an editor's removal must outlast later imports, key the association on an identifier every source shares, with `key:`: an exclusion of `{ external_id: 'T-2' }` then holds whatever happens to the row.

### How membership is decided

Membership is decided member by member. The highest precedence report with an opinion on a member decides it: a complete list has an opinion on every member, and a partial report only on the members it names. So a complete list from a higher precedence source excludes members that lower partial reports add, and a source that only adds members needs to rank above the complete lists it adds to.

Rows that no source has ever reported, such as ones created before an association was tracked, are left alone by partial reports. A complete list excludes them like any other member it doesn't list.

A `precedence:` given while recording a list ranks that report's say on membership only. The attributes in the list are recorded at the source's usual precedence. To make a source authoritative for a member attribute, give it a model-wide or per-record precedence on the member's model:

  ```ruby
    Tenant.update_attribute_source_precedence(:registration_number, business_registry, 100)
  ```

### Keys

- A report cannot name the same member twice.
- With a key other than the primary key, every member a report names needs a value for each key column. A current row missing a key value cannot be identified across sources, so forging leaves it alone, even when a complete list excludes every other member.
- Forging raises `LaForge::DuplicateMemberKey` when several current rows share a key, since LaForge cannot tell which one a source means. A unique index on the owner and key columns prevents this.
- Keys other than the primary key must be stable. A row whose key is edited becomes a different member: a source reporting the old key gets a new row, and a complete list removes the edited one.
- With a key other than the primary key, a member belongs to one owner. When a source starts reporting a member under another owner, the new owner gets a new row, built from what the source reports, and the old owner's row is removed when its sources stop including it, along with everything else recorded on it.

### When a member can't be created

When membership includes a member named by `id` that is no longer one of the owner's members, because it was destroyed or moved after the source named it, the forge skips it, logs a warning and lists it under `skipped:` in `forge_diff`. LaForge does not recreate a record with a given `id`; a source that reports it without one creates a new member.

With a key other than the primary key, when membership includes a member that does not exist and no report says anything about it besides its key, the forge builds the member from its key. This happens when a source lists a member by key alone, and when a member was removed and destroyed, taking what was recorded on it, and membership later includes it again, such as when a map editor undoes an exclusion. If that member is invalid, as an opening hour without a time would be, the forge skips it in the same way, until a source reports it with its attributes.

### When a source stops reporting

A member that membership no longer includes is removed the way assigning the collection without it would remove it, following the association's `dependent:` option: destroyed for `:destroy`, deleted for `:delete_all`, and detached by nullifying its foreign key otherwise. Everything recorded on a destroyed member goes with it.

When a source's report drops a member that another source keeps, because its complete list leaves the member out, or its partial report excludes it or stops including it, the forge withdraws the source from that member: its entries on the member are destroyed when the owner is saved, and its reports for the member's own tracked associations are withdrawn in turn, down every level. Each of the member's attributes then falls back to the other sources' entries. An attribute no other source has an entry for keeps its value, as it does when `withdraw_source` destroys a record's entries, so withdrawing never leaves a member invalid.

A source that records on a member directly, and also reports a complete list on its owner, should list that member: its complete list is its whole say on which members it describes.

When an import no longer reports a record at all, choose between two things, as for attributes:

- **Retract what the source said:** `withdraw_source` destroys the source's attribute entries and withdraws every member it reported, so the next forge removes those members unless another source includes them. What its reports said about members not yet recorded on them is dropped, and the next forge withdraws the source from every member another source keeps, as above.
- **Stop tracking what the source said:** destroying the source's entries leaves the association as it is. The members the source added stay, as attribute values stay when their entries are destroyed, and are treated from then on as rows no source has reported: left alone by partial reports, removed by a complete list that doesn't include them.

  ```ruby
    place.withdraw_source(business_registry)
    place.forge!
  ```

### Inspecting associations

  ```ruby
    place.source_values(:tenants)        # => { business_directory => [{ 'id' => 7, 'name' => 'Corner Café' }], ... }, including what reports hold for members not yet recorded on
    Place.source_values(:tenants, records: places)                  # the same for many records, in a constant number of queries
    place.member_sources(:tenants, id: 7)
    # => { membership: map_editor, listed_by: [map_editor, business_directory], excluded_by: [],
    #      attributes: { 'name' => business_directory } }
    place.forge_diff['tenants']          # => { added: [...], removed: [...], changed: [...] }, and skipped: when any would be; a new member is added as its attributes
  ```

A member's own `data_source_names` and `data_source?` count only the sources with entries on the member. A source that lists the member without saying anything about it, such as a map editor including it by key, is not among them; `member_sources` on the owner reports it. So an orphan check that asks whether another source still claims a member should check both:

  ```ruby
    tenant.withdraw_source(business_registry)
    listed_by = place.member_sources(:tenants, id: tenant.id)[:listed_by] - [business_registry]
    tenant.archive! if listed_by.empty? && tenant.data_entries.without_source(business_registry).empty?
  ```

`spec/lib/association_importer_scenarios_spec.rb` walks through these cases over several import runs, and `spec/lib/association_capabilities_spec.rb` covers each capability.

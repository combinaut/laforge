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

3. Add laforge to your model.

  ```ruby
    # In your model
    class MyModel < ApplicationModel
      laforged
    end
  ```

## Upgrading

### Upgrading from 0.0.1.alpha to 1.0

1.0 requires Rails 7.2 or later.

1. Move precedence into the precedence rules table. The migration moves each source's `priority` and each entry's `priority` into precedence rules and drops both columns. Before changing anything, it checks that every source has its own priority, that entries for the same record, attribute and source agree, and that every entry with a priority belongs to an existing source. It is reversible (see [Precedence](#precedence)).

  ```bash
    rails generate laforge:precedence_rules
    rails db:migrate
  ```

2. Add the columns 1.0 adds to LaForge's tables. Each generator creates one migration.
  - `laforge:active_sources` adds `active` to data sources, with every existing source active (see [Deactivating a source](#deactivating-a-source)).

  ```bash
    rails generate laforge:active_sources
    rails db:migrate
  ```

3. Rename `priority` to `precedence` where you call LaForge. There are no aliases.

  | Before | After |
  |---|---|
  | `DataSource.create!(name:, priority:)`, `source.priority` | `DataSource.create!(name:, precedence:)`, `source.precedence` |
  | `record_data_entries(…, priority:)`, `record_data_entry(…, priority:)` | `record_data_entries(…, precedence:)`, `record_data_entry(…, precedence:)` |
  | `record.update_attribute_source_priority` | `record.update_attribute_source_precedence`, which also works before the source has recorded the attribute |
  | `DataEntry#priority_with_fallback`, `DataEntry#source_priority` | `DataEntry#effective_precedence`, `DataEntry#source_precedence` |

4. Check the precedences set on one record. A source with a precedence for an attribute of one record, such as one given with `priority:` when recording, now outranks every source without one for that attribute of that record, whatever the numbers. Sources rank by the most specific level they have a rule at, and numbers are compared only within a level (see [Precedence](#precedence)). Where a per-record priority was meant to rank a source above some sources but not others, set an order that lists them all instead, such as `record.update_precedence_order(:name, [map_editor, cadastre, business_directory])`.

5. Record `nil` where a removal was meant to blank an attribute. Removing entries inside `forge!` used to blank the removed attributes for that forge, and the next forge then fell back to lower sources. A forge now leaves removed entries out, so each attribute falls back to the next source straight away, or keeps its value where no other source has one (see [When a source stops reporting a record](#when-a-source-stops-reporting-a-record)). Where a source should blank what it supplied, record `nil` for those attributes instead.

  ```ruby
    # Before
    place.forge! { place.remove_data_entries(attribute_names: %i[name phone_number], sources: business_directory) }

    # After
    place.record_data_entries({ name: nil, phone_number: nil }, business_directory)
    place.forge!
  ```

6. Record only values JSON can hold. Recording anything other than a string, symbol, number, boolean, date, time, `nil`, or an array or hash of those raises `LaForge::InvalidValue`, rather than storing whatever JSON makes of it. A saved record given for a `belongs_to` association is stored as its foreign key (see [belongs_to](#belongs_to)).

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

Each of LaForge's methods on a model and its records is also reachable through `laforge`, as `place.laforge.forge!` or `Place.laforge.update_source_precedence(map_editor, 3)`, for code that keeps LaForge's methods apart from the model's own.

### Precedence

A source's precedence ranks its values everywhere, unless a more specific rule applies. Rules are kept in the `laforge_precedence_rules` table at four levels:

| Level | Set with |
|---|---|
| One attribute of one record | `record.update_precedence_order(:height, [source2, source1])`, `record.update_attribute_source_precedence(:height, source2, 3)`, or `precedence:` when recording |
| One attribute of every record of a model | `MyModel.update_precedence_order([source2, source1], attribute: :height)` or `MyModel.update_attribute_source_precedence(:height, source2, 3)` |
| Every attribute of every record of a model | `MyModel.update_precedence_order([source2, source1])` or `MyModel.update_source_precedence(source2, 3)` |
| Everything (the source's own precedence) | `LaForge.update_precedence_order([source2, source1])` or `source2.update!(precedence: 3)` |

Sources rank by level first. A source with a rule at a more specific level outranks every source whose most specific rule is at a less specific level, whatever the numbers; precedences only compare sources with rules at the same level. So a rule always puts its source above the sources without one at that level, and an order set at one level, such as one record's order for an attribute, puts the sources it lists above the rest, which keep the order of the next level down. A source added later lands below every order someone set.

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

Sources never tie in the global order, since a unique index keeps each source's own precedence unique. Two sources can share a precedence at a more specific level, such as two model-wide rules of 3 for the same attribute, and are then ranked by their own precedence. `LaForge::DataSource.by_precedence` lists sources highest first and `LaForge::DataSource.maximum_precedence` returns the highest.

#### Precedence orders

To set the order of sources as a settings screen shows it, pass the order and let LaForge choose the numbers. Sources not listed rank below the listed ones, in the order of the next level down. Each call replaces the order at its level; `nil` or `[]` removes it, so the next level decides again.

  ```ruby
    foo.update_precedence_order(:height, [source2, source1])        # this record; saved with the record
    foo.update_precedence_order(:height, nil)                       # back to the model's order
    MyModel.update_precedence_order([source2], attribute: :height)  # every record, one attribute; saved now
    MyModel.update_precedence_order([source2, source1])             # every record, every attribute; saved now
    LaForge.update_precedence_order([source2, source1])             # the global order; renumbers every source, saved now

    foo.precedence_order(:height)
    # => [{ source: source2, level: :record }, { source: source1, level: :global }]
    MyModel.precedence_order(attribute: :height) # the same, for records with no rules of their own
  ```

`precedence_order` lists the active sources in rank order, each with the most specific level it has a rule at: `:record`, `:attribute`, `:model` or `:global`. `LaForge::PrecedenceRule.for_records(MyModel)` lists the rules records of a model have of their own.

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

A source's value for an attribute of one record can outrank sources with a higher precedence. Pass `precedence:` when recording it, and the precedence is kept for that attribute and record, as described in [Precedence](#precedence). A rule puts its source above every source without a rule at that level, so the number only matters against other rules at the same level.

  ```ruby
    place.record_data_entries({ land_use: 'Commercial' }, cadastre, precedence: 100) # outranks the map editor's land use on this place
    place.forge!
  ```

To keep the map editor on top while the cadastre outranks the other importers on this place, set the place's order for the attribute, including both.

  ```ruby
    place.update_precedence_order(:land_use, [map_editor, cadastre])
    place.save!
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

Whether another source still has entries on the record tells whether anything else still claims it exists. A source that only supplies values, such as the geocoder, can be left out of that check.

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
    LaForge::DataEntry.in_precedence_order(place.data_entries.select { |entry| entry.attribute_name == 'name' }, record: place)

    # The sources in the order they rank for an attribute, and the level that ranks each
    place.precedence_order(:name)

    # What would be forged without a source, such as the import value an edit replaced
    place.forge_attributes(attributes: :name, except_sources: map_editor)
  ```

`effective_precedence` on an entry is the precedence of its most specific rule. Since sources rank by level first, compare entries with `in_precedence_order` rather than by that number.

### Fields that come from one source together

Some attributes only make sense from one source together, such as the lines of an address, since one source's street with another's postcode is a broken address. Declare them as an attribute group.

  ```ruby
    class Place < ApplicationRecord
      laforged attribute_groups: { postal_address: %i[street postcode city] }
    end
  ```

- **Forging** takes every attribute of the group from the source whose entry for any of them ranks highest. An attribute that source has no entry for is `nil`.
- **Recording** some of a group's attributes but not all of them raises, naming the missing ones. Pass `nil` for a value the source doesn't have.
- **Precedence** is set on the group, as `place.update_precedence_order(:postal_address, [...])`. A rule on one of its attributes raises, naming the group. `precedence:` given while recording goes to the group.
- **Removing and forging** one attribute of a group, with `remove_data_entries(attribute_names:)` or `forge_attributes(attributes:)`, covers the whole group.

### Deactivating a source

A source that is no longer used can be deactivated. From each record's next forge, its entries are left out as if it had none, so attributes fall back to the next source, or keep their value where no other source has one. Nothing changes until a record is forged, and its entries are kept. Recording still works, and activating it again restores what it says at the next forge.

  ```ruby
    geocoder.update!(active: false)
    place.forge! # coordinates fall back to the next source, or stay as they are
  ```

### Following changes

Each data entry saved with a new or changed value, and each one destroyed, publishes `LaForge::DataEntry::CHANGED` (`'data_entry_changed.laforge'`), so an application can follow what sources say without reading every entry, such as to notice that an import changed the value an editor's entry replaced.

  ```ruby
    ActiveSupport::Notifications.subscribe(LaForge::DataEntry::CHANGED) do |*, payload|
      payload # => { entry:, record_type:, record_id:, attribute_name:, source_id:, value_was:, value:, destroyed: }
    end
  ```

The event fires once the write is committed, and not at all if the transaction rolls back, so a subscriber can enqueue a job, notify someone, or update another store without acting on a change that never happened. A write outside an explicit transaction is committed, and published, as it is saved. Each payload is taken when its write is made, so `value_was` is right when one transaction saves an entry more than once.

Writes that skip callbacks publish nothing, such as rows removed by database cascades when a source is deleted.

### Counting across records

Counts across many records, such as how many places have an order of their own for an attribute, are queries on LaForge's tables, such as `LaForge::PrecedenceRule.for_records(Place).where(attribute_name: 'name').distinct.count(:record_id)` or `LaForge::DataEntry.with_source(map_editor).with_attribute(:name).where(record_type: 'Place').count`. The default index on `laforge_data_entries` starts with the record, so for counts by attribute and source on a large table, add one.

  ```ruby
    add_index :laforge_data_entries, %i[record_type attribute_name source_id], name: :index_laforge_data_entries_on_type_attribute_and_source
  ```

It costs every write, so add it only where those counts are needed.

### Pitfalls

- Recorded entries are unsaved until the record is saved. Reloading the record before saving discards them, along with any forged values.
- `forge` applies every stored entry, so stopping recording an attribute is not enough to stop forging it; its existing entries must be deleted.

## Associations

### belongs_to

A `belongs_to` association needs no declaration. Record the associated record, or `nil`, and it is stored as the foreign key (and the type, when polymorphic), resolved across sources like any attribute. The associated record must already be saved.

  ```ruby
    tenant.record_data_entries({ occupiable: place }, business_directory) # stored as occupiable_id and occupiable_type
  ```

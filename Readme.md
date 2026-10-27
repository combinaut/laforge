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
  - `laforge:recorded_at` adds `recorded_at` to data entries, filled from `updated_at`.
  - `laforge:active_sources` adds `active` to data sources, with every existing source active (see [Deactivating a source](#deactivating-a-source)).
  - `laforge:expiry` adds `expires_at` and `expires_on_source_id` to data entries and precedence rules, and `recorded_at` to precedence rules, filled from `updated_at`. Nothing expires until a change is made with an expiry (see [Expiring a change](#expiring-a-change)). It also gives `created_at` and `updated_at` on LaForge's three tables sub-second precision, matching `recorded_at`, which an expiry on a source compares between a recording and the change it ends; this rewrites the columns, which can take a while on a large `laforge_data_entries` table.
  - `laforge:rulesets` adds `ruleset` to precedence rules, with every existing rule a base rule, and adds it to both unique indexes on `laforge_precedence_rules` (see [Rulesets](#rulesets)). Going down deletes every ruleset's rules.

  ```bash
    rails generate laforge:recorded_at
    rails generate laforge:active_sources
    rails generate laforge:expiry
    rails generate laforge:rulesets
    rails db:migrate
  ```

3. Rename `priority` to `precedence` where you call LaForge. There are no aliases.

  | Before | After |
  |---|---|
  | `DataSource.create!(name:, priority:)`, `source.priority` | `DataSource.create!(name:, precedence:)`, `source.precedence` |
  | `record_data_entries(…, priority:)`, `record_data_entry(…, priority:)` | `record_data_entries(…, precedence:)`, `record_data_entry(…, precedence:)` |
  | `record.update_attribute_source_priority` | `record.update_attribute_source_precedence`, which also works before the source has an entry for the attribute |
  | `DataEntry#priority_with_fallback`, `DataEntry#source_priority` | `DataEntry#effective_precedence`, `DataEntry#source_precedence` |

4. Check the precedences set on one record. A source with a precedence for an attribute of one record, such as one given with `priority:` when recording, now outranks every source without one for that attribute of that record, whatever the numbers. Sources rank by the most specific level they have a rule at, and numbers are compared only within a level (see [Precedence](#precedence)). Where a per-record priority was meant to rank a source above some sources but not others, set an order that lists them all instead, such as `record.update_precedence_order(:name, [map_editor, cadastre, business_directory])`.

5. Record `nil` where a removal was meant to blank an attribute. Removing entries inside `forge!` used to blank the removed attributes for that forge, and the next forge then fell back to lower sources. A forge now leaves removed entries out, so each attribute falls back to the next source straight away, or keeps its value where no other source has one (see [When a source stops providing a record](#when-a-source-stops-providing-a-record)). Where a source should blank what it provided, record `nil` for those attributes instead.

  ```ruby
    # Before
    place.forge! { place.remove_data_entries(attribute_names: %i[name phone_number], sources: business_directory) }

    # After
    place.record_data_entries({ name: nil, phone_number: nil }, business_directory)
    place.forge!
  ```

6. Record only values JSON can hold. Recording anything other than a string, symbol, number, boolean, date, time, `nil`, or an array or hash of those raises `LaForge::InvalidValue`, rather than storing whatever JSON makes of it. A saved record given for a `belongs_to` association is stored as its foreign key (see [belongs_to](#belongs_to)).

7. Record a form's `*_attributes` and `*_ids` as edits. They used to be recorded as attribute entries, which forging then assigned. They now raise `ArgumentError` unless recorded with `mode: :edit`, and `LaForge::InvalidAttributeName` for an association LaForge does not track (see [Recording a Rails form](#recording-a-rails-form)).

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
| One attribute of one record | `record.update_precedence_order(:height, [source2, source1])`, `record.update_attribute_source_precedence(:height, source2, 3)`, or `precedence:` when recording; each also takes `expires_at:` and `expires_on:` (see [Expiring a change](#expiring-a-change)) |
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

A record's precedence for an attribute is kept when a value from the source is recorded for the attribute again without passing one, and removed by passing `precedence: nil`. It does not depend on the source's entries, so it can be set before the source has an entry for the attribute, and it survives the source's entries being destroyed. Pass `nil` to any of the setters above to remove a rule.

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

`precedence_order` lists the active sources in rank order, each with the most specific level it has a rule at: `:record`, `:attribute`, `:model` or `:global`, and the ruleset the rules at that level come from, `nil` for the base rules (see [Rulesets](#rulesets)). `LaForge::PrecedenceRule.for_records(MyModel)` lists the rules records of a model have of their own.

#### Rulesets

An advanced option, which an app with one source order everywhere doesn't need. When groups of records need their sources in different orders, such as places in different regions where a different directory is the authority, give each group a ruleset, which is a named copy of the model-wide and global rules. Sources, data entries and records' own rules are shared; only the orders differ.

A ruleset selector names each record's ruleset, as a method name or a Proc given the record. Its value is turned into a String, and `nil` or blank selects the base rules. A model's own selector replaces the app-wide one, and `false` keeps its records on the base rules.

  ```ruby
    LaForge.ruleset_selector = :region                                  # every laforged model
    class Place < ApplicationRecord
      laforged ruleset_selector: ->(place) { place.region }             # this model only
    end

    Place.update_precedence_order([business_registry], attribute: :name, ruleset: 'north')
    LaForge.update_precedence_order([cadastre, map_editor], ruleset: 'north')
    Place.update_attribute_source_precedence(:name, cadastre, 5, ruleset: 'north')
    LaForge.update_source_precedence(cadastre, 5, ruleset: 'north')     # one global rule in a ruleset; without ruleset:, the base rules

    place.precedence_order(:name)
    # => [{ source: business_registry, level: :attribute, ruleset: 'north' }, ...]
  ```

- **A record's own rules come first.** Below them, a record whose ruleset has rules ranks by that ruleset's attribute, model-wide and global rules; any other record ranks by the base rules. The two are never mixed. A ruleset is a complete set of orders, so a change to the base rules can't reach a ruleset's records in a way nobody chose there, and removing an order in a ruleset falls back to that ruleset's next level.
- **The first rule written to a ruleset copies the base rules into it.** Every model-wide and global base rule is copied, in the same transaction as the rule being written, so the ruleset's records rank exactly as before except for that rule. From then on the ruleset keeps its own copy, and doesn't follow later changes to the base rules. `LaForge.fork_ruleset('north')` makes the copy without changing anything, and does nothing for a ruleset that has rules already.
- **`LaForge.reset_ruleset('north')`** deletes the ruleset's rules, so its records follow the base rules again. `LaForge.rulesets` lists the rulesets that have rules. Rulesets are created as they're used, and are named by Strings or Symbols of at most 100 characters. Names are case-sensitive, so `North` and `north` are two rulesets.
- **Only model-wide and global rules belong to a ruleset.** A record's own rules apply whatever its ruleset, so the record-level methods take no `ruleset:`.
- **Each ruleset is cached apart** inside `LaForge.with_precedence_cache`, and a copy or reset that rolls back is forgotten there too.

##### When the selector is called

The selector is called when a record is forged, by `forge`, `forge_attributes` or `forge_associations`, and by `forge_diff`, `precedence_order` and `member_sources`, never when the app boots. `member_sources` calls it for the owner and for the member it describes. `forge` and `forge_diff` call it once for each record, before any attribute is assigned, so a forge that changes what the selector reads ranks attributes and associations alike, and a `member_sources` call made during the forge, such as from a setter, ranks by that same selection. A forge forges a record's tracked associations before assigning its attributes, so a member whose selector reads its owner ranks by the owner as the forge found it, which is also what `forge_diff` previews. Other ranking helpers, such as `effective_precedence` and `DataEntry.in_precedence_order`, reuse the last selection until the record is forged again or reloaded.

##### Sources created or destroyed later

Every source keeps a global precedence in each ruleset, as in the base rules, so a source created later is placed at the bottom of each existing ruleset's global order, below its lowest, in the same transaction. A ruleset that has placed it already is left alone. Destroying a source deletes its rules in every ruleset.

##### Setting rulesets up while the app runs

Set rulesets up from one writer at a time. Two processes copying a ruleset at once don't copy it twice, since the unique indexes skip the rows the other inserted, but two processes making a ruleset's first write at the same moment can both copy the base rules, so a rule the first one removed can come back. Call `LaForge.fork_ruleset` once ahead of time, such as in a deploy task, to avoid it. Likewise, two sources created at the same moment while rulesets exist can be given the same place in a ruleset, and one creation then fails on the unique index and rolls back. Retry it.

### Querying
  ```ruby
    foo.data_sources # => The sources that provided at least one of foo's data entries, each listed once
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

These cover common ways of merging several feeds and manual edits into one record, and are covered by `spec/lib/usage_spec.rb`. They follow a map that places entities from several sources: a cadastre providing land records, a business directory that outranks it, a map editor whose edits outrank both, and a geocoder that only adds coordinates.

  ```ruby
    cadastre = LaForge::DataSource.create!(name: 'Cadastre', precedence: 1)
    business_directory = LaForge::DataSource.create!(name: 'Business Directory', precedence: 2)
    map_editor = LaForge::DataSource.create!(name: 'Map Editor', precedence: 3)
    geocoder = LaForge::DataSource.create!(name: 'Geocoder', precedence: 0)
  ```

### Importing

Each import run records everything the source currently says about a record, then forges. Attributes no source has an entry for are left as they are, so an importer can still write some columns directly.

  ```ruby
    place.record_data_entries({ land_use: 'Commercial', floor_area: 420 }, cadastre)
    place.notes = 'Entrance on 2nd Ave' # written directly, never recorded
    place.forge!
  ```

To see what an import would change before saving, use `forge_attributes` (the winning value of every recorded attribute) or `forge_diff` (only those that differ from the record).

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

### When a source stops providing a record

To blank what the source provided, record `nil` for it. Attributes a higher source provides are unaffected.

  ```ruby
    place.record_data_entries({ name: nil, phone_number: nil }, business_directory)
    place.forge!
  ```

To stop applying what the source provided instead, remove its entries. Each attribute falls back to the next source, or keeps its value where no other source has one.

  ```ruby
    place.forge! { place.remove_data_entries(attribute_names: %i[name phone_number], sources: business_directory) }
  ```

To save an explicit value instead, such as for a column that cannot be blank, remove the entries outside `forge!` and save the value. The entries are deleted on save without the attribute being forged.

  ```ruby
    place.remove_data_entries(attribute_names: :listed, sources: business_directory)
    place.update!(listed: false)
  ```

Whether another source still has entries on the record tells whether anything else still claims it exists. A source that only provides values, such as the geocoder, can be left out of that check. For a member of a tracked association, also check the sources that list it (see [Inspecting associations](#inspecting-associations)).

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

A source that lists a member of a tracked association without saying anything about it has no entries on the member, so it isn't among the member's sources; `member_sources` on the owner names it (see [Inspecting associations](#inspecting-associations)).

### Fields that come from one source together

Some attributes only make sense from one source together, such as the lines of an address, since one source's street with another's postcode is a broken address. Declare them as an attribute group.

  ```ruby
    class Place < ApplicationRecord
      laforged attribute_groups: { postal_address: %i[street postcode city] }
    end
  ```

- **Forging** takes every attribute of the group from the source whose entry for any of them ranks highest. An attribute that source has no entry for is `nil` rather than falling back to another source's value.
- **Recording** some of a group's attributes but not all of them raises, naming the missing ones, in every mode and for members recorded through an owner. Pass `nil` for a value the source doesn't have.
- **Precedence** is set on the group, as `place.update_precedence_order(:postal_address, [...])`. A rule on one of its attributes raises, naming the group. `precedence:` given while recording goes to the group.
- **Removing and forging** one attribute of a group, with `remove_data_entries(attribute_names:)` or `forge_attributes(attributes:)`, covers the whole group.

### Deactivating a source

A source that is no longer used can be deactivated. From each record's next forge, its entries are left out as if it had none, so attributes fall back to the next source, or keep their value where no other source has one. Nothing changes until a record is forged, and its entries are kept. Recording still works, and activating it again restores what it says at the next forge.

  ```ruby
    geocoder.update!(active: false)
    place.forge! # coordinates fall back to the next source, or stay as they are
  ```

In a tracked association, an inactive source's member lists are left out too. Members only it listed become rows no member list has named, which are left alone, and its exclusions and tombstones stop applying until it is active again. A tenant it excluded that another source listed as new meanwhile is removed, per `dependent:`, by the first forge after it is activated again. A tenant the application created itself meanwhile, after `LaForge.tombstone_blocking` allowed it, keeps its id and is not matched against the tombstone, so the exclusion does not apply to it.

### Expiring a change

A change to one record can be made to expire, so the record goes back to what its sources say without it and no one has to remember to undo it. A recorded value, a record's precedence order, a single precedence, or several of them in one save, take `expires_at:` (a time) or `expires_on:` (a source, so the change expires the next time a value from that source is recorded for the same attribute or association of the record, whatever that source provides, which sets `expires_at` to when it was recorded).

  ```ruby
    # Rename the place until the next cadastre import
    place.record_data_entries({ name: 'Harbor Building (temporary)' }, map_editor, expires_on: cadastre)

    # Rank the business registry first for the name for a month
    place.update_precedence_order(:name, [business_registry], expires_at: 1.month.from_now)
    place.forge!
  ```

- **Recording the value again, or setting the order again, replaces its expiry**; leaving the options out clears it. A precedence passed with `precedence:` while recording takes the same expiry.
- **An expired row is left out of forging, and kept.** Like an inactive source's entries, an expired value no longer counts, so the attribute falls back to the next source, or keeps its value where no other source has one; an expired order no longer ranks, so the next level's order applies. The rows stay readable, so a settings screen can show when a change expired, and removing them is up to the application. `source_precedences` lists only the rules that still count.
- **An expiry on part of an attribute group applies to the whole group.**
- **Only changes to one record expire.** Model-wide and global rules are configuration; giving one an expiry raises.

**Timing is the application's job.** Like any precedence change, an expiry takes effect at the record's next forge; nothing changes in between. An expiry on a source takes effect at the forge that follows the recording from that source, which an import does anyway. For expiries at a time, list what expires and forge those records on schedule, or warn ahead of time.

  ```ruby
    LaForge::DataEntry.expiring(before: 1.week.from_now)       # expired already, or expiring within the week
    LaForge::PrecedenceRule.expiring(before: Time.current)     # rules that have expired, whose records need a forge
    LaForge::DataEntry.expired                                 # and .unexpired; both take a time, now by default
  ```

LaForge publishes nothing when a change expires by time, and the forge writes nothing because of an expiry, since an expiry is not new data. The event that recorded the change carries its expiry, so the application's change tracking can note when it will expire and decide what to do (see [Following changes](#following-changes)). An expiry on a source that fires sets `expires_at` on the waiting entry, which is published when the entry is saved.

#### Which recordings end an expiry on a source

Only a recording made after the change counts, so a member list recorded from the source earlier, kept pending on an owner until the owner is forged, does not end it. A value can't expire on the source it comes from, since the next recording from that source replaces it anyway.

A change kept pending on an owner is made when its member list was recorded, so a recording from the source made after that and before the owner is forged ends it, whether that is a later member list forged with it or a recording on the member itself. A recording on the member shows only in the entries it changed, so one that changed nothing there does not end the change. If the source is deleted before the owner is forged, the change keeps only its expiry at a time, when it has one.

#### Expiring a member list

An expired member list counts as if it did not exist, exactly as an inactive source's member list, and nothing is removed because of the expiry itself. A member list recorded whole, as a complete or partial list, expires as a whole with the call's expiry. A member only it named becomes a row no member list names, which is left alone; a member another member list excludes, such as a higher-ranked complete list that leaves it out, is removed once the expired list no longer keeps it in. An expired exclusion or tombstone stops keeping its member out, so a source can bring the member back. What the member list says about members is recorded on them with the same expiry, so their attributes fall back with it.

#### Expiring one member

In an edit (`mode: :edit`), the expiry is given to each member the edit includes or excludes, not to the source's member list, so editing one member leaves the expiries earlier edits gave the others as they are. Editing the same member again replaces its expiry, and leaving the options out makes it permanent.

  ```ruby
    # Close the corner café until March; a later edit of another tenant leaves that alone
    place.record_data_entries({ tenants: { exclude: [corner_cafe] } }, map_editor, mode: :edit, expires_at: Date.new(2026, 3, 1).beginning_of_day)
    place.record_data_entries({ tenants: [{ id: harbor_books.id, unit: '2B' }] }, map_editor, mode: :edit)
  ```

- **A partial list no longer covers a member whose inclusion or exclusion has expired**, as an expired member list covers none. An expired inclusion no longer keeps the member in, so a complete list from another source that leaves it out removes it, and an expired exclusion or its tombstone stops keeping the member out. A complete list's own inclusion that has expired excludes the member, as the list no longer lists it. What an expired inclusion said about the member is not recorded on it.
- **An expiry on a source** fires the next time the association is recorded from that source for the record, under the same rule as for a row, so only a recording made after the edit counts.
- **A complete list can't exclude a member with an expiry.** Excluding from it drops the member from the list. Record the source's list with `mode: :partial`, or exclude from another source.
- **Edits don't change the member list's own expiry.** A member list recorded whole with an expiry expires as a whole, edits since included. An edit over a member list whose expiry has passed starts a new member list, which does not expire. A `precedence:` passed with an edit takes its expiry, as everything else it sets does.
- **The `expiring` scopes can't see these expiries**, which are kept in the member list's value. `place.data_entries.membership_expiries(:tenants)` lists them, as `[{ source_id:, key:, expires_at:, expires_on_source_id: }]`.

#### Settings for part of a payload

`LaForge.with_settings(value, precedence:, expires_at:, expires_on:)` wraps any part of a payload with settings of its own, which replace the call's for everything recorded from it: an attribute's value, a belongs_to, a member (its attributes, nested lists and its inclusion), an exclusion, or a nested list. Options left out are not given, so a wrapper without an expiry makes what it wraps permanent. One call then records what would otherwise take one call per setting.

  ```ruby
    place.record_data_entries({
      name: LaForge.with_settings('Harbor Building (temporary)', expires_on: cadastre),
      tenants: {
        include: [{ id: harbor_books.id, unit: '2B' }, LaForge.with_settings({ name: 'Bakery Pop-up' }, expires_at: 1.month.from_now)],
        exclude: [LaForge.with_settings(corner_cafe, expires_at: 3.months.from_now)]
      }
    }, map_editor, mode: :edit)
  ```

- **Precedence ranks a source for a whole association**, so a wrapper's precedence on a member applies to the member's own attributes, and the association's precedence comes from the call, or from a wrapper around the association's whole value. A wrapper with a precedence of its own around a member with no attributes, such as an exclusion or a saved record, raises.
- **An attribute group takes one set of settings.** Wrapping some of its attributes but not the others, or wrapping them differently, raises.
- **Settings go where something can carry them.** Wrapping part of an attribute's value, part of a member's key, a list of members rather than each member, or a member to forget raises, saying where, in nested lists too, before anything is saved. `record_data_entry` takes a wrapped value too.

### Following changes

Each data entry saved new, or with its value or its expiry changed, and each one destroyed, publishes `LaForge::DataEntry::CHANGED` (`'data_entry_changed.laforge'`), so an application can follow what sources say without reading every entry, such as to notice that an import changed the value an editor's entry replaced.

  ```ruby
    ActiveSupport::Notifications.subscribe(LaForge::DataEntry::CHANGED) do |*, payload|
      payload # => { entry:, record_type:, record_id:, attribute_name:, source_id:, value_was:, value:, destroyed:, expires_at:, expires_on_source_id: }
    end
  ```

The event fires once the write is committed, and not at all if the transaction rolls back, so a subscriber can enqueue a job, notify someone, or update another store without acting on a change that never happened. A write outside an explicit transaction is committed, and published, as it is saved. Each payload is taken when its write is made, so `value_was` and the expiry are right when one transaction saves an entry more than once.

The payload carries the entry's expiry, so recording the same value again with a new or cleared expiry publishes too. Nothing is published when a change expires by time; the event that recorded it already said when it would (see [Expiring a change](#expiring-a-change)).

Writes that skip callbacks publish nothing. These are `LaForge.merge` moving entries between records, and rows removed by database cascades, such as when a source is deleted.

### Counting across records

Counts across many records, such as how many places have an order of their own for an attribute, are queries on LaForge's tables, such as `LaForge::PrecedenceRule.for_records(Place).where(attribute_name: 'name').distinct.count(:record_id)` or `LaForge::DataEntry.with_source(map_editor).with_attribute(:name).where(record_type: 'Place').count`. The default index on `laforge_data_entries` starts with the record, so for counts by attribute and source on a large table, add one.

  ```ruby
    add_index :laforge_data_entries, %i[record_type attribute_name source_id], name: :index_laforge_data_entries_on_type_attribute_and_source
  ```

It costs every write, so add it only where those counts are needed.

### Merging duplicate records

When two records turn out to be the same, merge what LaForge holds for the duplicate into the survivor, then forge the survivor.

  ```ruby
    result = LaForge.merge(survivor, duplicate)          # on a conflict, the duplicate's entry wins, as the argument does in Hash#merge
    result = LaForge.reverse_merge(survivor, duplicate)  # on a conflict, the survivor's entry wins
    survivor.forge!
    duplicate.archive!                                   # the duplicate is left to the application
  ```

- **Attribute entries and per-record precedence rules** move to the survivor. Where both records have one for the same attribute and source, that's a conflict, and the function decides which is kept, unless only one of them has expired, in which case the one that still counts is kept. The other is destroyed.
- **Members of tracked associations** move to the survivor with their ids and everything recorded on them. Where both records have a member with the same key, as two join rows naming the same category do, the survivor's row is kept, and the duplicate's row is merged into it the same way, forged, and destroyed. Where both have a has_one member with different keys, such as markers with different labels, the merge raises `ArgumentError` before anything moves, since the survivor can hold only one. Remove one of them, or give them the same key, then merge again. The same goes for one source's has_one lists on both records that name members with different keys, as before either record is forged.
- **Each source's member lists** on the two records are combined, so the survivor's list names every member either named, and keeps both records' tombstones. Where the lists cover a member differently, the winner's coverage of it is kept.
- **Not touched:** associations LaForge doesn't track, and the duplicate itself, which is left with no LaForge data for the application to archive or destroy.

The result says what moved and what conflicted, as `{ entries_moved:, entries_conflicting: [{ attribute:, source:, kept: }], precedence_rules_moved:, precedence_rules_conflicting: [...], members_moved: { 'tenants' => [ids] }, members_merged: { 'place_categories' => [{ kept:, removed: }] } }`. Both records must be saved, of the same model, and have no unsaved entries or rules. The merge runs in a transaction and is saved immediately.

### Pitfalls

- Recorded entries are unsaved until the record is saved. Reloading the record before saving discards them, along with any forged values.
- `forge` applies every stored entry, so stopping recording an attribute is not enough to stop forging it; its existing entries must be deleted.

## Associations (experimental)

LaForge can track associations alongside attributes. The API is experimental and may change.

Recording never touches an association. Each source's member list is stored as a data entry on the owner, and only `forge` resolves the member lists into the association's membership and assigns it, as assigning the collection yourself would.

### belongs_to

A `belongs_to` association needs no declaration. Record the associated record, or `nil`, and it is stored as the foreign key (and the type, when polymorphic), resolved across sources like any attribute. The associated record must already be saved.

  ```ruby
    tenant.record_data_entries({ occupiable: place }, business_directory) # stored as occupiable_id and occupiable_type
  ```

### Declaring has_many and has_one associations

Tracking a `has_many` or `has_one` association is about which members (Rails' associated records) belong to it, its membership. Every member is identified by a key:

- The rows of a join model, such as those behind a `has_many :through`, are identified by the records they reference. LaForge derives that key from the association's reflection. It is every `belongs_to` on the member other than the one pointing back at the owner, with its type column for a polymorphic one.
- Other records, such as tenants, are identified by their primary key. A source names an existing member by its `id`, and a new member by its attributes alone (see [Naming members](#naming-members)).
- `key:` names other columns instead, for a natural key such as a weekday, or an identifier every source shares. It also overrides a derived key, as `key: :id` does for an owned model that happens to belong to another record.
- A `has_one` with no key has a single member, which every source lists.
- Member order is written to the integer column the association's scope orders by, such as `position` for `-> { order(:position) }`, in the scope's direction, unless that column identifies the member or its owner. `order_column:` names the column instead, written ascending, which a scope ordering by an expression such as `Arel.sql(...)` needs, and `order_column: false` writes no order. The list's order wins over a position recorded on the member itself.
- `tombstone_matcher:` recognizes a member a source excluded when a source lists it again (see [Removed members that sources list again](#removed-members-that-sources-list-again)).

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

`laforged` raises if the model already defines a method LaForge adds, such as `forge` or `source_values`, rather than replacing it without a word. A method meant to wrap LaForge's and call `super` is defined after `laforged`.

Track the join association, not the `has_many :through` itself. `has_and_belongs_to_many` and `has_one :through` are not supported.

#### When members point at a column other than the owner's id

An association declared with `primary_key:`, such as `has_many :tenants, as: :occupiable, primary_key: :number`, links its members by that column, and LaForge builds, reads and merges members by it too. Declare the same `primary_key:` on the member's `belongs_to`, as Rails needs to keep the link when it saves the member. A composite key, from the owner's primary key, `primary_key:` or `query_constraints:`, is not supported, and `laforged` raises for it.

### Recording a source's members

A source provides an association's members as a list of hashes. Each hash holds the member's key and whatever the source says about the member, including the member's own tracked associations. By default the list is complete, meaning the source says these are all the members, which excludes every other member that a member list has named. Rows no member list has named are left alone (see [How membership is decided](#how-membership-is-decided)). `mode:` says otherwise: `:partial` for the members a source knows about (see [Partial lists](#partial-lists)), and `:edit` for changes to the members named (see [Edits](#edits)).

  ```ruby
    # A business directory run. The importer finds the tenants it listed before by its own means, and names them by id.
    tenants = feed['tenants'].map do |row|
      attributes = { name: row['name'], opening_hours: row['hours'].map { |hours| { day: hours['day'], opens_at: hours['opens'] } } }
      existing = place.tenants.find_by(external_id: row['id'])
      existing ? attributes.merge(id: existing.id) : attributes.merge(external_id: row['id'])
    end

    place.record_data_entries({ tenants: tenants, place_categories: [{ category_id: cafe.id }] }, business_directory)
    place.forge!
  ```

The member list stored on the place names the members by key, and keeps what the source says about each one until a forge of the place includes that member. That forge records the member's attributes on the member itself as that source's entries, exactly as if they had been recorded from the source on the member directly, and removes them from the list. It then forges the member, which applies the member's own tracked associations in turn. So:

- A member's attributes are resolved on the member, with every other source's entries on it, under its precedence rules.
- Nothing is created for a member that membership excludes. What the source said about it waits in the source's member list, and is used if membership later includes it, until the source's next list replaces it.
- The owner can be saved after recording and forged later, and nothing is lost in between.
- A new member is built as the association's own `build` would, with the association scope's attributes.
- The owner's forge forges only the members it records attributes on. A member edited in some other way is forged on its own.
- Members appear in the order of the highest precedence list that includes them. If the association's scope orders by an integer column, LaForge writes the order there, so lists cannot set that column.

#### When values from a source are also recorded on the member directly

An attribute the member already has a newer value for from the same source, recorded on the member directly, is not overwritten by an older member list. An entry's `recorded_at` is when its value was recorded, and `updated_at` keeps its usual meaning.

### Naming members

A member keyed by primary key can be named four ways:

| Passed | Meaning |
|---|---|
| `{ id: 7, name: 'Corner Café' }` | Tenant 7 is a member, and the source says these attributes about it |
| `{ name: 'Corner Café' }` | A new member with these attributes |
| a saved `Tenant` | Tenant 7 is a member; the source says nothing about its attributes |
| an unsaved `Tenant` | Raises. LaForge cannot tell which of its attributes came from the source, so pass a hash |

A saved record suits a member created or edited on its own.

  ```ruby
    tenant = place.tenants.create!(name: 'Harbor Books')
    place.record_data_entries({ tenants: [tenant] }, map_editor, mode: :partial)
  ```

Sources rarely know the host application's ids, so an importer finds each record it listed before by its own means, such as the identifier its feed uses, and names it by `id`.

An `id` must be one of the owner's current members. LaForge does not move a record from one owner to another, nor create a record with a given `id`, so naming a record that belongs to another owner, or that does not exist, raises `LaForge::InvalidValue`. Move it outside LaForge, by saving its foreign key, before an import names it under its new owner.

#### When a new member is created twice

Until a forge creates a new member, its source's member list names it by a placeholder. Once the owner is saved, the placeholder is replaced by the new row's `id`. Forging again before saving reuses the member already built, rather than building another. Recording twice before a forge creates the member once, since a source's member list replaces its previous one. A new member is created twice only when:

- an importer doesn't find a member it listed before, so it lists it as new again. A complete list then also removes the old row, along with everything else recorded on it;
- two sources each list the same new member before either has been forged. LaForge cannot know they mean the same record, so the second source should find the member the first created;
- a source adds the same new member twice in single-member edits before a forge.

### Partial lists

A source that knows only some of the members provides a partial list, recorded with `mode: :partial`. It includes, or excludes, the members it names and leaves the rest to other sources. When its next list no longer includes a member, that member is removed unless another source includes it.

  ```ruby
    # A business registry that knows only the businesses it has registered
    place.record_data_entries({ tenants: [{ id: harbor_books.id, registration_number: 'R-10' }] }, business_registry, mode: :partial)

    # Including some members and excluding others
    place.record_data_entries({ tenants: { include: [harbor_books], exclude: [corner_cafe] } }, business_registry, mode: :partial)
  ```

### Edits

An editor changes only what it names. `mode: :edit` applies a payload as single-member edits, at every level. Each member listed under `include:` is added to the source's member list, with the attributes given, each under `exclude:` is removed even if other sources include it, and the source's member list stops covering each under `forget:`. A plain list includes each member. The rest of the source's member list stays as it is.

  ```ruby
    place.record_data_entries({
      name: 'Harbor Building',
      tenants: {
        include: [
          { id: corner_cafe.id, unit: '2B', opening_hours: { include: [{ day: 6, opens_at: '10:00' }], exclude: [{ day: 7 }] } },
          { name: 'Harbor Books' } # new
        ],
        exclude: [{ id: old_florist.id }]
      }
    }, map_editor, mode: :edit)
    place.forge!
  ```

A member's nested lists in an edit are edits too, so `opening_hours` above changes two days and leaves the others to the sources that provide them.

One member at a time is the same call with one member in it.

  ```ruby
    # A map editor removing one imported tenant, and later undoing it
    place.record_data_entries({ tenants: { exclude: [corner_cafe] } }, map_editor, mode: :edit)
    place.record_data_entries({ tenants: { forget: [corner_cafe] } }, map_editor, mode: :edit)

    # A map editor adding one category without restating the rest
    place.record_data_entries({ place_categories: [{ category_id: landmark.id }] }, map_editor, mode: :edit)
  ```

#### Several edits before a forge

Edits made before a forge add up. Each keeps what it said about a member, and the forge records them in order, so a later edit of the same attribute wins and an edit of another attribute keeps the first. Excluding or forgetting a member drops what earlier edits said about it.

#### What an edit can't do

- **Forget a member of a complete list.** A complete list covers every member, so forgetting one raises. Record the source's list with `mode: :partial` first.
- **Exclude a member keyed by primary key before it exists.** Exclusions name members by key only.

### Recording a Rails form

Edits also accept the shapes a Rails form submits, at every level, so a controller can record its permitted params as they are, whether or not the model declares `accepts_nested_attributes_for`.

  ```ruby
    # params[:place] => { name: 'Harbor Hall', category_ids: ['', '3', '7'],
    #                     tenants_attributes: { '0' => { id: '12', unit: '2B', opening_hours_attributes: { '0' => { id: '40', _destroy: '1' } } },
    #                                           '1' => { name: 'Florist' } } }
    place.record_data_entries(params.require(:place).permit!, map_editor, mode: :edit)
    place.forge!
  ```

- `tenants_attributes`, an array or a hash keyed by index, becomes edits of `tenants`. A member with a truthy `_destroy` is excluded by its `id`, and any other is included. A has_one's becomes its single member, or none when destroyed, and its row being destroyed with no `id` is left out, as Rails ignores it.
- Where the owner declares `accepts_nested_attributes_for`, its `reject_if:` (a Proc, a method name, or `:all_blank`) leaves out the rows it rejects, new and existing alike but never a row being destroyed, and `_destroy` counts only with `allow_destroy: true`, as when Rails assigns the rows. A new owner's rows are checked on an unsaved instance. `limit:` and `update_only:` are not applied, so recording `*_attributes` for an association that declares them raises.
- `category_ids` includes the ids listed and excludes the current members left out, so a member another source adds later, which the form never showed, is not excluded. It edits the tracked association it names, or the tracked join association a `has_many :through` goes through, such as `place_categories` for `categories`.
- Members keyed by other columns than the primary key, such as opening hours keyed by day, are named by the key of the row their `id` names.
- An `id` that names none of the owner's current members raises `ActiveRecord::RecordNotFound`, as in Rails, where members are keyed by other columns and for a has_one's row being destroyed.
- Ids may be strings, as forms submit them.
- `*_attributes` or `*_ids` for an association that is not tracked raise `LaForge::InvalidAttributeName`, rather than being recorded as an attribute LaForge cannot forge. Save such associations outside LaForge. In another mode, these shapes raise `ArgumentError`, since they describe edits.

Anything else in the form, such as an association's own metadata stored outside the member, is up to the controller. A has_one takes a complete list, so it can't be edited.

### Removed members that sources list again

Excluding a member keyed by primary key destroys it, per `dependent:`, like any removed member. Its exclusion has to outlast the row. Otherwise, when the business directory next lists the tenant, its importer finds nothing, lists it as new, and it comes back. So the exclusion keeps a **tombstone** in the row's place, holding what the member was, and the association declares how to recognize a tombstone in what a source lists.

  ```ruby
    class Place < ApplicationRecord
      has_many :tenants, as: :occupiable, dependent: :destroy

      laforged associations: {
        tenants: { tombstone_matcher: ->(tenant, tombstones) { tombstones.find { |tombstone| tombstone.name == tenant.name } } }
      }
    end
  ```

The matcher receives an unsaved member built from what a source provided, and an unsaved member for each tombstone, built from what it was. It returns the tombstone the member is, or nil. It can use a fuzzy matcher, such as one that scores addresses.

  ```ruby
    place.record_data_entries({ tenants_attributes: [{ id: 12, _destroy: '1' }] }, map_editor, mode: :edit)
    place.forge!                        # Tenant 12 is destroyed, and the map editor's list keeps its tombstone
    place.data_entries.tombstones(:tenants)  # => [#<LaForge::Tombstone source: map_editor, attributes: { 'name' => 'Corner Café', ... }, excluded_at: ...>]
  ```

- **Each forge** checks the new members that member lists name against the tombstones, before membership is decided. A member a tombstone matches is decided as the excluded member, so a source that ranks below the excluding source cannot add it again, and a source that ranks above it can, which creates it and drops the tombstone.
- **Code that creates members itself,** such as an importer that builds and saves a tenant rather than listing it on the place, asks before saving a new one. `LaForge.tombstone_blocking(tenant, source)` returns the tombstone that keeps it out, with the same precedence rule, or nil.
- **A tombstone lasts** through the excluding source's later lists, until the source forgets it with `place.record_data_entries({ tenants: { forget: [tombstone] } }, map_editor, mode: :edit)`, which lets sources add the member again. Withdrawing the source drops its tombstones too.
- **Associations that need no tombstones:** join rows and associations with `key:` name something that outlasts the row, so their exclusions hold already, and a has_one takes only complete lists. Declaring `tombstone_matcher:` on one raises.

Excluding a member keyed by primary key without a `tombstone_matcher` raises `ArgumentError` when the exclusion is recorded, naming what to declare, rather than letting the member come back at the next import.

### How membership is decided

Membership is decided member by member. The highest precedence member list that covers a member decides it. A complete list covers every member, and a partial list only the members it names. So a complete list from a higher precedence source excludes members that lower partial lists add, and a source that only adds members needs to rank above the complete lists it adds to.

**Rows no member list has named are left alone,** by complete lists as well as partial lists. LaForge cannot tell a row created before an association was tracked from one created outside LaForge since, so it removes neither. A complete list only excludes members that some member list has named, by its key, in an include, exclude or withdrawal.

- **Adopting LaForge on an existing model needs no backfill.** An importer's first complete list names the rows it finds, by `id`, and from then on a complete list that stops naming one removes it. Rows that no feed mentions stay until someone removes them explicitly, such as an editor's exclusion.
- **A row nobody lists stays,** such as one added by hand outside LaForge, until a source names it.
- **Destroying a member list forgets what it named.** Its members are then rows no member list has named, and are left alone. To retract what a source said, so that its members are removed unless another source includes them, withdraw it instead (see [When a source stops listing members](#when-a-source-stops-listing-members)).

A `precedence:` given while recording covers everything the payload says, as it does for attributes recorded directly: the member list's say on membership, and every attribute of every member hash, down through nested lists. When the forge records a member's attributes, it gives each one a per-record rule for that source.

  ```ruby
    place.record_data_entries({ tenants: [{ id: 7, registration_number: 'R-10', unit: '2B' }] }, business_registry, precedence: 100)
    # the registry decides Tenant 7's membership, registration_number and unit on this place, at 100
  ```

- **A member passed as a saved record** says nothing about its attributes, so the precedence covers only its membership.
- **Everything in the hash gets it.** To make a source authoritative for one attribute only, record that attribute in its own call, or use a rule.
- **It writes one rule per member and attribute.** For "this source always wins this attribute", one model-wide rule is the better fit.

  ```ruby
    Tenant.update_attribute_source_precedence(:registration_number, business_registry, 100)
  ```

### Keys

- A member list cannot name the same member twice.
- With a key other than the primary key, every member a member list names needs a value for each key column. A current row missing a key value cannot be identified across sources, so forging leaves it alone, even when a complete list excludes every other member.
- Forging raises `LaForge::DuplicateMemberKey` when several current rows share a key, since LaForge cannot tell which one a source means. A unique index on the owner and key columns prevents this.
- Keys other than the primary key must be stable. A row whose key is edited becomes a different member. A source listing the old key gets a new row, and a complete list removes the edited one.
- With a key other than the primary key, a member belongs to one owner. When a source starts listing a member under another owner, the new owner gets a new row, built from what the source provides, and the old owner's row is removed when its sources stop including it, along with everything else recorded on it.

### When a member can't be created

When membership includes a member named by `id` that is no longer one of the owner's members, because it was destroyed or moved after the source named it, the forge skips it, logs a warning and lists it under `skipped:` in `forge_diff`. LaForge does not recreate a record with a given `id`; a source that lists it without one creates a new member.

With a key other than the primary key, when membership includes a member that does not exist and no member list says anything about it besides its key, the forge builds the member from its key. This happens when a source lists a member by key alone, and when a member was removed and destroyed, taking what was recorded on it, and membership later includes it again, such as when a map editor undoes an exclusion. If that member is invalid, as an opening hour without a time would be, the forge skips it in the same way, until a source lists it with its attributes.

### When a source stops listing members

A member that membership no longer includes is removed the way assigning the collection without it would remove it, following the association's `dependent:` option: destroyed for `:destroy`, deleted for `:delete_all`, and detached by nullifying its foreign key otherwise. Everything recorded on a destroyed member goes with it.

When a source's member list drops a member that another source keeps, because its complete list leaves the member out, or its partial list excludes it or stops including it, the forge withdraws the source from that member. Its entries on the member are destroyed when the owner is saved, and its member lists for the member's own tracked associations are withdrawn in turn, down every level. Each of the member's attributes then falls back to the other sources' entries. An attribute no other source has an entry for keeps its value, as it does when `withdraw_source` destroys a record's entries, so withdrawing never leaves a member invalid.

When values from a source are recorded on a member directly and a complete list from the same source is recorded on its owner, that list should include the member, since a complete list covers every member.

When an import no longer provides a record at all, choose between two things, as for attributes:

- **Retract what the source said:** `withdraw_source` destroys the source's attribute entries and withdraws every member it listed, so the next forge removes those members unless another source includes them. What its member lists said about members not yet recorded on them is dropped, and the next forge withdraws the source from every member another source keeps, as above.
- **Stop tracking what the source said:** destroying the source's entries leaves the association as it is. The members the source added stay, as attribute values stay when their entries are destroyed, and are treated from then on as rows no member list has named, which every member list leaves alone.

  ```ruby
    place.withdraw_source(business_registry)
    place.forge!
  ```

### How it works

Each source's member list for an association is one data entry on the owner, named after the association:

- A complete list is stored as an array of member keys, such as `[{ 'id' => 7 }, { 'id' => 9 }]`, or as `{ 'include' => [...], 'withdrawn' => [...] }` while it remembers members it used to include.
- A partial list is stored as `{ 'partial' => true, 'include' => [...], 'exclude' => [...], 'withdrawn' => [...] }`, with `'tombstones' => [...]` when it has excluded members whose rows are gone; they are excluded by `{ 'tombstone' => '<token>' }`. `withdrawn` holds the keys of members the source used to include, until the next forge has acted on them; see below.
- What a source said about a member besides its key waits under `'pending'`, with when it was said, until a forge records it on the member. A complete list with anything pending is stored as `{ 'include' => [...], 'pending' => [...] }`.
- A new member is keyed `{ 'new' => '<placeholder>' }` until the forge that creates it is saved.

Everything else is ordinary data entries on the members themselves. A forge of the owner then:

1. Names each new member that the association's tombstone matcher recognizes by that tombstone's key.
2. Decides membership member by member, from the highest-precedence member list that covers each.
3. Finds or builds each included member, and records on it what the member lists hold pending for it, oldest first.
4. Withdraws each source whose member list excludes or withdrew a member it keeps from that member.
5. Forges the members it recorded on or withdrew from, which applies their own tracked associations the same way.
6. Removes what it recorded from the member lists' pending, and drops the withdrawn keys it has acted on. A partial list left with nothing in it is destroyed.
7. Keeps a tombstone for each member keyed by primary key that it removes because a member list excludes it, and names it by the tombstone's key in every member list.
8. Removes the members membership no longer includes, per the association's `dependent:` option.

Nothing is written until the owner is saved. Once it is, the member lists name new members by their ids, and the entries step 4 withdrew are destroyed.

The withdrawn keys exist because LaForge leaves alone rows that no member list has named. A member that a member list stops naming, or that `withdraw_source` withdraws, would otherwise look like such a row, and stay. The withdrawn keys mark it for one forge, which removes it unless another source includes it, and withdraws the source from it if it is kept. Then they go.

### Inspecting associations

  ```ruby
    place.source_values(:tenants)        # => { business_directory => [{ 'id' => 7, 'name' => 'Corner Café' }], ... }, including what member lists hold for members not yet recorded on
    Place.source_values(:tenants, records: places)                  # the same for many records, in a constant number of queries
    place.member_sources(:tenants, id: 7)
    # => { membership: map_editor, listed_by: [map_editor, business_directory], excluded_by: [],
    #      attributes: { 'name' => business_directory } }
    place.forge_diff['tenants']          # => { added: [...], removed: [...], changed: [...] }, and skipped: when any would be; a new member is added as its attributes
  ```

A member's own `data_source_names` and `data_source?` count only the sources with entries on the member. A source that lists the member without saying anything about it, such as a map editor including it by key, is not among them; `member_sources` on the owner names it. So an orphan check that asks whether another source still claims a member should check both.

  ```ruby
    tenant.withdraw_source(business_registry)
    listed_by = place.member_sources(:tenants, id: tenant.id)[:listed_by] - [business_registry]
    tenant.archive! if listed_by.empty? && tenant.data_entries.without_source(business_registry).empty?
  ```

`spec/lib/association_importer_scenarios_spec.rb` walks through these cases over several import runs, and `spec/lib/association_capabilities_spec.rb` covers each capability.

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

Whether another source still has entries on the record tells whether anything else still claims it exists. A source that only supplies values, such as the geocoder, can be left out of that check:

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

### Pitfalls

- Recorded entries are unsaved until the record is saved. Reloading the record before saving discards them, along with any forged values.
- `forge` applies every stored entry, so stopping recording an attribute is not enough to stop forging it; its existing entries must be deleted.

## Associations

A `belongs_to` association needs no declaration: record the associated record, or `nil`, and it is stored as the foreign key (and the type, when polymorphic), resolved across sources like any attribute.

  ```ruby
    tenant.record_data_entries({ occupiable: place }, business_directory) # stored as occupiable_id and occupiable_type
  ```

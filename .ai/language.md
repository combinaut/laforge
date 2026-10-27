# Language guide

How LaForge's README, code comments, spec descriptions, error messages, commit messages and PR bodies use words. Use the terms below, and only these, for the concepts they name, so a reader never wonders whether two words mean two things.

## Vocabulary

### Sources and values

| Say | Meaning | Don't say |
|---|---|---|
| a source **provides** a value | A data source has a value for an attribute. Nil is a value too, so a source that provides nil provides the attribute, and one that leaves the attribute out doesn't. The application records what a source provides, so a source never records or updates. | reports, supplies, sends, records, updates, has an opinion |
| **record** a value | Store values from a source. Importers, editors, forms and forges are application code, so they record. One call that records values from a source is **a recording** from the source. | report, import, save, the source records, the source's recording |
| **data entry**, or **entry** | One source's recorded value for one attribute of one record. | report, datum |
| **forge** | Combine a record's entries into its attributes and its tracked associations' membership. | build, sync, resolve |
| **precedence** | How sources rank against each other. A higher precedence wins. | priority, weight, source of truth |
| **wins**, **outranks** | A value wins when forging takes it. A source outranks another when its precedence is higher. | overrides, beats |
| **precedence rule** | A source's precedence at one level. | override, setting |
| **level** | One attribute of one record, one attribute of a model, a whole model, or global. | scope, tier |
| **precedence order** | The sources in order at one level. | ranking, priority list |
| **ruleset**, **base rules** | Defined, with the rest of the ruleset vocabulary, in the comment on `class << self` in `lib/laforge/rulesets.rb`. | profile, domain |
| **inactive source** | A source whose entries are kept but left out of forging. | disabled, paused |

### Associations

| Say | Meaning | Don't say |
|---|---|---|
| **tracked association** | A `has_many` or `has_one` whose membership LaForge forges from sources. | managed association |
| **owner**, **member** | The record a tracked association belongs to, which Rails calls its `owner`, and one of the association's records, which Rails calls an associated record. | parent, child, associated record |
| **member list** | What one source provides for a tracked association on one owner. A **complete list** covers every member, and a **partial list** only the members it names. An **edit** changes how a source's member list covers the members it names, and is never a kind of member list. | report, a bare "list" |
| a member list **covers** a member | It includes or excludes the member. Its **coverage** is which members it includes, which it excludes, and which it doesn't cover. A partial list no longer covers a member once its inclusion or exclusion expires, while a complete list still excludes a member whose inclusion expired. | has an opinion, stance, view, verdict |
| **includes**, **excludes** | How a member list covers a member. | adds, removes or keeps, which say what a forge or membership does to a member |
| **membership** | Which members an association ends up with, decided member by member. | final state |
| a member list **withdraws** a member | It stops including a member it included. A partial list then no longer covers the member, so other sources decide it, while a complete list excludes it. | drops, abandons |
| **withdraw a source** from a record | Take back everything the source provided for the record, its entries and its member lists' coverage alike. | remove, forget |
| **pending** | Values a member list provides for an included member, waiting to be recorded on it. | queued, staged |
| **tombstone** | What a partial list keeps of a member it excluded, once the member is removed. | archive, ghost |

## Examples

Examples use a map system, never a real client, product or field:

- **Sources:** `cadastre` (an importer), `business_directory` (outranks it), `business_registry` (outranks both where `precedence:` is passed with its values), `map_editor` (manual edits, the highest), `geocoder` (provides values only).
- **Models:** `Place`, `Category` through `PlaceCategory`, `ParcelLink` (with `Parcel` and `ParcelLinkType`), `Tenant` (polymorphic `occupiable`, `registration_number`, status `open` or `closed`), `OpeningHour`.

Run a new concept past the maintainers before adding it to the example domain.

## Writing

- **American spelling:** behavior, recognize, summarize.
- **People:** they/them for anyone whose pronouns you don't know.
- **Colons:** only to introduce a list, never inside a sentence.
- **Errors:** say what the developer has to declare or pass to fix it, naming the model, association or option.
- **README sections:** open with the common case. Put an unusual situation in a subsection named for the situation.
- **Code comments:** a comment explains what a clearer name or design can't. Before writing one, try renaming the method or variable, or restructuring the code, so that it needs no explanation. A class comment says what the class is for, as "Used to …" or a noun phrase defining the concept. A class or module comment that is the first thing inside `module LaForge`, or inside a reopened class, opens with its subject's name in backticks, as in "`Forging` is used to …". A method comment starts with what the method does or returns. Define working vocabulary once, at the module that owns it. Never narrate a change.
- **No self-narration:** say the thing, not that you're about to say it.

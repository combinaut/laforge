module LaForge
  # Used to read and build the value of a source's `DataEntry` for a tracked association, which is the source's report
  # of the association's members. Members are named by key (see AssociationConfig).
  #
  # A report is one of:
  # - complete: has an opinion on every member. It includes the members it lists and excludes every other member some
  #   report names.
  # - partial: has an opinion only on the members it includes or excludes, and leaves the rest to other sources.
  #
  # A report holds these lists:
  # - include: the members it includes.
  # - exclude: the members a partial report excludes. A complete report has none, since it excludes a member by leaving
  #   it out.
  # - withdrawn: the members it included before and no longer names. They stay named until the next forge, which
  #   removes each one no report includes and drops the source's entries on each one it keeps, then empties the list.
  #   A row no report names is left alone.
  # - pending: what the source said about included members besides their keys, until a forge of the owner includes the
  #   member and records it there. A member can have several items, recorded oldest first. Each item holds:
  #   - 'key': the member's key
  #   - 'attributes': what the source said about the member
  #   - 'recorded_at': when the source said it
  #   - 'edit': true for an item from an edit, whose nested lists are then recorded as edits
  #   - 'precedence': when present, given to every attribute the item records, as recording them directly with
  #     `precedence:` would. nil removes the source's precedence for them.
  # - tombstones: what each member a partial report excluded was, once a forge has removed its row (see Tombstone).
  #   Each item is { 'key' => { 'tombstone' => token }, 'attributes' => {...}, 'excluded_at' => time }, and every report
  #   names the member by that tombstone key from then on. A tombstone is kept until its source forgets the member,
  #   records a complete report, or withdraws its whole report.
  #
  # The stored value is:
  # - complete: the array of included members, or { 'include' => [...] } with 'withdrawn' and 'pending' when either has
  #   items
  # - partial: { 'partial' => true, 'include' => [...], 'exclude' => [...], 'withdrawn' => [...] }, with 'pending' and
  #   'tombstones' when either has items
  class MemberList
    attr_reader :include, :exclude, :withdrawn, :pending, :tombstones

    def self.partial(include: [], exclude: [], withdrawn: [], pending: [], tombstones: [])
      value(include: include, exclude: exclude, withdrawn: withdrawn, pending: pending, tombstones: tombstones, partial: true)
    end

    # Returns the value stored for a report with the given lists. Pending items whose attributes are empty are left out,
    # and so are the exclusions and tombstones given for a complete report.
    def self.value(include: [], exclude: [], withdrawn: [], pending: [], tombstones: [], partial: false)
      pending = pending.reject { |item| item['attributes'].empty? }
      value = partial ? { 'partial' => true, 'include' => include, 'exclude' => exclude, 'withdrawn' => withdrawn } : include
      value = value.merge('tombstones' => tombstones) if partial && tombstones.any?
      value = { 'include' => include, 'withdrawn' => withdrawn } if !partial && withdrawn.any?
      return value if pending.empty?

      (value.is_a?(Hash) ? value : { 'include' => include }).merge('pending' => pending)
    end

    def self.tombstone_item(key_hash, attributes, excluded_at)
      { 'key' => key_hash, 'attributes' => attributes, 'excluded_at' => excluded_at.utc.iso8601(6) }
    end

    # Returns a pending item for the member with the given key. It has 'precedence' only when `precedence:` is given, so
    # an explicit nil is kept and removes the source's precedence.
    def self.pending_item(key_hash, attributes, recorded_at, edit: false, precedence: NOT_GIVEN)
      item = { 'key' => key_hash, 'attributes' => attributes, 'recorded_at' => recorded_at.utc.iso8601(6) }
      item['edit'] = true if edit
      item['precedence'] = precedence unless precedence.equal?(NOT_GIVEN)
      item
    end

    # Reads a report from its stored value. `marked: true` reads the report of an entry marked for destruction, which
    # includes nothing, has no pending items or tombstones, and withdraws every member it included. A complete one then
    # excludes every member, and a partial one has no opinion on any.
    def initialize(value, marked: false)
      if value.is_a?(Hash) && value['partial']
        @partial = true
        @include = marked ? [] : Array(value['include'])
        @exclude = marked ? [] : Array(value['exclude'])
        @withdrawn = Array(value['withdrawn']) + (marked ? Array(value['include']) : [])
      else
        @partial = false
        listed = Array(value.is_a?(Hash) ? value['include'] : value)
        @include = marked ? [] : listed
        @exclude = []
        @withdrawn = Array(value.is_a?(Hash) ? value['withdrawn'] : nil) + (marked ? listed : [])
      end
      @pending = marked || !value.is_a?(Hash) ? [] : Array(value['pending'])
      @tombstones = marked || !@partial ? [] : Array(value['tombstones'])
    end

    def partial?
      @partial
    end

    # Returns the stored value for this report with `pending` as its pending items.
    def with_pending(pending)
      self.class.value(include: include, exclude: exclude, withdrawn: withdrawn, pending: pending, tombstones: tombstones, partial: partial?)
    end

    # Returns the stored value for this report with each member whose key is in `names` named by the key hash `names`
    # maps that key to, in every list and pending item. For example, `{ ['new', '9f2c4e1a7b3d5f60'] => { 'id' => 42 } }`
    # names a new member by the id it was saved with. Members that end up with the same key are listed once. A tombstone
    # whose key is renamed is dropped, since its member is named by a row again.
    def renamed(config, names)
      rename = ->(member) { names[config.key_of(member)] || member }
      unique = ->(list) { list.map(&rename).uniq { |member| config.key_of(member) } }
      pending = self.pending.map { |item| item.merge('key' => rename.(item['key'])) }
      tombstones = self.tombstones.reject { |item| names.key?(config.key_of(item['key'])) }
      self.class.value(include: unique.(include), exclude: unique.(exclude), withdrawn: unique.(withdrawn), pending: pending, tombstones: tombstones, partial: partial?)
    end

    # Returns :include or :exclude for the member with the given key, or nil when this report has no opinion on it. A
    # complete report excludes every member it does not include.
    def decision(config, key)
      return :include if include.any? { |member| config.key_of(member) == key }
      return :exclude if !partial? || exclude.any? { |member| config.key_of(member) == key }

      nil
    end

    def withdrew?(config, key)
      withdrawn.any? { |member| config.key_of(member) == key }
    end

    def reported_keys(config)
      (include + exclude + withdrawn).map { |member| config.key_hash(member) }.uniq
    end
  end
end

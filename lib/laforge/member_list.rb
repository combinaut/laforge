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
  #
  # Each kind is a subclass, `MemberList::Complete` or `MemberList::Partial`, with the same interface. A method that
  # changes a report returns the stored value of the changed report, for the caller to write.
  class MemberList
    attr_reader :include, :exclude, :withdrawn, :pending, :tombstones

    # Reads a report from its stored value, as a `Complete` or a `Partial`. `marked: true` reads the report of an entry
    # marked for destruction, which includes nothing, has no pending items or tombstones, and withdraws every member it
    # included. A complete one then excludes every member, and a partial one has no opinion on any.
    def self.new(value, marked: false)
      return super unless equal?(MemberList)

      (value.is_a?(Hash) && value['partial'] ? Partial : Complete).new(value, marked: marked)
    end

    # Returns the report of a source that has none, which is a partial report with no opinion on any member
    def self.none
      Partial.new(Partial.value)
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

    # Returns the stored value for this report with each member whose key is in `names` named by the key hash `names`
    # maps that key to, in every list and pending item. For example, `{ ['new', '9f2c4e1a7b3d5f60'] => { 'id' => 42 } }`
    # names a new member by the id it was saved with. Members that end up with the same key are listed once. A tombstone
    # whose key is renamed is dropped, since its member is named by a row again.
    def renamed(config, names)
      rename = ->(member) { names[config.key_of(member)] || member }
      unique = ->(list) { list.map(&rename).uniq { |member| config.key_of(member) } }
      pending = self.pending.map { |item| item.merge('key' => rename.(item['key'])) }
      tombstones = self.tombstones.reject { |item| names.key?(config.key_of(item['key'])) }
      with(include: unique.(include), exclude: unique.(exclude), withdrawn: unique.(withdrawn), pending: pending, tombstones: tombstones)
    end

    # Returns the stored value for this report including the member named by the key hash `member`, with `item` as its
    # newest pending item
    def including(config, member, item)
      key = config.key_of(member)
      with(include: others(config, include, key) + [member], exclude: others(config, exclude, key), withdrawn: others(config, withdrawn, key), pending: pending + [item])
    end

    # Returns the stored value for a partial report that withdraws every member this one names, so its source has no
    # opinion on any. New members and tombstones are left out, and so are the pending items and tombstones.
    def withdrawing_all(config)
      Partial.value(withdrawn: reported_keys(config).reject { |member| config.unsaved?(member) })
    end

    # Returns the key hashes of the members this report included or withdrew that are not among `members`, except new
    # members and tombstones. A report of `members` replacing this one withdraws them.
    def left_out_by(config, members)
      reported = members.map { |member| config.key_of(member) }
      (include + withdrawn).map { |member| config.key_hash(member) }.uniq.reject { |member| reported.include?(config.key_of(member)) || config.unsaved?(member) }
    end

    def includes?(config, key)
      include.any? { |member| config.key_of(member) == key }
    end

    def withdrew?(config, key)
      withdrawn.any? { |member| config.key_of(member) == key }
    end

    def reported_keys(config)
      (include + exclude + withdrawn).map { |member| config.key_hash(member) }.uniq
    end

    # Returns the stored value for a report of this kind with the given lists in place of this report's own (see
    # `value` on each kind)
    def with(include: self.include, exclude: self.exclude, withdrawn: self.withdrawn, pending: self.pending, tombstones: self.tombstones)
      self.class.value(include: include, exclude: exclude, withdrawn: withdrawn, pending: pending, tombstones: tombstones)
    end

    private

    # Returns the withdrawn list without the member named by the key hash `member`, then with it at the end when this
    # report includes it
    def withdrawn_with(config, member)
      key = config.key_of(member)
      others(config, withdrawn, key) + (includes?(config, key) ? [config.key_hash(member)] : [])
    end

    # Returns `list` without the member with the given key
    def others(config, list, key)
      list.reject { |listed| config.key_of(listed) == key }
    end

    # Returns the pending or tombstone `items` without those of the member with the given key
    def items_without(config, items, key)
      items.reject { |item| config.key_of(item['key']) == key }
    end
  end
end

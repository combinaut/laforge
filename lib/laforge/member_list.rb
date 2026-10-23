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
  #   - 'precedence', 'expires_at' and 'expires_on_source_id': when present, the settings it was recorded with (see
  #     RecordingSettings), given to every attribute the item records as recording them directly with those settings
  #     would. A nil 'precedence' removes the source's precedence for them.
  # - tombstones: what each member a partial report excluded was, once a forge has removed its row (see Tombstone).
  #   Each item is { 'key' => { 'tombstone' => token }, 'attributes' => {...}, 'excluded_at' => time }, and every report
  #   names the member by that tombstone key from then on. A tombstone is kept until its source forgets the member,
  #   records a complete report, or withdraws its whole report.
  # - expiries: the inclusions and exclusions given an expiry of their own, by an edit or by `LaForge.with_settings`.
  #   Each item is { 'key' => {...}, 'recorded_at' => time, 'expires_at' => time, 'expires_on_source_id' => id }, and
  #   'recorded_at' is when the inclusion or exclusion was made (see Expiring). Once an item has expired the report has
  #   no opinion on that member, except that a complete report excludes it like any member it does not include, and the
  #   member's tombstone stops counting (see `counting_tombstones`). An expired item is kept, and so is the member in
  #   the report's lists.
  #
  # The stored value is:
  # - complete: the array of included members, or { 'include' => [...] } with 'withdrawn', 'pending' and 'expiries' when
  #   any has items
  # - partial: { 'partial' => true, 'include' => [...], 'exclude' => [...], 'withdrawn' => [...] }, with 'pending',
  #   'tombstones' and 'expiries' when any has items
  #
  # Each kind is a subclass, `MemberList::Complete` or `MemberList::Partial`, with the same interface. A method that
  # changes a report returns the stored value of the changed report, for the caller to write.
  class MemberList
    attr_reader :include, :exclude, :withdrawn, :pending, :tombstones, :expiries

    # Reads a report from its stored value, as a `Complete` or a `Partial`. `marked: true` reads the report of an entry
    # marked for destruction as a partial report with no opinion on any member, which withdraws every member it included
    # or withdrew, so another source's report decides them.
    def self.new(value, marked: false)
      return super(value) unless equal?(MemberList)

      report = (value.is_a?(Hash) && value['partial'] ? Partial : Complete).new(value)
      marked ? Partial.new(Partial.value(withdrawn: report.include + report.withdrawn)) : report
    end

    # Returns the report of a source that has none, which is a partial report with no opinion on any member
    def self.none
      Partial.new(Partial.value)
    end

    # Returns an expiries item giving the member with the given key the settings' expiry, made at `recorded_at`
    def self.expiry_item(key_hash, settings, recorded_at)
      { 'key' => key_hash, 'recorded_at' => recorded_at.utc.iso8601(6) }.merge(settings.expiry_item)
    end

    def self.tombstone_item(key_hash, attributes, excluded_at)
      { 'key' => key_hash, 'attributes' => attributes, 'excluded_at' => excluded_at.utc.iso8601(6) }
    end

    # Returns a pending item for the member with the given key, holding `attributes` as `RecordingSettings.storable`
    # stores them and `settings` as `RecordingSettings#to_item` stores them
    def self.pending_item(key_hash, attributes, recorded_at, edit: false, settings: RecordingSettings::DEFAULT)
      item = { 'key' => key_hash, 'attributes' => RecordingSettings.storable(attributes), 'recorded_at' => recorded_at.utc.iso8601(6) }
      item['edit'] = true if edit
      item.merge(settings.to_item)
    end

    # Returns the stored value for this report with each member whose key is in `names` named by the key hash `names`
    # maps that key to, in every list, pending item and expiries item. For example,
    # `{ ['new', '9f2c4e1a7b3d5f60'] => { 'id' => 42 } }` names a new member by the id it was saved with. Members that
    # end up with the same key are listed once. A tombstone whose key is renamed is dropped, since its member is named
    # by a row again.
    def renamed(config, names)
      rename = ->(member) { names[config.key_of(member)] || member }
      unique = ->(list) { list.map(&rename).uniq { |member| config.key_of(member) } }
      pending = self.pending.map { |item| item.merge('key' => rename.(item['key'])) }
      tombstones = self.tombstones.reject { |item| names.key?(config.key_of(item['key'])) }
      expiries = self.expiries.map { |item| item.merge('key' => rename.(item['key'])) }.uniq { |item| config.key_of(item['key']) }
      with(include: unique.(include), exclude: unique.(exclude), withdrawn: unique.(withdrawn), pending: pending, tombstones: tombstones, expiries: expiries)
    end

    # Returns the stored value for this report including the member named by the key hash `member`, with `item` as its
    # newest pending item. The inclusion takes `expiry`, an expiries item, in place of any the member had, and has no
    # expiry of its own when it is nil.
    def including(config, member, item, expiry: nil)
      key = config.key_of(member)
      with(include: others(config, include, key) + [member], exclude: others(config, exclude, key), withdrawn: others(config, withdrawn, key), pending: pending + [item],
           expiries: expiries_with(config, key, expiry))
    end

    # Returns the stored value for this report with each expiries item that expires on `source_id` and was made before
    # `recorded_at` expiring at `recorded_at`, or nil when no item changes. An item that already expires by then is left
    # as it is. An item not among `saved`, the items as the report was last saved, was made now. An item whose key a
    # forge has renamed since, as to a tombstone, is still the saved one: it matches a saved item whose key the report
    # no longer names in everything but the key.
    def expired_on(source_id, recorded_at, saved: [])
      keys = self.expiries.map { |item| item['key'] }
      renamed = saved.reject { |item| keys.include?(item['key']) }.map { |item| item.except('key') }
      changed = false
      expiries = self.expiries.map do |item|
        made_at = saved.include?(item) || renamed.include?(item.except('key')) ? Time.iso8601(item['recorded_at']) : Time.current
        next item unless item['expires_on_source_id'] == source_id && recorded_at > made_at
        next item if item['expires_at'] && Time.iso8601(item['expires_at']) <= recorded_at

        changed = true
        item.merge('expires_at' => recorded_at.utc.iso8601(6))
      end
      with(expiries: expiries) if changed
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

    # Returns the pending items of the members whose inclusion has not expired
    def counting_pending(config)
      pending.reject { |item| expired?(config, config.key_of(item['key'])) }
    end

    # Returns the tombstones whose member's exclusion has not expired
    def counting_tombstones(config)
      tombstones.reject { |item| expired?(config, config.key_of(item['key'])) }
    end

    # Whether this report's inclusion or exclusion of the member with the given key has an expiry of its own that has
    # passed by `at`
    def expired?(config, key, at = Time.current)
      item = expiries.find { |candidate| config.key_of(candidate['key']) == key }
      item.present? && item['expires_at'].present? && Time.iso8601(item['expires_at']) <= at
    end

    def withdrew?(config, key)
      withdrawn.any? { |member| config.key_of(member) == key }
    end

    def reported_keys(config)
      (include + exclude + withdrawn).map { |member| config.key_hash(member) }.uniq
    end

    # Returns the stored value for a report of this kind with the given lists in place of this report's own (see
    # `value` on each kind)
    def with(include: self.include, exclude: self.exclude, withdrawn: self.withdrawn, pending: self.pending, tombstones: self.tombstones, expiries: self.expiries)
      self.class.value(include: include, exclude: exclude, withdrawn: withdrawn, pending: pending, tombstones: tombstones, expiries: expiries)
    end

    private

    # Returns the withdrawn list without the member named by the key hash `member`, then with it at the end when this
    # report includes it by an inclusion that has not expired, or withdrew it
    def withdrawn_with(config, member)
      key = config.key_of(member)
      others(config, withdrawn, key) + (decision(config, key) == :include || withdrew?(config, key) ? [config.key_hash(member)] : [])
    end

    # Returns the expiries without the member's with the given key, then with `expiry` at the end unless it is nil
    def expiries_with(config, key, expiry)
      items_without(config, expiries, key) + [expiry].compact
    end

    # Returns `list` without the member with the given key
    def others(config, list, key)
      list.reject { |listed| config.key_of(listed) == key }
    end

    # Returns the pending, tombstone or expiries `items` without those of the member with the given key
    def items_without(config, items, key)
      items.reject { |item| config.key_of(item['key']) == key }
    end
  end
end

module LaForge
  # `MemberList` is one source's member list for a tracked association on one owner, read from and written to the
  # value of the source's `DataEntry` for the association. Members are named by key hash (see `AssociationConfig`).
  #
  # It comes in two kinds, each a subclass, which implement the `mode:` option of `record_data_entries`:
  # - `MemberList::Complete`, recorded with `mode: :complete`, covers every member. It includes the members
  #   in its include list, and excludes every other member some member list names.
  # - `MemberList::Partial`, recorded with `mode: :partial`, covers only the members it includes or
  #   excludes, and leaves the rest to other sources. Only a partial list has `forgetting`.
  # `mode: :edit` changes the source's member list, of either kind, for the members it names, and starts a partial list
  # when the source has none (see `TrackedAssociation#edit_member`).
  #
  # A member list names a member when its include, exclude or withdrawn list holds the member (see `listed_keys`). It
  # holds:
  # - include: the members it includes
  # - exclude: the members a partial list excludes. A complete list holds none, since it excludes a member by leaving
  #   it out.
  # - withdrawn: the members it included before and now neither includes nor excludes, and the members an edit
  #   excluded from a complete list. The next forge withdraws the source from each one membership keeps and removes
  #   the rest, then empties the withdrawn list.
  # - pending: what the source said about each included member besides its key (see `pending_item`), kept until a
  #   forge includes the member and records it on the member
  # - tombstones: what a partial list keeps of each member it excluded, once a forge has removed the member's row (see
  #   `Tombstone` and `tombstone_item`). Every member list that has not expired names the member by the tombstone's
  #   key from then on. A tombstone is kept until its source forgets the member, provides a complete list, or is
  #   withdrawn from the owner (see `withdrawing_all`).
  # - expiries: the inclusions and exclusions given an expiry of their own, by an edit or by `LaForge.with_settings`
  #   (see `expiry_item` and `Expiring`). Once one has expired, a partial list no longer covers that member, and the
  #   member's pending items and tombstone stop counting (see `counting_pending` and `counting_tombstones`). A complete
  #   list still excludes the member, as it excludes every member it does not include. The expired item is kept, and
  #   so is the member in the include, exclude or withdrawn list that holds it.
  #
  # The stored value is built by `Complete.value` and `Partial.value`. A method named for a change, such as `including`
  # or `withdrawing_all`, returns the stored value of the changed member list for the caller to write, and leaves this
  # member list as it is.
  class MemberList
    attr_reader :include, :exclude, :withdrawn, :pending, :tombstones, :expiries

    # Reads a member list from its stored value, as a `Complete` or a `Partial`. `marked: true` reads the member list of
    # an entry marked for destruction as a partial list that covers no member, which withdraws every member it
    # included or withdrew, so another source's member list decides them.
    def self.new(value, marked: false)
      return super(value) unless equal?(MemberList)

      list = (value.is_a?(Hash) && value['partial'] ? Partial : Complete).new(value)
      marked ? Partial.new(Partial.value(withdrawn: list.include + list.withdrawn)) : list
    end

    # Returns the member list of a source that has none, which is a partial list that covers no member
    def self.none
      Partial.new(Partial.value)
    end

    # Returns an expiries item giving the member with the given key the settings' expiry, made at `recorded_at`
    def self.expiry_item(key_hash, settings, recorded_at)
      { 'key' => key_hash, 'recorded_at' => recorded_at.utc.iso8601(6) }.merge(settings.expiry_item)
    end

    # Returns a tombstones item for the member a partial list excluded, whose tombstone key is `key_hash`, holding the
    # removed row's `attributes` and `excluded_at`
    def self.tombstone_item(key_hash, attributes, excluded_at)
      { 'key' => key_hash, 'attributes' => attributes, 'excluded_at' => excluded_at.utc.iso8601(6) }
    end

    # Returns a pending item for the member with the key hash `key_hash`, holding:
    # - 'key': `key_hash`
    # - 'attributes': `attributes`, as `RecordingSettings.storable` stores them
    # - 'recorded_at': `recorded_at`
    # - 'edit': true for an item from an edit, whose nested member lists are then recorded as edits, and left out
    #   otherwise
    # - 'precedence', 'expires_at' and 'expires_on_source_id': `settings`, as `RecordingSettings#to_item` stores them.
    #   Every attribute the item records takes them, as recording it directly with those settings would. A nil
    #   'precedence' removes the source's precedence for them.
    def self.pending_item(key_hash, attributes, recorded_at, edit: false, settings: RecordingSettings::DEFAULT)
      item = { 'key' => key_hash, 'attributes' => RecordingSettings.storable(attributes), 'recorded_at' => recorded_at.utc.iso8601(6) }
      item['edit'] = true if edit
      item.merge(settings.to_item)
    end

    # Returns the stored value for this member list with each member whose key is in `names` named by the key hash
    # `names` maps that key to, in every list, pending item and expiries item. For example,
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

    # Returns the stored value for this member list including the member named by the key hash `member`, with `item` as
    # its newest pending item. The inclusion takes `expiry`, an expiries item, in place of any the member had, and has
    # no expiry of its own when it is nil.
    def including(config, member, item, expiry: nil)
      key = config.key_of(member)
      with(include: others(config, include, key) + [member], exclude: others(config, exclude, key), withdrawn: others(config, withdrawn, key), pending: pending + [item],
           expiries: expiries_with(config, key, expiry))
    end

    # Returns the stored value for this member list with each expiries item that expires on `source_id` and was made
    # before `recorded_at` expiring at `recorded_at`, or nil when no item changes. An item that already expires by then
    # is left as it is. An item not among `saved`, the items as the member list was last saved, was made now. An item
    # whose key a forge has renamed since, as to a tombstone, is still the saved one, since it matches a saved item
    # whose key the member list no longer names in everything but the key.
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

    # Returns the stored value for a partial list that withdraws every member this one names except new members and
    # tombstones, so its source covers none. It holds nothing but the withdrawn list, so pending items,
    # tombstones and expiries go.
    def withdrawing_all(config)
      Partial.value(withdrawn: listed_keys(config).reject { |member| config.unsaved?(member) })
    end

    # Returns the key hashes of the members this member list included or withdrew that are not among `members`, except
    # new members and tombstones. A member list of `members` replacing this one withdraws them.
    def left_out_by(config, members)
      listed = members.map { |member| config.key_of(member) }
      (include + withdrawn).map { |member| config.key_hash(member) }.uniq.reject { |member| listed.include?(config.key_of(member)) || config.unsaved?(member) }
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

    # Whether this member list's inclusion or exclusion of the member with the given key has an expiry of its own that
    # has passed by `at`
    def expired?(config, key, at = Time.current)
      item = expiries.find { |candidate| config.key_of(candidate['key']) == key }
      item.present? && item['expires_at'].present? && Time.iso8601(item['expires_at']) <= at
    end

    def withdrew?(config, key)
      withdrawn.any? { |member| config.key_of(member) == key }
    end

    def listed_keys(config)
      (include + exclude + withdrawn).map { |member| config.key_hash(member) }.uniq
    end

    # Returns the stored value for a member list of this kind with the given lists in place of this member list's own
    # (see `value` on each kind)
    def with(include: self.include, exclude: self.exclude, withdrawn: self.withdrawn, pending: self.pending, tombstones: self.tombstones, expiries: self.expiries)
      self.class.value(include: include, exclude: exclude, withdrawn: withdrawn, pending: pending, tombstones: tombstones, expiries: expiries)
    end

    private

    # Returns the withdrawn list without the member named by the key hash `member`, then with it at the end when this
    # member list includes it by an inclusion that has not expired, or withdrew it
    def withdrawn_with(config, member)
      key = config.key_of(member)
      others(config, withdrawn, key) + (decision(config, key) == :include || withdrew?(config, key) ? [config.key_hash(member)] : [])
    end

    # Returns the expiries without the item of the member with the given key, then with `expiry` at the end unless it is
    # nil
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

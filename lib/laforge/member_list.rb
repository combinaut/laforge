module LaForge
  # One source's report of a tracked association's members, as stored in its data entry on the owner.
  #
  # A complete report is an array of members: it includes every member it lists and excludes every other member some
  # report has named. It is stored as { 'include' => [...], 'withdrawn' => [...] } while it remembers members it used to
  # include, until a forge has acted on them.
  # A partial report is { 'partial' => true, 'include' => [...], 'exclude' => [...], 'withdrawn' => [...] }: it has an
  # opinion only on the members it includes or excludes. 'withdrawn' keeps the keys of members it used to include, so a
  # member nobody includes any more can be removed, while rows no source ever reported are left alone.
  #
  # Members are listed by key. What the source said about an included member besides its key is kept in 'pending', as
  # [{ 'key' => {...}, 'attributes' => {...}, 'recorded_at' => time }], until a forge of the owner records it on the
  # member. An item from an edit also has 'edit' => true, so its nested lists are recorded as edits, and a member can
  # have several, recorded in order. A complete report with pending attributes is stored as
  # { 'include' => [...], 'pending' => [...] }.
  #
  # A partial report that excluded a member keyed by primary key whose row is now gone names it in 'exclude' by a
  # tombstone key, { 'tombstone' => token }, and keeps what it was in 'tombstones', as
  # [{ 'key' => {...}, 'attributes' => {...}, 'excluded_at' => time }], until the source forgets it.
  class MemberList
    attr_reader :include, :exclude, :withdrawn, :pending, :tombstones

    def self.partial(include: [], exclude: [], withdrawn: [], pending: [], tombstones: [])
      value(include: include, exclude: exclude, withdrawn: withdrawn, pending: pending, tombstones: tombstones, partial: true)
    end

    # The value stored for a report; pending items whose attributes are empty are left out
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

    # An item with 'precedence' gives that precedence to every attribute it records, as recording them directly with
    # `precedence:` would; nil removes it
    def self.pending_item(key_hash, attributes, recorded_at, edit: false, precedence: NOT_GIVEN)
      item = { 'key' => key_hash, 'attributes' => attributes, 'recorded_at' => recorded_at.utc.iso8601(6) }
      item['edit'] = true if edit
      item['precedence'] = precedence unless precedence.equal?(NOT_GIVEN)
      item
    end

    # A report marked for destruction says nothing: a complete one excludes everything, a partial one withdraws all
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

    # The stored value for this report with its pending items replaced
    def with_pending(pending)
      self.class.value(include: include, exclude: exclude, withdrawn: withdrawn, pending: pending, tombstones: tombstones, partial: partial?)
    end

    # The stored value for this report with the members named by the keys in `names` ({ key values => key hash }) named
    # by those key hashes instead, such as a new member's placeholder replaced by its id. A tombstone renamed this way
    # names a row again, so it is no longer kept. Members that become the same member are listed once.
    def renamed(config, names)
      rename = ->(member) { names[config.key_of(member)] || member }
      unique = ->(list) { list.map(&rename).uniq { |member| config.key_of(member) } }
      pending = self.pending.map { |item| item.merge('key' => rename.(item['key'])) }
      tombstones = self.tombstones.reject { |item| names.key?(config.key_of(item['key'])) }
      self.class.value(include: unique.(include), exclude: unique.(exclude), withdrawn: unique.(withdrawn), pending: pending, tombstones: tombstones, partial: partial?)
    end

    # :include, :exclude, or nil when this report has no opinion on the member with the given key
    def decision(config, key)
      return :include if include.any? { |member| config.key_of(member) == key }
      return :exclude if !partial? || exclude.any? { |member| config.key_of(member) == key }

      nil
    end

    def withdrew?(config, key)
      withdrawn.any? { |member| config.key_of(member) == key }
    end

    # Every key this report has ever had an opinion on, as key hashes
    def reported_keys(config)
      (include + exclude + withdrawn).map { |member| config.key_hash(member) }.uniq
    end
  end
end

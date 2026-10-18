module LaForge
  # One source's report of a tracked association's members, as stored in its data entry on the owner.
  #
  # A complete report is an array of members: it includes every member it lists and excludes every other.
  # A partial report is { 'partial' => true, 'include' => [...], 'exclude' => [...], 'withdrawn' => [...] }: it has an
  # opinion only on the members it includes or excludes. 'withdrawn' keeps the keys of members it used to include, so a
  # member nobody includes any more can be removed, while rows no source ever reported are left alone.
  #
  # Members are listed by key. What the source said about an included member besides its key is kept in 'pending', as
  # [{ 'key' => {...}, 'attributes' => {...}, 'recorded_at' => time }], until a forge of the owner records it on the
  # member. A complete report with pending attributes is stored as { 'include' => [...], 'pending' => [...] }.
  class MemberList
    attr_reader :include, :exclude, :withdrawn, :pending

    def self.partial(include: [], exclude: [], withdrawn: [], pending: [])
      value(include: include, exclude: exclude, withdrawn: withdrawn, pending: pending, partial: true)
    end

    # The value stored for a report; pending items whose attributes are empty are left out
    def self.value(include: [], exclude: [], withdrawn: [], pending: [], partial: false)
      pending = pending.reject { |item| item['attributes'].empty? }
      value = partial ? { 'partial' => true, 'include' => include, 'exclude' => exclude, 'withdrawn' => withdrawn } : include
      return value if pending.empty?

      (partial ? value : { 'include' => include }).merge('pending' => pending)
    end

    def self.pending_item(key_hash, attributes, recorded_at)
      { 'key' => key_hash, 'attributes' => attributes, 'recorded_at' => recorded_at.utc.iso8601(6) }
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
        @include = marked ? [] : Array(value.is_a?(Hash) ? value['include'] : value)
        @exclude = []
        @withdrawn = []
      end
      @pending = marked || !value.is_a?(Hash) ? [] : Array(value['pending'])
    end

    def partial?
      @partial
    end

    # The stored value for this report with its pending items replaced
    def with_pending(pending)
      self.class.value(include: include, exclude: exclude, withdrawn: withdrawn, pending: pending, partial: partial?)
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

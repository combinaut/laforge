module LaForge
  # One source's report of a tracked association's members, as stored in its data entry on the owner.
  #
  # A complete report is an array of members: it includes every member it lists and excludes every other.
  # A partial report is { 'partial' => true, 'include' => [...], 'exclude' => [...], 'withdrawn' => [...] }: it has an
  # opinion only on the members it includes or excludes. 'withdrawn' keeps the keys of members it used to include, so a
  # member nobody includes any more can be removed, while rows no source ever reported are left alone.
  class MemberList
    attr_reader :include, :exclude, :withdrawn

    def self.partial(include: [], exclude: [], withdrawn: [])
      { 'partial' => true, 'include' => include, 'exclude' => exclude, 'withdrawn' => withdrawn }
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
        @include = marked ? [] : Array(value)
        @exclude = []
        @withdrawn = []
      end
    end

    def partial?
      @partial
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

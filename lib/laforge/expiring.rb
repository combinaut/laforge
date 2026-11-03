module LaForge
  # `Expiring` is used to let a change to one record expire. A change is a data entry, or a precedence rule on one
  # record. A recording makes the change when it creates the row, and makes it again when it changes the row's value,
  # precedence or expiry. A save that changes none of them, such as a forge's bookkeeping, does not make the change
  # again.
  #
  # A change expires at a time, its `expires_at`, or on a source, its `expires_on_source`, by the trigger `expires_when`
  # names.
  #
  # With `:changes`, the default, an expiry on a source fires the first time a value from that source is recorded, after
  # the change was made (see `changed_at`), that differs from the source's own entry for the attribute, or for any
  # attribute of its group:
  # - an attribute's value doesn't match the entry's (see ValueMatcher). The record's forged value is not compared.
  # - a member list covers some member differently. An expiry on one member of an edit fires only when that member's
  #   coverage changes.
  # - a source with no entry for it yet provides one. For a tracked association, a first member list counts only when
  #   it covers some member.
  # Recording the same value from the source again leaves the change as it is. The expiry sets `expires_at` to when
  # the different value was recorded, and keeps the source, so the row still names what ended the change.
  #
  # With `:matches`, an expiry on a source fires once the change's value matches the source's (see ValueMatcher), or for
  # an attribute group, once every attribute of it matches. It is a state, not an event, so it is checked each time a
  # value from the source is recorded, the same value included, and when the change is recorded (see
  # `ExpiryTrigger::Matches`). A precedence rule has no value of its own, so it compares its source's entry for the same
  # record and attribute. A source with no entry, or an expired one, provides no value, so nothing matches it. A change
  # that already matches expires at its own `recorded_at`. Tracked associations have no value to compare, so they raise.
  #
  # Forging leaves an expired row out, as it leaves out an inactive source's, and the row is kept, so it can still be
  # read. An expiry takes effect when the record is next forged. Forging records on time, and removing expired rows,
  # are up to the application (see `expiring`).
  module Expiring
    extend ActiveSupport::Concern

    # CHANGES is the trigger of a change that names none
    CHANGES = 'changes'.freeze

    # TRIGGERS are the triggers `expires_when` holds, by name. A proc from `match_by:` is not stored, so a matcher is read
    # from the model each time a change is checked.
    TRIGGERS = { CHANGES => ExpiryTrigger::Changes.new(CHANGES), 'matches' => ExpiryTrigger::Matches.new('matches') }.freeze

    # NONE is the expiry of a change made without `expires_at:` or `expires_on:`. Assigning it clears an earlier expiry.
    NONE = { expires_at: nil, expires_on_source_id: nil, expires_when: CHANGES }.freeze

    # COLUMNS are the columns of a change that hold its expiry
    COLUMNS = NONE.keys.map(&:to_s).freeze

    # Returns the trigger named `name`. One that names none, as nil does, or no trigger `columns` takes, is CHANGES.
    def self.trigger(name)
      TRIGGERS.fetch(name.to_s, TRIGGERS[CHANGES])
    end

    included do
      belongs_to :expires_on_source, class_name: 'LaForge::DataSource', optional: true
      after_save do
        @remade = false
        @made_at = nil
      end
      # `recorded_at` is when the change was last made, as when a source said an entry's value and expiry, or a rule's
      # precedence and expiry were set. Recording them again unchanged leaves it as it is. Recording through LaForge
      # sets it, and a row saved without one gets the time of the save.
      before_save { self.recorded_at ||= Time.current }

      scope :expired, ->(at = Time.current) { where(arel_table[:expires_at].lteq(at)) }
      scope :unexpired, ->(at = Time.current) { where(expires_at: nil).or(where(arel_table[:expires_at].gt(at))) }
      # `expiring` returns the rows whose `expires_at` is before `before`, those already expired included, such as to
      # forge their records on time. A row that expires on a source has no `expires_at` until its expiry fires, so it is
      # left out until then.
      scope :expiring, ->(before:) { where(arel_table[:expires_at].lt(before)) }
    end

    # Returns `{ expires_at:, expires_on_source_id:, expires_when: }` for the `expires_at:`, `expires_on:` and
    # `expires_when:` given where a change is made, or NONE when none is given. `where` names the place in the error
    # message. Given any, raises ArgumentError when:
    # - `removing` is given. It describes what was passed that removes the change, such as "a nil precedence", which
    #   leaves nothing to expire.
    # - `expires_at` is not a time
    # - `expires_on` is `source`, the source the change comes from. The next values recorded from it replace the change
    #   and its expiry anyway.
    # - `expires_when` is given without `expires_on`, or is not the name of a trigger
    def self.columns(expires_at, expires_on, where:, expires_when: nil, source: nil, removing: nil)
      return NONE if expires_at.nil? && expires_on.nil? && expires_when.nil?

      raise ArgumentError, "#{where} with #{removing} removes it, so there is nothing to expire; pass expires_at: or expires_on: only when setting it" if removing
      raise ArgumentError, "#{where}: expires_at: must be a time, such as 2.weeks.from_now, not #{expires_at.inspect}" unless expires_at.nil? || expires_at.acts_like?(:time)
      raise ArgumentError, "#{where}: expires_when: says when an expiry on a source fires, so it needs expires_on:. Pass the source as expires_on:, or leave out expires_when:" if expires_when && expires_on.nil?
      raise ArgumentError, "#{where}: expires_when: must be #{TRIGGERS.keys.map { |name| ":#{name}" }.to_sentence(two_words_connector: ' or ', last_word_connector: ' or ')}, not #{expires_when.inspect}" unless expires_when.nil? || TRIGGERS.key?(expires_when.to_s)

      expires_on_source_id = expires_on && DataSource.normalize_source_id(expires_on)
      if expires_on_source_id && source && expires_on_source_id == DataSource.normalize_source_id(source)
        raise ArgumentError, "#{where}: expires_on: names the source these values come from, and the next values recorded from it replace these and their expiry anyway. " \
                             'Pass another source, whose different values should end the change'
      end

      { expires_at: expires_at, expires_on_source_id: expires_on_source_id, expires_when: trigger(expires_when).name }
    end

    def expired?(at = Time.current)
      expires_at.present? && expires_at <= at
    end

    def trigger
      Expiring.trigger(expires_when)
    end

    # Sets `expires_at` to `at`, unless the change already expires at or before `at`
    def expire(at)
      self.expires_at = at if expires_at.nil? || expires_at > at
    end

    # @api private
    # Notes that a recording has made the change again, at `at`, or now when `at` is nil. The note lasts until the row
    # is saved (see `changed_at`).
    def remade(at = nil)
      @remade = true
      @made_at = at
    end

    # @api private
    # `remade_state` and `remade_state=` read and restore what `remade` noted, so a preview of a recording can be undone
    def remade_state
      [@remade, @made_at]
    end

    def remade_state=(state)
      @remade, @made_at = state
    end

    # @api private
    # Returns when the change was made, which an expiry on a source compares a recording's time with. A new row, or one
    # made again since it was saved, was made when `remade` noted, or now. Any other row was made at its `recorded_at`.
    def changed_at
      new_record? || @remade ? (@made_at || Time.current) : recorded_at
    end
  end
end

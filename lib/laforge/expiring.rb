module LaForge
  # `Expiring` is used to let a change to one record expire. A change is a data entry, or a precedence rule on one
  # record. A recording makes the change when it creates the row, and makes it again when it changes the row's value,
  # precedence or expiry. A save that changes none of them, such as a forge's bookkeeping, does not make the change
  # again.
  #
  # A change expires at a time, its `expires_at`, or on a source, its `expires_on_source`. An expiry on a source fires
  # the first time a value from that source is recorded for the same attribute, attribute group or association of the
  # record after the change was made (see `changed_at`), whatever the source provides. It sets `expires_at` to when that
  # value was recorded, and keeps the source, so the row still names what ended the change.
  #
  # Forging leaves an expired row out, as it leaves out an inactive source's, and the row is kept, so it can still be
  # read. An expiry takes effect when the record is next forged. Forging records on time, and removing expired rows,
  # are up to the application (see `expiring`).
  module Expiring
    extend ActiveSupport::Concern

    # NONE is the expiry of a change made without `expires_at:` or `expires_on:`. Assigning it clears an earlier expiry.
    NONE = { expires_at: nil, expires_on_source_id: nil }.freeze

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
      # forge their records on time. A row that expires on a source has no `expires_at` until a value from the source is
      # recorded, so it is left out until then.
      scope :expiring, ->(before:) { where(arel_table[:expires_at].lt(before)) }
    end

    # Returns `{ expires_at:, expires_on_source_id: }` for the `expires_at:` and `expires_on:` given where a change is
    # made, or NONE when neither is given. `where` names the place in the error message. Given either, raises
    # ArgumentError when:
    # - `removing` is given. It describes what was passed that removes the change, such as "a nil precedence", which
    #   leaves nothing to expire.
    # - `expires_at` is not a time
    # - `expires_on` is `source`, the source the change comes from. The next values recorded from it replace the change
    #   and its expiry anyway.
    def self.columns(expires_at, expires_on, where:, source: nil, removing: nil)
      return NONE if expires_at.nil? && expires_on.nil?

      raise ArgumentError, "#{where} with #{removing} removes it, so there is nothing to expire; pass expires_at: or expires_on: only when setting it" if removing
      raise ArgumentError, "#{where}: expires_at: must be a time, such as 2.weeks.from_now, not #{expires_at.inspect}" unless expires_at.nil? || expires_at.acts_like?(:time)

      expires_on_source_id = expires_on && DataSource.normalize_source_id(expires_on)
      if expires_on_source_id && source && expires_on_source_id == DataSource.normalize_source_id(source)
        raise ArgumentError, "#{where}: expires_on: names the source these values come from, and the next values recorded from it replace these and their expiry anyway. " \
                             'Pass another source, whose next values should end the change'
      end

      { expires_at: expires_at, expires_on_source_id: expires_on_source_id }
    end

    def expired?(at = Time.current)
      expires_at.present? && expires_at <= at
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

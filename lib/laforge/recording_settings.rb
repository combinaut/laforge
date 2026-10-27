module LaForge
  # `NOT_GIVEN` stands for an omitted `precedence:` argument, so omitting it can be told from passing nil, which removes
  # the precedence.
  NOT_GIVEN = Object.new.freeze

  # Used to carry a recording's settings, the precedence and expiry it gives everything it records, however its payload
  # is split. That covers attributes, attribute groups, belongs_to columns, member lists at every level, edits, and the
  # pending items member lists keep for members until their owner is forged. The settings are
  # built once where recording starts, passed down as they are, and applied where an entry is written and where the
  # record's precedence rule for it is set.
  #
  # A wrapper is a part of a payload given settings of its own with `LaForge.with_settings`. It takes them in place of
  # the call's, for everything recorded from it (see `for`). A stored wrapper is a wrapper kept in a pending item, as a
  # hash with the STORED key.
  #
  # - precedence: the precedence of the record's rule for the source, for each attribute or attribute group recorded.
  #   NOT_GIVEN keeps the rule as it is, and nil removes it.
  # - expiry: `{ expires_at:, expires_on_source_id: }` for the entries and rules written (see Expiring).
  #   `Expiring::NONE` clears an earlier expiry.
  # - entry_expiry: the expiry of the entry the settings are applied to, which is `expiry` unless `with_entry_expiry`
  #   gives another. nil leaves the entry's own expiry as it is.
  class RecordingSettings
    attr_reader :precedence, :expiry, :entry_expiry

    # STORED is the key of a stored wrapper, which holds the wrapper's settings beside its 'value' (see `storable`)
    STORED = '_laforge_settings'.freeze

    # Returns the settings for the options given where a change is made. Raises as `Expiring.columns` does for an expiry
    # that cannot be used.
    def self.given(precedence: NOT_GIVEN, expires_at: nil, expires_on: nil, where:, source: nil, removing: nil)
      new(precedence: precedence, expiry: Expiring.columns(expires_at, expires_on, where: where, source: source, removing: removing))
    end

    # Returns the settings stored in a pending item (see MemberList) or a stored wrapper, under the keys `to_item`
    # writes
    def self.from_item(item)
      new(precedence: item.key?('precedence') ? item['precedence'] : NOT_GIVEN,
          expiry: { expires_at: item['expires_at'] && Time.iso8601(item['expires_at']), expires_on_source_id: item['expires_on_source_id'] })
    end

    # Returns pending `items` (see MemberList) without each 'expires_on_source_id' that names a source deleted since, in
    # an item and in the stored wrappers in its attributes, so restoring the settings gives no expiry on a source, and
    # 'expires_at' is kept. Deleting a source nulls the columns that name it, but not the ids in a member list's value,
    # which would then fail the foreign key where they are recorded. Looks the ids up in one query, when there are any.
    def self.without_deleted_sources(items)
      ids = items.flat_map { |item| [item['expires_on_source_id'], *stored_source_ids(item['attributes'])] }.compact.uniq
      return items if ids.empty?

      deleted = ids - DataSource.where(id: ids).ids
      return items if deleted.empty?

      drop = ->(settings) { deleted.include?(settings['expires_on_source_id']) ? settings.except('expires_on_source_id') : settings }
      items.map { |item| drop.(item).merge('attributes' => with_stored_settings(item['attributes'], &drop)) }
    end

    # Returns the 'expires_on_source_id' of each stored wrapper in `value`
    def self.stored_source_ids(value)
      case value
      when Hash then stored?(value) ? [value[STORED]['expires_on_source_id'], *stored_source_ids(value['value'])] : value.values.flat_map { |item| stored_source_ids(item) }
      when Array then value.flat_map { |item| stored_source_ids(item) }
      else []
      end
    end

    # Returns `value` with the settings of each stored wrapper in it replaced by what the block returns for them
    def self.with_stored_settings(value, &block)
      case value
      when Hash
        return value.transform_values { |item| with_stored_settings(item, &block) } unless stored?(value)

        { STORED => block.call(value[STORED]), 'value' => with_stored_settings(value['value'], &block) }
      when Array then value.map { |item| with_stored_settings(item, &block) }
      else value
      end
    end

    # Raises ArgumentError, naming `where`, when anywhere in `value`:
    # - a wrapper expires on `source_id`, the source of the values. The next values recorded from it replace what it
    #   wraps anyway.
    # - a hash has the STORED key, which would read back as a stored wrapper
    def self.assert_wrappers_valid!(value, source_id, where:)
      case value
      when WithSettings
        if value.settings.expiry && value.settings.expiry[:expires_on_source_id] == source_id
          raise ArgumentError, "#{where}: LaForge.with_settings(expires_on:) names the source this value comes from, and the next values recorded from it replace it and its expiry anyway. " \
                               'Pass another source, whose next values should end the change'
        end
        assert_wrappers_valid!(value.value, source_id, where: where)
      when Hash
        if value.key?(STORED) || value.key?(STORED.to_sym)
          raise ArgumentError, "#{where}: #{STORED} is a key LaForge reserves for the settings it keeps with a value in a member list's pending items, so a recorded hash cannot use it. " \
                               'Rename the key, or give the value settings with LaForge.with_settings'
        end
        value.each_value { |item| assert_wrappers_valid!(item, source_id, where: where) }
      when Array then value.each { |item| assert_wrappers_valid!(item, source_id, where: where) }
      end
    end

    # Raises ArgumentError, naming `where`, for a wrapper or a stored wrapper anywhere in `value`, a value recorded
    # whole, such as an attribute's JSON value, which has nowhere to keep a wrapper's settings
    def self.assert_none_in!(value, where:)
      case value
      when WithSettings, ->(item) { stored?(item) }
        raise ArgumentError, "#{where}: LaForge.with_settings can wrap an attribute's whole value, a member or a nested list, not part of a value; wrap the whole value"
      when Hash then value.each_value { |item| assert_none_in!(item, where: where) }
      when Array then value.each { |item| assert_none_in!(item, where: where) }
      end
    end

    # Raises ArgumentError, naming `where`, unless the attributes of each of `model`'s attribute groups in `values`,
    # `{ attribute name => value }`, are all wrapped with equal settings or all unwrapped, since a group's values from a
    # source are recorded together
    def self.assert_groups_alike!(model, values, where:)
      return unless model.respond_to?(:laforge)

      values = values.to_h { |name, value| [name.to_s, value] }
      model.laforge.attribute_groups.each do |group, attributes|
        settings = attributes.select { |attribute| values.key?(attribute) }.map { |attribute| settings_of(values[attribute]) }.uniq
        next if settings.size < 2

        raise ArgumentError, "#{where}: #{attributes.join(', ')} are attribute group #{group}, whose values from a source are recorded together with the same settings; " \
                             'wrap all of them with the same LaForge.with_settings, or none'
      end
    end

    # Returns `value` with each wrapper and stored wrapper replaced by the value it wraps, at every level. For example,
    # `{ 'name' => LaForge.with_settings('Harbor Café', expires_at: time) }` becomes `{ 'name' => 'Harbor Café' }`.
    def self.strip(value)
      case value
      when WithSettings then strip(value.value)
      when Hash then stored?(value) ? strip(value['value']) : value.transform_values { |item| strip(item) }
      when Array then value.map { |item| strip(item) }
      else value
      end
    end

    # Returns `value` as a pending item stores it, each wrapper at every level replaced by a stored wrapper,
    # `{ STORED => settings.to_item, 'value' => value }`
    def self.storable(value)
      case value
      when WithSettings then { STORED => value.settings.to_item, 'value' => storable(value.value) }
      when Hash then value.transform_values { |item| storable(item) }
      when Array then value.map { |item| storable(item) }
      else value
      end
    end

    def self.wrapped?(value)
      value.is_a?(WithSettings) || stored?(value)
    end

    def self.stored?(value)
      value.is_a?(Hash) && value.key?(STORED)
    end

    # Returns the settings of a wrapper or a stored wrapper, or nil for any other value
    def self.settings_of(value)
      return value.settings if value.is_a?(WithSettings)

      from_item(value[STORED]) if stored?(value)
    end

    def initialize(precedence: NOT_GIVEN, expiry: Expiring::NONE, entry_expiry: expiry)
      @precedence = precedence
      @expiry = expiry.freeze
      @entry_expiry = entry_expiry&.freeze
      freeze
    end

    # DEFAULT is the settings of a recording given no options, which keep rules as they are and clear expiries
    DEFAULT = new

    def ==(other)
      other.is_a?(RecordingSettings) && precedence.equal?(NOT_GIVEN) == other.precedence.equal?(NOT_GIVEN) &&
        (precedence.equal?(NOT_GIVEN) || precedence == other.precedence) && expiry == other.expiry && entry_expiry == other.entry_expiry
    end
    alias eql? ==

    def hash
      [precedence_given? ? precedence : NOT_GIVEN, expiry, entry_expiry].hash
    end

    # Returns `[value, settings]` for a part of a payload. A wrapper or stored wrapper gives the value it wraps and its
    # own settings, and any other value is returned as it is with these settings.
    def for(value)
      return [value.value, value.settings] if value.is_a?(WithSettings)
      return [value['value'], self.class.from_item(value[STORED])] if self.class.stored?(value)

      [value, self]
    end

    def precedence_given?
      !precedence.equal?(NOT_GIVEN)
    end

    def expiring?
      expiry.values.any?
    end

    # Returns these settings with `precedence` in place of their own
    def with_precedence(precedence)
      self.class.new(precedence: precedence, expiry: expiry, entry_expiry: entry_expiry)
    end

    # Returns these settings with `entry_expiry` for the entry they are applied to, and `expiry` for the rest. nil
    # leaves the entry's own expiry as it is.
    def with_entry_expiry(entry_expiry)
      self.class.new(precedence: precedence, expiry: expiry, entry_expiry: entry_expiry)
    end

    # Returns the keys a pending item stores these settings under, for `from_item` to read back. 'precedence' is present
    # only when a precedence is given, so an explicit nil is kept and removes the source's precedence.
    def to_item
      item = {}
      item['precedence'] = precedence if precedence_given?
      item.merge(expiry_item)
    end

    # Returns the expiry's keys alone, as `to_item` writes them
    def expiry_item
      item = {}
      item['expires_at'] = expiry[:expires_at].utc.iso8601(6) if expiry[:expires_at]
      item['expires_on_source_id'] = expiry[:expires_on_source_id] if expiry[:expires_on_source_id]
      item
    end

    def apply_to_entry(data_entry)
      data_entry.assign_attributes(entry_expiry) if entry_expiry
    end

    # Sets the rule's precedence and expiry, for settings whose precedence is not nil
    def apply_to_rule(rule)
      rule.precedence = precedence
      rule.assign_attributes(expiry)
    end
  end

  # A wrapper (see RecordingSettings), made with `LaForge.with_settings`
  class WithSettings
    attr_reader :value, :settings

    def initialize(value, settings)
      @value = value
      @settings = settings
      freeze
    end

    # Returns a wrapper with the same settings around `value`
    def with_value(value)
      self.class.new(value, settings)
    end
  end

  # Returns `value` wrapped with settings of its own, which replace the call's for everything recorded from it. In a
  # `record_data_entries` payload, the wrapper can stand for any of:
  # - an attribute's whole value, or a belongs_to's record
  # - a member, for its attributes, its nested lists and its inclusion
  # - an excluded member
  # - a tracked association's whole value, or a nested list
  # An option left out is not given, as for the call, so a wrapper without `expires_at:` or `expires_on:` gives what it
  # wraps no expiry, whatever the call's.
  #
  # A precedence ranks the source for a whole association, so a wrapper's precedence on a member applies to the
  # member's own attributes. The association's precedence comes from the call, or from a wrapper around its whole value.
  # Raises ArgumentError for a value that is already wrapped, and for an expiry that cannot be used (see
  # `Expiring.columns`). Recording raises for a precedence on a member with no attributes, such as an exclusion or a
  # saved record, unless it is the call's.
  def self.with_settings(value, precedence: NOT_GIVEN, expires_at: nil, expires_on: nil)
    raise ArgumentError, 'LaForge.with_settings cannot wrap a value that is already wrapped; give one wrapper all the settings' if RecordingSettings.wrapped?(value)

    WithSettings.new(value, RecordingSettings.given(precedence: precedence, expires_at: expires_at, expires_on: expires_on, where: 'LaForge.with_settings'))
  end
end

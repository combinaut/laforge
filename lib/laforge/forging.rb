module LaForge
  # `Forging` is used to forge a laforged record's attributes and tracked associations from its data entries
  module Forging
    extend ActiveSupport::Concern

    API = %i[forge! forge forge_associations forge_diff forge_attributes resolved_entries resolved_entry resolved_source].freeze

    # Assign attributes and save the record based on the data entries
    def forge!(**forge_options, &block)
      record.transaction do
        block.call if block_given?
        record.forge(**forge_options) # through the model, so a `forge` it defines after `laforged` runs here too
        record.save!
      end
    end

    # Assign attributes and tracked associations based on the data entries. The record's ruleset is selected once,
    # before any attribute is assigned, so attributes and associations rank alike even when forging changes what the
    # selector reads. Associations are forged before the attributes are assigned, so each member selects its ruleset
    # from the record as the forge found it, as `forge_diff` does.
    # A writer that raises a StandardError does not stop the forge. The remaining attributes are assigned, and the forge
    # then raises one `WriterError` for every writer that raised, so `forge!` saves nothing.
    def forge(attributes: nil, sources: nil)
      with_one_ruleset do
        forged = forged_entries(attributes: attributes, sources: sources)
        forge_associations(associations: attributes)
        assign_forged(record, forged)
      end
    end

    def forge_associations(associations: nil)
      reset_resolver_unless_held # selects the ruleset and reads the rules again
      names = associations ? Array.wrap(associations).map(&:to_s) : self.associations.keys
      self.associations.slice(*names).each_value { |config| TrackedAssociation.new(record, config).forge }
    end

    # @api private
    # Returns `forge_diff` as it would be once `pending` is recorded on the record, then restores the record's entries
    # and rules. `pending` is what its owner's member lists keep pending for it, as
    # [[source id, attributes, recorded_at, edit, settings], ...].
    def forge_diff_with(pending)
      entries = record.data_entries.to_a
      values = entries.to_h { |entry| [entry, [entry.attributes.slice('value', 'recorded_at', *Expiring::COLUMNS), entry.remade_state, entry.marked_for_destruction?]] }
      rules = record.precedence_rules.to_a # recording builds, changes and expires rules, which the owner's next save writes
      settings = rules.to_h { |rule| [rule, [rule.attributes.slice('precedence', 'recorded_at', *Expiring::COLUMNS), rule.remade_state, rule.marked_for_destruction?]] }
      replay_pending(pending)
      forge_diff
    ensure
      record.data_entries.target.replace(entries)
      values.each { |entry, (attributes, remade, marked)| entry.assign_attributes(attributes); entry.remade_state = remade; LaForge::ActiveRecord.set_marked_for_destruction(entry, marked) }
      record.precedence_rules.target.replace(rules)
      settings.each { |rule, (attributes, remade, marked)| rule.assign_attributes(attributes); rule.remade_state = remade; LaForge::ActiveRecord.set_marked_for_destruction(rule, marked) }
    end

    # Returns { attribute name => [the record's value, the forged value] } for each attribute whose forged value
    # differs from what the record reads, and each tracked association's membership diff (see `TrackedAssociation#diff`)
    # by its name. Takes the options `forge_attributes` takes, and selects the ruleset once as `forge` does.
    #
    # The forged value is compared as it was recorded, so an attribute whose writer changes what it is given is reported
    # although a forge would leave it as it is, such as a date recorded as text, or a name the writer strips.
    #
    # `through_setters: true` compares what the record would read once a forge had assigned the forged values. It
    # assigns every forged value, in the order a forge does, to an unsaved copy of the record, a `dup` marked read-only,
    # and reads each attribute back from the copy. It reports the attributes that read differently from the record,
    # with the value the copy reads. The copy is never validated or saved. The assignment runs inside a transaction that
    # is rolled back, a savepoint inside an open one, so what a writer writes to the database is undone. Nothing else a
    # writer does is undone. A writer finds no id on the copy, and callbacks that run on save do not run, so a value one
    # of them would change is still reported. Raises `WriterError` for the writers that raised, as `forge` does, among
    # them a writer that saves or destroys the copy, whose error is an `ActiveRecord::ReadOnlyRecord` saying so.
    # Membership diffs are returned as without the option, and no association is assigned to the copy.
    def forge_diff(through_setters: false, **forge_options)
      with_one_ruleset { diff_in_ruleset(through_setters: through_setters, **forge_options) }
    end

    # Returns a hash of the attributes generated from the record's the data entries
    # Optionally pass `attributes` to limit data entries used in the calculation to only those for the given attributes
    # Optionally pass `sources` to limit data entries used in the calculation to only those from the given sources
    # Optionally pass `except_sources` to leave out the entries of the given sources, as when asking what would be
    # forged without one source's values
    # An attribute in `attributes` brings in the rest of its group. Tracked associations, the entries of inactive
    # sources and expired entries are left out. An expired entry for one attribute of a group leaves out its source's
    # entries for the whole group.
    # Entries marked for destruction are left out, so each of their attributes takes the value of the next entry, and an
    # attribute with no other entry is left out of the hash.
    # A group's attributes all come from one source, so an attribute that source has no entry for is nil rather than
    # falling back to another source's value.
    def forge_attributes(attributes: nil, sources: nil, except_sources: nil)
      forged_entries(attributes: attributes, sources: sources, except_sources: except_sources).transform_values { |_, entry| entry&.value }
    end

    # Returns the entry `forge` takes for the attribute, or nil (see `resolved_entries`)
    def resolved_entry(attribute)
      resolved_entries(attributes: attribute)[attribute.to_s]
    end

    # Returns the source of the entry `forge` takes for the attribute, or the source that decided its group, or nil
    # when it takes none (see `resolved_entries`)
    def resolved_source(attribute)
      resolved_entries(attributes: self.class.with_groups(attribute)).values.compact.first&.source
    end

    # Returns { attribute_name => resolved entry } for `attributes`, or for every attribute a source provides and the
    # rest of its group when `attributes` is nil. An attribute resolves to the entry `forge` takes for it, or to nil
    # when it takes none. Inactive sources, expired entries and entries marked for destruction are left out, and unsaved
    # entries count, as in `forge`. An attribute in a group resolves to the entry of the source that decided the group,
    # which is nil when that source has none. Raises for a tracked association in `attributes`, whose membership is
    # decided member by member, and leaves tracked associations out when `attributes` is nil.
    def resolved_entries(attributes: nil)
      names = attributes&.then { |given| Array.wrap(given).map(&:to_s) }
      if (association = names&.find { |name| associations.key?(name) })
        raise ArgumentError, "#{record.class.name}##{association} is a tracked association, whose membership is decided member by member. " \
                             "Ask which sources decide a member with member_sources(:#{association}, ...)"
      end

      reset_resolver_unless_held # selects the ruleset and reads the rules again, as a forge does
      entries = forging_entries(attributes: names && self.class.with_groups(names)).reject { |entry| entry.marked_for_destruction? || associations.key?(entry.attribute_name) }
      resolved = resolve_entries(entries).transform_values(&:last)
      names ? names.index_with { |name| resolved[name] } : resolved
    end

    # @api private
    # Makes the record's pending writes, then drops them, keeping the new members the save created in
    # `saved_new_members`
    def write_pending_writes!
      pending_writes.new_members.each { |name, created| (saved_new_members[name] ||= {}).merge!(created.select { |_, member| member.persisted? }) }
      pending_writes.write!
      @pending_writes = nil
    end

    # @api private
    # Returns { association name => { token => member } } for the new members the record's saves created, by the token
    # of the placeholder key each was named by until then (see AssociationConfig). A reloaded record has none.
    def saved_new_members
      @saved_new_members ||= {}
    end

    # @api private
    # Returns the record's pending writes (see PendingWrites), which forges add to and its next save makes
    def pending_writes
      @pending_writes ||= PendingWrites.new(record)
    end

    # @api private
    # Returns the association's entries in precedence order, each paired with its member list (see MemberList). Inactive
    # sources' entries and expired entries are left out unless `inactive` is true.
    def association_member_lists(config, inactive: false)
      entries = inactive ? filter_data_entries_in_memory(attributes: config.name) : forging_entries(attributes: config.name)
      by_precedence(entries).map { |data_entry| [data_entry, MemberList.new(data_entry.value, marked: data_entry.marked_for_destruction?)] }
    end

    # @api private
    # Returns { attribute_name => [deciding entry, resolved entry] } for `entries`. They are the same entry for an
    # attribute outside a group. A group's deciding entry is the highest-ranked entry for any of its attributes, and
    # each attribute resolves to that source's entry, or nil when it has none.
    def resolve_entries(entries)
      entries = by_precedence(entries)
      entries.each_with_object({}) do |entry, resolved|
        next if resolved.key?(entry.attribute_name)

        group = self.class.group_of(entry.attribute_name)
        next resolved[entry.attribute_name] = [entry, entry] unless group

        attribute_groups.fetch(group).each do |attribute_name|
          resolved[attribute_name] = [entry, entries.find { |candidate| candidate.attribute_name == attribute_name && candidate.source_id == entry.source_id }]
        end
      end
    end

    # @api private
    # Returns the entries matching the filters that forging reads, leaving out those of inactive sources and of
    # `except_sources`, and expired ones (see `expired?`)
    def forging_entries(attributes: nil, sources: nil, except_sources: nil)
      left_out = DataSource.inactive_ids + DataSource.normalize_source_ids(except_sources)
      filter_data_entries_in_memory(attributes: attributes, sources: sources).reject { |data_entry| left_out.include?(data_entry.source_id) || expired?(data_entry) }
    end

    private

    # Returns { attribute name => [deciding entry, resolved entry] } for the attributes `forge_attributes` returns, with
    # its options and in its order (see `resolve_entries`)
    def forged_entries(attributes: nil, sources: nil, except_sources: nil)
      # Each forge selects the ruleset and reads the model-wide and global rules again (see PrecedenceCache)
      reset_resolver_unless_held
      attributes = self.class.with_groups(attributes) unless attributes.nil?
      data_entries = forging_entries(attributes: attributes, sources: sources, except_sources: except_sources).reject { |data_entry| data_entry.marked_for_destruction? || associations.key?(data_entry.attribute_name) }
      resolved = resolve_entries(data_entries)

      # The hash's key order is the order `forge` calls the setters, which matters when one setter
      # resets another attribute. It is by the rank of each attribute's highest-ranked entry, highest first,
      # and a group's attributes come together where the first of them would. Attributes whose entries
      # rank equally come in no defined order.
      assignment_order = self.class.with_groups(data_entries.sort_by { |data_entry| rank_of(data_entry) }.reverse.map(&:attribute_name).uniq)

      assignment_order.select { |attribute_name| record.respond_to?("#{attribute_name}=") }.index_with { |attribute_name| resolved.fetch(attribute_name) }
    end

    # Assigns each resolved entry's value among `forged`, as `forged_entries` returns them, to `target`, the record or
    # the read-only copy `read_through_setters` made of it, in order. A writer that raises a StandardError does not stop
    # the rest. Raises one `WriterError` afterwards for every writer that raised, each with its value and the source of
    # its resolved entry, or of its group's deciding entry where that source leaves the attribute out. A writer that
    # saves or destroys the copy is among them, with an error saying so.
    def assign_forged(target, forged)
      failures = forged.each_with_object({}) do |(attribute_name, (deciding, resolved)), failed|
        target.public_send("#{attribute_name}=", resolved&.value)
      rescue StandardError => error
        error = saved_copy_error(attribute_name) if error.is_a?(::ActiveRecord::ReadOnlyRecord) && !target.equal?(record)
        failed[attribute_name] = { error: error, value: resolved&.value, source: (resolved || deciding).source }
      end
      raise WriterError.new(record, failures) if failures.any?
    end

    # Returns the error for a writer that saved or destroyed the read-only copy `read_through_setters` assigns to
    def saved_copy_error(attribute_name)
      ::ActiveRecord::ReadOnlyRecord.new(
        "#{record.class.name}##{attribute_name}= saved or destroyed the record while forge_diff(through_setters: true) assigned it to a read-only copy. " \
        "Compare #{record.class.name}##{attribute_name} with forge_diff, or keep the writer from saving, as by leaving the save to the forge's caller"
      )
    end

    # Returns `forge_diff` within the ruleset already selected
    def diff_in_ruleset(through_setters: false, **forge_options)
      diff = {}
      forged = forged_entries(**forge_options)
      forge_attrs = through_setters ? read_through_setters(forged) : forged.transform_values { |_, entry| entry&.value }
      record_attrs = record.slice(*forge_attrs.keys)

      record_attrs.each do |key, value|
        diff[key] = [value, forge_attrs[key]] if forge_attrs[key] != value
      end

      names = forge_options[:attributes] ? Array.wrap(forge_options[:attributes]).map(&:to_s) : associations.keys # limited as `forge` limits them
      associations.slice(*names).each do |name, config|
        association_diff = TrackedAssociation.new(record, config).diff
        diff[name] = association_diff if association_diff
      end

      return diff
    end

    # Returns { attribute name => value } for the attributes of `forged`, as `forged_entries` returns them, each as an
    # unsaved read-only copy of the record reads it once `assign_forged` has assigned them to the copy. The transaction
    # is rolled back, so what the writers and readers wrote to the database is undone, also when a writer raises.
    def read_through_setters(forged)
      return {} if forged.empty?

      copy = record.dup
      copy.readonly!
      read = nil
      record.class.transaction(requires_new: true) do
        assign_forged(copy, forged)
        read = forged.keys.index_with { |attribute_name| copy.public_send(attribute_name) }
        raise ::ActiveRecord::Rollback
      end
      read
    end

    # Whether the entry has expired, or, for an attribute of a group, whether any of its source's entries for the group
    # has, so a group expires as a whole
    def expired?(data_entry)
      group = self.class.group_of(data_entry.attribute_name)
      return data_entry.expired? unless group

      filter_data_entries_in_memory(attributes: attribute_groups.fetch(group), sources: data_entry.source_id).any?(&:expired?)
    end

    def by_precedence(entries)
      DataEntry.in_precedence_order(entries, record: record)
    end
  end
end

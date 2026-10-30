module LaForge
  # `Merge` is used to merge what LaForge holds for two records of the same model into the survivor, as when a duplicate
  # record is found:
  #
  # - The duplicate's attribute entries and per-record precedence rules move to the survivor. When both records have one
  #   for the same attribute and source, the preferred one is kept and the other destroyed, unless the preferred one has
  #   expired and the other has not.
  # - In each tracked association, the duplicate's members move to the survivor, keeping their ids and everything
  #   recorded on them. Where both records have a member with the same key, as join rows naming the same record do, the
  #   survivor's row is kept. The duplicate's row is merged into it the same way, then destroyed. Where both have a
  #   has_one member and their keys differ, or a source's member lists for the has_one on the two records name members
  #   whose keys differ, the merge raises and nothing moves.
  # - Where a source has a member list on both records, the two are combined into the survivor's (see
  #   `combined_member_list`). The combined member list takes the expiry of the preferred one, unless the preferred
  #   one has expired and the other has not (see `kept_row`). An expired member list adds nothing to one that has not
  #   expired.
  #
  # The survivor is always the record that stays. `on_conflict:` only decides whose data is kept where both records have
  # an entry or rule for the same attribute and source, `:duplicate` as the argument's is in `Hash#merge`, or
  # `:survivor` as the receiver's is in `Hash#reverse_merge`. That record's row is the preferred one.
  #
  # The survivor is not forged, so forge it afterwards. A member merged into one of the survivor's is forged and saved
  # by the merge. The duplicate is left for the application to archive or destroy, with no LaForge data, and
  # associations LaForge does not track are not touched. Saved immediately.
  module Merge
    extend self

    def run(survivor, duplicate, on_conflict:)
      assert_mergeable!(survivor, duplicate)
      result = { entries_moved: 0, entries_conflicting: [], precedence_rules_moved: 0, precedence_rules_conflicting: [], members_moved: {}, members_merged: {} }

      ::ActiveRecord::Base.transaction { merge_records(survivor, duplicate, on_conflict, result) }
      [survivor, duplicate].each(&:reload)
      result
    end

    private

    def merge_records(survivor, duplicate, on_conflict, result)
      assert_has_ones_mergeable!(survivor, duplicate)
      merge_entries(survivor, duplicate, on_conflict, result)
      merge_precedence_rules(survivor, duplicate, on_conflict, result)
      survivor.class.laforge.associations.each_value { |config| merge_members(survivor, duplicate, config, on_conflict, result) }
    end

    # Moves the duplicate's entries to the survivor. Where both have one for the same attribute and source, keeps the
    # preferred attribute entry (see `kept_row`), or combines the two member lists into the survivor's entry.
    def merge_entries(survivor, duplicate, on_conflict, result)
      kept = DataEntry.where(record: survivor).index_by { |entry| [entry.attribute_name, entry.source_id] }

      DataEntry.where(record: duplicate).find_each do |entry|
        survivors_entry = kept[[entry.attribute_name, entry.source_id]]
        if survivors_entry.nil?
          entry.update_columns(record_id: survivor.id)
          result[:entries_moved] += 1
        elsif (config = survivor.class.laforge.associations[entry.attribute_name])
          preferred = kept_row(survivors_entry, entry, on_conflict)
          other = preferred.equal?(survivors_entry) ? entry : survivors_entry
          other_list = other.expired? && !preferred.expired? ? MemberList.new([]) : MemberList.new(other.value)
          combined = combined_member_list(config, MemberList.new(preferred.value), other_list)
          assert_one_member!(survivor, duplicate, config, entry.source, combined) unless config.collection?
          survivors_entry.update_columns(value: combined, recorded_at: [survivors_entry.recorded_at, entry.recorded_at].max,
                                         expires_at: preferred.expires_at, expires_on_source_id: preferred.expires_on_source_id)
          entry.destroy!
        else
          keep_survivors = kept_row(survivors_entry, entry, on_conflict).equal?(survivors_entry)
          conflict = { attribute: entry.attribute_name, source: entry.source, kept: keep_survivors ? :survivor : :duplicate }
          result[:entries_conflicting] << conflict unless survivors_entry.value == entry.value
          if keep_survivors
            entry.destroy!
          else
            survivors_entry.destroy!
            entry.update_columns(record_id: survivor.id)
          end
        end
      end
    end

    def merge_precedence_rules(survivor, duplicate, on_conflict, result)
      type = PrecedenceRule.model_type(survivor.class)
      kept = PrecedenceRule.where(record_type: type, record_id: survivor.id).index_by { |rule| [rule.attribute_name, rule.source_id] }

      PrecedenceRule.where(record_type: type, record_id: duplicate.id).find_each do |rule|
        other = kept[[rule.attribute_name, rule.source_id]]
        if other.nil?
          rule.update_columns(record_id: survivor.id)
          result[:precedence_rules_moved] += 1
        else
          keep_survivors = kept_row(other, rule, on_conflict).equal?(other)
          result[:precedence_rules_conflicting] << { attribute: rule.attribute_name, source: rule.source, kept: keep_survivors ? :survivor : :duplicate } unless other.precedence == rule.precedence
          if keep_survivors
            rule.destroy!
          else
            other.destroy!
            rule.update_columns(record_id: survivor.id)
          end
        end
      end
      PrecedenceCache.clear
    end

    # Raises when both records have a member in a tracked has_one and their keys differ, as the survivor can hold only
    # one. Members keyed by primary key always differ.
    def assert_has_ones_mergeable!(survivor, duplicate)
      survivor.class.laforge.associations.each_value do |config|
        next if config.collection?

        kept, moving = [survivor, duplicate].map { |record| config.members_of(record).first }
        next unless kept && moving
        next if !config.primary_keyed? && config.record_key(kept) == config.record_key(moving)

        model = survivor.class.name
        raise ArgumentError, "Cannot merge #{model} #{duplicate.id} into #{model} #{survivor.id}: both have a #{config.name}, with " \
                             "#{config.describe_key(config.record_key(kept))} and #{config.describe_key(config.record_key(moving))}, and #{model}##{config.name} holds one. " \
                             'Remove one of them, or give them the same key so the merge combines them, then merge again'
      end
    end

    # Raises when a source's member lists for a has_one on the two records, combined, include more than one member, as
    # when neither has been forged yet. Raising rolls back what the merge has moved.
    def assert_one_member!(survivor, duplicate, config, source, combined)
      keys = MemberList.new(combined).include.map { |member| config.key_of(member) }
      return unless keys.many?

      model = survivor.class.name
      raise ArgumentError, "Cannot merge #{model} #{duplicate.id} into #{model} #{survivor.id}: #{source.name}'s member lists for their #{config.name} name " \
                           "#{keys.map { |key| config.describe_key(key) }.join(' and ')}, and #{model}##{config.name} holds one. " \
                           'Remove one of the member lists, or give the members the same key so the merge combines them, then merge again'
    end

    # Returns the one of the survivor's and the duplicate's rows for the same attribute and source that the merge keeps,
    # which is the preferred row, that of the record `on_conflict` names, unless it has expired and the other has not
    def kept_row(survivors, duplicates, on_conflict)
      preferred, other = on_conflict == :survivor ? [survivors, duplicates] : [duplicates, survivors]
      preferred.expired? && !other.expired? ? other : preferred
    end

    # Moves the duplicate's members of the association to the survivor. A member with the same key as one of the
    # survivor's is merged into it, then destroyed. Members keyed by primary key always move.
    def merge_members(survivor, duplicate, config, on_conflict, result)
      existing = config.primary_keyed? ? {} : config.identified_members_of(survivor)

      config.members_of(duplicate.reload).each do |member|
        kept = existing[config.record_key(member)]
        if kept
          merge_records(kept, member, on_conflict, result)
          member.reload.destroy!
          kept.reload.forge! # no forge of the survivor reaches a member it has nothing pending for
          (result[:members_merged][config.name] ||= []) << { kept: kept.id, removed: member.id }
        else
          member[config.owner_foreign_key] = config.owner_key(survivor)
          member[config.owner_type_column] = survivor.class.polymorphic_name if config.owner_type_column
          member.save!(validate: false)
          (result[:members_moved][config.name] ||= []) << member.id
        end
      end
    end

    # Returns one source's two member lists for an association combined into one stored value, of the preferred list's
    # kind:
    # - include: every member either includes, the preferred list's first, except one the preferred partial list excludes
    # - exclude, for a partial result: every member either excludes that the result does not include
    # - withdrawn: both member lists' withdrawn members that the result does not include
    # - pending: both member lists' items
    # - tombstones, for a partial result: both member lists' tombstones
    # - expiries: the preferred list's, and the other's for members the preferred list neither includes nor excludes
    def combined_member_list(config, preferred, other)
      by_key = ->(list) { list.uniq { |member| config.key_of(member) } }
      included = by_key.(preferred.include + other.include.reject { |member| preferred.partial? && preferred.decision(config, config.key_of(member)) == :exclude })
      included_keys = included.map { |member| config.key_of(member) }
      excluded = by_key.(preferred.exclude + other.exclude).reject { |member| included_keys.include?(config.key_of(member)) }
      withdrawn = by_key.(preferred.withdrawn + other.withdrawn).reject { |member| included_keys.include?(config.key_of(member)) }
      tombstones = (preferred.tombstones + other.tombstones).uniq { |item| config.key_of(item['key']) }
      preferred_keys = (preferred.include + preferred.exclude).map { |member| config.key_of(member) }
      expiries = preferred.expiries + other.expiries.reject { |item| preferred_keys.include?(config.key_of(item['key'])) }

      preferred.with(include: included, exclude: excluded, withdrawn: withdrawn, pending: preferred.pending + other.pending, tombstones: tombstones,
                     expiries: expiries)
    end

    def assert_mergeable!(survivor, duplicate)
      unless survivor.class.respond_to?(:laforge)
        raise ArgumentError, "Cannot merge #{survivor.class.name} records: #{survivor.class.name} is not declared with `laforged`"
      end
      unless survivor.class.base_class == duplicate.class.base_class
        raise ArgumentError, "LaForge merges two records of the same model, not #{survivor.class.name} #{survivor.id.inspect} and #{duplicate.class.name} #{duplicate.id.inspect}"
      end
      raise ArgumentError, "Cannot merge #{survivor.class.name} #{survivor.id} into itself" if survivor == duplicate

      [survivor, duplicate].each do |record|
        raise ArgumentError, "Cannot merge an unsaved #{record.class.name}; save it first" if record.new_record?

        unsaved = record.data_entries.target.any? { |entry| entry.new_record? || entry.changed? || entry.marked_for_destruction? } ||
                  record.precedence_rules.target.any? { |rule| rule.new_record? || rule.changed? || rule.marked_for_destruction? }
        raise ArgumentError, "#{record.class.name} #{record.id} has unsaved data entries or precedence rules; save it, or forge! it, before merging" if unsaved
      end
    end
  end

  # Merges the duplicate's LaForge data into the survivor (see Merge). Where both have an attribute entry or rule for
  # the same attribute and source, the duplicate's is kept. Returns a hash of what moved and what conflicted, a merged member's own entries, rules and members
  # included:
  # - entries_moved: how many entries moved to the survivor
  # - entries_conflicting: [{ attribute:, source:, kept: }] for each attribute entry both had with different values
  # - precedence_rules_moved, precedence_rules_conflicting: the same for per-record precedence rules
  # - members_moved: { association name => [member ids] } moved to the survivor
  # - members_merged: { association name => [{ kept:, removed: }] } merged into one of the survivor's members
  def self.merge(survivor, duplicate)
    Merge.run(survivor, duplicate, on_conflict: :duplicate)
  end

  # As `merge`, but where both have an attribute entry or rule for the same attribute and source, the survivor's is
  # kept
  def self.reverse_merge(survivor, duplicate)
    Merge.run(survivor, duplicate, on_conflict: :survivor)
  end
end

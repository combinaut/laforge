module LaForge
  # Merges what LaForge holds for two records of the same model into the survivor, as when a duplicate record is found:
  #
  # - The duplicate's attribute entries and per-record precedence rules move to the survivor. When both records have one
  #   for the same attribute and source, the winner's is kept and the other's destroyed.
  # - In each tracked association, the duplicate's members move to the survivor, keeping their ids and everything
  #   recorded on them. Where both records have a member with the same key, as join rows naming the same record do, the
  #   survivor's row is kept: the duplicate's row is merged into it the same way, then destroyed. Where both have a
  #   has_one member and their keys differ, the merge raises before anything moves.
  # - Each source's reports on the two records are combined, so the survivor's report names every member either named.
  #   Where the reports disagree on a member, the winner's opinion is kept.
  #
  # The survivor is not forged; forge it afterwards. A member merged into one of the survivor's is forged and saved by the
  # merge, since no forge of the survivor reaches it. The duplicate is left for the application to archive or destroy,
  # with no LaForge data, and associations LaForge does not track are not touched. Saved immediately.
  module Merge
    extend self

    def run(survivor, duplicate, winner:)
      assert_mergeable!(survivor, duplicate)
      report = { entries_moved: 0, entries_conflicting: [], precedence_rules_moved: 0, precedence_rules_conflicting: [], members_moved: {}, members_merged: {} }

      ::ActiveRecord::Base.transaction { merge_records(survivor, duplicate, winner, report) }
      [survivor, duplicate].each(&:reload)
      report
    end

    private

    def merge_records(survivor, duplicate, winner, report)
      assert_has_ones_mergeable!(survivor, duplicate)
      merge_entries(survivor, duplicate, winner, report)
      merge_precedence_rules(survivor, duplicate, winner, report)
      survivor.class.laforged_associations.each_value { |config| merge_members(survivor, duplicate, config, winner, report) }
    end

    # Attribute entries and association reports, by attribute and source
    def merge_entries(survivor, duplicate, winner, report)
      kept = DataEntry.where(record: survivor).index_by { |entry| [entry.attribute_name, entry.source_id] }

      DataEntry.where(record: duplicate).find_each do |entry|
        other = kept[[entry.attribute_name, entry.source_id]]
        if other.nil?
          entry.update_columns(record_id: survivor.id)
          report[:entries_moved] += 1
        elsif (config = survivor.class.laforged_associations[entry.attribute_name])
          winning, losing = winner == :survivor ? [other, entry] : [entry, other]
          other.update_columns(value: combined_report(config, MemberList.new(winning.value), MemberList.new(losing.value)), recorded_at: [other.recorded_at, entry.recorded_at].max)
          entry.destroy!
        else
          conflict = { attribute: entry.attribute_name, source: entry.source, kept: winner }
          report[:entries_conflicting] << conflict unless other.value == entry.value
          if winner == :survivor
            entry.destroy!
          else
            other.destroy!
            entry.update_columns(record_id: survivor.id)
          end
        end
      end
    end

    def merge_precedence_rules(survivor, duplicate, winner, report)
      type = PrecedenceRule.model_type(survivor.class)
      kept = PrecedenceRule.where(record_type: type, record_id: survivor.id).index_by { |rule| [rule.attribute_name, rule.source_id] }

      PrecedenceRule.where(record_type: type, record_id: duplicate.id).find_each do |rule|
        other = kept[[rule.attribute_name, rule.source_id]]
        if other.nil?
          rule.update_columns(record_id: survivor.id)
          report[:precedence_rules_moved] += 1
        else
          report[:precedence_rules_conflicting] << { attribute: rule.attribute_name, source: rule.source, kept: winner } unless other.precedence == rule.precedence
          if winner == :survivor
            rule.destroy!
          else
            other.destroy!
            rule.update_columns(record_id: survivor.id)
          end
        end
      end
      PrecedenceCache.clear
    end

    # Raises when both records have a member in a tracked has_one and their keys differ, since moving the duplicate's
    # would give the survivor two rows behind a reader that shows one. Called before anything moves.
    def assert_has_ones_mergeable!(survivor, duplicate)
      survivor.class.laforged_associations.each_value do |config|
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

    # Moves the duplicate's members to the survivor, merging a member the survivor already has by key into the survivor's
    def merge_members(survivor, duplicate, config, winner, report)
      existing = config.primary_keyed? ? {} : config.identified_members_of(survivor)

      config.members_of(duplicate.reload).each do |member|
        kept = existing[config.record_key(member)]
        if kept
          merge_records(kept, member, winner, report)
          member.reload.destroy!
          kept.reload.forge! # no forge of the survivor reaches a member it has nothing pending for
          (report[:members_merged][config.name] ||= []) << { kept: kept.id, removed: member.id }
        else
          member[config.owner_foreign_key] = survivor.id
          member[config.owner_type_column] = survivor.class.polymorphic_name if config.owner_type_column
          member.save!(validate: false)
          (report[:members_moved][config.name] ||= []) << member.id
        end
      end
    end

    # One source's two reports for an association as one: every member either includes, in the winner's order first,
    # and the winner's opinion where they disagree. The result is complete if the winner's report is.
    def combined_report(config, winning, losing)
      by_key = ->(list) { list.uniq { |member| config.key_of(member) } }
      included = by_key.(winning.include + losing.include.reject { |member| winning.partial? && winning.decision(config, config.key_of(member)) == :exclude })
      included_keys = included.map { |member| config.key_of(member) }
      excluded = by_key.(winning.exclude + losing.exclude).reject { |member| included_keys.include?(config.key_of(member)) }
      withdrawn = by_key.(winning.withdrawn + losing.withdrawn).reject { |member| included_keys.include?(config.key_of(member)) }
      tombstones = (winning.tombstones + losing.tombstones).uniq { |item| config.key_of(item['key']) }

      MemberList.value(include: included, exclude: winning.partial? ? excluded : [], withdrawn: withdrawn, pending: winning.pending + losing.pending,
                       tombstones: tombstones, partial: winning.partial?)
    end

    def assert_mergeable!(survivor, duplicate)
      unless survivor.class.respond_to?(:laforged_associations)
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

  # Merges the duplicate's LaForge data into the survivor (see Merge). Where both have an entry or rule for the same
  # attribute and source, the duplicate's wins, as the argument does in Hash#merge. Returns a report of what moved and
  # what conflicted.
  def self.merge(survivor, duplicate)
    Merge.run(survivor, duplicate, winner: :duplicate)
  end

  # As merge, but where both have an entry or rule for the same attribute and source, the survivor's wins, as the
  # receiver does in Hash#reverse_merge
  def self.reverse_merge(survivor, duplicate)
    Merge.run(survivor, duplicate, winner: :survivor)
  end
end

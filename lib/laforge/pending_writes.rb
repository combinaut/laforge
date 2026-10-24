module LaForge
  # Used to hold a laforged record's pending writes, and to make them once the record is saved. Pending writes are the
  # writes forges of the record have decided on but left for its next save to make:
  # - removing the members they no longer include, per the association's dependent option
  # - destroying the entries they withdrew from the record's members
  # - naming the members they created by their new ids in the reports
  # A member a forge removes stays in the pending writes until the save, so a later forge can include it again.
  class PendingWrites
    def initialize(record)
      @record = record
      @marked_members = []
      @replaced_members = []
      @withdrawn_entries = []
      @created_members = {}
    end

    # Adds the removal of a collection member a forge no longer includes, as assigning the collection without it would,
    # per the association's dependent option:
    # - :destroy, :destroy_async: marked for destruction, so the record's save destroys it
    # - :delete_all: deleted without callbacks once the record is saved
    # - otherwise: detached once the record is saved, by nullifying its foreign key and saving it without validation
    def remove(config, member)
      if %i[destroy destroy_async].include?(config.reflection.options[:dependent])
        member.mark_for_destruction
        @marked_members << member
      else
        remove_on_save(config, member)
      end
    end

    # Adds the removal of a member a forge replaced or dropped once the record is saved, per the association's dependent
    # option (see `write!`), so forging alone writes nothing
    def remove_on_save(config, member)
      @replaced_members << [config, member]
    end

    # Returns the members of the tracked association that pending writes remove with `remove_on_save`, which a later
    # forge can include again
    def removed_members(config)
      @replaced_members.select { |removed, _| removed.equal?(config) }.map(&:last)
    end

    # Drops the removal of `member` from the pending writes when a forge includes it again. A member the application
    # marked for destruction itself is left marked.
    def cancel_removal(config, member)
      LaForge::ActiveRecord.set_marked_for_destruction(member, false) if @marked_members.reject! { |marked| marked.equal?(member) }
      @replaced_members.reject! { |_, replaced| replaced.equal?(member) }
    end

    # Adds the destruction of an entry a forge withdrew from one of the record's members once the record is saved
    def delete_entry(entry)
      @withdrawn_entries << entry
    end

    # Returns the new members forges built for a tracked association and the record has not saved yet, by placeholder
    # key (see AssociationConfig)
    def created_members(config)
      @created_members[config.name] ||= {}
    end

    # Makes the pending writes, once the record is saved:
    # - names the members forges created by their new ids in the reports
    # - deletes the entries they withdrew from members, publishing `DataEntry::CHANGED` for each
    # - removes the members they replaced or dropped, per the association's dependent option, skipping any never saved
    def write!
      name_created_members
      delete_withdrawn_entries
      @marked_members = []
      remove_replaced_members
    end

    private

    def name_created_members
      @created_members.each { |name, created| TrackedAssociation.new(@record, @record.class.laforge.association(name)).name_created(created) }
      @created_members = {}
    end

    def delete_withdrawn_entries
      if @withdrawn_entries.any?
        @withdrawn_entries.each { |entry| DataEntry.publish_change(entry, value_was: entry.value, value: nil, destroyed: true) }
        DataEntry.where(id: @withdrawn_entries.map(&:id)).delete_all
      end
      @withdrawn_entries = []
    end

    def remove_replaced_members
      @replaced_members.each { |config, member| remove_now(config, member) unless member.new_record? }
      @replaced_members = []
    end

    # Removes a saved member a forge replaced or dropped, per the association's dependent option, as `remove` describes
    def remove_now(config, member)
      case config.reflection.options[:dependent]
      when :destroy, :destroy_async then member.destroy!
      when :delete, :delete_all
        member.delete
        @record.association(config.name.to_sym).target.delete(member) if config.collection?
      else
        member[config.owner_foreign_key] = nil
        member[config.owner_type_column] = nil if config.owner_type_column
        member.save!(validate: false)
        @record.association(config.name.to_sym).target.delete(member) if config.collection?
      end
    end
  end
end

module LaForge
  # Used to hold what forges of a laforged record schedule for its next save, and to carry it out once the record is
  # saved
  module ScheduledChanges
    # @api private
    # Schedules the removal of a collection member a forge no longer includes, as assigning the collection without it
    # would, per the association's dependent option:
    # - :destroy, :destroy_async: marked for destruction, so the owner's save destroys it
    # - :delete_all: deleted without callbacks once the owner is saved
    # - otherwise: detached once the owner is saved, by nullifying its foreign key and saving it without validation
    def laforge_remove(config, record)
      if %i[destroy destroy_async].include?(config.reflection.options[:dependent])
        record.mark_for_destruction
        (@laforge_marked_members ||= []) << record
      else
        laforge_remove_on_save(config, record)
      end
    end

    # @api private
    # Schedules a member a forge replaced or dropped for removal once this owner is saved, per the association's
    # dependent option (see `laforge_after_save`), so forging alone writes nothing
    def laforge_remove_on_save(config, record)
      (@laforge_replaced_members ||= []) << [config, record]
    end

    # @api private
    # Returns the members of the tracked association that a forge scheduled with `laforge_remove_on_save` and this owner
    # has not been saved since, which a later forge can include again
    def laforge_scheduled_members(config)
      (@laforge_replaced_members || []).select { |scheduled, _| scheduled.equal?(config) }.map(&:last)
    end

    # @api private
    # Cancels the removal an earlier forge scheduled for `record`, before this owner was saved, when a forge includes it
    # again. A member the application marked for destruction itself is left marked.
    def laforge_cancel_removal(config, record)
      LaForge::ActiveRecord.set_marked_for_destruction(record, false) if (@laforge_marked_members || []).reject! { |marked| marked.equal?(record) }
      (@laforge_replaced_members || []).reject! { |_, replaced| replaced.equal?(record) }
    end

    # @api private
    # Schedules an entry a forge withdrew from one of this owner's members for destruction once this owner is saved
    def laforge_destroy_on_save(data_entry)
      (@laforge_withdrawn_entries ||= []) << data_entry
    end

    # @api private
    # Returns the new members forges built for a tracked association and this owner has not saved yet, by placeholder
    # key (see AssociationConfig)
    def laforge_created_members(config)
      (@laforge_created_members ||= {})[config.name] ||= {}
    end

    # Also forgets what forges built or scheduled for this record's next save, and the model-wide and global rules read
    # for the last forge, so the next ranking reads them again
    def reload(*)
      @laforge_replaced_members = nil
      @laforge_marked_members = nil
      @laforge_created_members = nil
      @laforge_withdrawn_entries = nil
      @laforge_precedence_resolver = nil
      super
    end

    private

    # Finishes what forges scheduled for this save:
    # - names the members they created by their new ids in the reports
    # - deletes the entries they withdrew from members, publishing `DataEntry::CHANGED` for each
    # - removes the members they replaced or dropped, per the association's dependent option, skipping any never saved
    def laforge_after_save
      laforge_name_created_members
      laforge_delete_withdrawn_entries
      @laforge_marked_members = nil
      laforge_remove_replaced_members
    end

    def laforge_name_created_members
      (@laforge_created_members || {}).each { |name, created| TrackedAssociation.new(self, laforged_associations.fetch(name)).name_created(created) }
      @laforge_created_members = nil
    end

    def laforge_delete_withdrawn_entries
      if @laforge_withdrawn_entries
        @laforge_withdrawn_entries.each { |entry| DataEntry.publish_change(entry, value_was: entry.value, value: nil, destroyed: true) }
        DataEntry.where(id: @laforge_withdrawn_entries.map(&:id)).delete_all
      end
      @laforge_withdrawn_entries = nil
    end

    def laforge_remove_replaced_members
      (@laforge_replaced_members || []).each { |config, record| laforge_remove_now(config, record) unless record.new_record? }
      @laforge_replaced_members = nil
    end

    # Removes a saved member a forge replaced or dropped, per the association's dependent option, as `laforge_remove`
    # describes
    def laforge_remove_now(config, record)
      case config.reflection.options[:dependent]
      when :destroy, :destroy_async then record.destroy!
      when :delete, :delete_all
        record.delete
        association(config.name.to_sym).target.delete(record) if config.collection?
      else
        record[config.owner_foreign_key] = nil
        record[config.owner_type_column] = nil if config.owner_type_column
        record.save!(validate: false)
        association(config.name.to_sym).target.delete(record) if config.collection?
      end
    end
  end
end

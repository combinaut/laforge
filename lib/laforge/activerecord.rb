module LaForge
  # `NOT_GIVEN` stands for an omitted `precedence:` argument, so omitting it can be told from passing nil, which removes
  # the precedence.
  NOT_GIVEN = Object.new.freeze

  module ActiveRecord
    extend ActiveSupport::Concern

    # Declares the model's data entries, data sources and precedence rules, with these options:
    # - associations: { name => options }, the has_many and has_one associations to track (see AssociationTracking),
    #   each with the options AssociationConfig takes
    # - attribute_groups: { name => [attributes] }. An attribute group is a set of attributes that come from one source
    #   together, such as the lines of a postal address. Sources record a group's attributes together, precedence rules
    #   are set on the group, and forging takes every attribute of the group from the highest-ranked source with an
    #   entry for any of them.
    def laforged(associations: {}, attribute_groups: {})
      LaForge::ActiveRecord.assert_no_collisions!(self)
      groups = LaForge::ActiveRecord.attribute_groups(self, attribute_groups, associations)

      has_many :data_entries, as: :record, dependent: :delete_all, autosave: true, class_name: 'LaForge::DataEntry' do
        # Returns the tombstones of the tracked association `name` (see Tombstone)
        def tombstones(name)
          owner = proxy_association.owner
          AssociationTracking.tombstones(owner, owner.class.laforged_association(name))
        end
      end
      has_many :data_sources, -> { distinct }, through: :data_entries, source: :source, class_name: 'LaForge::DataSource'
      has_many :precedence_rules, as: :record, dependent: :delete_all, autosave: true, class_name: 'LaForge::PrecedenceRule'

      scope :with_source, ->(source) { joins(:data_entries).merge(DataEntry.with_source(source)) }
      scope :without_source, ->(source) { joins(:data_entries).merge(DataEntry.without_source(source)) }
      scope :with_attribute, ->(attribute) { joins(:data_entries).merge(DataEntry.with_attribute(attribute)) }
      scope :without_attribute, ->(attribute) { joins(:data_entries).merge(DataEntry.without_attribute(attribute)) }
      scope :with_attribute_with_source, ->(attribute, source) { joins(:data_entries).merge(DataEntry.with_attribute(attribute).with_source(source)) }
      scope :with_attribute_without_source, ->(attribute, source) { joins(:data_entries).merge(DataEntry.with_attribute(attribute).without_source(source)) }
      scope :without_attribute_with_source, ->(attribute, source) { joins(:data_entries).merge(DataEntry.without_attribute(attribute).with_source(source)) }

      class_attribute :laforged_associations, instance_writer: false, default: {}
      class_attribute :laforged_attribute_groups, instance_writer: false, default: {}
      self.laforged_attribute_groups = groups

      configs = associations.to_h { |name, options| [name.to_s, AssociationConfig.new(self, name, **options)] }
      configs.each_value { |config| AssociationTracking.declare(self, config) }
      self.laforged_associations = configs
      after_save :laforge_after_save

      extend ClassMethods
      include InstanceMethods
    end

    # OVERRIDES are the methods LaForge defines over Active Record's own, calling super, which `assert_no_collisions!`
    # lets through
    OVERRIDES = %i[reload].freeze

    # Raises when the model already has a method by a name `laforged` adds, other than `OVERRIDES`, naming each one. A
    # method defined after `laforged` is not checked, so a model can wrap LaForge's and call super. Nothing is checked
    # when the model already has LaForge's methods, as when `laforged` is declared again.
    def self.assert_no_collisions!(model)
      instance_names = model.include?(InstanceMethods) ? [] : InstanceMethods.public_instance_methods(false) + InstanceMethods.private_instance_methods(false) - OVERRIDES
      instance = instance_names.select { |name| model.method_defined?(name) || model.private_method_defined?(name) }
      class_names = model.singleton_class.include?(ClassMethods) ? [] : ClassMethods.public_instance_methods(false)
      klass = class_names.select { |name| model.respond_to?(name) }
      return if instance.empty? && klass.empty?

      names = instance.map { |name| "##{name}" } + klass.map { |name| ".#{name}" }
      raise ArgumentError, "#{model.name} already defines #{names.join(', ')}, which would hide LaForge's of the same name. Rename #{model.name}'s " \
                           "#{names.one? ? 'method' : 'methods'}, or, to wrap LaForge's and call super, define #{names.one? ? 'it' : 'them'} after `laforged`"
    end

    # Returns the attribute groups declared on a model as { group name => [attribute names] }, names as strings. Raises
    # unless:
    # - each group names at least two distinct attributes
    # - no group is named like an attribute of any group
    # - no attribute is in two groups or is a tracked association
    def self.attribute_groups(model, groups, associations)
      groups = groups.to_h { |name, attributes| [name.to_s, Array.wrap(attributes).map(&:to_s)] }
      seen = {}
      groups.each do |name, attributes|
        raise ArgumentError, "#{model.name} attribute group #{name} names #{attributes.size} attribute#{'s' unless attributes.one?}; a group needs at least two" if attributes.uniq.size < 2
        raise ArgumentError, "#{model.name} attribute group #{name} is named like one of its attributes; give the group its own name" if attributes.include?(name)

        attributes.each do |attribute|
          raise ArgumentError, "#{model.name}##{attribute} is in attribute groups #{seen[attribute]} and #{name}; an attribute belongs to one group at most" if seen[attribute]
          raise ArgumentError, "#{model.name}##{attribute} is a tracked association, which cannot be in an attribute group" if associations.key?(attribute) || associations.key?(attribute.to_sym)

          seen[attribute] = name
        end
      end
      clash = groups.keys & seen.keys
      raise ArgumentError, "#{model.name} attribute group #{clash.first} is also an attribute of group #{seen[clash.first]}; give the group its own name" if clash.any?

      groups
    end

    # Returns `sources` highest-ranked first, as [{ source:, level: }], given each source's rank from the block (see
    # `PrecedenceRule::Resolver#rank`). `levels` names the rank's positions, and a source's level is the first one it
    # has a rule at. Sources that rank equally come in id order. A source with no rule at any level, such as one without
    # a global precedence, comes last with a nil level.
    def self.order_by_rank(sources, levels)
      ranked = sources.map { |source| [source, yield(source)] }.sort_by { |source, rank| rank.map(&:-@) + [source.id] }
      ranked.map do |source, rank|
        level = rank.index { |precedence| precedence != -Float::INFINITY }
        { source: source, level: level && levels[level] }
      end
    end
  end

  module ClassMethods
    def laforged_association(name)
      laforged_associations.fetch(name.to_s)
    end

    # Set and save the precedence of a source for one attribute, or one attribute group, on every record of this model.
    # Pass nil to remove it. Raises for an attribute in a group, whose precedence is set on the group.
    def update_attribute_source_precedence(attribute, source, precedence)
      laforge_assert_rule_attribute!(attribute)
      update_model_precedence_rule(attribute.to_s, source, precedence)
    end

    # Set and save the precedence of a source for every attribute on every record of this model. Pass nil to remove it.
    def update_source_precedence(source, precedence)
      update_model_precedence_rule(PrecedenceRule::ANY_ATTRIBUTE, source, precedence)
    end

    # Set and save the precedence order of this model's model-wide rules for one attribute, or attribute group, or for
    # every attribute when `attribute` is nil. It replaces every rule at that level, so nil or [] removes them. Raises
    # for an attribute in a group, whose precedence is set on the group.
    def update_precedence_order(sources, attribute: nil)
      laforge_assert_rule_attribute!(attribute) if attribute
      attribute_name = attribute ? attribute.to_s : PrecedenceRule::ANY_ATTRIBUTE
      source_ids = DataSource.normalize_source_ids(sources)

      transaction do
        PrecedenceRule.for_model(self).where(attribute_name: attribute_name).where.not(source_id: source_ids).destroy_all
        source_ids.each_with_index { |source_id, index| update_model_precedence_rule(attribute_name, source_id, source_ids.size - index) }
      end
    end

    # Returns the active sources in the order they rank for one attribute, or for every attribute when `attribute` is
    # nil, on a record of this model with no rules of its own, as [{ source:, level: }]. An attribute in a group ranks
    # as its group. The level is the most specific one the source has a rule at, :attribute, :model or :global, or nil
    # when it has none.
    def precedence_order(attribute: nil)
      resolver = PrecedenceRule::Resolver.new(self)
      LaForge::ActiveRecord.order_by_rank(DataSource.active.to_a, %i[record attribute model global]) { |source| resolver.rank(nil, attribute.to_s, source.id) }
    end

    # Returns `{ attribute_name => { source => precedence } }` for this model's model-wide rules. A rule for every
    # attribute is keyed by `PrecedenceRule::ANY_ATTRIBUTE`.
    def source_precedences
      PrecedenceRule.for_model(self).includes(:source).group_by(&:attribute_name).transform_values { |rules| rules.to_h { |rule| [rule.source, rule.precedence] } }
    end

    # Returns what each source says about the members of the tracked association `name` on each of `records`, as
    # { record_id => { source => [member hashes] } }
    def source_values(name, records:)
      AssociationTracking.source_values(self, laforged_association(name), records)
    end

    # @api private
    # Returns the attribute names as strings, each attribute in a group replaced by its whole group, in the group's
    # order. With a group `address: [:street, :city]`, `[:name, :city]` becomes `['name', 'street', 'city']`.
    def laforge_with_groups(attribute_names)
      Array.wrap(attribute_names).map(&:to_s).flat_map { |name| (group = laforge_attribute_group(name)) ? laforged_attribute_groups[group] : [name] }.uniq
    end

    # @api private
    # Raises unless the attributes recorded together include every attribute of each group they touch, naming the
    # missing ones. `where` describes what is being recorded, for the message.
    def laforge_assert_whole_groups!(attribute_names, where: name)
      attribute_names = attribute_names.map(&:to_s)
      laforged_attribute_groups.each do |group, attributes|
        given = attributes & attribute_names
        next if given.empty? || given.size == attributes.size

        raise ArgumentError, "#{where}: #{attributes.join(', ')} are attribute group #{group}, which a source records together (missing: #{(attributes - given).join(', ')}). " \
                             'Pass nil for a value the source does not have'
      end
    end

    # @api private
    # Raises when `attribute` is in an attribute group, since its precedence rules are set on the group
    def laforge_assert_rule_attribute!(attribute)
      group = laforge_attribute_group(attribute)
      raise ArgumentError, "#{name}##{attribute} is in attribute group #{group}, which is ranked as a whole; set the precedence on #{group}" if group
    end

    # @api private
    # The name of the attribute group an attribute belongs to, or nil
    def laforge_attribute_group(attribute_name)
      attribute_name = attribute_name.to_s
      laforged_attribute_groups.find { |_, attributes| attributes.include?(attribute_name) }&.first
    end

    private

    def update_model_precedence_rule(attribute_name, source, precedence)
      rules = PrecedenceRule.for_model(self).where(attribute_name: attribute_name, source_id: DataSource.normalize_source_id(source))
      return rules.destroy_all if precedence.nil?

      rule = rules.first_or_initialize
      rule.update!(precedence: precedence)
    end
  end

  module InstanceMethods
    # Assign attributes and save the record based on the data entries
    def forge!(**forge_options, &block)
      transaction do
        block.call if block_given?
        forge(**forge_options)
        save!
      end
    end

    # Assign attributes and tracked associations based on the data entries
    def forge(attributes: nil, sources: nil)
      self.attributes = forge_attributes(attributes: attributes, sources: sources)
      forge_associations(associations: attributes)
    end

    def forge_associations(associations: nil)
      names = associations ? Array.wrap(associations).map(&:to_s) : laforged_associations.keys
      laforged_associations.slice(*names).each_value { |config| AssociationTracking.forge(self, config) }
    end

    # Returns a hash of the attribute changes between the saved record and the data entries
    def forge_diff(**forge_options)
      diff = {}
      forge_attrs = forge_attributes(**forge_options)
      record_attrs = slice(*forge_attrs.keys)

      record_attrs.each do |key, value|
        diff[key] = [value, forge_attrs[key]] if forge_attrs[key] != value
      end

      names = forge_options[:attributes] ? Array.wrap(forge_options[:attributes]).map(&:to_s) : laforged_associations.keys # limited as `forge` limits them
      laforged_associations.slice(*names).each do |name, config|
        association_diff = AssociationTracking.diff(self, config)
        diff[name] = association_diff if association_diff
      end

      return diff
    end

    # Returns a hash of the attributes generated from the record's the data entries
    # Optionally pass `attributes` to limit data entries used in the calculation to only those for the given attributes
    # Optionally pass `sources` to limit data entries used in the calculation to only those from the given sources
    # Optionally pass `except_sources` to leave out the entries of the given sources, as when asking what would be
    # forged without one source's values
    # An attribute in `attributes` brings in the rest of its group. Tracked associations and the entries of inactive
    # sources are left out.
    # Entries marked for destruction are left out, so each of their attributes takes the value of the next entry, and an
    # attribute with no other entry is left out of the hash.
    # An attribute of a group is nil when the source that supplies the group has no entry for it.
    def forge_attributes(attributes: nil, sources: nil, except_sources: nil)
      @laforge_precedence_resolver = nil # each forge reads the model-wide and global rules again (see PrecedenceCache)
      forged_attrs = {}
      attributes = self.class.laforge_with_groups(attributes) unless attributes.nil?
      data_entries = laforge_forging_entries(attributes: attributes, sources: sources, except_sources: except_sources).reject { |data_entry| data_entry.marked_for_destruction? || laforged_associations.key?(data_entry.attribute_name) }
      winners = laforge_winning_entries(data_entries)

      # The hash's key order is the order `forge` calls the setters, which matters when one setter
      # resets another attribute. It is by the rank of each attribute's highest-ranked entry, highest first,
      # and a group's attributes come together where the first of them would. Attributes whose entries
      # rank equally come in no defined order.
      assignment_order = self.class.laforge_with_groups(data_entries.sort_by { |data_entry| laforge_rank_of(data_entry) }.reverse.map(&:attribute_name).uniq)

      assignment_order.each do |attribute_name|
        next unless respond_to?("#{attribute_name}=")

        data_entry = winners.fetch(attribute_name).last
        forged_attrs[attribute_name] = data_entry&.value
      end

      return forged_attrs
    end

    # Mark several data entries for destruction, so they are destroyed when the record is saved and a forge leaves them
    # out. To blank an attribute instead, record nil for it.
    # Optionally pass `attribute_names` to remove only the entries for those attributes, and `sources` to remove only
    # the entries from those sources. An attribute in a group removes the entries for its whole group.
    def remove_data_entries(attribute_names: nil, sources: nil)
      attribute_names = self.class.laforge_with_groups(attribute_names) unless attribute_names.nil?
      filter_data_entries_in_memory(attributes: attribute_names, sources: sources).each do |data_entry|
        data_entry.mark_for_destruction
      end
    end

    # Record several pieces of information from the same source.
    # `mode:` says what kind of report a tracked association's value is (see MemberList):
    # - :complete (the default): a complete report, given as the list of members it includes
    # - :partial: a partial report, given as the list of members it includes or as { include: [...], exclude: [...] }
    # - :edit: changes to the source's report for the members named, given as a list of members to include or as
    #   { include: [...], exclude: [...], forget: [...] }. The rest of the report is kept, and the members' nested lists
    #   are edits too. The shapes a Rails form submits, `*_attributes` for a tracked association and `*_ids`, are
    #   accepted (see Payload).
    # A complete or partial report replaces the source's previous one.
    # A member is a hash of its key and what the source says about it (see AssociationTracking), or a saved record.
    # Where members are keyed by primary key, a hash without an id is a new member.
    # `precedence:` covers everything the call records, members' attributes included (see `record_data_entry`).
    # The attributes of an attribute group are recorded together, on the record and on members alike.
    def record_data_entries(attributes_hash, source, precedence: NOT_GIVEN, mode: :complete)
      raise ArgumentError, "Unknown mode #{mode.inspect}; pass :complete, :partial or :edit" unless %i[complete partial edit].include?(mode)

      edit = mode == :edit
      payload = Payload.translate(self.class, attributes_hash, (self unless new_record?), edit: edit, owner: self)
      self.class.laforge_assert_whole_groups!(payload.keys.reject { |attribute_name| laforged_associations.key?(attribute_name.to_s) }, where: "Recording #{self.class.name}")
      payload.each do |attribute_name, value|
        if edit && (config = laforged_associations[attribute_name.to_s])
          AssociationTracking.edit(self, config, value, source, precedence: precedence)
        elsif (config = laforged_associations[attribute_name.to_s])
          options = { precedence: precedence }
          options[:partial] = true if mode == :partial
          AssociationTracking.record(self, config, value, source, **options)
        else
          laforge_record_attribute(attribute_name, value, source, precedence: precedence)
        end
      end
    end

    # Record a single piece of information from a source.
    # Optionally pass `precedence` to set this record's precedence for the attribute and source, saved with the record.
    # Omitting it keeps an existing precedence, and passing nil removes it.
    # Pass a record or nil for a belongs_to association, which is recorded as its foreign key, and its type when
    # polymorphic.
    # A tracked association's value is a complete report, and the shapes a Rails form submits raise, as in the default
    # mode of `record_data_entries`.
    # Raises for an attribute in an attribute group, whose attributes are recorded together with `record_data_entries`.
    def record_data_entry(attribute_name, value, source, precedence: NOT_GIVEN)
      self.class.laforge_assert_whole_groups!([attribute_name], where: "Recording #{self.class.name}##{attribute_name}")
      record_data_entries({ attribute_name => value }, source, precedence: precedence)
    end

    # Destroys the source's attribute entries on this record and withdraws every member its reports in tracked
    # associations named, as when the source no longer reports the record. Saved immediately, without forging.
    # Precedence rules for the source are kept.
    def withdraw_source(source)
      transaction do
        filter_data_entries_in_memory(sources: source).each do |data_entry|
          if (config = laforged_associations[data_entry.attribute_name])
            AssociationTracking.withdraw(config, data_entry)
            data_entry.save! if data_entry.persisted?
          else
            data_entries.destroy(data_entry)
          end
        end
      end
    end

    # Set the precedence of a source for one attribute, or one attribute group, of this record, whether or not the
    # source has recorded it yet. Saved immediately on a persisted record, otherwise with the record. Pass nil to remove
    # it. Raises for an attribute in a group, whose precedence is set on the group.
    def update_attribute_source_precedence(attribute, source, precedence)
      self.class.laforge_assert_rule_attribute!(attribute)
      rule = write_precedence_rule(attribute, source, precedence)
      return unless persisted? && rule

      rule.marked_for_destruction? ? precedence_rules.destroy(rule) : rule.save!
    end

    # Set the precedence order of this record's own rules for one attribute, or attribute group. It replaces the
    # record's other rules for the attribute, so nil or [] removes them. Saved with the record. Raises for an attribute
    # in a group, whose precedence is set on the group.
    def update_precedence_order(attribute, sources)
      self.class.laforge_assert_rule_attribute!(attribute)
      source_ids = DataSource.normalize_source_ids(sources)
      precedence_rules.select { |rule| rule.attribute_name == attribute.to_s && !source_ids.include?(rule.source_id) }.each { |rule| write_precedence_rule(attribute, rule.source_id, nil) }
      source_ids.each_with_index { |source_id, index| write_precedence_rule(attribute, source_id, source_ids.size - index) }
    end

    # Returns the active sources in the order they rank for one attribute of this record, as [{ source:, level: }]. An
    # attribute in a group ranks as its group. The level is the most specific one the source has a rule at, :record,
    # :attribute, :model or :global, or nil when it has none.
    def precedence_order(attribute)
      resolver = PrecedenceRule::Resolver.new(self.class) # not the last forge's, so rules changed since then count
      LaForge::ActiveRecord.order_by_rank(DataSource.active.to_a, %i[record attribute model global]) { |source| resolver.rank(self, attribute, source.id) }
    end

    # @api private
    # Records one attribute, without checking its group
    def laforge_record_attribute(attribute_name, value, source, precedence: NOT_GIVEN)
      reflection = self.class.reflect_on_association(attribute_name)
      if reflection&.belongs_to?
        return laforge_reference_columns(reflection, value).each { |column, column_value| write_data_entry(column, column_value, source, precedence: precedence) }
      end

      raise InvalidAttributeName, "#{self.class.name}##{attribute_name} is not a tracked association" if reflection
      raise InvalidAttributeName, "Cannot set #{attribute_name} on #{self.class.name}" unless respond_to?("#{attribute_name}=")
      raise InvalidValue, "Cannot record #{value.class} for #{self.class.name}##{attribute_name}; values are stored as JSON, so record a string, number, boolean, date, nil, or an array or hash of those" unless DataEntry.storable?(value)

      write_data_entry(attribute_name, value, source, precedence: precedence)
    end

    # Returns `{ attribute_name => { source => precedence } }` for this record's own rules, unsaved ones included and
    # those marked for destruction left out
    def source_precedences
      precedence_rules.reject(&:marked_for_destruction?).group_by(&:attribute_name).transform_values { |rules| rules.to_h { |rule| [rule.source, rule.precedence] } }
    end

    # @api private
    # Returns the effective precedence of `data_entry` on this record
    def laforge_precedence_of(data_entry)
      laforge_precedence_resolver.precedence(self, data_entry.attribute_name, data_entry.source_id)
    end

    # @api private
    # Returns the rank of `data_entry`'s source for its attribute on this record (see `PrecedenceRule::Resolver#rank`)
    def laforge_rank_of(data_entry)
      laforge_precedence_resolver.rank(self, data_entry.attribute_name, data_entry.source_id)
    end

    # Whether the source has entries on this record
    def data_source?(source)
      filter_data_entries_in_memory(sources: source).any?
    end

    # Returns the names of the sources with entries on this record, for `attributes` when given
    def data_source_names(attributes: nil)
      filter_data_entries_in_memory(attributes: attributes).map(&:source).map(&:name).uniq
    end

    # Returns what each source says about the members of the tracked association `name`, as
    # { source => [member hashes] } (see the class method)
    def source_values(name)
      self.class.source_values(name, records: [self])[id] || {}
    end

    # @api private
    # Whether one source's value for an attribute of this record outranks another's
    def laforge_outranks?(attribute_name, source_id, other_source_id)
      rank = ->(id) { laforge_precedence_resolver.rank(self, attribute_name, id) }
      (rank.(source_id) <=> rank.(other_source_id)) == 1
    end

    # Returns { membership: source, listed_by: [sources], excluded_by: [sources], attributes: { attribute => source } }
    # for one member
    def member_sources(name, **member)
      AssociationTracking.member_sources(self, self.class.laforged_association(name), member.stringify_keys)
    end

    # @api private
    # Schedules a member a forge replaced or dropped for removal once this owner is saved, per the association's
    # dependent option (see `laforge_after_save`), so forging alone writes nothing
    def laforge_remove_on_save(config, record)
      (@laforge_replaced_members ||= []) << [config, record]
    end

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
    # Returns the members of the tracked association that a forge scheduled with `laforge_remove_on_save` and this owner
    # has not been saved since, which a later forge can include again
    def laforge_scheduled_members(config)
      (@laforge_replaced_members || []).select { |scheduled, _| scheduled.equal?(config) }.map(&:last)
    end

    # @api private
    # Cancels the removal an earlier forge scheduled for `record`, before this owner was saved, when a forge includes it
    # again. A member the application marked for destruction itself is left marked.
    def laforge_cancel_removal(config, record)
      record.instance_variable_set(:@marked_for_destruction, false) if (@laforge_marked_members || []).reject! { |marked| marked.equal?(record) }
      (@laforge_replaced_members || []).reject! { |_, replaced| replaced.equal?(record) }
    end

    # @api private
    # Withdraws the source from this record, a member of `owner`, in memory, as `owner`'s forge does when the source's
    # report there excludes or has withdrawn it. The source's attribute entries are dropped, to be destroyed when
    # `owner` is saved, and each of its reports in this record's tracked associations withdraws every member it named.
    # Returns whether the source had any entry on this record not marked for destruction.
    def laforge_withdraw(source_id, owner)
      entries = filter_data_entries_in_memory(sources: source_id).reject(&:marked_for_destruction?)
      entries.each do |data_entry|
        if (config = laforged_associations[data_entry.attribute_name])
          AssociationTracking.withdraw(config, data_entry)
        else
          data_entries.target.delete(data_entry)
          owner.laforge_destroy_on_save(data_entry) if data_entry.persisted?
        end
      end
      entries.any?
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

    # @api private
    # Returns `forge_diff` as it would be once `reported` is recorded on this record, then restores the record's entries
    # and rules. `reported` is what its owner's reports say about it, as
    # [[source id, attributes, recorded_at, edit, precedence], ...].
    def laforge_forge_diff_with(reported)
      entries = data_entries.to_a
      values = entries.to_h { |entry| [entry, [entry.value, entry.recorded_at, entry.marked_for_destruction?]] }
      rules = precedence_rules.to_a # recording with a precedence builds or changes rules, which the owner's next save writes
      precedences = rules.to_h { |rule| [rule, [rule.precedence, rule.marked_for_destruction?]] }
      reported.each { |source_id, attributes, recorded_at, edit, precedence| laforge_record_reported(attributes, source_id, recorded_at, edit: edit, precedence: precedence) }
      forge_diff
    ensure
      data_entries.target.replace(entries)
      values.each { |entry, (value, recorded_at, marked)| entry.value = value; entry.recorded_at = recorded_at; entry.instance_variable_set(:@marked_for_destruction, marked) }
      precedence_rules.target.replace(rules)
      precedences.each { |rule, (precedence, marked)| rule.precedence = precedence; rule.instance_variable_set(:@marked_for_destruction, marked) }
    end

    # @api private
    # Records what the source's report on this record's owner said about it at `recorded_at`, which the owner validated
    # when recording the report. An attribute this record has a newer entry for from the same source is left out, so an
    # older report does not undo it. With `edit`, nested lists are recorded as edits. `precedence` covers everything
    # recorded, nested lists included. Returns whether anything was recorded.
    def laforge_record_reported(attributes, source, recorded_at, edit: false, precedence: NOT_GIVEN)
      newer = filter_data_entries_in_memory(sources: source).select { |entry| entry.recorded_at && entry.recorded_at > recorded_at }.map(&:attribute_name)
      attributes = attributes.except(*newer)

      attributes.each do |attribute_name, value|
        if (config = laforged_associations[attribute_name]) && edit && config.collection?
          AssociationTracking.edit(self, config, value, source, precedence: precedence, recorded_at: recorded_at)
        elsif config
          AssociationTracking.record(self, config, value, source, precedence: precedence, recorded_at: recorded_at)
        else
          write_data_entry(attribute_name, value, source, precedence: precedence, recorded_at: recorded_at)
        end
      end
      attributes.any?
    end

    private

    # Writes the source's entry for the attribute in memory, and the precedence rule for the attribute, or its attribute
    # group, when `precedence` is given. Recording onto an entry marked for destruction undoes the unsaved removal.
    def write_data_entry(attribute_name, value, source, precedence: NOT_GIVEN, recorded_at: Time.current)
      data_entry = filter_data_entries_in_memory(attributes: attribute_name, sources: source).first
      data_entry ||= data_entries.build(attribute_name: attribute_name, source_id: DataSource.normalize_source_id(source))
      data_entry.instance_variable_set(:@marked_for_destruction, false)
      data_entry.value = value
      data_entry.recorded_at = recorded_at if data_entry.new_record? || data_entry.will_save_change_to_value?
      write_precedence_rule(self.class.laforge_attribute_group(attribute_name) || attribute_name, source, precedence) unless precedence.equal?(NOT_GIVEN)
    end

    # Sets this record's rule for the attribute and source in memory, and returns it. With a nil `precedence`, marks a
    # saved rule for destruction and returns it, or otherwise drops any unsaved rule and returns nil.
    def write_precedence_rule(attribute_name, source, precedence)
      source_id = DataSource.normalize_source_id(source)
      rule = precedence_rules.find { |candidate| candidate.attribute_name == attribute_name.to_s && candidate.source_id == source_id }

      if precedence.nil?
        return unless rule

        if rule.new_record?
          precedence_rules.target.delete(rule)
          return
        end
        rule.mark_for_destruction
      else
        rule ||= precedence_rules.build(attribute_name: attribute_name.to_s, source_id: source_id)
        rule.instance_variable_set(:@marked_for_destruction, false) # setting a precedence again undoes an unsaved removal
        rule.precedence = precedence
      end
      rule
    end

    # Returns { foreign_key => id, foreign_type => class name } for `target`, a record or nil, assigned to the
    # belongs_to `reflection`, foreign_type only when it is polymorphic. Raises unless `target` is nil or a saved record
    # of a class the association takes.
    def laforge_reference_columns(reflection, target)
      unless target.nil? || target.is_a?(::ActiveRecord::Base)
        raise InvalidValue, "#{self.class.name}##{reflection.name} must be recorded as a record or nil, not #{target.class}"
      end
      raise InvalidValue, "Cannot record an unsaved #{target.class.name} for #{self.class.name}##{reflection.name}" if target&.new_record?
      if target && !reflection.polymorphic? && !target.is_a?(reflection.klass)
        raise InvalidValue, "#{self.class.name}##{reflection.name} must be a #{reflection.klass.name}, not #{target.class.name}"
      end

      primary_key = reflection.polymorphic? ? target&.class&.primary_key : reflection.association_primary_key
      columns = { reflection.foreign_key.to_s => target && target[primary_key] }
      columns[reflection.foreign_type.to_s] = target&.class&.polymorphic_name if reflection.polymorphic?
      columns
    end

    # Finishes what forges scheduled for this save:
    # - names the members they created by their new ids in the reports
    # - deletes the entries they withdrew from members, publishing `DataEntry::CHANGED` for each
    # - removes the members they replaced or dropped, per the association's dependent option, skipping any never saved
    def laforge_after_save
      (@laforge_created_members || {}).each { |name, created| AssociationTracking.name_created(self, laforged_associations.fetch(name), created) }
      @laforge_created_members = nil
      if @laforge_withdrawn_entries
        @laforge_withdrawn_entries.each { |entry| DataEntry.publish_change(entry, value_was: entry.value, value: nil, destroyed: true) }
        DataEntry.where(id: @laforge_withdrawn_entries.map(&:id)).delete_all
      end
      @laforge_withdrawn_entries = nil
      @laforge_marked_members = nil
      (@laforge_replaced_members || []).each do |config, record|
        next if record.new_record?

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
      @laforge_replaced_members = nil
    end

    def laforge_precedence_resolver
      @laforge_precedence_resolver ||= PrecedenceRule::Resolver.new(self.class)
    end

    # Returns the association's entries in precedence order, each paired with the members its report includes, none for
    # an entry marked for destruction
    def laforge_association_lists(config)
      laforge_association_reports(config).map { |data_entry, report| [data_entry, report.include] }
    end

    # Returns the association's entries in precedence order, each paired with its report (see MemberList). Inactive
    # sources' entries are left out unless `inactive` is true.
    def laforge_association_reports(config, inactive: false)
      entries = inactive ? filter_data_entries_in_memory(attributes: config.name) : laforge_forging_entries(attributes: config.name)
      laforge_by_precedence(entries).map { |data_entry| [data_entry, MemberList.new(data_entry.value, marked: data_entry.marked_for_destruction?)] }
    end

    def laforge_by_precedence(entries)
      DataEntry.in_precedence_order(entries, record: self)
    end

    # Returns { attribute_name => [winning entry, the attribute's entry from the winning source] } for `entries`. They
    # are the same entry for an attribute outside a group. For a group, the winner is the highest-ranked entry for any
    # of its attributes, and each attribute takes that source's entry, or nil when it has none.
    def laforge_winning_entries(entries)
      entries = laforge_by_precedence(entries)
      entries.each_with_object({}) do |entry, winners|
        next if winners.key?(entry.attribute_name)

        group = self.class.laforge_attribute_group(entry.attribute_name)
        next winners[entry.attribute_name] = [entry, entry] unless group

        self.class.laforged_attribute_groups.fetch(group).each do |attribute_name|
          winners[attribute_name] = [entry, entries.find { |candidate| candidate.attribute_name == attribute_name && candidate.source_id == entry.source_id }]
        end
      end
    end

    # Returns the entries matching the filters that forging reads, leaving out those of inactive sources and of
    # `except_sources`
    def laforge_forging_entries(attributes: nil, sources: nil, except_sources: nil)
      left_out = DataSource.inactive_ids + DataSource.normalize_source_ids(except_sources)
      filter_data_entries_in_memory(attributes: attributes, sources: sources).reject { |data_entry| left_out.include?(data_entry.source_id) }
    end

    # Returns the record's entries matching the filters, from the in-memory association: every saved
    # entry (loaded on first use), plus entries built but not yet saved and entries marked for destruction.
    def filter_data_entries_in_memory(attributes: nil, sources: nil)
      list = data_entries.to_a

      unless attributes.nil?
        attributes = Array.wrap(attributes).map(&:to_s)
        list.select! {|data_entry| attributes.include?(data_entry.attribute_name) }
      end

      unless sources.nil?
        source_ids = Array.wrap(sources).map {|source| DataSource.normalize_source_id(source) }
        list.select! {|data_entry| source_ids.include?(data_entry.source_id) }
      end

      return list
    end
  end

  class InvalidAttributeName < StandardError; end
  class InvalidValue < StandardError; end
  class DuplicateMemberKey < StandardError; end
end

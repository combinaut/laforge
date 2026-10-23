module LaForge
  # Describes a tracked has_many or has_one association, deriving everything it can from the association reflection.
  # A has_one is tracked as a list of at most one member; with no key, every source reports the same single member.
  #
  # Members are identified by their key: given with `key:`, else derived from the records a join row references, else the
  # member's primary key. A member keyed by primary key that a source names without one is a new member: its report names
  # it by a placeholder until the forge that creates it has been saved, which writes the new row's id in its place.
  #
  # A member keyed by primary key that a source explicitly excludes is destroyed like any removed member, and the
  # exclusion keeps a tombstone in its place: what the member was, so that `tombstone_matcher:` can recognise it when a
  # source reports it again (see Tombstone).
  #
  # Member order is written to `order_column:` when given, or else to the integer column the association scope orders
  # by, unless it identifies the member or its owner. `order_column: false` writes none.
  class AssociationConfig
    # The field of a placeholder key, which names a new member until it has an id
    NEW_MEMBER = 'new'
    # The field of a tombstone's key, which names an excluded member whose row is gone
    TOMBSTONE = 'tombstone'

    attr_reader :owner_class, :name, :reflection, :key, :order_column, :order_descending, :tombstone_matcher

    def initialize(owner_class, name, key: nil, order_column: nil, tombstone_matcher: nil)
      @owner_class = owner_class
      @name = name.to_s
      @reflection = owner_class.reflect_on_association(name)

      raise ArgumentError, "#{owner_class.name} has no association named #{name}" unless reflection
      raise ArgumentError, "#{owner_class.name}##{name} must be a has_many or has_one without :through; track its join association instead" unless %i[has_many has_one].include?(reflection.macro) && !reflection.through_reflection?

      @key = Array.wrap(key || derived_key.presence || (collection? ? klass.primary_key : nil)).map(&:to_s)
      @tombstone_matcher = tombstone_matcher
      assert_tombstone_matcher_usable! if tombstone_matcher

      @order_column, @order_descending = order_column.nil? ? derived_order_column : [given_order_column(order_column), false]
    end

    def klass
      reflection.klass
    end

    def collection?
      reflection.collection?
    end

    # The owner's current members, as an array for a has_one too
    def members_of(owner)
      reader = owner.association(name.to_sym).reader
      collection? ? reader.to_a : [reader].compact
    end

    # The current members that can be identified across sources, by key. A row missing a key value cannot be, so LaForge
    # leaves it alone, as it does any row no source has reported. Raises if several rows share a key, since LaForge cannot
    # tell which of them a source means.
    def identified_members_of(owner)
      members = members_of(owner).reject { |record| blank_key?(record_key(record)) }.group_by { |record| record_key(record) }
      duplicated = members.select { |_, records| records.size > 1 }
      if duplicated.any?
        raise DuplicateMemberKey, "#{owner_class.name} #{owner.id}'s #{name} has several #{klass.name} rows with the same key: " \
                                  "#{duplicated.keys.map { |values| describe_key(values) }.join('; ')}. Remove the duplicates before forging"
      end

      members.transform_values(&:first)
    end

    # "external_id "T-1"" for a key's values, "no key" for a has_one's single member, or "no id" for a new member
    def describe_key(values)
      return 'no id' if values.first == NEW_MEMBER

      key.zip(values).map { |column, value| "#{column} #{value.inspect}" }.join(', ').presence || 'no key'
    end

    def blank_key?(key_values)
      key_values.any?(&:nil?)
    end

    def owner_foreign_key
      reflection.foreign_key.to_s
    end

    def owner_type_column
      reflection.type&.to_s
    end

    def nested_config(field)
      klass.respond_to?(:laforged_associations) && klass.laforged_associations[field.to_s]
    end

    def key_of(member)
      return [NEW_MEMBER, member[NEW_MEMBER]] if new_member?(member)
      return [TOMBSTONE, member[TOMBSTONE]] if tombstone?(member)

      key.map { |column| member[column] }
    end

    def key_hash(member)
      return member.slice(NEW_MEMBER) if new_member?(member)
      return member.slice(TOMBSTONE) if tombstone?(member)

      key.index_with { |column| member[column] }
    end

    def record_key(record)
      key.map { |column| record[column] }
    end

    # Whether members are keyed by their primary key, so a member named without one is new
    def primary_keyed?
      key == [klass.primary_key]
    end

    # Whether a member is named by a placeholder because it has no id yet
    def new_member?(member)
      member.is_a?(Hash) && member.key?(NEW_MEMBER)
    end

    # Whether a member is named by the key of a tombstone, because the excluded member it was is gone
    def tombstone?(member)
      member.is_a?(Hash) && member.key?(TOMBSTONE)
    end

    # Whether a member has no row to find by its key, and is built from what sources report about it
    def unsaved?(member)
      new_member?(member) || tombstone?(member)
    end

    # The attributes a member that does not exist is built with: its key, or nothing for a new member or a tombstone
    def build_attributes(member)
      unsaved?(member) ? {} : key_hash(member)
    end

    # Raise for an explicit exclusion that could not outlast its row: a member keyed by primary key is destroyed when it
    # is excluded, so without `tombstone_matcher:` a source reporting it again could not be recognised, and it would
    # come back as a new member
    def assert_excludable!(owner, members)
      return unless primary_keyed? && !tombstone_matcher

      ids = members.reject { |member| tombstone?(member) }.map { |member| member[klass.primary_key] }
      return if ids.empty?

      raise ArgumentError, "Cannot exclude #{klass.name} #{ids.join(', ')} from #{owner_class.name} #{owner.id.inspect}'s #{name}: excluding it destroys it, " \
                           "and without a tombstone_matcher LaForge could not recognise it when a source reports it again, so it would come back. " \
                           "Declare tombstone_matcher: on #{owner_class.name}'s #{name}, a callable given the reported #{klass.name} and the excluded ones " \
                           "that returns the one it is, or nil, such as " \
                           "`laforged associations: { #{name}: { tombstone_matcher: ->(#{klass.model_name.element}, tombstones) { tombstones.find { |tombstone| ... } } } }`"
    end

    # Validates members recorded for this association and returns [key hash, attributes] for each, where the attributes
    # are what the source says about the member besides its key, to be recorded on the member itself. A member is a hash
    # of its key and attributes (nested tracked associations included), or a saved record, which contributes only its key.
    # Where members are keyed by primary key, a hash without one is a new member, named by a placeholder. A has_one is
    # recorded as one member, or nil for none, and stored as a list of at most one. Pass `attributes: false` for members
    # that can only be named, such as exclusions. Pass `edit: true` for members of edits, whose nested lists are edits too.
    def normalize_members(members, attributes: true, edit: false)
      unless collection?
        unless members.nil? || members.is_a?(Hash) || members.is_a?(::ActiveRecord::Base) || (members.is_a?(Array) && members.size <= 1)
          raise ArgumentError, "#{owner_class.name}##{name} must be recorded as one member or nil"
        end

        members = Array.wrap(members)
      end
      raise ArgumentError, "#{owner_class.name}##{name} must be recorded as an array of members" unless members.is_a?(Array)

      normalized = members.map { |member| normalize_member(member, attributes: attributes, edit: edit) }
      repeated = normalized.map { |key_hash, _| key_of(key_hash) }.tally.select { |_, count| count > 1 }.keys
      raise ArgumentError, "#{owner_class.name}##{name} lists the same member more than once (#{repeated.map { |values| describe_key(values) }.join('; ')})" if repeated.any?

      normalized
    end

    # [[action, member], ...] for a source's edits, given as a list of members to include, or as
    # { include: [...], exclude: [...], forget: [...] }
    def edits(value)
      raise ArgumentError, "#{owner_class.name}##{name} is a has_one, which takes a complete report" unless collection?

      lists = value.is_a?(Hash) ? value.to_h.stringify_keys : { 'include' => value }
      unknown = lists.keys - %w[include exclude forget]
      raise ArgumentError, "#{owner_class.name}##{name} edits are a list of members, or { include:, exclude:, forget: }, not #{unknown.join(', ')}" if unknown.any?

      lists.flat_map do |action, members|
        raise ArgumentError, "#{owner_class.name}##{name} edits must list members as an array for #{action}" unless members.is_a?(Array)

        members.map { |member| [action.to_sym, member] }
      end
    end

    # Raise if a member references a record that does not exist, or is named by an id that is not one of the owner's
    # members. LaForge does not move a record from one owner to another; that is done outside it.
    def assert_references_exist!(owner, members)
      assert_members_of!(owner, members) if primary_keyed?
      reference_reflections.each do |reference|
        foreign_key = reference.foreign_key.to_s
        ids = members.map { |member| member[foreign_key] }.compact.uniq
        missing = ids - existing_reference_ids(reference, ids)
        raise ::ActiveRecord::RecordNotFound, "Couldn't find #{reference.klass.name} with #{reference.association_primary_key} #{missing.join(', ')} for #{owner_class.name}##{name}" if missing.any?
      end
    end

    # Drop members whose referenced record has been deleted since they were recorded
    def drop_dangling(members)
      reference_reflections.inject(members) do |list, reference|
        foreign_key = reference.foreign_key.to_s
        ids = list.map { |member| member[foreign_key] }.compact.uniq
        existing = existing_reference_ids(reference, ids)
        list.select { |member| member[foreign_key].nil? || existing.include?(member[foreign_key]) }
      end
    end

    # Remove a former member the way assigning a collection without it would, per the association's dependent option
    private

    def normalize_member(member, attributes:, edit:)
      if member.is_a?(::ActiveRecord::Base)
        raise InvalidValue, "#{owner_class.name}##{name} members must be #{klass.name} records, not #{member.class.name}" unless member.is_a?(klass)
        raise InvalidValue, "Cannot list an unsaved #{klass.name} in #{owner_class.name}##{name}; save it first, or pass its attributes as a hash" if member.new_record?

        member = key_hash(member)
      end
      member = member.to_h if member.is_a?(Tombstone)
      member = member.to_h.stringify_keys
      if tombstone?(member)
        raise ArgumentError, "A tombstone in #{owner_class.name}##{name} can only be forgotten, which lets sources add the member again; it has no row to include or exclude" if attributes

        return [member.slice(TOMBSTONE), {}]
      end
      key.each { |column| member[column] = klass.type_for_attribute(column).cast(member[column]) if member.key?(column) } # ids from params are strings
      if primary_keyed? && member[klass.primary_key].nil?
        raise ArgumentError, "#{owner_class.name}##{name} members are named here by #{klass.primary_key}, which a new member does not have yet" unless attributes

        member = member.merge(NEW_MEMBER => SecureRandom.hex(8))
      end

      member.each do |field, value|
        next if field == NEW_MEMBER && primary_keyed?
        next if key.include?(field)

        if !attributes
          raise ArgumentError, "#{owner_class.name}##{name} members are named here by key only (#{key.join(', ')}), not #{field}"
        elsif (nested = nested_config(field)) # validated now, recorded on the member when a forge of the owner includes it
          if edit && nested.collection? && !value.nil?
            nested.edits(value).each { |action, nested_member| nested.normalize_members([nested_member], attributes: action == :include, edit: true) }
          else
            nested.normalize_members(value)
          end
        elsif field == klass.primary_key || field == owner_foreign_key || field == owner_type_column || !klass.column_names.include?(field)
          raise InvalidAttributeName, "Cannot set #{field} on #{klass.name} members of #{owner_class.name}##{name}"
        elsif field == order_column
          raise ArgumentError, "Cannot set #{field} on #{klass.name} members of #{owner_class.name}##{name}; LaForge writes it from the order of the list"
        elsif !DataEntry.storable?(value)
          raise InvalidValue, "Cannot record #{value.class} for #{field} on #{klass.name} members of #{owner_class.name}##{name}; values are stored as JSON, so record a string, number, boolean, date, nil, or an array or hash of those"
        end
      end

      if attributes && klass.respond_to?(:laforge_assert_whole_groups!)
        fields = member.keys.reject { |field| field == NEW_MEMBER || key.include?(field) || nested_config(field) }
        klass.laforge_assert_whole_groups!(fields, where: "#{klass.name} members of #{owner_class.name}##{name}")
      end

      unless new_member?(member)
        missing = key - member.keys
        raise ArgumentError, "#{owner_class.name}##{name} members must include their key (#{missing.join(', ')} missing)" if missing.any?
        raise ArgumentError, "#{owner_class.name}##{name} members must have a value for each key column (#{key.join(', ')})" if blank_key?(key_of(member))
      end

      [key_hash(member), member.except(*key, NEW_MEMBER)]
    end

    def assert_members_of!(owner, members)
      ids = members.reject { |member| new_member?(member) }.map { |member| member[klass.primary_key] }
      return if ids.empty?

      own = owner.new_record? ? [] : owner.association(name.to_sym).scope.where(klass.primary_key => ids).pluck(klass.primary_key)
      foreign = ids - own
      return if foreign.empty?

      raise InvalidValue, "#{klass.name} #{foreign.join(', ')} #{foreign.size == 1 ? 'is not one' : 'are not'} of #{owner_class.name} #{owner.id.inspect}'s #{name}. " \
                          "LaForge does not move records between owners or create a member with a given #{klass.primary_key}; " \
                          "name a new member without one, or reassign the record outside LaForge first"
    end

    def assert_tombstone_matcher_usable!
      raise ArgumentError, "#{owner_class.name}##{name} tombstone_matcher: must respond to call, as a lambda does" unless tombstone_matcher.respond_to?(:call)
      return if collection? && primary_keyed?

      reason =
        if !collection? then 'it is a has_one, which takes complete reports, so nothing is explicitly excluded from it'
        else "its members are keyed by #{key.join(', ')}, so an exclusion names something that outlasts the row"
        end
      raise ArgumentError, "#{owner_class.name}##{name} does not use a tombstone_matcher: #{reason}. Remove tombstone_matcher:"
    end

    # Every belongs_to on the member other than the one pointing back at the owner identifies a join member
    # A polymorphic reference is identified by its type as well as its id, since records of two models can share an id
    def derived_key
      references = klass.reflect_on_all_associations(:belongs_to).reject { |reference| reference.foreign_key.to_s == owner_foreign_key }
      references.flat_map { |reference| reference.polymorphic? ? [reference.foreign_key.to_s, reference.foreign_type.to_s] : [reference.foreign_key.to_s] }
    end

    def reference_reflections
      klass.reflect_on_all_associations(:belongs_to).select { |reference| !reference.polymorphic? && key.include?(reference.foreign_key.to_s) }
    end

    def existing_reference_ids(reference, ids)
      return [] if ids.empty?

      reference.klass.where(reference.association_primary_key => ids).pluck(reference.association_primary_key)
    end

    # The `order_column:` given, after checking it can hold member order: an integer column of the member that does not
    # identify the member or its owner. false is none.
    def given_order_column(column)
      return if column == false

      column = column.to_s
      where = "#{owner_class.name}##{name} order_column: #{column.inspect}"
      raise ArgumentError, "#{where} is not a column of #{klass.table_name}; name an integer column to write member order to, or pass false for none" unless klass.columns_hash.key?(column)
      raise ArgumentError, "#{where} is a #{klass.columns_hash[column].type} column; member order is written as an integer, so name an integer column" unless klass.columns_hash[column].type == :integer
      raise ArgumentError, "#{where} identifies the member or its owner, so writing order to it would change which record it is; name another integer column" if identifying_columns.include?(column)

      column
    end

    # [column, descending] for the integer column the association scope orders by, which is where member order is
    # written, in the scope's direction, unless it identifies the member or its owner. A scope ordering by an expression,
    # such as Arel.sql, names no column; declare order_column:.
    def derived_order_column
      scope = reflection.scope
      return unless scope&.arity&.zero?

      relation = klass.unscoped.instance_exec(&scope)
      columns = relation.order_values.filter_map do |value|
        case value
        when Symbol, String then [value.to_s, false]
        when Arel::Nodes::Ordering then [value.expr.name.to_s, value.descending?] if value.expr.respond_to?(:name)
        end
      end

      columns.find { |column, _| identifying_columns.exclude?(column) && klass.columns_hash[column]&.type == :integer }
    end

    # The member's primary key, key columns, and the columns pointing back at its owner
    def identifying_columns
      key + [klass.primary_key, owner_foreign_key, owner_type_column].compact
    end
  end
end

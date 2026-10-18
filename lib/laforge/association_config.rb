module LaForge
  # Describes a tracked has_many or has_one association, deriving everything it can from the association reflection.
  # A has_one is tracked as a list of at most one member; with no key, every source reports the same single member.
  #
  # Members are identified by their key: derived from the records a join row references, or given with `key:`.
  class AssociationConfig
    attr_reader :owner_class, :name, :reflection, :key, :order_column

    def initialize(owner_class, name, key: nil)
      @owner_class = owner_class
      @name = name.to_s
      @reflection = owner_class.reflect_on_association(name)

      raise ArgumentError, "#{owner_class.name} has no association named #{name}" unless reflection
      raise ArgumentError, "#{owner_class.name}##{name} must be a has_many or has_one without :through; track its join association instead" unless (reflection.collection? || reflection.has_one?) && !reflection.through_reflection?

      @key = Array.wrap(key || derived_key).map(&:to_s)
      raise ArgumentError, "Cannot derive a key for #{owner_class.name}##{name} because its members have no foreign keys other than the owner's; pass key:" if @key.empty? && collection?

      @order_column = derived_order_column
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

    # "external_id "T-1"" for a key's values, or "no key" for a has_one's single member
    def describe_key(values)
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
      key.map { |column| member[column] }
    end

    def key_hash(member)
      key.index_with { |column| member[column] }
    end

    def record_key(record)
      key.map { |column| record[column] }
    end

    # Validates members recorded for this association and returns [key hash, attributes] for each, where the attributes
    # are what the source says about the member besides its key, to be recorded on the member itself. A member is a hash
    # of its key and attributes (nested tracked associations included), or a saved record, which contributes only its key.
    # A has_one is recorded as one member, or nil for none, and stored as a list of at most one. Pass `attributes: false`
    # for members that can only be named, such as exclusions.
    def normalize_members(members, attributes: true)
      unless collection?
        unless members.nil? || members.is_a?(Hash) || members.is_a?(::ActiveRecord::Base) || (members.is_a?(Array) && members.size <= 1)
          raise ArgumentError, "#{owner_class.name}##{name} must be recorded as one member or nil"
        end

        members = Array.wrap(members)
      end
      raise ArgumentError, "#{owner_class.name}##{name} must be recorded as an array of members" unless members.is_a?(Array)

      normalized = members.map { |member| normalize_member(member, attributes: attributes) }
      repeated = normalized.map { |key_hash, _| key_of(key_hash) }.tally.select { |_, count| count > 1 }.keys
      raise ArgumentError, "#{owner_class.name}##{name} lists the same member more than once (#{repeated.map { |values| describe_key(values) }.join('; ')})" if repeated.any?

      normalized
    end

    # Raise if a member references a record that does not exist
    def assert_references_exist!(members)
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
    def remove(record)
      case reflection.options[:dependent]
      when :destroy, :destroy_async, :delete_all
        record.mark_for_destruction
      else
        record[owner_foreign_key] = nil
        record[owner_type_column] = nil if owner_type_column
      end
    end

    private

    def normalize_member(member, attributes:)
      if member.is_a?(::ActiveRecord::Base)
        raise InvalidValue, "#{owner_class.name}##{name} members must be #{klass.name} records, not #{member.class.name}" unless member.is_a?(klass)
        raise InvalidValue, "Cannot list an unsaved #{klass.name} in #{owner_class.name}##{name}; save it first, or pass its attributes as a hash" if member.new_record?

        member = key_hash(member)
      end
      member = member.to_h.stringify_keys

      member.each do |field, value|
        next if key.include?(field)

        if !attributes
          raise ArgumentError, "#{owner_class.name}##{name} members are named here by key only (#{key.join(', ')}), not #{field}"
        elsif (nested = nested_config(field))
          nested.normalize_members(value) # validated now, recorded on the member when a forge of the owner includes it
        elsif field == klass.primary_key || field == owner_foreign_key || field == owner_type_column || !klass.column_names.include?(field)
          raise InvalidAttributeName, "Cannot set #{field} on #{klass.name} members of #{owner_class.name}##{name}"
        elsif field == order_column
          raise ArgumentError, "Cannot set #{field} on #{klass.name} members of #{owner_class.name}##{name}; LaForge writes it from the order of the list"
        elsif !DataEntry.storable?(value)
          raise InvalidValue, "Cannot record #{value.class} for #{field} on #{klass.name} members of #{owner_class.name}##{name}; values are stored as JSON, so record a string, number, boolean, date, nil, or an array or hash of those"
        end
      end

      missing = key - member.keys
      raise ArgumentError, "#{owner_class.name}##{name} members must include their key (#{missing.join(', ')} missing)" if missing.any?
      raise ArgumentError, "#{owner_class.name}##{name} members must have a value for each key column (#{key.join(', ')})" if blank_key?(key_of(member))

      [key_hash(member), member.except(*key)]
    end

    # Every belongs_to on the member other than the one pointing back at the owner identifies a join member
    def derived_key
      klass.reflect_on_all_associations(:belongs_to).reject { |reference| reference.foreign_key.to_s == owner_foreign_key }.map { |reference| reference.foreign_key.to_s }
    end

    def reference_reflections
      klass.reflect_on_all_associations(:belongs_to).select { |reference| !reference.polymorphic? && key.include?(reference.foreign_key.to_s) }
    end

    def existing_reference_ids(reference, ids)
      return [] if ids.empty?

      reference.klass.where(reference.association_primary_key => ids).pluck(reference.association_primary_key)
    end

    # An integer column the association scope orders by, other than a key column, is where member order is written
    def derived_order_column
      scope = reflection.scope
      return unless scope&.arity&.zero?

      relation = klass.unscoped.instance_exec(&scope)
      columns = relation.order_values.filter_map do |value|
        case value
        when Symbol, String then value.to_s
        when Arel::Nodes::Ordering then value.expr.respond_to?(:name) ? value.expr.name.to_s : nil
        end
      end

      columns.find { |column| !key.include?(column) && klass.columns_hash[column]&.type == :integer }
    end
  end
end

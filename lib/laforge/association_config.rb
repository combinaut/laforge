module LaForge
  # Describes a tracked has_many or has_one association, deriving everything it can from the association reflection.
  # A has_one is tracked as a list of at most one member; with no key, every source describes the same single member.
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

    # Stringify and validate members recorded for this association, recursing into nested tracked associations. A has_one
    # is recorded as one member hash, or nil for none, and stored as a list of at most one.
    def normalize_members(members)
      unless collection?
        raise ArgumentError, "#{owner_class.name}##{name} must be recorded as one member hash or nil" unless members.nil? || members.is_a?(Hash) || (members.is_a?(Array) && members.size <= 1)

        members = Array.wrap(members)
      end
      raise ArgumentError, "#{owner_class.name}##{name} must be recorded as an array of member hashes" unless members.is_a?(Array)

      members.map { |member| normalize_member(member) }
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

    def normalize_member(member)
      member = member.to_h.stringify_keys

      member.each do |field, value|
        if (nested = nested_config(field))
          member[field] = nested.normalize_members(value)
        elsif field == klass.primary_key || field == owner_foreign_key || field == owner_type_column || !klass.column_names.include?(field)
          raise InvalidAttributeName, "Cannot set #{field} on #{klass.name} members of #{owner_class.name}##{name}"
        end
      end

      missing = key - member.keys
      raise ArgumentError, "#{owner_class.name}##{name} members must include their key (#{missing.join(', ')} missing)" if missing.any?

      member
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

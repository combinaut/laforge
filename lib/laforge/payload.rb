module LaForge
  # Translates the shapes a Rails form submits into the edits `record_data_entries(..., mode: :edit)` takes, at every
  # level, so a controller can record its permitted params as they are:
  #
  # - `tenants_attributes`, an array or a hash keyed by index of member hashes, as `accepts_nested_attributes_for` takes,
  #   becomes `tenants: { include: [...], exclude: [...] }`: a hash with a truthy `_destroy` excludes the member its `id`
  #   names, and any other is included. A has_one's becomes its single member, or nil when destroyed.
  # - `category_ids` becomes edits of the tracked association behind it, such as `place_categories` for
  #   `has_many :categories, through: :place_categories`: the ids listed are included, and the current members not listed
  #   are excluded.
  #
  # A member of an association keyed by other columns than its primary key is named by those columns, read from the row
  # its `id` names. A key naming an association that is not tracked raises, rather than being recorded as an attribute.
  module Payload
    extend self

    DESTROY = '_destroy'

    # The payload for `record`, an instance of `model` or nil for a new one, with Rails form shapes translated. Raises for
    # those shapes unless `edit` is true, since they describe edits.
    def translate(model, payload, record, edit:)
      payload = payload.to_h if payload.respond_to?(:permitted?) # ActionController::Parameters, which must be permitted
      payload.to_h.stringify_keys.each_with_object({}) do |(field, value), result|
        if (name = nested_attributes_name(model, field))
          require_edit!(model, field, edit)
          result[name] = nested_attributes(model.laforged_association(name), value, record)
        elsif (reflection = ids_reflection(model, field))
          require_edit!(model, field, edit)
          result.merge!(ids(model, field, reflection, value, record))
        elsif tracked?(model, field)
          result[field] = members(model.laforged_association(field), value, record, edit: edit)
        else
          result[field] = value
        end
      end
    end

    private

    # The tracked association a `*_attributes` field is for. Raises when it is for an association that is not tracked.
    def nested_attributes_name(model, field)
      return unless field.end_with?('_attributes')

      name = field.delete_suffix('_attributes')
      return unless model.reflect_on_association(name)
      return name if tracked?(model, name)

      raise InvalidAttributeName, "Cannot record #{model.name}##{field}: #{name} is not a tracked association. Declare it with `laforged associations:`, or save it outside LaForge"
    end

    def ids_reflection(model, field)
      return unless field.end_with?('_ids')

      model.reflect_on_all_associations.find { |reflection| reflection.collection? && "#{reflection.name.to_s.singularize}_ids" == field }
    end

    def tracked?(model, name)
      model.respond_to?(:laforged_associations) && model.laforged_associations.key?(name)
    end

    def require_edit!(model, field, edit)
      raise ArgumentError, "#{model.name}##{field} describes edits, as a Rails form submits them; record it with mode: :edit" unless edit
    end

    def nested_attributes(config, value, owner)
      unless config.collection?
        attributes = value.to_h.stringify_keys
        return destroy?(attributes) ? nil : member(config, attributes.except(DESTROY), owner)
      end

      items = hash?(value) ? value.to_h.stringify_keys : value
      items = items.key?('id') ? [items] : items.values if items.is_a?(Hash) # keyed by index, as Rails forms submit them
      include, exclude = [], []
      Array(items).map { |attributes| attributes.to_h.stringify_keys }.each do |attributes|
        if !destroy?(attributes)
          include << member(config, attributes.except(DESTROY), owner)
        elsif attributes['id'].present?
          exclude << key_of(config, attributes, owner)
        end
      end
      { 'include' => include, 'exclude' => exclude }
    end

    # Edits of the association a `*_ids` field names, or of the tracked association it goes through
    def ids(model, field, reflection, value, owner)
      config, column = ids_config(model, reflection)
      raise InvalidAttributeName, "Cannot record #{model.name}##{field}: neither #{reflection.name} nor an association it goes through is tracked with a key of the ids it lists" unless config

      type = config.klass.type_for_attribute(column)
      ids = Array(value).reject(&:blank?).map { |id| type.cast(id) }
      current = owner ? config.members_of(owner).map { |row| row[column] }.compact : []
      { config.name => { 'include' => ids.map { |id| { column => id } }, 'exclude' => (current - ids).map { |id| { column => id } } } }
    end

    # The tracked association a `*_ids` field edits, and the member column its ids are
    def ids_config(model, reflection)
      if tracked?(model, reflection.name.to_s)
        config = model.laforged_association(reflection.name)
        [config, config.klass.primary_key] if config.primary_keyed?
      elsif reflection.through_reflection? && tracked?(model, reflection.through_reflection.name.to_s)
        config = model.laforged_association(reflection.through_reflection.name)
        column = reflection.source_reflection.foreign_key.to_s
        [config, column] if config.key == [column]
      end
    end

    # Members given directly, which may hold Rails form shapes for their own associations. Values of any other shape are
    # left for recording to reject.
    def members(config, value, owner, edit:)
      return member(config, value, owner, edit: edit) unless config.collection?

      if hash?(value)
        value.to_h.stringify_keys.to_h { |action, list| [action, action == 'include' && list.is_a?(Array) ? list.map { |item| member(config, item, owner, edit: edit) } : list] }
      elsif value.is_a?(Array)
        value.map { |item| member(config, item, owner, edit: edit) }
      else
        value
      end
    end

    # A member hash, its own Rails form shapes translated. Where the association is keyed by other columns than the
    # primary key, an `id` is replaced by the key of the row it names.
    def member(config, attributes, owner, edit: true)
      return attributes unless hash?(attributes)

      attributes = attributes.to_h.stringify_keys
      row = row_for(config, attributes['id'], owner)
      attributes = (row ? config.key_hash(row) : {}).merge(attributes).except('id') unless config.primary_keyed?
      translate(config.klass, attributes, row, edit: edit)
    end

    def key_of(config, attributes, owner)
      return { config.klass.primary_key => attributes['id'] } if config.primary_keyed?

      row = row_for(config, attributes['id'], owner)
      raise ::ActiveRecord::RecordNotFound, "Couldn't find #{config.klass.name} #{attributes['id']} among #{config.owner_class.name}##{config.name}" unless row

      config.key_hash(row)
    end

    # The owner's current member with the given id, if any
    def row_for(config, id, owner)
      return if id.blank? || owner.nil?

      config.members_of(owner).find { |row| row.id.to_s == id.to_s }
    end

    def hash?(value)
      value.is_a?(Hash) || value.respond_to?(:permitted?)
    end

    def destroy?(attributes)
      ::ActiveModel::Type::Boolean.new.cast(attributes[DESTROY]) == true
    end
  end
end

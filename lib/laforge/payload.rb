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
  #
  # Where the owner declares `accepts_nested_attributes_for`, its `reject_if:` and `allow_destroy:` apply as they do when
  # Rails assigns the rows: a rejected row is left out, and `_destroy` counts only if destroying is allowed.
  module Payload
    extend self

    DESTROY = '_destroy'

    # What a has_one's rejected row translates to: nothing is recorded for the association
    REJECTED = Object.new.freeze

    # The payload for `record`, an instance of `model` or nil for a new one, with Rails form shapes translated. Raises for
    # those shapes unless `edit` is true, since they describe edits.
    def translate(model, payload, record, edit:)
      payload = payload.to_h if payload.respond_to?(:permitted?) # ActionController::Parameters, which must be permitted
      payload.to_h.stringify_keys.each_with_object({}) do |(field, value), result|
        if (name = nested_attributes_name(model, field))
          require_edit!(model, field, edit)
          edits = nested_attributes(model.laforged_association(name), field, value, record)
          result[name] = edits unless edits.equal?(REJECTED)
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

    def nested_attributes(config, field, value, owner)
      options = nested_attributes_options(config, field)
      unless config.collection?
        attributes = value.to_h.stringify_keys
        return REJECTED if rejected?(config, attributes, owner, options)

        return destroy?(attributes, options) ? nil : member(config, attributes.except(DESTROY), owner)
      end

      items = hash?(value) ? value.to_h.stringify_keys : value
      items = items.key?('id') ? [items] : items.values if items.is_a?(Hash) # keyed by index, as Rails forms submit them
      include, exclude = [], []
      Array(items).map { |attributes| attributes.to_h.stringify_keys }.each do |attributes|
        next if rejected?(config, attributes, owner, options)

        if !destroy?(attributes, options)
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

    # The owner's `accepts_nested_attributes_for` options for the association, or nil where it declares none. Raises for
    # the options LaForge does not apply.
    def nested_attributes_options(config, field)
      options = config.owner_class.nested_attributes_options[config.name.to_sym]
      unsupported = %i[limit update_only].select { |option| options&.dig(option) }
      return options if unsupported.empty?

      raise ArgumentError, "#{config.owner_class.name} accepts nested attributes for #{config.name} with #{unsupported.map { |option| "#{option}:" }.join(' and ')}, " \
                           "which LaForge does not apply when recording #{field}. Remove #{unsupported.size == 1 ? 'it' : 'them'} from accepts_nested_attributes_for, " \
                           'or check the rows in the controller before recording them'
    end

    # Whether the owner's `reject_if:` leaves the row out, as Rails does: never for a row being destroyed
    def rejected?(config, attributes, owner, options)
      return false if options.nil? || destroy?(attributes, options)

      attributes = attributes.with_indifferent_access
      case (reject_if = options[:reject_if])
      when Symbol
        target = owner || config.owner_class.new # a new owner's rows are checked on an unsaved one
        target.method(reject_if).arity.zero? ? target.send(reject_if) : target.send(reject_if, attributes)
      when Proc then reject_if.call(attributes) # :all_blank is stored as one
      else false
      end
    end

    # Whether the row asks for its member to be destroyed: `_destroy` is truthy, and the owner allows it where it declares
    # nested attributes
    def destroy?(attributes, options)
      (options.nil? || options[:allow_destroy]) && ::ActiveModel::Type::Boolean.new.cast(attributes[DESTROY]) == true
    end
  end
end

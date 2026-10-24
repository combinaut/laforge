module LaForge
  # Used to translate the shapes a Rails form submits into the edits `record_data_entries(..., mode: :edit)` takes, at
  # every level, so a controller can record its permitted params as they are:
  #
  # - `tenants_attributes`, an array or a hash keyed by index of member hashes, as `accepts_nested_attributes_for`
  #   takes, becomes `tenants: { include: [...], exclude: [...] }`. A hash with a truthy `_destroy` excludes the member
  #   its `id` names, and any other is included. A has_one's becomes its single member, or nil when destroyed.
  # - `category_ids` becomes edits of the tracked association behind it, such as `place_categories` for
  #   `has_many :categories, through: :place_categories`. The ids listed are included, and the current members not
  #   listed are excluded.
  #
  # A member of an association keyed by other columns than its primary key is named by those columns, read from the row
  # its `id` names. A `*_attributes` or `*_ids` field for an association LaForge does not track raises.
  #
  # Where the owner declares `accepts_nested_attributes_for`, its `reject_if:` and `allow_destroy:` apply as they do
  # when Rails assigns the rows. A rejected row is left out, and `_destroy` counts only if destroying is allowed.
  module Payload
    extend self

    DESTROY = '_destroy'

    # REJECTED stands for a has_one's rejected row, for which nothing is recorded
    REJECTED = Object.new.freeze

    # Returns `payload` with its Rails form shapes translated, at every level. `record` is the instance of `model` the
    # payload is for, or nil for a new one. Raises for those shapes unless `edit` is true, as they describe edits.
    # `owner` is the record the form is for, new or not, which a method-based `reject_if:` is called on.
    def translate(model, payload, record, edit:, owner: record)
      payload = payload.to_h if payload.respond_to?(:permitted?) # ActionController::Parameters, which must be permitted
      payload.to_h.stringify_keys.each_with_object({}) do |(field, value), result|
        if (name = nested_attributes_name(model, field))
          require_edit!(model, field, edit)
          edits = nested_attributes(model.laforge.association(name), field, value, record, owner)
          result[name] = edits unless edits.equal?(REJECTED)
        elsif (reflection = ids_reflection(model, field))
          require_edit!(model, field, edit)
          result.merge!(ids(model, field, reflection, value, record))
        elsif tracked?(model, field)
          result[field] = members(model.laforge.association(field), value, record, edit: edit)
        else
          result[field] = value
        end
      end
    end

    private

    # Returns the name of the tracked association a `*_attributes` field is for, or nil when it names no association.
    # Raises when the association is not tracked.
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
      model.respond_to?(:laforge) && model.laforge.associations.key?(name)
    end

    def require_edit!(model, field, edit)
      raise ArgumentError, "#{model.name}##{field} describes edits, as a Rails form submits them; record it with mode: :edit" unless edit
    end

    def nested_attributes(config, field, value, owner, form_owner)
      options = nested_attributes_options(config, field)
      unless config.collection?
        attributes = value.to_h.stringify_keys
        return REJECTED if rejected?(config, attributes, form_owner, options)

        return destroy?(attributes, options) ? nil : member(config, attributes.except(DESTROY), owner)
      end

      items = hash?(value) ? value.to_h.stringify_keys : value
      items = items.key?('id') ? [items] : items.values if items.is_a?(Hash) # keyed by index, as Rails forms submit them
      include, exclude = [], []
      Array(items).map { |attributes| attributes.to_h.stringify_keys }.each do |attributes|
        next if rejected?(config, attributes, form_owner, options)

        if !destroy?(attributes, options)
          include << member(config, attributes.except(DESTROY), owner)
        elsif attributes['id'].present?
          exclude << key_of(config, attributes, owner)
        end
      end
      { 'include' => include, 'exclude' => exclude }
    end

    # Returns { association name => edits } for a `*_ids` field, editing the association it names or the tracked
    # association that one goes through. Raises when neither is tracked with a key of the ids it lists.
    def ids(model, field, reflection, value, owner)
      config, column = ids_config(model, reflection)
      raise InvalidAttributeName, "Cannot record #{model.name}##{field}: neither #{reflection.name} nor an association it goes through is tracked with a key of the ids it lists" unless config

      type = config.klass.type_for_attribute(column)
      ids = Array(value).reject(&:blank?).map { |id| type.cast(id) }
      current = owner ? config.members_of(owner).map { |row| row[column] }.compact : []
      { config.name => { 'include' => ids.map { |id| { column => id } }, 'exclude' => (current - ids).map { |id| { column => id } } } }
    end

    # Returns [config, column] for the tracked association a `*_ids` field edits and the member column its ids fill, or
    # nil when there is none. That is the association itself when keyed by primary key, or the tracked association it
    # goes through when keyed by the foreign key the ids fill.
    def ids_config(model, reflection)
      if tracked?(model, reflection.name.to_s)
        config = model.laforge.association(reflection.name)
        [config, config.klass.primary_key] if config.primary_keyed?
      elsif reflection.through_reflection? && tracked?(model, reflection.through_reflection.name.to_s)
        config = model.laforge.association(reflection.through_reflection.name)
        column = reflection.source_reflection.foreign_key.to_s
        [config, column] if config.key == [column]
      end
    end

    # Returns members given directly, a has_one's single member or a collection's list or { include: [...] } hash, with
    # the Rails form shapes in them translated. Values of any other shape are returned as they are, for recording to
    # reject.
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

    # Returns a member hash with its own Rails form shapes translated, or anything else as it is. Where the association
    # is keyed by other columns than the primary key, an `id` is replaced by the key of the owner's row it names, or
    # dropped when it names none.
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

    # Whether the owner's `reject_if:` leaves the row out. As in Rails, a row being destroyed is never rejected.
    def rejected?(config, attributes, owner, options)
      return false if options.nil? || destroy?(attributes, options)

      attributes = attributes.with_indifferent_access
      case (reject_if = options[:reject_if])
      when Symbol
        target = owner || config.owner_class.new # an unsaved instance stands in for a member not created yet
        target.method(reject_if).arity.zero? ? target.send(reject_if) : target.send(reject_if, attributes)
      when Proc then reject_if.call(attributes) # :all_blank is stored as one
      else false
      end
    end

    # Whether the row asks for its member to be destroyed, which takes a truthy `_destroy` and, where the owner declares
    # nested attributes for the association, `allow_destroy: true`
    def destroy?(attributes, options)
      (options.nil? || options[:allow_destroy]) && ::ActiveModel::Type::Boolean.new.cast(attributes[DESTROY]) == true
    end
  end
end

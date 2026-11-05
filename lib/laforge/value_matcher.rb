module LaForge
  # `ValueMatcher` is used to compare two values of one attribute of a laforged model, as an expiry on a source does.
  # Values are compared as an entry's value reads once saved and loaded again, so `:open` matches `'open'`, and a value
  # recorded for the first time compares as it will after a round trip. Two values match when their match values are
  # equal. An attribute's match value is that stored form, or what `laforged match_by:` makes of it, which `nil` reaches
  # too. Matching never changes what is recorded or forged.
  class ValueMatcher
    # Returns the matcher for an attribute of `named`, which is a record, a model, or anything else that names the
    # model, such as its name or a data entry. Raises as `assert_matchable!` and `assert_attribute!` do, and when `named`
    # names no laforged model.
    def self.for(named, attribute)
      model = laforged_model(named)
      assert_matchable!(model, attribute, model.laforge.associations.keys, model.laforge.attribute_groups)
      assert_attribute!(model, attribute)
      model.laforge.value_matcher(attribute)
    end

    # Returns the model `named` names. Raises unless it is laforged.
    def self.laforged_model(named)
      model =
        if named.respond_to?(:laforge) then named.laforge.model
        elsif named.respond_to?(:record_type) then named.record_type.safe_constantize
        else named.to_s.camelize.safe_constantize
        end
      return model if model.respond_to?(:laforge)

      raise ArgumentError, "#{named.inspect} names no laforged model. Pass a record, a model or a model's name, and declare `laforged` on the model"
    end

    # Raises unless values of `attribute` of `model` can be matched, given the names of the model's tracked
    # `associations` and its attribute `groups`, { group name => [attribute names] }. Uses no database, so `laforged` can
    # call it while the model loads, and leaves whether the model has the attribute to `assert_attribute!`.
    def self.assert_matchable!(model, attribute, associations, groups)
      name = attribute.to_s
      if associations.include?(name)
        raise ArgumentError, "#{model.name}##{name} is a tracked association, whose members are identified by key: and tombstone_matcher:, not by match_by. Declare those in `laforged associations:`"
      end
      if groups.key?(name)
        raise ArgumentError, "#{model.name} attribute group #{name} matches when every one of its attributes matches; declare match_by on #{groups[name].join(', ')} instead"
      end

      reflection = model.reflect_on_association(name)
      return unless reflection
      raise ArgumentError, "#{model.name}##{name} is recorded as #{reflection.foreign_key}; declare match_by on #{reflection.foreign_key} instead" if reflection.belongs_to?

      raise unknown_attribute(model, name)
    end

    # Raises unless `model` has `attribute`, which is a column or anything else with a setter. Reads the model's columns,
    # so it runs at a matcher's first use, not while the model loads.
    def self.assert_attribute!(model, attribute)
      name = attribute.to_s
      raise unknown_attribute(model, name) unless model.attribute_names.include?(name) || model.method_defined?("#{name}=")
    end

    # Returns the error for a `name` that is not an attribute of `model`
    def self.unknown_attribute(model, name)
      ArgumentError.new("#{model.name} has no attribute #{name} to match. Name a column or an attribute with a setter")
    end

    # `match_by` takes a value in its stored form and returns its match value. Without one, the stored form is the match
    # value.
    def initialize(match_by = nil)
      @match_by = match_by
    end

    # Returns whether two values match. A source with no entry has no value, so check that it has one first.
    def matches?(value, other)
      match_value(value) == match_value(other)
    end

    def match_value(value)
      stored = ActiveSupport::JSON.decode(ActiveSupport::JSON.encode(value))
      @match_by ? @match_by.call(stored) : stored
    end
  end
end

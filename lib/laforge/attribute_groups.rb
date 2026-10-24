module LaForge
  # Used to read and check a laforged model's attribute groups. An attribute group is a set of attributes that come from
  # one source together, such as the lines of a postal address, declared with `laforged attribute_groups:`. Sources
  # record a group's attributes together, precedence rules are set on the group, and forging takes every attribute of
  # the group from the highest-ranked source with an entry for any of them.
  module AttributeGroups
    extend ActiveSupport::Concern

    class_methods do
      # @api private
      # Returns the attribute names as strings, each attribute in a group replaced by its whole group, in the group's
      # order. With a group `address: [:street, :city]`, `[:name, :city]` becomes `['name', 'street', 'city']`.
      def with_groups(attribute_names)
        Array.wrap(attribute_names).map(&:to_s).flat_map { |name| (group = group_of(name)) ? attribute_groups[group] : [name] }.uniq
      end

      # @api private
      # Returns the name of the attribute group an attribute belongs to, or nil
      def group_of(attribute_name)
        attribute_name = attribute_name.to_s
        attribute_groups.find { |_, attributes| attributes.include?(attribute_name) }&.first
      end

      # @api private
      # Raises unless the attributes recorded together include every attribute of each group they touch, naming the
      # missing ones. `where` describes what is being recorded, for the message.
      def assert_whole_groups!(attribute_names, where: model.name)
        attribute_names = attribute_names.map(&:to_s)
        attribute_groups.each do |group, attributes|
          given = attributes & attribute_names
          next if given.empty? || given.size == attributes.size

          raise ArgumentError, "#{where}: #{attributes.join(', ')} are attribute group #{group}, which a source records together (missing: #{(attributes - given).join(', ')}). " \
                               'Pass nil for a value the source does not have'
        end
      end
    end
  end
end

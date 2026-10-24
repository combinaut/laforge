module LaForge
  # `NOT_GIVEN` stands for an omitted `precedence:` argument, so omitting it can be told from passing nil, which removes
  # the precedence.
  NOT_GIVEN = Object.new.freeze

  module ActiveRecord
    extend ActiveSupport::Concern

    # Declares the model's data entries, data sources and precedence rules
    def laforged
      include Model

      LaForge::ActiveRecord.declare_data_associations(self)
      LaForge::ActiveRecord.declare_scopes(self)
    end

    # Declares the model's associations to its data entries, data sources and precedence rules
    def self.declare_data_associations(model)
      model.has_many :data_entries, as: :record, dependent: :delete_all, autosave: true, class_name: 'LaForge::DataEntry'
      model.has_many :data_sources, -> { distinct }, through: :data_entries, source: :source, class_name: 'LaForge::DataSource'
      model.has_many :precedence_rules, as: :record, dependent: :delete_all, autosave: true, class_name: 'LaForge::PrecedenceRule'
    end

    # Declares the scopes that find the model's records by the sources and attributes of their entries
    def self.declare_scopes(model)
      model.scope :with_source, ->(source) { joins(:data_entries).merge(DataEntry.with_source(source)) }
      model.scope :without_source, ->(source) { joins(:data_entries).merge(DataEntry.without_source(source)) }
      model.scope :with_attribute, ->(attribute) { joins(:data_entries).merge(DataEntry.with_attribute(attribute)) }
      model.scope :without_attribute, ->(attribute) { joins(:data_entries).merge(DataEntry.without_attribute(attribute)) }
      model.scope :with_attribute_with_source, ->(attribute, source) { joins(:data_entries).merge(DataEntry.with_attribute(attribute).with_source(source)) }
      model.scope :with_attribute_without_source, ->(attribute, source) { joins(:data_entries).merge(DataEntry.with_attribute(attribute).without_source(source)) }
      model.scope :without_attribute_with_source, ->(attribute, source) { joins(:data_entries).merge(DataEntry.without_attribute(attribute).with_source(source)) }
    end

    # Sets whether `record` is marked for destruction, which undoes an unsaved removal when `marked` is false. Active
    # Record offers no method to unmark a record, so this sets the flag `marked_for_destruction?` reads.
    def self.set_marked_for_destruction(record, marked)
      record.instance_variable_set(:@marked_for_destruction, marked)
    end

    # Used to give a laforged model its `laforge` and to delegate LaForge's methods to it
    module Model
      extend ActiveSupport::Concern

      delegate(*Record::API, to: :laforge)

      # Returns the record's `LaForge::Record`, through which LaForge records, forges and ranks it, made on first use
      def laforge
        @laforge ||= self.class.laforge.new(self)
      end

      # Also drops the record's `laforge`, so the next ranking reads the model-wide and global rules again
      def reload(*)
        @laforge = nil
        super
      end

      # Gives a duplicate its own `laforge`, bound to the duplicate
      def initialize_dup(*)
        @laforge = nil
        super
      end

      class_methods do
        delegate(*Record::CLASS_API, to: :laforge)

        # Returns the model's own subclass of LaForge::Record, made on first use. A subclass of a laforged model gets a
        # subclass of its parent's, so it keeps what `laforged` declared on the parent.
        def laforge
          @laforge ||= Class.new(superclass.respond_to?(:laforge) ? superclass.laforge : Record).tap { |klass| klass.model = self }
        end
      end
    end
  end

  class InvalidAttributeName < StandardError; end
end

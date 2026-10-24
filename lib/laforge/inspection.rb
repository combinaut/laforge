module LaForge
  # Used to find where a laforged record's values came from
  module Inspection
    extend ActiveSupport::Concern

    API = %i[data_source? data_source_names].freeze

    # Whether the source has entries on this record
    def data_source?(source)
      filter_data_entries_in_memory(sources: source).any?
    end

    # Returns the names of the sources with entries on this record, for `attributes` when given
    def data_source_names(attributes: nil)
      filter_data_entries_in_memory(attributes: attributes).map(&:source).map(&:name).uniq
    end
  end
end

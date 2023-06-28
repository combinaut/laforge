module LaForge
  class DataSource < ActiveRecord::Base
    self.table_name = "laforge_data_sources"

    has_many :data_entries, class_name: 'LaForge::DataEntry'

    validates :priority, presence: true, uniqueness: true
    validates :name, presence: true, uniqueness: { case_sensitive: false }

    def self.normalize_source_ids(sources)
      Array.wrap(sources).map { |source| normalize_source_id(source) }
    end

    def self.normalize_source_id(source)
      case source
      when /\d+/, Integer
        source.to_i
      when String
        data_source = find_by(name: source)
        return data_source.id if data_source.present?
        raise Invalid, "Could not find a DataSource with the name #{source}"
      when DataSource
        source.id
      else
        raise Invalid, "Cannot find a DataSource with value: #{source.class} (#{source}). Supported values include: source_id, source_name, or source object"
      end
    end

    # EXCEPTIONS
    class Invalid < StandardError; end
  end
end

module LaForge
  class DataSource < ActiveRecord::Base
    self.table_name = "laforge_data_sources"

    has_many :data_entries, class_name: 'LaForge::DataEntry'
    has_many :precedence_rules, class_name: 'LaForge::PrecedenceRule', foreign_key: :source_id, dependent: :delete_all
    after_destroy { PrecedenceCache.clear } # its rules are deleted without the callbacks that clear the cache
    has_one :global_precedence_rule, -> { global }, class_name: 'LaForge::PrecedenceRule', foreign_key: :source_id, autosave: true, inverse_of: :source

    validates :name, presence: true, uniqueness: { case_sensitive: false }
    validates :precedence, presence: true, numericality: { only_integer: true, allow_nil: true }
    validate :precedence_is_unique

    # Sources from the highest global precedence to the lowest, leaving out any source without one
    scope :by_precedence, -> { joins(:global_precedence_rule).order(PrecedenceRule.arel_table[:precedence].desc) }

    def self.maximum_precedence
      PrecedenceRule.global.maximum(:precedence)
    end

    # Returns the source's global precedence, or nil when it has none
    def precedence
      global_precedence_rule&.precedence
    end

    def precedence=(value)
      (global_precedence_rule || build_global_precedence_rule).precedence = value
    end

    def self.normalize_source_ids(sources)
      Array.wrap(sources).map { |source| normalize_source_id(source) }
    end

    # Resolves a source given as an id, an all-digit id string, a name, or a DataSource. A string
    # is an id only when it is all digits, so a name such as "Channel 2" resolves by name.
    def self.normalize_source_id(source)
      case source
      when Integer
        source
      when /\A\d+\z/
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

    private

    def precedence_is_unique
      return if precedence.nil?

      taken = PrecedenceRule.global.where(precedence: precedence)
      taken = taken.where.not(source_id: id) if persisted?
      errors.add(:precedence, :taken) if taken.exists?
    end
  end
end

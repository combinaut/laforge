module LaForge
  # `DataSource` is a source of values, such as an importer or an editor, ranked against the others by precedence
  class DataSource < ActiveRecord::Base
    self.table_name = "laforge_data_sources"

    has_many :data_entries, class_name: 'LaForge::DataEntry'
    has_many :precedence_rules, class_name: 'LaForge::PrecedenceRule', foreign_key: :source_id, dependent: :delete_all
    after_destroy { PrecedenceCache.clear } # its rules are deleted without the callbacks that clear the cache
    after_create { LaForge.place_in_rulesets(self) }
    after_save { PrecedenceCache.clear if saved_change_to_active? }
    after_rollback { PrecedenceCache.clear } # so no forge sees an undone change to `active`
    has_one :global_precedence_rule, -> { global }, class_name: 'LaForge::PrecedenceRule', foreign_key: :source_id, autosave: true, inverse_of: :source

    validates :name, presence: true, uniqueness: { case_sensitive: false }
    validates :precedence, presence: true, numericality: { only_integer: true, allow_nil: true }
    validate :precedence_is_unique

    scope :active, -> { where(active: true) }
    scope :inactive, -> { where(active: false) }

    # Returns the ids of the inactive sources, through `PrecedenceCache`. Forging leaves out an inactive source's
    # entries as if it had none. Its entries are kept and recording still writes them, so activating the source again
    # and forging restores what it says.
    def self.inactive_ids
      PrecedenceCache.fetch(:inactive_sources) { inactive.ids }
    end

    # Sources from the highest global precedence to the lowest, leaving out any source without one
    scope :by_precedence, -> { joins(:global_precedence_rule).order(PrecedenceRule.arel_table[:precedence].desc) }

    def self.maximum_precedence
      PrecedenceRule.global.maximum(:precedence)
    end

    # @api private
    # Returns the active sources highest-ranked first by `resolver` for the attribute on `record`, or on a record with
    # no rules of its own when `record` is nil, as [{ source:, level:, precedence:, ruleset: }]. A source's level is the
    # most specific one it has a rule at, its precedence is that rule's, and its ruleset is `resolver.ruleset` below the
    # record level, else nil. Sources that rank equally come in id order. A source with no rule at any level, such as
    # one without a global precedence, comes last with a nil level and precedence.
    def self.precedence_order(attribute, resolver:, record: nil)
      levels = %i[record attribute model global]
      ranked = active.to_a.map { |source| [source, resolver.rank(record, attribute.to_s, source.id)] }.sort_by { |source, rank| rank.map(&:-@) + [source.id] }
      ranked.map do |source, rank|
        index = rank.index { |precedence| precedence != -Float::INFINITY }
        level = index && levels[index]
        { source: source, level: level, precedence: (rank[index] if index), ruleset: (resolver.ruleset if level && level != :record) }
      end
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

  # Set and save the global precedence order, highest first, in the base rules or in a ruleset. Sources not listed rank
  # below the listed ones in their current order, and sources without a global precedence come last. Every source's
  # global precedence is renumbered, from the number of sources down to 1.
  def self.update_precedence_order(sources, ruleset: nil)
    ruleset = PrecedenceRule.ruleset_name(ruleset, where: 'LaForge.update_precedence_order')
    listed = DataSource.normalize_source_ids(sources)

    DataSource.transaction do
      fork_ruleset(ruleset) unless ruleset == PrecedenceRule::BASE
      globals = PrecedenceRule.global.in_ruleset(ruleset)
      order = listed + globals.order(precedence: :desc).pluck(:source_id).reject { |id| listed.include?(id) }
      order += DataSource.where.not(id: order).ids # sources without a global precedence there yet

      rules = order.map { |id| globals.find_or_initialize_by(source_id: id) }
      clear = [globals.maximum(:precedence) || 0, order.size].max + 1
      rules.each_with_index { |rule, index| rule.update!(precedence: clear + index) } # clear of the unique index first
      rules.each_with_index { |rule, index| rule.update!(precedence: order.size - index) }
    end
  end
end

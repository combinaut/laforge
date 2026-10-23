module LaForge
  # A tombstone is what a partial report keeps of a member it excluded, once a forge has removed the member's row. Every
  # report names the member by the tombstone's key from then on (see AssociationConfig). The association's tombstone
  # matcher compares each new member a source reports with the tombstones, so membership decides a member reported again
  # as the excluded member it was.
  #
  # - `source_id`: the source whose report excluded the member
  # - `record`: an unsaved member built from what the member was, which is what the tombstone matcher is given
  # - `to_h`: the tombstone's key. Pass it, or the tombstone, to a `forget:` edit from its source to drop the tombstone,
  #   so it no longer keeps the member out.
  class Tombstone
    attr_reader :owner, :config, :source_id, :key, :attributes, :excluded_at

    def initialize(owner, config, source_id, item)
      @owner = owner
      @config = config
      @source_id = source_id
      @key = item['key']
      @attributes = item['attributes']
      @excluded_at = Time.iso8601(item['excluded_at'])
    end

    def token
      key[AssociationConfig::TOMBSTONE]
    end

    def source
      @source ||= DataSource.find(source_id)
    end

    def record
      @record ||= TrackedAssociation.new(owner, config).unsaved_member(attributes)
    end

    def to_h
      key
    end
  end

  # Returns the tombstone that keeps the unsaved member `record` out, or nil. That is the first tombstone, in a tracked
  # association `record` would join, that the association's tombstone matcher matches and whose source outranks `source`
  # there. Code that creates members itself, such as an importer that saves a Tenant rather than reporting it on its
  # Place, calls it before saving one. Raises when `record` is saved, or when none of its owners tracks it.
  def self.tombstone_blocking(record, source)
    TrackedAssociation.tombstone_blocking(record, source)
  end
end

module LaForge
  # An excluded member whose row is gone, as the report that excluded it remembers it. Its source is the one that
  # excluded it. `record` is an unsaved member built from what it was, which a tombstone matcher compares with what a
  # source reports. Pass a tombstone, or its `to_h`, to a `forget:` edit to let sources add the member again.
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
      @record ||= AssociationTracking.unsaved_member(owner, config, attributes)
    end

    def to_h
      key
    end
  end

  # The tombstone that keeps a new member out, or nil: one that its association's tombstone matcher matches, from a
  # source that outranks `source` there. For code that creates members itself, such as an importer that builds and saves
  # a member rather than reporting it on the owner, to call before saving it.
  def self.tombstone_blocking(record, source)
    AssociationTracking.tombstone_blocking(record, source)
  end
end

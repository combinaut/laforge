module LaForge
  # `WriterError` is raised once a forge has assigned every forged value, when writers of the record raised for the
  # values they were assigned. `forge`, `forge!` and `forge_diff(through_setters: true)` raise it.
  #
  # - `record`: the record forged
  # - `errors`: { attribute name => what its writer raised }, in the order the forge assigned them, such as an
  #   application turns into validation errors
  # - `values`: { attribute name => the forged value the writer was assigned }
  # - `sources`: { attribute name => the source that value came from }
  class WriterError < StandardError
    attr_reader :record, :errors, :values, :sources

    # `failures` is { attribute name => { error:, value:, source: } }
    def initialize(record, failures)
      @record = record
      @errors = failures.transform_values { |failure| failure[:error] }
      @values = failures.transform_values { |failure| failure[:value] }
      @sources = failures.transform_values { |failure| failure[:source] }

      raised = failures.map do |attribute_name, failure|
        "#{record.class.name}##{attribute_name}= given #{failure[:value].inspect} from #{failure[:source].name} raised #{failure[:error].class.name} (#{failure[:error].message})"
      end
      super("#{failures.one? ? 'A writer' : "#{failures.size} writers"} of #{record.class.name} #{record.id.inspect} raised while a forge assigned the forged values: " \
            "#{raised.join('; ')}. Record #{failures.one? ? 'a value the writer takes' : 'values the writers take'}, or rescue LaForge::WriterError and read its errors")
    end
  end
end

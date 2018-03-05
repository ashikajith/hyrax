module Hyrax
  module Admin
    class RepositoryObjectPresenter
      include Blacklight::SearchHelper

      def initialize(object_type = 'works')
        @object_type = object_type
      end

      def as_json(*)
        counts.map do |k, v|
          { label: I18n.translate(k, scope: 'hyrax.admin.stats.repository_objects.series'),
            value: v }
        end
      end

      private

        delegate :blacklight_config, to: CatalogController

        def counts
          translation = { 'false' => :published, 'true' => :unpublished, nil => :unknown }
          raw_count = Hash[*results.to_a.flatten]
          @counts ||= raw_count.each_with_object({}) { |(k, v), o| o[translation[k]] = v }
        end

        def search_builder
          Stats::WorkStatusSearchBuilder.new(self)
        end

        # results come from Solr in an array where the first item is the status and
        # the second item is the count
        # @example
        #   [ "true", 55, "false", 205, nil, 11 ]
        # @return [#each] an enumerable object of tuples (status and count)
        def results
          facet_results = repository.search(search_builder)
          facet_results.facet_fields[IndexesWorkflow.suppressed_field].each_slice(2)
        end
    end
  end
end

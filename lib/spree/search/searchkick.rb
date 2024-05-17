module Spree
  module Search
    class Searchkick < Spree::Core::Search::Base
      @enable_aggregations = false

      class << self
        attr_accessor :enable_aggregations
      end

      def retrieve_products(**args)
        @products =  defined?(args) ? base_elasticsearch(**args) : base_elasticsearch
      end

      def base_elasticsearch(**args)
        curr_page = page || 1
        dft_includes = [
          master: [:default_price, :stock_items, images: {attachment_attachment: :blob}]
        ]
        includes = args.delete(:includes)

        options = {
          page: curr_page,
          per_page: per_page,
          includes: includes.nil? ? dft_includes : includes,
        }
        if @properties[:body].blank?
          options.merge!({
            fields: Spree::Product.search_fields,
            where: defined?(args) ? where_query(**args) : where_query,
            order: sorted,
          })
          if @enable_aggregations
            options.merge!({
              aggs: aggregations,
              smart_aggs: true,
            })
          end

          ::Spree::Product.search(keyword_query, **options)
        else
          options.merge!({body: @properties[:body]})
          ::Spree::Product.search(keyword_query, **options)
        end
      end

      def where_query(**args)
        where_query = {
          active: true,
          price: { gt: 0 },
        }

        if defined?(args)
          where_query = where_query.merge(args)
        end
        if taxon
          where_query[:taxon_ids] = taxon.is_a?(::Spree::Taxon) ? taxon.id : taxon
        end

        (::Spree::Product.try(:filter_fields) || []).each do |filter_field|
          if @properties.include?(filter_field)
            where_query[filter_field] = @properties[filter_field]
          end
        end

        add_search_filters(where_query)
      end

      def keyword_query
        @properties[:keywords].blank? ? "*" : @properties[:keywords]
      end

      def sorted
        sort_conds = [{_score: :desc}]
        return sort_conds if @properties[:sort_by] == 'relevance'

        order_params = {}
        order_params[:conversions] = :desc if @properties[:sort_by] == 'conversions' || @properties[:sort_by] == 'default'
        order_params[:price] = :desc if @properties[:sort_by] == 'price-high-to-low'
        order_params[:price] = :asc if @properties[:sort_by] == 'price-low-to-high'
        order_params[:created_at] = :desc if @properties[:sort_by] == 'newest-first'

        sort_conds << order_params
      end

      def aggregations
        fs = []

        aggregation_classes.each do |agg_class|
          agg_class.filterable.each do |record|
            fs << record.filter_name.to_sym
          end
        end
        fs
      end

      def aggregation_classes
        [
          ::Spree::Taxonomy, 
          ::Spree::Property, 
          ::Spree::OptionType
        ]
      end

      def add_search_filters(query)
        return query unless search
        search.each do |name, scope_attribute|
          query.merge!(::Hash[name, scope_attribute])
        end
        query
      end

      def prepare(params)
        options = params.dup

        @properties[:body] = options.delete(:body)
        @properties[:keywords] = options.delete(:keywords) || options.delete(:brand)

        @properties[:search] = options.delete(:search)
        @properties[:taxon] = params[:taxon].blank? ? nil : params.delete(:taxon)

        @properties[:sort_by] = options.delete(:sort_by) || 'default'

        per_page = params[:per_page].to_i
        @properties[:per_page] = per_page > 0 ? per_page : ::Spree::Config[:products_per_page]
        @properties[:page] = if params[:page].respond_to?(:to_i)
                               params[:page].to_i <= 0 ? 1 : params[:page].to_i
                             else
                               1
                             end

        (::Spree::Product.try(:filter_fields) || []).each do |filter_field|
          unless options.include?(filter_field)
            next
          end
          if filter_field == :price
            price_range = get_price_range(options[:price])
            unless price_range.blank?
              low_price, high_price = price_range.split(',').map(&:to_i)
              @properties[:price] = {gt: low_price, lte: high_price}
            end
          else
            @properties[filter_field] = options[filter_field]
          end
        end
        unless params[:include_images].blank?
          @properties[:has_image] = params[:include_images]
        end
      end
    end
  end
end

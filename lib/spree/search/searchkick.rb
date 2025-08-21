module Spree
  module Search
    class Searchkick < Spree::Core::Search::Base
      @enable_aggregations = false

      class << self
        attr_accessor :enable_aggregations
      end

      def retrieve_products(**args)
        @products = defined?(args) ? base_elasticsearch(args) : base_elasticsearch
      end

      def base_elasticsearch(**args)
        curr_page = page || 1
        dft_includes = [
          # :tax_category,
          variants: [
            :prices,
          # :images
          ],
          master: [
            # :prices,
            :images
          ],
        ]
        includes = args.delete(:includes)
        if includes.nil?
          if defined?(::Spree::ProductRepresentation)
            includes = [:representation]
          end
        end

        options = {
          page: curr_page,
          per_page: per_page,
          includes: includes.nil? ? dft_includes : includes
        }

        if @properties[:body].blank?
          options.merge!({
                           fields: Spree::Product.search_fields,
                           where: defined?(args) ? where_query(**args) : where_query,
                           order: sorted,
                         })
          # if @enable_aggregations
          options.merge!({
                           aggs: aggregations,
                           smart_aggs: true,
                         })
          # end
          ::Spree::Product.search(keyword_query, **options)
        else
          options.merge!({ body: @properties[:body] })
          ::Spree::Product.search(keyword_query, **options)
        end
      end

      def where_query(**args)
        where_query = {
          # active: true,
          price: { gt: 0 }
        }

        if defined?(args)
          where_query = where_query.merge(args)
        end
        where_query[:taxon_ids] = taxon.id if taxon
        if country
          where_query[:countries] = country.upcase
        end

        if vendor_id
          where_query[:vendor_ids] = vendor_id
        end

        if conversions
          where_query[:conversions] = conversions
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
        order_params = {}
        # unless @properties[:conversions]
        #   order_params = { :featured => :desc }
        # end

        order_params[:conversions] = :desc if @properties[:sort_by] == 'conversions' || @properties[:conversions]
        order_params[:price] = :desc if @properties[:sort_by] == 'price-high-to-low'
        order_params[:price] = :asc if @properties[:sort_by] == 'price-low-to-high'

        order_params[:created_at] = :desc if @properties[:sort_by] == 'newest-first' || order_params.size == 0
        order_params
      end

      def aggregations
        fs = {}
        price_ranges = [{ to: 25 }, { from: 25, to: 50 }, { from: 50, to: 100 }, { from: 100, to: 150 }, { from: 150, to: 200 }, { from: 200, to: 300 }, { from: 300 }]
        fs[:price] = { ranges: price_ranges }
        aggregation_classes.each do |agg_class|
          agg_class.filterable.each do |record|
            fs[record.filter_name.to_sym] = {}
          end
        end
        fs[:ship_from_countries] = {
          "terms": { "field": "ship_from_countries.keyword", "size": 1000 }
        }
        fs
      end

      def aggregation_classes
        [
          Spree::Taxonomy,
          Spree::Property,
        # Spree::Price,
        ]
      end

      def add_search_filters(query)
        return query unless search
        search.each do |name, scope_attribute|
          query.merge!(Hash[name, scope_attribute])
        end
        query
      end

      def prepare(params)
        options = params.dup
        @properties[:body] = options.delete(:body)
        @properties[:keywords] = options.delete(:keywords)

        @properties[:search] = options.delete(:search)
        @properties[:taxon] = params[:taxon].blank? ? nil : Spree::Taxon.find(params.delete(:taxon))
        @properties[:country] = params[:country].blank? ? nil : params.delete(:country)&.upcase
        @properties[:vendor_id] = params[:vendor_id].blank? ? nil : params.delete(:vendor_id)
        @properties[:sort_by] = options.delete(:sort_by) || 'default'
        @properties[:conversions] = params[:conversions]
        per_page = params[:per_page].to_i
        @properties[:per_page] = per_page > 0 ? per_page : Spree::Config[:products_per_page]
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
              @properties[:price] = { gt: low_price, lte: high_price }
            end
          else
            @properties[filter_field] = options[filter_field]
          end
        end

        ::Spree::Property.filterable.each do |property|
          if options.include?(property.filter_name)
            @properties[property.filter_name] = options[property.filter_name]
          end
        end

        if @properties[:price].blank?
          @properties[:price] = { gt: 0 }
        end

        @properties[:has_image] = true
        unless params[:include_images].blank?
          @properties[:has_image] = params[:include_images]
        end
      end
    end
  end
end

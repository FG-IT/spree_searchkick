module SpreeSearchkick
  module Spree
    module ProductDecorator
      def self.prepended(base)
        base.searchkick(
          callbacks: :queue,
          match: :word,
          word_start: [:name],
          settings: { :number_of_replicas => 0, :"index.mapping.total_fields.limit" => 10000 },
          index_prefix: ENV['SITE_NAME'],
          merge_mappings: true,
          mappings: {
            properties: {
              properties: {
                type: 'nested'
              }
            }
          }
        ) unless base.respond_to?(:searchkick_index)

        base.scope :search_import, lambda {
          includes(:orders, :taxons, :variants_including_master, master: [:default_price, :images, :stock_items])
        }

        base.skip_callback :commit, :after, :reindex, raise: false
        base.after_save -> { reindex_later(300) }
        base.after_destroy :reindex, if: -> { ::Searchkick.callbacks?(default: :async) }

        def base.autocomplete_fields
          [:name]
        end

        def base.search_fields
          ["upc^100", "brand^70", "name^30", "description"]
        end

        def base.filter_fields
          fields = [:active, :price, :in_stock, :conversions, :has_image, :total_on_hand, :purchasable, :taxon_ids]
          # Disabled property and option search temporary
          # fields.concat(::Spree::Property.filterable_properties.map {|prop| prop.filter_name })
          # fields.concat(::Spree::OptionType.filterable_option_types.map {|ot| ot.filter_name })

          fields.compact.uniq
        end

        def base.replace_indice
          ::Spree::Product.searchkick_index.replace_indice

          begin
            ::Spree::Product.select(:id).find_in_batches do |products|
              product_ids = products.map {|product| product.id.to_s }
              ::Searchkick::ProcessBatchJob.perform_later(class_name: '::Spree::Product', record_ids: product_ids, index_name: nil)
            end
          rescue ActiveRecord::ActiveRecordError => e
            ActiveRecord::Base.connection.reconnect!
            sleep 3

            retry
          end
        end

        def base.autocomplete(keywords)
          if keywords
            Spree::Product.search(
              keywords,
              fields: autocomplete_fields,
              match: :word_start,
              limit: 10,
              load: false,
              misspellings: { below: 3 },
              where: search_where,
            ).map(&:name).map(&:strip).uniq
          else
            Spree::Product.search(
              "*",
              fields: autocomplete_fields,
              load: false,
              misspellings: { below: 3 },
              where: search_where,
            ).map(&:name).map(&:strip)
          end
        end

        def base.search_where
          {
            active: true,
            price: { gt: 0 },
          }
        end

        # Searchkick can't be reinitialized, this method allow to change options without it
        # ex add_searchkick_option { settings: { "index.mapping.total_fields.limit": 2000 } }
        def base.add_searchkick_option(option)
          base.class_variable_set(:@@searchkick_options, base.searchkick_options.deep_merge(option))
        end
      end

      def reindex_later(wait_seconds)
        ::Searchkick::ReindexV2Job.set(wait: wait_seconds.seconds).perform_later('::Spree::Product', self.id)
      end

      def search_data
        all_variants = variants_including_master.pluck(:id, :sku)

        all_taxons = taxons.flat_map { |t| t.self_and_ancestors.pluck(:id, :name) }.uniq

        quantity = total_on_hand
        if quantity == Float::INFINITY
          quantity = 100
        end

        json = {
          id: id,
          name: name,
          slug: slug,
          description: description[0..6000],
          active: available?,
          in_stock: in_stock?,
          created_at: created_at,
          updated_at: updated_at,
          price: price,
          currency: currency,
          conversions: orders.complete.count,
          taxon_ids: all_taxons.map(&:first),
          taxon_names: all_taxons.map(&:last),
          skus: all_variants.map(&:last),
          total_on_hand: quantity,
          has_image: images.count > 0,
          purchasable: purchasable?
        }

        # json.merge!(option_types_for_es_index(all_variants))
        # json.merge!(properties_for_es_index)

        json.merge!(index_data)

        json
      end

      def option_types_for_es_index(all_variants)
        filterable_option_types = option_types.filterable.pluck(:id, :name)
        option_value_ids = ::Spree::OptionValueVariant.where(variant_id: all_variants.map(&:first)).pluck(:option_value_id).uniq
        option_values = ::Spree::OptionValue.where(
          id: option_value_ids, 
          option_type_id: filterable_option_types.map(&:first)
        ).pluck(:option_type_id, :name)

        json = {
          option_type_ids: filterable_option_types.map(&:first),
          option_type_names: filterable_option_types.map(&:last),
          option_value_ids: option_value_ids
        }

        filterable_option_types.each do |option_type|
          values = option_values.find_all { |ov| ov.first == option_type.first }.map(&:last).uniq.compact.each(&:downcase)

          json.merge!(Hash[option_type.last.downcase, values]) if values.present?
        end

        json
      end

      def properties_for_es_index
        filterable_properties = properties.filterable.pluck(:id, :name)
        properties_values = product_properties.where(property_id: filterable_properties.map(&:first)).pluck(:property_id, :value)

        filterable_properties = filterable_properties.map do |prop|
          {
            id: prop.first,
            name: prop.last,
            value: properties_values.find { |pv| pv.first == prop.first }&.last
          }
        end

        json = { property_ids: filterable_properties.map { |p| p[:id] } }
        json.merge!(property_names: filterable_properties.map { |p| p[:name] })
        json.merge!(properties: filterable_properties)

        filterable_properties.each do |prop|
          json.merge!(Hash[prop[:name].downcase, prop[:value].downcase]) if prop[:value].present?
        end

        json
      end

      def index_data
        {}
      end
    end
  end
end

::Spree::Product.prepend(::SpreeSearchkick::Spree::ProductDecorator)

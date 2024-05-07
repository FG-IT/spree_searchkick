module SpreeSearchkick
  module Spree
    module ProductDecorator
      def self.prepended(base)
        base.has_many :inventories, class_name: 'SpreeSearchkick::Spree::Inventory', dependent: :destroy

        base.searchkick(
          callbacks: :async,
          word_start: [:name],
          settings: { number_of_replicas: 0 },
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
          includes(
            :option_types,
            :variants_including_master,
            taxons: :taxonomy,
            master: :default_price,
            product_properties: :property,
            variants: :option_values
          )
        }

        # base.skip_callback :commit, :after, :reindex, raise: false
        # base.after_save :reindex, if: -> { ::Searchkick.callbacks?(default: :async) }
        # base.after_destroy :reindex, if: -> { ::Searchkick.callbacks?(default: :async) }

        def base.autocomplete_fields
          [:name]
        end

        def base.search_fields
          [:name, :isins, :brand, :main_brand, :barcode]
        end

        def base.filter_fields
          [:brand, :taxon_ids, :vendor_ids, :isins, :has_image, :property_ids, :option_type_ids, :option_value_ids, :shipping_category_ids, :countries, :price]
        end

        def base.replace_indice
          ::Spree::Product.searchkick_index.replace_indice

          begin
            ::Spree::Product.includes(:representation).find_in_batches.each do |batch|
              batch.each do |product|
                product.reindex(nil, mode: :inline)
              end
            end
          rescue ActiveRecord::ActiveRecordError => e
            ActiveRecord::Base.connection.reconnect!
            sleep 3

            retry
          end
        end

        def base.autocomplete(keywords)
          if keywords
            ::Spree::Product.search(
              keywords,
              fields: autocomplete_fields,
              match: :word_start,
              limit: 10,
              load: false,
              misspellings: { below: 3 },
              where: search_where,
            ).map(&:name).map(&:strip).uniq
          else
            ::Spree::Product.search(
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
            price: { gt: 0 },
            has_image: true
          }
        end

        # Searchkick can't be reinitialized, this method allow to change options without it
        # ex add_searchkick_option { settings: { "index.mapping.total_fields.limit": 2000 } }
        def base.add_searchkick_option(option)
          base.class_variable_set(:@@searchkick_options, base.searchkick_options.deep_merge(option))
        end
      end

      def check_for_reindex
        if new_record? || name_changed?
          mark_for_reindex
        end
      end

      def mark_for_reindex
        @should_reindex = true
      end

      def do_reindex
        if @should_reindex.present?
          self.reindex
          @should_reindex = false
        end
      end

      def should_index?
        available?
      end

      def search_data
        if respond_to?(:presenter)
          json = search_data_representable
        else
          all_variants = variants_including_master_and_children

          all_taxons = taxons.flat_map { |t| t.self_and_ancestors.pluck(:id, :name) }.uniq

          isins = []
          all_variants.each { |v| isins << v.isin unless v.isin.blank? }
          isins.uniq!

          vendor_ids = []
          all_variants.each { |variant| vendor_ids << variant[:vendor_id] unless variant[:vendor_id].blank? }
          vendor_ids.uniq!

          skus = []
          all_variants.each { |variant| skus << variant[:sku] unless variant[:sku].blank? }
          skus.uniq!

          option_type_ids = options.map { |option_type| option_type[:option_type_id] }
          option_value_ids = []
          options.each { |option_type| option_value_ids.concat(option_type[:option_values]&.map { |option_value| option_value[:id] } || []) }
          option_value_ids.uniq!

          sellable_variants = all_variants.select { |v| v.available? && v.purchasable? && v.price > 0 }

          shipping_category_ids = []
          sellable_variants.each { |v| shipping_category_ids << v.shipping_category_id if v.shipping_category_id.present? }
          shipping_category_ids.uniq!
          countries = self.ship_to_country_codes

          price = 0
          compare_at_price = 0
          sellable_variants.each do |v|
            if v.price < price || price == 0
              price = v.price
              compare_at_price = v.compare_at_price
            end
          end
          # sellable_variants.each { |v| price = v.price compare_at_price = v.compare_at_price if v.price < price || price == 0 }
          json = {
            id: id,
            name: name,
            slug: slug,
            created_at: created_at,
            updated_at: updated_at,
            taxon_ids: all_taxons.map(&:first),
            taxon_names: all_taxons.map(&:last),
            isins: isins,
            has_image: images.count > 0,
            option_type_ids: option_type_ids,
            option_value_ids: option_value_ids,
            shipping_category_ids: shipping_category_ids,
            countries: countries,
            price: price,
            compare_at_price: compare_at_price,
            on_sale: compare_at_price > 0 ? 1 : 0,
            description: description,
            main_brand: main_brand,
            barcode: barcode,
            skus: all_variants.map { |v| v.sku }.uniq,
            vendor_ids: all_variants.map { |v| v.vendor_id }.uniq,
            active: available?,
            in_stock: in_stock?,
            conversions: orders.complete.count,
            featured: featured
          }
          json.merge!(option_types_for_es_index(all_variants))
          json.merge!(properties_for_es_index)
        end

        json.merge!(index_data)

        json
      end

      def search_data_representable
        taxons = {}
        presenter[:taxons]&.each do |t_path|
          t_path.each do |taxon|
            unless taxons.has_key?(taxon[:id])
              taxons[taxon[:id]] = taxon
            end
          end
        end

        isins = []
        presenter[:variants]&.each { |variant| isins << variant[:isin] if !variant[:isin].blank? }
        isins.uniq!

        vendor_ids = []
        presenter[:variants]&.each { |variant| vendor_ids << variant[:vendor_id] if !variant[:vendor_id].blank? }
        vendor_ids.uniq!

        skus = []
        presenter[:variants]&.each { |variant| skus << variant[:sku] if !variant[:sku].blank? }
        skus.uniq!

        properties = presenter[:properties]&.select { |prop| !prop[:value].blank? }
        if properties.nil?
          properties = []
        end

        option_type_ids = presenter[:options]&.map { |option_type| option_type[:option_type_id] }
        option_value_ids = []
        presenter[:options]&.each { |option_type| option_value_ids.concat(option_type[:option_values]&.map { |option_value| option_value[:id] } || []) }
        option_value_ids.uniq!

        shipping_category_ids = []
        price = 0
        compare_at_price = 0
        if false
          # inventories = ::SpreeSearchkick::Spree::Inventory.where(product_id: self.id).where(purchasable: true).where("price > 0")
          inventories.where(purchasable: true).where('price > 0').each do |inv|
            shipping_category_ids << inv.shipping_category_id
            if price == 0 || inv.price < price
              price = inv.price
            end
          end
          shipping_category_ids.uniq!
        else
          sellable_variants = []
          presenter[:variants].each { |v| sellable_variants << v if v[:available] && v[:in_stock] }

          sellable_variants.each { |v| shipping_category_ids << v[:shipping_category][:id] if v[:shipping_category].present? }
          shipping_category_ids.uniq!

          sellable_variants.each do |v|
            v[:prices].each do |p|
              if p[:amount] < price || price == 0
                price = p[:amount]
                if p[:compare_at_amount].present? && p[:compare_at_amount] > 0
                  compare_at_price = p[:compare_at_amount]
                end
              end
            end
          end

          # sellable_variants.each { |v| price = v[:price].to_f compare_at_price = v[:compare_at_price].to_f if v[:price].to_f < price || price == 0 }
        end

        countries = presenter[:variants]&.map { |v| v[:ship_to_country_codes] }.flatten.uniq

        json = {
          id: presenter[:id],
          name: presenter[:name],
          description: description,
          slug: presenter[:slug],
          created_at: presenter[:created_at],
          updated_at: presenter[:updated_at],
          taxon_ids: taxons.values.map { |t| t[:id] },
          taxon_names: taxons.values.map { |t| t[:name] },
          isins: isins,
          has_image: presenter[:images].present?,
          property_ids: properties.map { |prop| prop[:id] },
          property_names: properties.map { |prop| prop[:name] },
          option_type_ids: option_type_ids,
          option_value_ids: option_value_ids,
          shipping_category_ids: shipping_category_ids,
          countries: countries,
          price: price,
          compare_at_price: compare_at_price,
          on_sale: compare_at_price.present? && compare_at_price > 0 ? 1 : 0,
          vendor_ids: vendor_ids,
          skus: skus,
          barcode: barcode,
          active: available? && presenter[:available],
          conversions: orders.complete.count,
          main_brand: main_brand,
          featured: featured
        }

        properties.each do |prop|
          json.merge!(Hash[prop[:name].downcase, prop[:value]])
        end

        json
      end

      def option_types_for_es_index(all_variants)
        filterable_option_types = option_types.filterable.pluck(:id, :name)
        option_value_ids = ::Spree::OptionValueVariant.where(variant_id: all_variants.map(&:id)).pluck(:option_value_id).uniq
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

        filterable_properties.each do |prop|
          json.merge!(Hash[prop[:name].downcase, prop[:value]]) if prop[:value].present?
        end

        json
      end

      def index_data
        {}
      end

      def after_add_for_taxon_hook(taxon)
        updated_at = Time.now
        mark_for_reindex
      end

      def after_remove_for_taxon_hook(taxon)
        updated_at = Time.now
        mark_for_reindex
      end

    end
  end
end

::Spree::Product.prepend(::SpreeSearchkick::Spree::ProductDecorator)

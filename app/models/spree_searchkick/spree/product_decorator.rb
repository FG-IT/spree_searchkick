module SpreeSearchkick
  module Spree
    module ProductDecorator
      def self.prepended(base)
        base.has_many :inventories, class_name: 'SpreeSearchkick::Spree::Inventory', dependent: :destroy

        base.searchkick(
          callbacks: :async,
          word: [:name],
          settings: { number_of_replicas: 1, number_of_shards: ENV.fetch('ELASTICSEARCH_SHARDS', 4) },
          index_prefix: ENV['SITE_NAME'],
          merge_mappings: true,
          filterable: [
            :countries, # keyword (array/string)
            :main_brand,
            :brand, # keyword
            :country,
            :taxon_ids, # integer or keyword; either is fine for aggs
            :ship_from_countries, # keyword (array/string)
            :isins,
            :barcode,
            :conversions,
            :tags,
            :search_keywords,
            :country_of_origin
          ],
          mappings: {
            properties: {
              # ship_from_countries: { type: "keyword" },
              # countries: { type: "keyword" },
              # brand: { type: "keyword" },
              # conversions: { type: "integer" },
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
          [:name, :isins, :brand, :barcode]
        end

        def base.filter_fields
          [:brand, :tags, :taxon_ids, :vendor_ids, :isins, :property_ids, :option_type_ids, :option_value_ids, :shipping_category_ids, :countries, :price, :ship_from_countries, :country_of_origin]
            .union ::Spree::Property.filterable.map { |p| p.filter_name }
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
            featured: is_featured?(sku),
            country_of_origin: country_of_origin
          }
          json.merge!(option_types_for_es_index(all_variants))
          json.merge!(properties_for_es_index)
        end

        json.merge!(index_data)

        json
      end

      def is_featured?(variants)
        prefix_mapping = {
          "mw" => 1,
          "pl" => 2,
          "cndf" => 2,
          "ib" => 3
        }.freeze

        variants.each do |variant|
          sku = variant["sku"]&.downcase
          next unless sku

          prefix_mapping.each do |prefix, value|
            return value if sku.start_with?("#{prefix}-", "#{prefix}_")
          end
        end

        -1

      end

      def country_of_origin
        country_names = ["region", "country of origin", "country", "country_of_origin", "country/region of origin"]
        presenter[:properties]&.find { |p| country_names.include?(p["name"].to_s.downcase) }&.dig("value")
      end

      def presenter_price_in_currency(variant, currency = 'USD')
        price = variant[:prices].detect { |price| price[:currency] == currency&.upcase }
        if price.nil?
          money = ::Spree::Money.new(variant[:prices][0][:amount] || 0, currency: variant[:prices][0][:currency]).money.exchange_to(currency)
          compare_at = ::Spree::Money.new(variant[:prices][0][:compare_at_amount] || 0, currency: variant[:prices][0][:currency]).money.exchange_to(currency)
          price = { :currency => currency, :amount => money.to_f, :compare_at_amount => compare_at.to_f }
        end
        price
      end

      def normalize_es_datetime(value)
        return value unless value.is_a?(String)

        if value.match?(/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}\z/)
          value.sub(/\.\d{6}\z/, '').sub(' ', 'T') + 'Z'
        else
          value
        end
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

        properties = presenter[:properties]&.select { |prop| prop[:filterable] > 0 && !prop[:value].blank? }
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

        sellable_variants = []
        presenter[:variants].each { |v| sellable_variants << v if v[:available] && v[:in_stock] }
        sellable_variants.each { |v| shipping_category_ids << v[:shipping_category][:id] if v[:shipping_category].present? }
        shipping_category_ids.uniq!

        ship_from_countries = []
        sellable_variants.each do |v|
          v[:stock_items].each do |s|
            if s[:count_on_hand] > 0
              ship_from_countries << s[:stock_location_country]
            end
          end
        end

        created_at = presenter[:created_at]
        sellable_variants.each do |v|
          variant_price = presenter_price_in_currency(v)
          if v[:created_at] > created_at
            created_at = v[:created_at]
          end
          if variant_price[:amount] < price || price == 0
            price = variant_price[:amount]
            compare_at_price = variant_price[:compare_at_amount]
          end
        end
        countries = presenter[:variants]&.map { |v| v[:ship_to_country_codes] }.flatten.uniq

        json = {
          id: presenter[:id],
          name: presenter[:name],
          description: description.nil? ? '' : ActionView::Base.full_sanitizer.sanitize(description).gsub(/\r?\n/, " ").squeeze(" ").strip,
          slug: presenter[:slug],
          created_at: normalize_es_datetime(created_at),
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
          ship_from_countries: ship_from_countries,
          countries: countries,
          price: price,
          compare_at_price: compare_at_price,
          on_sale: compare_at_price.present? && compare_at_price > 0 ? 1 : 0,
          vendor_ids: vendor_ids,
          skus: skus,
          barcode: barcode,
          active: available? && presenter[:available] && presenter[:in_stock],
          in_stock: presenter[:in_stock] && price > 1,
          conversions: orders.complete.count,
          main_brand: main_brand,
          featured: is_featured?(sellable_variants),
          tags: meta_keywords.to_s.downcase.split(",").map(&:strip),
          search_keywords: extra_keywords(presenter[:name]).map(&:strip),
          country_of_origin: country_of_origin
        }

        properties.each do |prop|
          json.merge!(Hash[prop[:name].downcase, prop[:value]])
        end

        unless json["brand"].present?
          json["brand"] = main_brand
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

      def extra_keywords(title)
        words = title.to_s.downcase.scan(/[a-z0-9]+/)
        counts = words.tally
        extract_clean_keywords(counts.select { |tag, count| count > 0 && tag.length > 2 }.keys)
      end

      def extract_clean_keywords(words)
        # words = title.downcase.scan(/[a-z0-9]+/)
        stopwords = %w[
  # --- English stopwords ---
  the a an and or but if then else when where how what which who whose
  this that these those is are was were be been being
  in on at by with for from to of as into over under
  it its they them their my your our we you he she

  # --- Colors (basic + extended e-commerce set) ---
  red blue green yellow white black brown grey gray pink purple orange
  silver gold beige tan ivory lime mint navy teal violet bronze rose
  multicolor multi-color assorted assortedcolor rainbow

  # --- Sizes, units, quantities ---
  size weight volume length width height
  oz ml l g kg lb lbs mg mcg gram grams ml liter litre
  pack packs packof bundle bunch lot count piece pieces
  1oz 2oz 4oz 8oz 16oz 30ml 50ml 100ml 250ml 500ml

  # --- Generic marketing fluff ---
  natural organic pure premium original new authentic genuine
  quality high highquality best top grade extra strong strong formula complex

  # --- Product forms ---
  spray toner cleanser wash liquid oil
  powder extract capsule softgel tablet pill drops solution paste
  wipe wipes patch patches bar sheet sheets foam mousse sugar added

  # --- Packaging words ---
  bottle jar tube bag pouch box container brand
  the and with for from made vegan capsule capsules supplement supplements
  complex in a an of to by uk bio culture cultures strain strains
  billion cfu tablets tablet size weight pack mg g ml this that is are
  color colors form forms bottle bottles softgel softgels sugar-free
  the a an and or but if then else when where how what which who whose
  this that these those is are was were be been being
  in on at by with for from to of as into over under
  it its they them their my your our we you he she
  red blue green yellow white black brown grey gray pink purple orange
  silver gold beige tan ivory lime mint navy teal violet bronze rose
  multicolor multi-color assorted assortedcolor rainbow
  size weight volume length width height
  oz ml l g kg lb lbs mg mcg gram grams ml liter litre
  pack packs packof bundle bunch lot count piece pieces
  1oz 2oz 4oz 8oz 16oz 30ml 50ml 100ml 250ml 500ml
  natural organic pure premium original new authentic genuine
  quality high highquality best top grade extra strong strong formula complex
  spray toner cleanser wash liquid oil
  powder extract capsule softgel tablet pill drops solution paste
  wipe wipes patch patches bar sheet sheets foam mousse
  bottle jar tube bag pouch box container brand cultures category supreme
]

        words
          .reject { |w| stopwords.include?(w) }
          .reject { |w| w =~ /^\d+$/ || w.match?(/^\d+([a-z]+)?$/i) || # 1oz, 30ml, 500mg, 60caps
            w.match?(/^\d+$/) } # remove pure numbers
          .uniq
      end

    end
  end
end

::Spree::Product.prepend(::SpreeSearchkick::Spree::ProductDecorator)

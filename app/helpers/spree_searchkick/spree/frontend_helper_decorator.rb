module SpreeSearchkick
  module Spree
    module FrontendHelperDecorator

      def filtering_params
        if true
          @filtering_params ||= []
        else
          @filtering_params ||= available_option_types.map(&:filter_param).concat(available_properties.map(&:filter_param)).concat(static_filters)
        end
      end

      def available_properties_cache_key
        @available_properties_cache_key ||= ::Spree::Property.filterable.maximum(:updated_at)&.utc&.to_i
      end

      def available_properties
        if true
          @available_properties ||= []
        else
          @available_properties ||= Rails.cache.fetch("available-properties/#{available_properties_cache_key}") do
            Spree::Property.filterable.to_a
          end
          @available_properties
        end
      end
    end
  end
end

::Spree::FrontendHelper.prepend(::SpreeSearchkick::Spree::FrontendHelperDecorator) unless ::Spree::FrontendHelper.include?(::SpreeSearchkick::Spree::FrontendHelperDecorator)

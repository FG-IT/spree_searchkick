module Spree::Admin::OrdersControllerDecorator
  def index
    params[:q] ||= {}
    params[:q][:completed_at_not_null] ||= '1' if Spree::Config[:show_only_complete_orders_by_default]
    @show_only_completed = params[:q][:completed_at_not_null] == '1'
    params[:q][:s] ||= @show_only_completed ? 'completed_at desc' : 'created_at desc'
    params[:q][:completed_at_not_null] = '' unless @show_only_completed

    # As date params are deleted if @show_only_completed, store
    # the original date so we can restore them into the params
    # after the search
    created_at_gt = params[:q][:created_at_gt]
    created_at_lt = params[:q][:created_at_lt]

    params[:q].delete(:inventory_units_shipment_id_null) if params[:q][:inventory_units_shipment_id_null] == '0'

    if params[:q][:created_at_gt].present?
      params[:q][:created_at_gt] = begin
                                      Time.zone.parse(params[:q][:created_at_gt]).beginning_of_day
                                    rescue StandardError
                                      ''
                                    end
    end

    if params[:q][:created_at_lt].present?
      params[:q][:created_at_lt] = begin
                                      Time.zone.parse(params[:q][:created_at_lt]).end_of_day
                                    rescue StandardError
                                      ''
                                    end
    end

    if @show_only_completed
      params[:q][:completed_at_gt] = params[:q].delete(:created_at_gt)
      params[:q][:completed_at_lt] = params[:q].delete(:created_at_lt)
    end

    @search = Spree::Order.preload(:user).accessible_by(current_ability, :index).ransack(params[:q])

    # lazy loading other models here (via includes) may result in an invalid query
    # e.g. SELECT  DISTINCT DISTINCT "spree_orders".id, "spree_orders"."created_at" AS alias_0 FROM "spree_orders"
    # see https://github.com/spree/spree/pull/3919
    # @orders = @search.result(distinct: true).
    #           page(params[:page]).
    #           per(params[:per_page] || Spree::Config[:admin_orders_per_page])

    search_params_key_converter = 
    {
      created_at_gt: :created_at_gt,
      created_at_lt: :created_at_lt,
      completed_at_gt: :completed_at_gt,
      completed_at_lt: :completed_at_lt,
      keywords: :number_cont,
      state: :state_eq,
      payment_state: :payment_state_eq, 
      shipment_state: :shipment_state_eq, 
      firstname: :bill_address_firstname_start, 
      lastname: :bill_address_lastname_start, 
      email: :email_cont, 
      skus: :line_items_variant_sku_eq, 
      promotions_ids: :promotions_id_in, 
      store_id: :store_id_in, 
      channel: :channel_eq, 
      completed_at: :completed_at_not_null, 
      considered_risky: :considered_risky_eq, 
      approver_id: :approver_id_null, 
      group_buy: :group_buy_eq
    }
    search_params = {}
    search_params_key_converter.map do |key, value|
      if params[:q].key?(value)
        search_params[key] = params[:q][value]
      end
    end

    @searcher = build_searcher(search_params.merge({page: params[:page], per_page: params[:per_page]}))
    @orders = @searcher.retrieve_orders(search_params)
    
    # Restore dates
    params[:q][:created_at_gt] = created_at_gt
    params[:q][:created_at_lt] = created_at_lt
  end
end

if defined?(Spree::Admin::OrdersController)
  Spree::Admin::OrdersController.prepend(Spree::Admin::OrdersControllerDecorator)
end
  
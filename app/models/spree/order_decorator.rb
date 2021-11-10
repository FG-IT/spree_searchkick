module Spree::OrderDecorator
  def self.prepended(base)
    base.searchkick(
      callbacks: :async,
      settings: { number_of_replicas: 0 },
      index_prefix: ENV['SITE_NAME'],
      merge_mappings: true,
      mappings: {
        properties: {
        }
      }
    ) unless base.respond_to?(:searchkick_index)

    def base.search_fields
      [:number, :email, :firstname, :lastname, :skus, :products_name]
    end

  end

  def search_data
    all_variants = variants.pluck(:id, :sku)
    products_name = []
    variants.each do |all_variant|
      products_name << all_variant.product.name
    end
    firstname = shipping_address&.firstname
    lastname = shipping_address&.lastname
    json = {
      id: id,
      number: number,
      email: email,
      skus: all_variants.map(&:last),
      products_name: products_name,
      firstname: firstname,
      lastname: lastname,
      created_at: created_at,
      state: state,
      payment_state: payment_state,
      shipment_state: shipment_state,
      promotions_ids: promotions.pluck(:id),
      store_id: store_id,
      channel: channel,
      completed_at: completed_at,
      considered_risky: considered_risky,
      approver_id: approver_id,
      approved_at: approved_at,
      group_buy: group_buy
    }
    json
  end

end

Spree::Order.prepend(Spree::OrderDecorator)
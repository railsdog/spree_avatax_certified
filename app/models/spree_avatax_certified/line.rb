module SpreeAvataxCertified
  class Line
    attr_reader :order, :invoice_type, :lines

    def initialize(order, invoice_type)
      @order = order
      @invoice_type = invoice_type
      @lines = []
      @logger ||= AvataxHelper::AvataxLog.new('avalara_order_lines', 'SpreeAvataxCertified::Line', 'building lines')
      build_lines
    end

    def build_lines
      @logger.info('build lines')

      if invoice_type == 'ReturnInvoice' || invoice_type == 'ReturnOrder'
        reimbursement_lines
      else
        item_lines
        shipment_lines
      end
    end

    def item_lines
      @logger.info('build line_item lines')
      line_item_lines = []

      @logger.info('getting stock locations')

      stock_location_ids = Spree::Stock::Coordinator.new(order).packages.map(&:to_shipment).map(&:stock_location_id)
      stock_locations = Spree::StockLocation.where(id: stock_location_ids)

      @logger.debug stock_locations

      order.line_items.each do |line_item|

        stock_location = get_stock_location(stock_locations, line_item)

        line = {
          :LineNo => "#{line_item.id}-LI",
          :Description => line_item.name[0..255],
          :TaxCode => line_item.tax_category.try(:description) || 'P0000000',
          :ItemCode => line_item.variant.sku,
          :Qty => line_item.quantity,
          :Amount => line_item.discounted_amount.to_f,
          :OriginCode => stock_location,
          :DestinationCode => 'Dest',
          :CustomerUsageType => order.user ? order.user.avalara_entity_use_code.try(:use_code) : '',
          :Discounted => line_item.promo_total > 0.0
        }

        @logger.debug line

        line_item_lines << line
      end

      lines.concat(line_item_lines) unless line_item_lines.empty?
    end

    def shipment_lines
      @logger.info('build shipment lines')

      ship_lines = []
      order.shipments.each do |shipment|
        if shipment.tax_category
          shipment_line = {
            :LineNo => "#{shipment.id}-FR",
            :ItemCode => shipment.shipping_method.name,
            :Qty => 1,
            :Amount => shipment.discounted_amount.to_f,
            :OriginCode => "#{shipment.stock_location_id}",
            :DestinationCode => 'Dest',
            :CustomerUsageType => order.user ? order.user.avalara_entity_use_code.try(:use_code) : '',
            :Description => 'Shipping Charge',
            :TaxCode => shipment.shipping_method.tax_category.try(:description) || 'FR000000',
          }

          @logger.debug shipment_line

          ship_lines << shipment_line
        end

        lines.concat(ship_lines) unless ship_lines.empty?
      end
    end

    def refund_lines
      refunds = []
      order.refunds.each do |refund|
        next unless refund.reimbursement_id.nil?

        refund_line = {
          :LineNo => "#{refund.id}-RA",
          :ItemCode => refund.transaction_id || 'Refund',
          :Qty => 1,
          :Amount => -refund.amount.to_f,
          :OriginCode => 'Orig',
          :DestinationCode => 'Dest',
          :CustomerUsageType => myusecode.try(:use_code),
          :Description => 'Refund'
        }

        @logger.debug refund_line

        refunds << refund_line
      end
    end

    def reimbursement_return_item_lines
      @logger.info('build return reimbursement lines')

      return_item_lines = []

      order.reimbursements.each do |reimbursement|
        next if reimbursement.reimbursement_status == 'reimbursed'
        reimbursement.return_items.each do |return_item|
          return_item_line = {
            :LineNo => "#{return_item.inventory_unit.line_item_id}-RA-#{return_item.reimbursement_id}",
            :ItemCode => return_item.inventory_unit.line_item.sku || 'Reimbursement',
            :Qty => 1,
            :Amount => -return_item.pre_tax_amount.to_f,
            :OriginCode => 'Orig', #need to fix this
            :DestinationCode => 'Dest',
            :CustomerUsageType => order.user ? order.user.avalara_entity_use_code.try(:use_code) : '',
            :Description => 'Reimbursement'
          }

          if return_item.variant.tax_category.tax_code.nil?
            return_item_line[:TaxCode] = 'P0000000'
          else
            return_item_line[:TaxCode] = return_item.variant.tax_category.tax_code
          end

          @logger.debug return_item_line

          return_item_lines << return_item_line
        end
      end

      lines.concat(return_item_lines) unless return_item_lines.empty?
    end

    def get_stock_location(stock_locations, line_item)
      line_item_stock_locations = stock_locations.joins(:stock_items).where(spree_stock_items: {variant_id: line_item.variant_id})

      if line_item_stock_locations.empty?
        'Orig'
      else
        "#{line_item_stock_locations.first.id}"
      end
    end
  end
end

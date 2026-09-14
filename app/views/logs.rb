# frozen_string_literal: true

require_relative "common"

module Market
  module Views
    # 成交记录 / 挂单面板：整表由信号驱动（成交与挂单都是低频事件，整体重建可接受）
    module Logs
      include Common

      private

      def render_logs
        panel("panel-log") do # 容器块：不读信号
          panel_head("成交与挂单") do # 工具区块：读 log_tab
            chip("成交记录", log_tab == :trades, -> { set_log_tab(:trades) })
            chip("挂单", log_tab == :orders, -> { set_log_tab(:orders) })
          end

          # 表格：读 log_tab + 对应集合 → 事件驱动重建；行内全部是静态文字
          box(css_class: "log-body", direction: :column) do
            if log_tab == :orders
              render_order_rows
            else
              render_trade_rows
            end
          end
        end
      end

      def render_trade_rows
        trades = account_trades
        if trades.empty?
          label(css_class: "empty") { "还没有成交记录 · 下单后在这里出现" }
          return
        end

        box(css_class: "log-head") do
          label(css_class: "num") { "档位" }
          label { "标的" }
          label { "方向" }
          label(css_class: "num") { "成交价" }
          label(css_class: "num") { "数量" }
          label(css_class: "num") { "费用" }
          label(css_class: "num") { "已实现盈亏" }
        end
        trades.first(14).each { |trade| render_trade_row(trade) }
      end

      def render_trade_row(trade)
        box(css_class: "log-row") do
          label(css_class: "num dim") { trade.tick.to_s }
          label { trade.code }
          label(css_class: trade.side == :buy ? "side is-buy" : "side is-sell") { side_label(trade.side) }
          label(css_class: "num") { money(trade.price) }
          label(css_class: "num") { qty(trade.quantity) }
          label(css_class: "num") { money(trade.fee + trade.tax) }
          if trade.side == :sell
            label(css_class: "num", style: pct_style(trade.realized)) { signed_money(trade.realized) }
          else
            label(css_class: "num dim") { "—" }
          end
        end
      end

      def render_order_rows
        orders = account_orders
        if orders.empty?
          label(css_class: "empty") { "无挂单 · 限价单会在这里排队等待成交" }
          return
        end

        box(css_class: "log-head") do
          label(css_class: "num") { "档位" }
          label { "标的" }
          label { "方向" }
          label(css_class: "num") { "限价" }
          label(css_class: "num") { "数量" }
          label(css_class: "num") { "冻结资金" }
          label { "操作" }
        end
        orders.each { |order| render_order_row(order) }
      end

      def render_order_row(order)
        box(css_class: "log-row") do
          label(css_class: "num dim") { order.placed_tick.to_s }
          label { order.code }
          label(css_class: order.side == :buy ? "side is-buy" : "side is-sell") { side_label(order.side) }
          label(css_class: "num") { money(order.limit) }
          label(css_class: "num") { qty(order.quantity) }
          label(css_class: "num") { money(order.frozen) }
          box(css_class: "pos-act") do
            chip("撤单", false, -> { cancel_order(order.id) })
          end
        end
      end
    end
  end
end

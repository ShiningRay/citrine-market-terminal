# frozen_string_literal: true

require_relative "common"

module Market
  module Views
    # 成交记录行（子组件，key = 成交号）。
    #
    # 成交是不可变快照（Trade 只在产生时构造一次），所以整行可以当**值**传：
    # 它永远不会变，也就不会因为 props 变化触发重建（见 common.rb 纪律 3 的例外）。
    class TradeRow < Citrine::Component
      include Common

      prop :trade

      def view
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
    end

    # 挂单行（子组件，key = 委托号）：撤单动作通过回调 prop 交回根组件。
    class OrderRow < Citrine::Component
      include Common

      prop :order
      prop :on_cancel         # ->(order_id) { ... }

      def view
        box(css_class: "log-row") do
          label(css_class: "num dim") { order.placed_tick.to_s }
          label { order.code }
          label(css_class: order.side == :buy ? "side is-buy" : "side is-sell") { side_label(order.side) }
          label(css_class: "num") { money(order.limit) }
          label(css_class: "num") { qty(order.quantity) }
          label(css_class: "num") { money(order.frozen) }
          box(css_class: "pos-act") do
            chip("撤单", false, -> { on_cancel.call(order.id) })
          end
        end
      end
    end

    # 成交 / 挂单面板（子组件）：标签页是本面板自己的 state。
    class Logs < Citrine::Component
      include Common

      components TradeRow, OrderRow

      prop :trades            # -> { account_trades }
      prop :orders            # -> { account_orders }
      prop :on_cancel         # ->(order_id) { cancel_order(order_id) }

      state :tab, default: :trades

      def view
        panel("panel-log") do # 容器块：不读信号
          panel_head("成交与挂单") do # 工具区块：读本面板的 tab
            chip("成交记录", tab == :trades, -> { self.tab = :trades })
            chip("挂单", tab == :orders, -> { self.tab = :orders })
          end

          # 表格：读 tab + 对应集合 → 事件驱动重跑。行带 key（成交号 / 委托号）：
          # 新来一笔成交只是插入一行，已有行的节点与实例全部保留。
          #
          # 两张表直接放在同一层：行按各自 key 的组件身份区分与复用
          # （框架侧 F24 已修：新组件的根不会再被按位置复用到旧组件的根上）。
          box(css_class: "log-body", direction: :column) do
            if tab == :orders
              order_rows
            else
              trade_rows
            end
          end
        end
      end

      private

      def trade_rows
        list = trades.call
        if list.empty?
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
        list.first(14).each { |trade| trade_row(trade: trade, key: trade.id) }
      end

      def order_rows
        list = orders.call
        if list.empty?
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
        list.each { |order| order_row(order: order, key: order.id, on_cancel: on_cancel) }
      end
    end
  end
end

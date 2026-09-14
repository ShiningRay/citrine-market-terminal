# frozen_string_literal: true

require_relative "common"

module Market
  module Views
    # 持仓行（子组件，key = 股票代码）。
    #
    # 列分两类，各自的订阅落在各自的叶子上：
    #   · 快照列（持仓/可用/成本）读 ledger（仅成交时变，低频）；
    #   · 实时列（现价/市值/浮盈/收益率）读该标的行情信号（每档变）。
    # 两类的更新都只改文字/属性；行节点与整棵子树在行情变化时不动
    # （F6 落地前这里是"父块读 quote 后把 style 传给子节点，每档重建这 4 个标签"）。
    class PositionRow < Citrine::Component
      include Common

      prop :code              # 股票代码（值：永不变化）
      prop :name              # 名称（同上）
      prop :quote_for         # ->(code) { quote_of(code) }
      prop :position_for      # ->(code) { 持仓快照 }
      prop :on_close          # ->(code) { 平仓 }
      prop :on_cancel_orders  # ->(code) { 撤该标的挂单 }

      def view
        box(css_class: "pos-row") do
          box(css_class: "pos-name", direction: :column) do
            label(css_class: "wl-code") { code }
            label(css_class: "wl-cn") { name }
          end
          label(css_class: "num") { qty(position[:quantity]) }
          label(css_class: "num") { qty(position[:available]) }
          label(css_class: "num") { money(position[:avg_cost]) }

          # 实时列：三个数字各自的响应式 style 在本节点属性 Effect 里求值
          box(css_class: "pos-live") do
            label(css_class: "num") { money(quote[:last]) }
            label(css_class: "num", style: -> { pnl_style }) { money(position_value) }
            label(css_class: "num", style: -> { pnl_style }) { signed_money(position_pnl) }
            label(css_class: "num", style: -> { pnl_style }) { pct(position_pnl_pct) }
          end

          box(css_class: "pos-act") do
            chip("平仓", false, -> { on_close.call(code) })
            chip("撤挂单", false, -> { on_cancel_orders.call(code) })
          end
        end
      end

      private

      def position
        position_for.call(code)
      end

      def quote
        quote_for.call(code)
      end

      def position_value
        position[:quantity] * quote[:last]
      end

      def position_pnl
        position[:quantity] * (quote[:last] - position[:avg_cost])
      end

      def position_pnl_pct
        position[:avg_cost] > 0 ? quote[:last] / position[:avg_cost] - 1.0 : 0.0
      end

      def pnl_style
        pct_style(position_pnl)
      end
    end

    # 持仓面板（子组件）：汇总 + keyed 明细行。
    class Positions < Citrine::Component
      include Common

      components PositionRow

      prop :positions         # -> { account_positions }（code → 快照）
      prop :position_for      # ->(code) { 单个持仓快照 }
      prop :name_for          # ->(code) { engine_name(code) }
      prop :quote_for         # ->(code) { quote_of(code) }
      prop :summary           # -> { { market:, pnl:, available:, frozen: } }
      prop :on_close          # ->(code) { ... }
      prop :on_cancel_orders  # ->(code) { ... }
      prop :on_close_all      # -> { ... }

      def view
        panel("panel-pos") do # 容器块：不读信号
          panel_head("持仓") do # 工具区块：不读信号（动作在点击时求值）
            chip("一键清仓", false, on_close_all)
          end

          # 汇总：读 computed（价格驱动）
          box(css_class: "pos-summary") do
            stats = summary.call
            kv("持仓市值", money(stats[:market]))
            kv("浮动盈亏", signed_money(stats[:pnl]), pct_style(stats[:pnl]))
            kv("可用资金", money(stats[:available]))
            kv("冻结资金", money(stats[:frozen]))
          end

          # 明细表：读 ledger（仅交易时重跑）。行带 key（股票代码）：
          # 买入/卖出/清仓只增删受影响的行，其余行的节点与订阅原样保留。
          box(css_class: "pos-table", direction: :column) do
            rows = positions.call
            if rows.empty?
              label(css_class: "empty") { "暂无持仓 · 在右侧下单面板买入试试" }
            else
              box(css_class: "pos-head") do
                label { "标的" }
                label(css_class: "num") { "持仓" }
                label(css_class: "num") { "可用" }
                label(css_class: "num") { "成本" }
                label(css_class: "num") { "现价 / 市值 / 浮盈 / 收益率" }
                label { "操作" }
              end
              rows.each_key do |code|
                position_row(code: code, name: name_for.call(code), key: code,
                             quote_for: quote_for, position_for: position_for,
                             on_close: on_close, on_cancel_orders: on_cancel_orders)
              end
            end
          end
        end
      end
    end
  end
end

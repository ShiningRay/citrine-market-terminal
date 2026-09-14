# frozen_string_literal: true

require_relative "common"

module Market
  module Views
    # 持仓面板：明细行由 ledger 快照驱动（只在成交时重建），
    # 实时列（现价/市值/浮盈）由叶子块读行情信号（每档只改文字或重建 4 个节点）。
    module Positions
      include Common

      private

      def render_positions
        panel("panel-pos") do # 容器块：不读信号
          panel_head("持仓") do # 工具区块：不读信号（动作在点击时求值）
            chip("一键清仓", false, -> { close_all_positions })
          end

          # 汇总：读 computed（价格驱动）
          box(css_class: "pos-summary") do
            stats = {
              market: market_value,
              pnl: unrealized_pnl,
              available: account_available_cash,
              frozen: account_frozen
            }
            kv("持仓市值", money(stats[:market]))
            kv("浮动盈亏", signed_money(stats[:pnl]), pct_style(stats[:pnl]))
            kv("可用资金", money(stats[:available]))
            kv("冻结资金", money(stats[:frozen]))
          end

          # 明细表：读 ledger（仅交易时重建整表）
          box(css_class: "pos-table", direction: :column) do
            positions = account_positions
            if positions.empty?
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
              positions.each { |code, position| render_position_row(code, position) }
            end
          end
        end
      end

      # 快照（code / position）由父块传入；行块本身不读信号
      def render_position_row(code, position)
        box(css_class: "pos-row") do
          box(css_class: "pos-name", direction: :column) do
            label(css_class: "wl-code") { code }
            label(css_class: "wl-cn") { engine_name(code) }
          end
          label(css_class: "num") { qty(position[:quantity]) }
          label(css_class: "num") { qty(position[:available]) }
          label(css_class: "num") { money(position[:avg_cost]) }

          # 实时列：读该标的行情（颜色随盈亏变 → 重建这 4 个节点）
          box(css_class: "pos-live") do
            quote = quote_of(code)
            value = position[:quantity] * quote[:last]
            pnl = position[:quantity] * (quote[:last] - position[:avg_cost])
            pnl_pct = position[:avg_cost] > 0 ? quote[:last] / position[:avg_cost] - 1.0 : 0.0
            style = pct_style(pnl)
            label(css_class: "num") { money(quote[:last]) }
            label(css_class: "num", style: style) { money(value) }
            label(css_class: "num", style: style) { signed_money(pnl) }
            label(css_class: "num", style: style) { pct(pnl_pct) }
          end

          box(css_class: "pos-act") do
            chip("平仓", false, -> { close_position(code) })
            chip("撤挂单", false, -> { cancel_orders_for(code) })
          end
        end
      end
    end
  end
end

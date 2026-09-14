# frozen_string_literal: true

require_relative "common"

module Market
  module Views
    # 持仓面板：明细行由 ledger 快照驱动（只在成交时重建），
    # 实时列（现价/市值/浮盈）由叶子块读行情信号 + 响应式 style 着色
    # （每档只改文字与属性，**0 个新建节点**）。
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

          # 实时列：读该标的行情。三个数字各自的响应式 style 在本节点属性 Effect 里
          # 求值 → 每档只重设 style/文字，**0 个新建节点**（从前是容器块读 quote 后
          # 把 style 传给子节点，每档重建这 4 个标签）。
          box(css_class: "pos-live") do
            label(css_class: "num") { money(quote_of(code)[:last]) }
            label(css_class: "num", style: -> { position_style(code, position) }) do
              money(position_value(code, position))
            end
            label(css_class: "num", style: -> { position_style(code, position) }) do
              signed_money(position_pnl(code, position))
            end
            label(css_class: "num", style: -> { position_style(code, position) }) do
              pct(position_pnl_pct(code, position))
            end
          end

          box(css_class: "pos-act") do
            chip("平仓", false, -> { close_position(code) })
            chip("撤挂单", false, -> { cancel_orders_for(code) })
          end
        end
      end

      # ── 实时列的派生值（读行情信号；只在叶子块 / 属性 Proc 里调用）──

      def position_value(code, position)
        position[:quantity] * quote_of(code)[:last]
      end

      def position_pnl(code, position)
        quote = quote_of(code)
        position[:quantity] * (quote[:last] - position[:avg_cost])
      end

      def position_pnl_pct(code, position)
        quote = quote_of(code)
        position[:avg_cost] > 0 ? quote[:last] / position[:avg_cost] - 1.0 : 0.0
      end

      def position_style(code, position)
        pct_style(position_pnl(code, position))
      end
    end
  end
end

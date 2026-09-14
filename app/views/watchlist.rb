# frozen_string_literal: true

require_relative "common"

module Market
  module Views
    module Watchlist
      include Common

      private

      def render_watchlist
        panel("panel-watch") do # 容器块：不读信号
          panel_head("自选行情") do # 工具区块：读 sort_key
            chip("代码", sort_key == :code, -> { apply_sort(:code) })
            chip("涨跌幅", sort_key == :change, -> { apply_sort(:change) })
            chip("成交额", sort_key == :amount, -> { apply_sort(:amount) })
          end

          box(css_class: "wl-head") do # 静态表头（不读信号）
            label(css_class: "wl-c-code") { "标的" }
            label(css_class: "wl-c-last num") { "最新" }
            label(css_class: "wl-c-chg num") { "涨跌" }
            label(css_class: "wl-c-pct num") { "涨跌幅" }
            label(css_class: "wl-c-vol num") { "成交量" }
          end

          # 行集合：只在排序变化时重建。
          # 换股（selected 变）不再重建行——选中态是行自己的响应式 css_class（见下）。
          box(css_class: "wl-body", direction: :column) do
            row_order.each { |code| render_watch_row(code) }
          end
        end
      end

      # 单行：行块本身不读信号（选中态是响应式属性，行情由叶子块各自读）
      def render_watch_row(code)
        box(css_class: -> { selected == code ? "wl-row is-active" : "wl-row" },
            on_click: -> { select_symbol(code) }) do
          box(css_class: "wl-name", direction: :column) do
            label(css_class: "wl-code") { code }
            label(css_class: "wl-cn") { engine_name(code) }
            render_hold_badge(code)
          end

          # 价格组：颜色随涨跌变化。容器块不读信号，三个数字各自的响应式 style
          # 在本节点的属性 Effect 里求值 → 每档只重设 style/文字，**0 个新建节点**
          # （从前是容器块读 quote 后把 style 传给子节点，每档重建 3 个标签）。
          box(css_class: "wl-price") do
            label(css_class: "wl-c-last num", style: -> { quote_style(code) }) { money(quote_of(code)[:last]) }
            label(css_class: "wl-c-chg num", style: -> { quote_style(code) }) { signed_money(quote_of(code)[:change]) }
            label(css_class: "wl-c-pct num", style: -> { quote_style(code) }) { pct(quote_of(code)[:change_pct]) }
          end

          # 成交量/成交额：无色变化 → 叶子块读，只改文字（0 元素重建）
          label(css_class: "wl-c-vol num") { volume(quote_of(code)[:volume]) }
          label(css_class: "wl-c-amt num") { amount(quote_of(code)[:amount]) }
        end
      end

      # 响应式属性用：涨跌色（在本节点的属性 Effect 内求值）
      def quote_style(code)
        pct_style(quote_of(code)[:change])
      end

      # 持仓标记：读 ledger（仅交易时变化）
      def render_hold_badge(code)
        box(css_class: "wl-badge-slot") do
          if position_of(code)
            label(css_class: "badge badge-hold") { "持" }
          end
        end
      end
    end
  end
end

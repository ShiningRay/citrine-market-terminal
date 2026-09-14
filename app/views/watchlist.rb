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

          # 行集合：只在排序 / 选中变化时重建（不是每 tick）
          box(css_class: "wl-body", direction: :column) do
            active = selected
            order = row_order
            order.each { |code| render_watch_row(code, active) }
          end
        end
      end

      # 单行：row 块本身不读信号（全选态由父块传入，行情由叶子块各自读）
      def render_watch_row(code, active)
        box(css_class: active == code ? "wl-row is-active" : "wl-row",
            on_click: -> { select_symbol(code) }) do
          box(css_class: "wl-name", direction: :column) do
            label(css_class: "wl-code") { code }
            label(css_class: "wl-cn") { engine_name(code) }
            render_hold_badge(code)
          end

          # 价格组：颜色随涨跌变化 → 外层块读 quote，内层标签静态
          box(css_class: "wl-price") do
            quote = quote_of(code)
            style = pct_style(quote[:change])
            label(css_class: "wl-c-last num", style: style) { money(quote[:last]) }
            label(css_class: "wl-c-chg num", style: style) { signed_money(quote[:change]) }
            label(css_class: "wl-c-pct num", style: style) { pct(quote[:change_pct]) }
          end

          # 成交量/成交额：无色变化 → 叶子块读，只改文字（0 元素重建）
          label(css_class: "wl-c-vol num") { volume(quote_of(code)[:volume]) }
          label(css_class: "wl-c-amt num") { amount(quote_of(code)[:amount]) }
        end
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

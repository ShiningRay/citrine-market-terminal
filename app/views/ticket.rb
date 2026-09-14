# frozen_string_literal: true

require_relative "common"

module Market
  module Views
    # 下单面板。
    # 关键纪律：数量/限价两个输入框所在的块**不读任何信号**，
    # 否则每档 tick 都会重建输入框（丢焦点、丢输入法状态）。
    module Ticket
      include Common

      private

      def render_ticket
        panel("panel-ticket") do # 容器块：不读信号
          panel_head("交易下单") do # 工具区块：读 order_kind
            chip("市价", order_kind == :market, -> { set_order_kind(:market) })
            chip("限价", order_kind == :limit, -> { set_order_kind(:limit) })
          end

          box(css_class: "tk-side") do # 读 side
            chip("买入", side == :buy, -> { set_side(:buy) })
            chip("卖出", side == :sell, -> { set_side(:sell) })
          end

          # 报价 + 当前持仓：读 quote 与 ledger → 重建几个静态标签
          box(css_class: "tk-quote", direction: :column) do
            quote = quote_of(selected)
            label(css_class: "tk-sym") { "#{quote[:name]} · #{quote[:code]}" }
            label(css_class: "tk-last num", style: pct_style(quote[:change])) { money(quote[:last]) }
            label(css_class: "tk-ba num") { "买一 #{money(quote[:bid])} · 卖一 #{money(quote[:ask])}" }
            label(css_class: "tk-hold num") { holding_line(quote[:code]) }
          end

          # 数量输入：本块不读信号 → 输入框在整个会话中保持同一个 DOM 节点
          box(css_class: "tk-field", direction: :column) do
            label(css_class: "tk-label") { "数量（股）" }
            box(css_class: "tk-row") do
              text_input(value: signal(:qty_text), placeholder: "100 的整数倍", css_class: "tk-input num")
              box(css_class: "tk-quick") do
                chip("100", false, -> { fill_quantity_with(100) })
                chip("500", false, -> { fill_quantity_with(500) })
                chip("1000", false, -> { fill_quantity_with(1000) })
                chip("全部", false, -> { use_max_quantity })
              end
            end
          end

          # 限价输入：仅限价模式出现（读 order_kind）
          box(css_class: "tk-field", direction: :column) do
            if order_kind == :limit
              label(css_class: "tk-label") { "限价（元）" }
              text_input(value: signal(:limit_text), placeholder: "如 1,500.00", css_class: "tk-input num")
            end
          end

          # 预估明细：读 qty_text / limit_text / side / order_kind / quote / ledger
          box(css_class: "tk-estimate", direction: :column) do
            estimate_lines
          end

          # 提交按钮 + 反馈：读 side / alert / selected —— 全部在**本块**取值，
          # 内层标签只用局部变量。若内层再读同一信号，就会踩到
          # "祖先块与后代块订阅同一信号"的框架崩溃（FRICTION.md 的 F1）。
          box(css_class: "tk-submit") do
            current_side = side
            message = alert
            code = selected
            name = engine_name(code)
            button(on_click: :submit_order,
                   css_class: current_side == :buy ? "btn-submit is-buy" : "btn-submit is-sell") do
              "#{side_label(current_side)} #{name}"
            end
            if message
              label(css_class: message[:ok] ? "alert is-ok" : "alert is-bad") { message[:text] }
            end
          end

          box(css_class: "tk-notice") do # 读 notice（内层标签只用局部变量）
            kind = notice[:kind]
            text = notice[:text].to_s
            label(css_class: "notice notice-#{kind}") { text.empty? ? "—" : text }
          end
        end
      end

      def holding_line(code)
        position = position_of(code)
        return "当前未持有" if position.nil?

        "持仓 #{qty(position[:quantity])} 股 · 可用 #{qty(position[:available])} 股 · 成本 #{money(position[:avg_cost])}"
      end

      # 预估明细（调用方 block 负责依赖收集）
      def estimate_lines
        quantity = parse_quantity(qty_text).to_i
        quote = quote_of(selected)
        limit = parse_price(limit_text)
        price = if order_kind == :limit
                  limit || quote[side == :buy ? :ask : :bid]
                else
                  side == :buy ? quote[:ask] : quote[:bid]
                end
        estimate = @account.estimate(side, quantity, price)
        max_quantity = side == :buy ? @account.max_buy_quantity(quote[:ask]) : @account.available(selected, @engine.tick)

        kv("委托类型", order_kind == :market ? "市价" : (limit ? "限价 #{money(limit)}" : "限价（未填）"))
        kv("预估成交价", money(price))
        kv("预估金额", money(estimate[:gross]))
        kv("预估费用", money(estimate[:fee] + estimate[:tax]))
        kv(side == :buy ? "预估支出" : "预估收入", money(estimate[:total]))
        kv(side == :buy ? "最大可买" : "最大可卖", "#{qty(max_quantity)} 股")
      end
    end
  end
end

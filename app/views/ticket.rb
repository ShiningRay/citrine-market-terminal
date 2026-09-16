# frozen_string_literal: true

require_relative "common"

module Market
  module Views
    # 下单面板（子组件）。
    #
    # **下单草稿（方向 / 委托类型 / 数量 / 限价）是本面板自己的 state**：它只属于这张表单，
    # 从前因为"v1 无组件嵌套"只能全挂在 Terminal 上（FRICTION F5），现在下沉到这里。
    # 成交撮合、提示与告警仍由根组件负责——本面板只管收集草稿并通过 `on_submit` 回调交出去
    # （子改父：回调 prop 的闭包 self 是根组件）。
    #
    # 输入框所在的两个块照常读自己需要的信号：keyed/位置复用落地后，块重跑会命中同一批
    # 节点，输入框不再被销毁重建（F6 时代的"输入框块绝不读信号"纪律已退休）。
    class Ticket < Citrine::Component
      include Common

      prop :selected        # -> { selected }
      prop :quote_for       # ->(code) { quote_of(code) }
      prop :name_for        # ->(code) { engine_name(code) }   非响应式（提交按钮文案用）
      prop :position_for    # ->(code) { 持仓快照 | nil }
      prop :alert           # -> { alert }      最近一次委托结果（含跨面板动作）
      prop :estimate        # ->(side, quantity, price) { 费用预估 }
      prop :max_buy_for     # ->(price) { 该价位的最大可买 }
      prop :available_for   # ->(code) { 该标的当前可用（T+1 后）}
      prop :parse_qty       # ->(text) { 数量文本 → Integer | nil }（解析口径只有一份，在根组件）
      prop :parse_px        # ->(text) { 限价文本 → Float | nil }
      prop :on_submit       # ->(side, kind, quantity_text, limit_text) { 交给根组件撮合 }

      state :side, default: :buy
      state :order_kind, default: :market
      state :qty_text, default: "100"
      state :limit_text, default: ""

      def view
        panel("panel-ticket") do # 容器块：不读信号
          panel_head("交易下单") do # 工具区块：读 order_kind
            chip("市价", order_kind == :market, -> { self.order_kind = :market })
            chip("限价", order_kind == :limit, -> { self.order_kind = :limit })
          end

          box(css_class: "tk-side") do # 读 side
            chip("买入", side == :buy, -> { self.side = :buy })
            chip("卖出", side == :sell, -> { self.side = :sell })
          end

          # 报价 + 当前持仓：读 quote 与 ledger → 重跑这几个静态标签
          box(css_class: "tk-quote", direction: :column) do
            code = selected.call
            quote = quote_for.call(code)
            label(css_class: "tk-sym") { "#{quote[:name]} · #{quote[:code]}" }
            label(css_class: "tk-last num", style: pct_style(quote[:change])) { money(quote[:last]) }
            label(css_class: "tk-ba num") { "买一 #{money(quote[:bid])} · 卖一 #{money(quote[:ask])}" }
            label(css_class: "tk-hold num") { holding_line(position_for.call(code)) }
          end

          # 数量输入：受控输入绑到本面板的 qty_text
          box(css_class: "tk-field", direction: :column) do
            label(css_class: "tk-label") { "数量（股）" }
            box(css_class: "tk-row") do
              text_input(value: signal(:qty_text), placeholder: "100 的整数倍", css_class: "tk-input num")
              box(css_class: "tk-quick") do
                chip("100", false, -> { self.qty_text = "100" })
                chip("500", false, -> { self.qty_text = "500" })
                chip("1000", false, -> { self.qty_text = "1000" })
                chip("全部", false, -> { fill_max_quantity })
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

          # 预估明细：读草稿（qty_text / limit_text / side / order_kind）+ 行情 + 账本
          box(css_class: "tk-estimate", direction: :column) { estimate_lines }

          # 提交按钮 + 反馈：读 side / alert / selected —— 全部在**本块**取值，
          # 内层标签只用局部变量
          box(css_class: "tk-submit") do
            current_side = side
            message = alert.call
            code = selected.call
            name = name_for.call(code)
            button(on_click: :submit,
                   css_class: current_side == :buy ? "btn-submit is-buy" : "btn-submit is-sell") do
              "#{side_label(current_side)} #{name}"
            end
            if message
              label(css_class: message[:ok] ? "alert is-ok" : "alert is-bad") { message[:text] }
            end
          end

          # 常驻免责声明（瞬时通知已迁往右下角 toast 堆叠，不再借用这一行）
          box(css_class: "tk-notice") do
            label(css_class: "notice notice-info") { "本地模拟盘：数据为随机生成，与真实行情无关" }
          end
        end
      end

      # 提交当前草稿（点击提交按钮 / 输入框外按 Enter 都走这里）
      def submit
        on_submit.call(side, order_kind, qty_text, limit_text)
        self
      end

      # 快捷键 B / S（根组件的 window_key 转发过来）
      def set_side(value)
        self.side = value
        self
      end

      private

      def holding_line(position)
        return "当前未持有" if position.nil?

        "持仓 #{qty(position[:quantity])} 股 · 可用 #{qty(position[:available])} 股 · 成本 #{money(position[:avg_cost])}"
      end

      # 数量快捷「全部」：按当前方向取最大可买 / 可卖（事件处理器里读，不建立订阅）
      def fill_max_quantity
        code = selected.call
        quote = quote_for.call(code)
        quantity = side == :buy ? max_buy_for.call(quote[:ask]) : available_for.call(code)
        self.qty_text = quantity.to_s
        self
      end

      # 预估明细（本块负责收集依赖）
      def estimate_lines
        quantity = parse_qty.call(qty_text).to_i
        code = selected.call
        quote = quote_for.call(code)
        limit = parse_px.call(limit_text)
        price = if order_kind == :limit
                  limit || quote[side == :buy ? :ask : :bid]
                else
                  side == :buy ? quote[:ask] : quote[:bid]
                end
        costs = estimate.call(side, quantity, price)
        max_quantity = side == :buy ? max_buy_for.call(quote[:ask]) : available_for.call(code)

        kv("委托类型", order_kind == :market ? "市价" : (limit ? "限价 #{money(limit)}" : "限价（未填）"))
        kv("预估成交价", money(price))
        kv("预估金额", money(costs[:gross]))
        kv("预估费用", money(costs[:fee] + costs[:tax]))
        kv(side == :buy ? "预估支出" : "预估收入", money(costs[:total]))
        kv(side == :buy ? "最大可买" : "最大可卖", "#{qty(max_quantity)} 股")
      end
    end
  end
end

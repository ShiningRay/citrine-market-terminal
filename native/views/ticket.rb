# frozen_string_literal: true

require_relative "common"

module Market
  module Native
    module Views
      # 下单面板（原生版，纯原生控件）：方向 / 委托类型 / 数量 / 限价 / 提交 / 反馈。
      #
      # 逻辑、state 与动作全部沿用 app/views/ticket.rb 的 Ticket（草稿 side/order_kind/qty_text/
      # limit_text 仍归本面板所有；#submit 与 #set_side 是键盘路径的入口），本类只重写 #view。
      #
      # 两处原生侧限制决定了这里的写法：
      #   1. **libui 的 entry 拿不到 Enter**（设计文档 2.3）→ 必须有一个点击提交的按钮；
      #      输入框里的回车不可用，B/S/Enter 快捷键走 window_key 转发。
      #   2. entry 没有 placeholder → 说明文字放到相邻 label 里。
      class Ticket < ::Market::Views::Ticket
        include Common

        def view
          # stretch: false —— 下单面板是固定几行原生控件（label/按钮/输入框），没有可拉伸的
          # 数据区。让它 stretchy 会让"这一列的最小高度"按最高的 stretchy 面板算两次
          # （libui 的 box 规则，见 Common#panel_frame 的实测），窗口就没法缩小了。
          panel_frame("交易下单", stretch: false) do
            box(direction: :row, gap: 6) do
              state_button(-> { self.order_kind = :market }) { order_kind == :market ? "市价 ✓" : "市价" }
              state_button(-> { self.order_kind = :limit }) { order_kind == :limit ? "限价 ✓" : "限价" }
            end

            box(direction: :row, gap: 6) do
              state_button(-> { self.side = :buy }) { side == :buy ? "买入 ✓" : "买入" }
              state_button(-> { self.side = :sell }) { side == :sell ? "卖出 ✓" : "卖出" }
            end

            label { quote_line }
            label { holding_line(position_for.call(selected.call)) }
            label { "数量（股，须为 100 的整数倍）" }

            box(direction: :row, gap: 4) do
              text_input(value: signal(:qty_text))
              state_button(-> { self.qty_text = "100" }) { "100" }
              state_button(-> { self.qty_text = "500" }) { "500" }
              state_button(-> { self.qty_text = "1000" }) { "1000" }
              state_button(-> { fill_max_quantity }) { "全部" }
            end

            # 限价输入只在这一档出现（读 order_kind；切回市价即撤掉 entry）。
            #
            # 这个容器**任何时候都不能是空的**（市价模式下也要留一行 label）：
            # libui 的 box 会把列里的剩余空间分给"空容器"，于是这个本该固定高度的下单面板
            # 会反过来吃掉整列高度，把下面的成交/挂单表挤成 0 高（真窗口实测：
            # 空容器 212 高、日志表 areaView 0×0）。原理见 Common#panel_frame 的说明。
            box(direction: :column, gap: 2) do
              label { order_kind == :limit ? "限价（元）" : "限价（元）：市价单不用填，点「限价」切换" }
              text_input(value: signal(:limit_text)) if order_kind == :limit
            end

            label { estimate_line }
            button(on_click: -> { submit }) { "提交#{side_label(side)} #{name_for.call(selected.call)}" }
            label { alert_text }
            label { notice_text }
          end
        end

        private

        # 报价 + 持仓：一个 label 一次读齐（label 的块 Effect 原地改文字）。
        # 拆两行：原生 label 不换行，单行 ~399px 会把右列的**最小宽度**顶高——
        # 三列等宽布局下即窗口最小宽度，见 native/README.md
        def quote_line
          quote = quote_for.call(selected.call)
          "#{quote[:name]} · #{quote[:code]} · 最新 #{money(quote[:last])}\n" \
            "买一 #{money(quote[:bid])} / 卖一 #{money(quote[:ask])}"
        end

        # 预估明细：浏览器版是 6 行 kv，这里三行（原生 label 里换行即换行）
        def estimate_line
          quote = quote_for.call(selected.call)
          quantity = parse_qty.call(qty_text).to_i
          price = estimate_price(quote)
          costs = estimate.call(side, quantity, price)
          max_quantity = side == :buy ? max_buy_for.call(quote[:ask]) : available_for.call(quote[:code])
          "预估成交价 #{money(price)} · 预估金额 #{money(costs[:gross])}\n" \
            "预估费用 #{money(costs[:fee] + costs[:tax])} · " \
            "#{side == :buy ? '预估支出' : '预估收入'} #{money(costs[:total])}\n" \
            "#{side == :buy ? '最大可买' : '最大可卖'} #{qty(max_quantity)} 股"
        end

        # 与浏览器版 #estimate_lines 同一口径：限价模式优先用限价（没填则退回对手价）
        def estimate_price(quote)
          if order_kind == :limit
            parse_px.call(limit_text) || quote[side == :buy ? :ask : :bid]
          else
            side == :buy ? quote[:ask] : quote[:bid]
          end
        end

        # 浏览器侧瞬时通知走 toast 堆叠（app 版已删此 prop）；原生侧无浮层宿主，
        # 保留"单行最新提示"——prop 由本子类自有声明，不影响 app 版契约
        prop :notice          # -> { notice }     全局提示

        def notice_text
          current = notice.call
          text = current[:text].to_s
          "提示：#{text.empty? ? '—' : text}"
        end

        def alert_text
          result = alert.call
          "委托结果：#{result ? result[:text] : '—'}"
        end

      end
    end
  end
end

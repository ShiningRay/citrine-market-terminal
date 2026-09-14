# frozen_string_literal: true

require_relative "common"

module Market
  module Views
    # 顶部条（子组件）：品牌 / 交易时段 / 账户总览 / 运行控制。
    #
    # 无局部状态、无交易动作：会变的值全部是根组件传下来的**取值 Proc**
    # （`equity.call` / `paused.call`…），本组件在需要它们的那一层块里才调用，
    # 于是订阅落在那个块自己的 Effect 上（见 common.rb 纪律 3）。
    class Header < Citrine::Component
      include Common

      prop :tick              # -> { tick_value }        当前档位
      prop :equity            # -> { equity }            总资产
      prop :pnl               # -> { unrealized_pnl }    浮动盈亏
      prop :total_return      # -> { total_return }      累计收益率
      prop :paused            # -> { paused }
      prop :speed             # -> { speed }
      prop :auto_trade        # -> { auto_trade }
      prop :on_toggle_pause   # -> { ... }
      prop :on_speed          # ->(value) { ... }
      prop :on_toggle_auto
      prop :on_reset

      def view
        box(css_class: "hd") do # 容器块：不读信号
          box(css_class: "hd-brand", direction: :column) do
            label(css_class: "hd-logo") { "Citrine 行情终端" }
            label(css_class: "hd-sub") { "本地模拟数据 · 红涨绿跌 · T+1 · 100 股整手" }
          end

          # 三格各自在自己的叶子块里读档位（**容器块不读信号**：读在这里会让整块每档重跑）
          box(css_class: "hd-clock", direction: :row, gap: 12) do
            label(css_class: "hd-phase") { session_phase(tick.call) }
            label(css_class: "hd-time num") { session_time(tick.call) }
            label(css_class: "hd-tick num") { "第 #{tick.call} 档" }
          end

          # 账户总览：颜色随盈亏变化，值在本块里取（kpi 收的是值而不是 Proc）
          box(css_class: "hd-equity", direction: :row, gap: 18) do
            equity_value = equity.call
            pnl_value = pnl.call
            total = total_return.call
            kpi("总资产", money(equity_value), nil)
            kpi("浮动盈亏", signed_money(pnl_value), pct_style(pnl_value))
            kpi("累计收益率", pct(total), pct_style(total))
          end

          box(css_class: "hd-controls", direction: :row, gap: 6) do
            paused_now = paused.call
            speed_now = speed.call
            chip(paused_now ? "▶ 继续" : "⏸ 暂停", paused_now, on_toggle_pause)
            chip("1x", !paused_now && speed_now == 1, -> { on_speed.call(1) })
            chip("2x", !paused_now && speed_now == 2, -> { on_speed.call(2) })
            chip("4x", !paused_now && speed_now == 4, -> { on_speed.call(4) })
          end

          box(css_class: "hd-controls", direction: :row, gap: 6) do
            auto = auto_trade.call
            chip(auto ? "自动交易 开" : "自动交易 关", auto, on_toggle_auto)
            chip("重置账户", false, on_reset)
            label(css_class: "hd-hint") { "快捷键：空格暂停 · 1/2/3 变速 · ↑↓ 换股 · B/S 买卖 · Esc 清提示" }
          end
        end
      end

      private

      def kpi(label_text, value_text, value_style)
        box(css_class: "kpi", direction: :column) do
          label(css_class: "kpi-k") { label_text }
          label(css_class: "kpi-v num", style: value_style) { value_text }
        end
      end
    end
  end
end

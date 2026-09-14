# frozen_string_literal: true

require_relative "common"

module Market
  module Views
    module Header
      include Common

      private

      # 顶部条：品牌 / 交易时段 / 账户总览 / 运行控制
      # 各单元互不嵌套订阅，逐块标注读取的信号。
      def render_header
        box(css_class: "hd") do # 容器块：不读信号
          box(css_class: "hd-brand", direction: :column) do
            label(css_class: "hd-logo") { "Citrine 行情终端" }
            label(css_class: "hd-sub") { "本地模拟数据 · 红涨绿跌 · T+1 · 100 股整手" }
          end

          box(css_class: "hd-clock", direction: :row, gap: 12) do
            label(css_class: "hd-phase") { Format.session_phase(tick_value) }        # 读 tick
            label(css_class: "hd-time num") { Format.session_time(tick_value) }      # 读 tick
            label(css_class: "hd-tick num") { "第 #{tick_value} 档" }                # 读 tick
          end

          # 账户总览：颜色随盈亏变化 → 外层块读，内层静态文字
          # （kv/kpi 收的是值而不是 Proc，这里还没法收成响应式属性；
          #   理由见 views/common.rb 顶部注释）
          box(css_class: "hd-equity", direction: :row, gap: 18) do
            equity = self.equity
            pnl = unrealized_pnl
            total = total_return
            kpi("总资产", money(equity), nil)
            kpi("浮动盈亏", signed_money(pnl), pct_style(pnl))
            kpi("累计收益率", pct(total), pct_style(total))
          end

          box(css_class: "hd-controls", direction: :row, gap: 6) do
            chip(paused ? "▶ 继续" : "⏸ 暂停", paused, -> { toggle_pause })      # 读 paused
            chip("1x", !paused && speed == 1, -> { set_speed(1) })              # 读 paused/speed
            chip("2x", !paused && speed == 2, -> { set_speed(2) })
            chip("4x", !paused && speed == 4, -> { set_speed(4) })
          end

          box(css_class: "hd-controls", direction: :row, gap: 6) do
            chip(auto_trade ? "自动交易 开" : "自动交易 关", auto_trade, -> { toggle_auto_trade })
            chip("重置账户", false, -> { reset_account })
            label(css_class: "hd-hint") { "快捷键：空格暂停 · 1/2/3 变速 · ↑↓ 换股 · B/S 买卖 · Esc 清提示" }
          end
        end
      end

      def kpi(label_text, value_text, value_style)
        box(css_class: "kpi", direction: :column) do
          label(css_class: "kpi-k") { label_text }
          label(css_class: "kpi-v num", style: value_style) { value_text }
        end
      end
    end
  end
end

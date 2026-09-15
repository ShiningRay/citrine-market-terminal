# frozen_string_literal: true

require_relative "common"

module Market
  module Native
    module Views
      # 顶部条（原生版，纯原生控件）：品牌 / 时段 / 账户总览 / 运行控制。
      #
      # 逻辑与 props 全部沿用 app/views/header.rb 的 Header（会变的值都是根组件下发的取值
      # Proc，本面板在各自 label 的块里才调用），本类只重写 #view。
      # 原生控件没有颜色/样式位，所以：按钮的"选中态"用文案 ✓ 标记（见 Common#state_button），
      # 涨跌色只出现在自绘面板里。
      class Header < ::Market::Views::Header
        include Common

        def view
          box(direction: :column, gap: 4) do
            box(direction: :row, gap: 14) do
              label { "Citrine 行情终端" }
              label { "#{session_phase(tick.call)} #{session_time(tick.call)} · 第 #{tick.call} 档" }
              label { "总资产 #{money(equity.call)}" }
              label { "浮动盈亏 #{signed_money(pnl.call)}" }
              label { "累计收益率 #{pct(total_return.call)}" }
            end

            box(direction: :row, gap: 6) do
              state_button(on_toggle_pause) { paused.call ? "▶ 继续" : "⏸ 暂停" }
              speed_button(1)
              speed_button(2)
              speed_button(4)
              state_button(on_toggle_auto) { auto_trade.call ? "自动交易 开 ✓" : "自动交易 关" }
              state_button(on_reset) { "重置账户" }
            end

            # 快捷键说明拆三行：原生 label 不换行，单行有 ~584px 的天然宽度，
            # 会把窗口的**最小宽度**顶高（小窗口就没法用）——见 native/README.md
            label { "快捷键：空格 暂停 · 1/2/3 变速 · ↑↓ 换股" }
            label { "B/S 买卖 · Enter 下单 · Esc 清提示" }
            label { "（挂载时自动聚焦自选面板；必要时先点一下面板）" }
          end
        end

        private

        def speed_button(value)
          state_button(-> { on_speed.call(value) }) do
            "#{value}x#{!paused.call && speed.call == value ? ' ✓' : ''}"
          end
        end
      end
    end
  end
end

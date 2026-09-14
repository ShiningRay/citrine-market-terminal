# frozen_string_literal: true

require_relative "common"

module Market
  module Views
    # 账户统计 + 权益曲线（纯 div 折线）
    module Stats
      include Common

      CURVE_BARS = 48

      private

      def render_stats
        panel("panel-stats") do # 容器块：不读信号
          panel_head("账户统计") {}

          # 账本类指标（读 ledger，仅成交时变）
          box(css_class: "stat-grid") do
            kv("初始资金", money(initial_cash))
            kv("可用资金", money(account_available_cash))
            kv("冻结资金", money(account_frozen))
            kv("已实现盈亏", signed_money(account_realized), pct_style(account_realized))
            kv("累计费用", money(account_fees))
            kv("平仓 / 胜率", "#{account_closed_trades} / #{account_win_rate.nil? ? '—' : pct_abs(account_win_rate)}")
          end

          # 估值类指标（读 computed，价格驱动 → 每档重建）
          box(css_class: "stat-grid") do
            equity_value = equity
            total = total_return
            drawdown = max_drawdown
            pnl = unrealized_pnl
            kv("总资产", money(equity_value))
            kv("累计收益率", pct(total), pct_style(total))
            kv("浮动盈亏", signed_money(pnl), pct_style(pnl))
            kv("最大回撤", pct_abs(drawdown))
          end

          render_equity_curve
        end
      end

      # 权益曲线：读 curve 信号（每 CURVE_EVERY 档采样一次）
      def render_equity_curve
        box(css_class: "curve-wrap", direction: :column) do
          label(css_class: "curve-title") { "权益曲线（每 #{curve_sample_every} 档采样）" }
          box(css_class: "curve") do
            curve = account_curve
            if curve.size < 2
              label(css_class: "empty") { "采样中…" }
            else
              step = curve.size > CURVE_BARS ? Num.idiv(curve.size, CURVE_BARS) : 1
              points = []
              index = 0
              while index < curve.size
                points << curve[index]
                index += step
              end
              points << curve.last if points.last != curve.last
              lo = points.min
              hi = points.max
              range = hi - lo
              range = hi * 0.0005 if range <= 0.0001
              slot = 100.0 / points.size
              points.each_with_index do |value, i|
                ratio = (value - lo) / range * 100.0
                ratio = 0.5 if ratio < 0.5
                box(css_class: "curve-bar", style: {
                      left: "#{Num.round_to(i * slot, 2)}%",
                      width: "#{Num.round_to(slot * 0.9, 2)}%",
                      height: "#{Num.round_to(ratio, 2)}%",
                      background: value >= points.first ? "#f6465d" : "#0ecb81"
                    }) {}
              end
            end
          end
          box(css_class: "curve-legend") do
            curve = account_curve
            label(css_class: "num dim") do
              "低 #{money(curve.min)} · 高 #{money(curve.max)} · 最新 #{money(curve.last)}"
            end
          end
        end
      end
    end
  end
end

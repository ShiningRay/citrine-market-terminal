# frozen_string_literal: true

require_relative "common"

module Market
  module Views
    # 账户统计 + 权益曲线（子组件）。
    #
    # 两块数字各自的订阅落在各自的块上：账本类指标只在成交时重跑，
    # 估值类指标（computed，价格驱动）每档重跑；曲线每 CURVE_EVERY 档重跑一次。
    class Stats < Citrine::Component
      include Common

      CURVE_BARS = 48

      prop :ledger            # -> { 初始/可用/冻结/已实现/费用/平仓/胜率 }
      prop :equity            # -> { 总资产/收益率/浮盈/最大回撤 }
      prop :curve             # -> { 权益曲线采样点 }
      prop :sample_every      # 采样间隔（档），值形态：它是个常量

      def view
        panel("panel-stats") do # 容器块：不读信号
          panel_head("账户统计") {}

          # 账本类指标（读 ledger，仅成交时变）
          box(css_class: "stat-grid") do
            book = ledger.call
            kv("初始资金", money(book[:initial]))
            kv("可用资金", money(book[:available]))
            kv("冻结资金", money(book[:frozen]))
            kv("已实现盈亏", signed_money(book[:realized]), pct_style(book[:realized]))
            kv("累计费用", money(book[:fees]))
            kv("平仓 / 胜率", "#{book[:closed]} / #{book[:win_rate].nil? ? '—' : pct_abs(book[:win_rate])}")
          end

          # 估值类指标（读 computed，价格驱动 → 每档重跑）
          box(css_class: "stat-grid") do
            values = equity.call
            kv("总资产", money(values[:equity]))
            kv("累计收益率", pct(values[:total_return]), pct_style(values[:total_return]))
            kv("浮动盈亏", signed_money(values[:pnl]), pct_style(values[:pnl]))
            kv("最大回撤", pct_abs(values[:drawdown]))
          end

          render_equity_curve
        end
      end

      private

      # 权益曲线：读 curve 信号（每 sample_every 档采样一次）
      def render_equity_curve
        box(css_class: "curve-wrap", direction: :column) do
          label(css_class: "curve-title") { "权益曲线（每 #{sample_every} 档采样）" }
          box(css_class: "curve") do
            curve_points = curve.call
            if curve_points.size < 2
              label(css_class: "empty") { "采样中…" }
            else
              step = curve_points.size > CURVE_BARS ? Num.idiv(curve_points.size, CURVE_BARS) : 1
              points = []
              index = 0
              while index < curve_points.size
                points << curve_points[index]
                index += step
              end
              points << curve_points.last if points.last != curve_points.last
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
                      background: value >= points.first ? Tokens[:up] : Tokens[:down]
                    }) {}
              end
            end
          end
          box(css_class: "curve-legend") do
            points = curve.call
            label(css_class: "num dim") do
              "低 #{money(points.min)} · 高 #{money(points.max)} · 最新 #{money(points.last)}"
            end
          end
        end
      end
    end
  end
end

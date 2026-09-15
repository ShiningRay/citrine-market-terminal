# frozen_string_literal: true

require_relative "test_helper"

module Market
  module Native
    # 账户统计（area 自绘）：两块指标 + 权益曲线（polygon 面积 + polyline 折线 + 图例）。
    class StatsAreaTest < NativeScreenTest
      CURVE_BARS = Views::Stats::CURVE_BARS

      def curve = term.account_curve

      def test_metric_labels_and_values
        shown = texts(draw(:stats))
        %w[初始资金 可用资金 冻结资金 已实现盈亏 累计费用 总资产 累计收益率 浮动盈亏 最大回撤].each do |label_text|
          assert_includes shown, label_text
        end
        assert_includes shown, money(term.initial_cash)
        assert_includes shown, money(term.equity)
        assert(shown.any? { |text| text.start_with?("平仓 / 胜率") })
      end

      def test_equity_curve_drawn_as_area_and_line
        recording = draw(:stats)
        polygon = recording.calls_of(:polygon).first
        polyline = recording.calls_of(:polyline).first
        assert polygon, "权益曲线应有面积图"
        assert polyline, "权益曲线应有折线"
        assert_equal curve.size, polyline[:points].size
        assert_equal curve.size + 2, polygon[:points].size, "面积图比折线多两个收口点"
        assert_operator curve.size, :>=, 2
      end

      def test_curve_color_follows_trend_and_legend
        recording = draw(:stats)
        points = curve
        expected = points.last >= points.first ? rgb(Theme::UP) : rgb(Theme::DOWN)
        assert_equal expected, recording.calls_of(:polyline).first[:color]
        assert_includes texts(recording),
                        "低 #{money(points.min)} · 高 #{money(points.max)} · 最新 #{money(points.last)}"
      end

      def test_curve_is_sampled_down_when_long
        term.run_ticks(300)
        raw = curve.size
        assert_operator raw, :>, CURVE_BARS, "原始采样点已超过面板能画的上限"
        points = draw(:stats).calls_of(:polyline).first[:points]
        assert_operator points.size, :<, raw, "超过上限后应等间隔抽稀（与浏览器版同口径）"
        assert_operator points.size, :<=, CURVE_BARS + 4, "抽稀后的点数有界"
      end

      def test_repaint_is_queued_on_tick
        before = @backend.redraw_count(area_widget(:stats))
        term.run_ticks(1)
        assert_operator @backend.redraw_count(area_widget(:stats)), :>, before,
                        "每档响应式收敛应把面板排一次重绘（设计 2.4 的粗粒度兜底）"
      end
    end
  end
end

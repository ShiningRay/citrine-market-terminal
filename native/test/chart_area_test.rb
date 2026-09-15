# frozen_string_literal: true

require_relative "test_helper"

module Market
  module Native
    # 走势图（area 自绘）：蜡烛/分时切换、粒度切换（都走真实的模式按钮）、SMA 折线、
    # 成交量柱、最新价线，以及"每档重绘"。
    #
    # "实体 / 量柱"按**当次绘制的几何**分（geometry.vol_top 以下算量柱）：面板尺寸由布局给，
    # 带位随尺寸算，测试不能再拿面板类的常量当坐标。
    class ChartAreaTest < NativeScreenTest
      def bodies(recording)
        split = chart_geometry.vol_top
        recording.calls_of(:rect).select do |call|
          [rgb(Theme::UP), rgb(Theme::DOWN)].include?(call[:fill]) && call[:y] < split
        end
      end

      def volume_bars(recording)
        split = chart_geometry.vol_top
        recording.calls_of(:rect).select do |call|
          [rgb(Theme::UP), rgb(Theme::DOWN)].include?(call[:fill]) && call[:y] >= split
        end
      end

      def wick_lines(recording)
        recording.calls_of(:line).select { |call| [rgb(Theme::UP), rgb(Theme::DOWN)].include?(call[:color]) }
      end

      def expected_bars(mode: :candle, bucket: 3)
        Views::ChartData.bars(mode: mode, bucket: bucket, series: term.series_of(term.selected),
                              candles: engine.candles(term.selected, bucket: bucket, limit: 48))
      end

      def engine = @term.instance_variable_get(:@engine)

      def test_candle_mode_draws_wicks_bodies_and_volume
        recording = draw(:chart)
        assert_equal 40, bodies(recording).size, "桶=3 时 120 档聚合成 40 根蜡烛"
        assert_equal 40, wick_lines(recording).size, "每根蜡烛一条影线"
        assert_equal 40, volume_bars(recording).size, "每根蜡烛一根量柱"
      end

      def test_minute_mode_draws_bars_without_volume
        click_button("分时")
        recording = draw(:chart)
        list = expected_bars(mode: :minute)
        lo = list.map { |bar| bar[:low] }.min
        # 分时柱自区间下沿起画：收盘价正好等于最低价的那几根高度为 0，Painter 会跳过
        assert_equal 60, list.size, "分时取逐档价最近 60 点"
        assert_equal list.count { |bar| bar[:low] > lo }, bodies(recording).size
        assert_empty volume_bars(recording), "分时没有成交量，不应画量柱"
        assert_empty wick_lines(recording), "分时柱没有影线"
      end

      def test_bucket_buttons_change_bar_count
        click_button("细")
        assert_equal 48, bodies(draw(:chart)).size
        click_button("粗")
        assert_equal 15, bodies(draw(:chart)).size
      end

      def test_sma_polyline_uses_same_samples_as_data
        polyline = draw(:chart).calls_of(:polyline).first
        assert polyline, "应画 SMA 折线"
        assert_equal rgb(Theme::SMA), polyline[:color]
        expected = expected_bars.count { |bar| !bar[:sma20].nil? }
        assert_equal expected, polyline[:points].size
        assert_operator polyline[:points].size, :>=, 2
      end

      def test_axis_labels_and_last_price_line
        recording = draw(:chart)
        list = expected_bars
        hi = list.map { |bar| bar[:high] }.max
        lo = list.map { |bar| bar[:low] }.min
        assert_includes texts(recording), money(hi)
        assert_includes texts(recording), money(lo)
        assert_includes texts(recording), money((hi + lo) / 2.0)

        last_line = recording.calls_of(:line).find { |call| call[:color] == rgb(Theme::LAST_LINE) }
        assert last_line, "应画最新价线"
        assert_operator last_line[:y1], :>=, chart_geometry.plot_top
        assert_operator last_line[:y1], :<=, chart_geometry.plot_bottom
      end

      # 面板尺寸由布局给：图元的带位必须跟着面板走，不能越出面板（成交量柱下沿曾被切 18px）
      def test_geometry_follows_panel_size
        recording = draw(:chart, width: 360, height: 300)
        geometry = chart_geometry
        assert_equal 360, geometry.width
        assert_equal 300, geometry.height
        assert_equal 360 - geometry.axis_w, geometry.plot_right
        assert_operator geometry.vol_bottom, :<=, 300, "成交量带必须在面板内（含下沿）"
        assert_operator geometry.plot_bottom, :<, geometry.vol_top, "主图与成交量带不重叠"
        assert_operator geometry.plot_h, :>=, Views::Chart::MIN_PLOT_H

        (volume_bars(recording) + bodies(recording)).each do |call|
          assert_operator call[:x] + call[:w], :<=, 360, "图元不应越出面板右缘：#{call.inspect}"
          assert_operator call[:y] + call[:h], :<=, 300, "图元不应越出面板下缘：#{call.inspect}"
        end
        assert_includes texts(recording), money(expected_bars.map { |bar| bar[:high] }.max),
                        "换尺寸后价格轴照画"
      end

      # 面板变窄时右侧价格轴按比例收（不然主图区被挤没）
      def test_axis_narrows_with_panel
        draw(:chart, width: 200, height: 232)
        assert_operator chart_geometry.axis_w, :<, Views::Chart::AXIS_W
        assert_operator chart_geometry.plot_h, :>=, Views::Chart::MIN_PLOT_H
      end

      def test_redraws_with_new_ticks
        before = bodies(draw(:chart)).map { |call| [call[:x], call[:y], call[:fill]] }
        term.run_ticks(3)
        after = bodies(draw(:chart)).map { |call| [call[:x], call[:y], call[:fill]] }
        refute_equal before, after, "新档位应重绘出不同的图形"
      end

      # 引擎预热后序列非空，这条走的是"空数据"的兜底分支：单独挂一个最小组件
      def test_empty_series_shows_hint
        backend = Citrine::Native::Widgets::Memory.new
        renderer = Citrine::Native::Renderer.new(widgets: backend)
        component = EmptySeriesChart.new(quote_for: ->(code) { term.quote_of(code) },
                                         indicators_for: ->(code) { term.indicator_snapshot(code) })
        root = renderer.mount_component(component, { title: "empty" })
        recording = backend.fire_draw(backend.find_all(root.dom, kind: :area).first)
        assert_includes recording.calls_of(:text).map { |call| call[:text] }, "等待行情数据…"
        assert_empty recording.calls_of(:rect).select { |call| [rgb(Theme::UP), rgb(Theme::DOWN)].include?(call[:fill]) }
      ensure
        Citrine.unmount(component) if root
      end

      class EmptySeriesChart < Citrine::Component
        prop :quote_for
        prop :indicators_for

        def view
          render(Market::Native::Views::Chart,
                 selected: -> { "600519" },
                 quote_for: quote_for,
                 series_for: ->(_code) { [] },
                 candles_for: ->(_code, _bucket) { [] },
                 indicators_for: indicators_for)
        end
      end
    end
  end
end

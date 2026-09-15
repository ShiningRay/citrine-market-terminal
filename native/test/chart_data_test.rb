# frozen_string_literal: true

require_relative "test_helper"

module Market
  module Native
    # 图表数据准备（纯函数）：蜡烛/分时的 bar 序列、SMA20 取样点，
    # 以及**与浏览器版 app/views/chart.rb#build_bars 的逐项一致性**——这份逻辑是复制的，
    # 分叉只能靠这条测试挡住（浏览器版的方法是私有方法，测试里 send 直接调）。
    class ChartDataTest < NativeUnitTest
      CODE = "600519"
      BAR_COUNTS = { 1 => 48, 3 => 40, 8 => 15 }.freeze

      def series = term.series_of(CODE)

      def candles(bucket) = engine.candles(CODE, bucket: bucket, limit: 48)

      def bars(mode: :candle, bucket: 3)
        Views::ChartData.bars(mode: mode, bucket: bucket, series: series, candles: candles(bucket))
      end

      def test_candle_bar_count_per_bucket
        assert_equal 120, series.size, "引擎预热 120 档"
        BAR_COUNTS.each { |bucket, expected| assert_equal expected, bars(bucket: bucket).size }
      end

      def test_candle_ohlc_comes_from_the_same_slices_as_engine
        first = bars(bucket: 3).first
        slice = series[0, 3]
        assert_equal slice.first, first[:open]
        assert_equal slice.max, first[:high]
        assert_equal slice.min, first[:low]
        assert_equal slice.last, first[:close]
        assert_equal candles(3).first[:volume], first[:volume]
      end

      def test_sma20_only_where_enough_history
        list = bars(bucket: 3)
        list.each_with_index do |bar, index|
          position = index * 3 + 2
          if position < 19
            assert_nil bar[:sma20], "第 #{index} 根（位置 #{position}）历史不足，不应有 SMA20"
          else
            assert_in_delta Indicators.sma(series[0, position + 1], 20), bar[:sma20], 1e-9
          end
        end
        assert_equal 6, list.index { |bar| !bar[:sma20].nil? }
      end

      def test_minute_mode_uses_tick_prices_without_volume
        list = bars(mode: :minute)
        assert_equal 60, list.size
        list.each_with_index do |bar, index|
          value = series[series.size - 60 + index]
          assert_equal [value, value, value, value], [bar[:open], bar[:high], bar[:low], bar[:close]]
          assert_equal 0.0, bar[:volume]
          refute_nil bar[:sma20], "分时模式每个点都有 20 档历史"
        end
      end

      def test_matches_browser_build_bars
        browser = ::Market::Views::Chart.new(
          candles_for: ->(code, bucket) { engine.candles(code, bucket: bucket, limit: 48) }
        )
        %i[candle minute].each do |mode|
          assert_equal browser.send(:build_bars, CODE, series, mode, 3), bars(mode: mode, bucket: 3),
                       "#{mode} 模式的 bar 序列应与浏览器版逐项一致（同一份引擎读数）"
        end
      end
    end
  end
end

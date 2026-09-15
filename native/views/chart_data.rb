# frozen_string_literal: true

require "indicators"

module Market
  module Native
    module Views
      # 图表数据准备：把"绘图要的那串 bar"从引擎读数里整理出来，纯函数、可单测。
      #
      # 与 app/views/chart.rb#build_bars **同一口径**（bar 形状、SMA20 取样点、分时用逐档价）：
      # 原生图与浏览器图必须画出同样的东西，否则两个渲染目标会悄悄分叉。
      #
      # 为什么是复制而不是复用：那段逻辑是浏览器 Chart 组件的私有方法，只服务于它的
      # div 渲染路径；要真正共用得把它提到 app/ 内的共享模块，那会动到浏览器路径
      # （本任务边界外）。差异由 native/test/chart_data_test.rb 锁定：同一份输入下
      # 蜡烛根数、SMA20 取样点、分时 bar 数都与浏览器版一致。
      module ChartData
        module_function

        # mode: :candle（candles 给 OHLC）/ :minute（逐档价当收盘价）
        # → [{ open:, high:, low:, close:, volume:, sma20: }, …]
        def bars(mode:, bucket:, series:, candles:)
          raw =
            if mode == :candle
              candles
            else
              series.last(60).map { |value| { open: value, high: value, low: value, close: value, volume: 0.0 } }
            end
          step = mode == :candle ? bucket : 1
          start = series.size - raw.size * step
          raw.each_with_index.map do |bar, index|
            position = start + index * step + step - 1
            sma = position >= 19 ? Indicators.sma(series[0, position + 1], 20) : nil
            bar.merge(sma20: sma)
          end
        end
      end
    end
  end
end

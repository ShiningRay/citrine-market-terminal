# frozen_string_literal: true

require_relative "common"

module Market
  module Views
    # 图表面板：纯 div 绘制的蜡烛图 / 分时图 + 均线点 + 成交量柱。
    #
    # 为什么用 div 而不是 Canvas：CanvasRenderer 会独占一整块 canvas 元素，
    # 无法嵌进 DOM 布局里的一个小面板（渲染器之间不能混合，见 FRICTION.md 的 F8）。
    module ChartPanel
      include Common

      PLOT_HEIGHT = 190
      VOLUME_HEIGHT = 46

      private

      def render_chart
        panel("panel-chart") do # 容器块：不读信号
          panel_head("行情走势") do # 工具区块：读 chart_mode / chart_bucket
            chip("蜡烛", chart_mode == :candle, -> { set_chart_mode(:candle) })
            chip("分时", chart_mode == :minute, -> { set_chart_mode(:minute) })
            chip("细", chart_bucket == 1, -> { set_chart_bucket(1) })
            chip("中", chart_bucket == 3, -> { set_chart_bucket(3) })
            chip("粗", chart_bucket == 8, -> { set_chart_bucket(8) })
          end

          # 标的名 + 大字报价：颜色随涨跌变 → 外层块读，内层静态
          box(css_class: "chart-head") do
            quote = quote_of(selected)
            style = pct_style(quote[:change])
            label(css_class: "chart-name") { "#{quote[:name]} · #{quote[:code]} · #{quote[:sector]}" }
            label(css_class: "chart-last num", style: style) { money(quote[:last]) }
            label(css_class: "chart-delta num", style: style) do
              "#{direction_arrow(quote[:direction])} #{signed_money(quote[:change])}  #{pct(quote[:change_pct])}"
            end
            label(css_class: "chart-flag") { chart_flag(quote) }
          end

          render_chart_canvas
          render_chart_quote_stats
          render_chart_tech_stats
        end
      end

      def chart_flag(quote)
        return "涨停" if quote[:limit_up_hit]
        return "跌停" if quote[:limit_down_hit]

        quote[:direction] == :up ? "上行" : (quote[:direction] == :down ? "下行" : "持平")
      end

      # 绘图区：读 selected / chart_mode / chart_bucket / series → 每 chart_every 档重建一次
      def render_chart_canvas
        box(css_class: "chart-canvas", direction: :column, gap: 6) do
          code = selected
          mode = chart_mode
          series = series_of(code)
          bucket = chart_bucket

          if series.empty?
            label(css_class: "chart-empty") { "等待行情数据…" }
          else
            bars = build_bars(code, series, mode, bucket)
            highs = bars.map { |b| b[:high] }
            lows = bars.map { |b| b[:low] }
            hi = highs.max
            lo = lows.min
            range = hi - lo
            range = hi * 0.002 if range <= 0.0001
            slot = 100.0 / bars.size
            max_volume = bars.map { |b| b[:volume] }.max

            box(css_class: "plot") do # 内层全部用局部变量，不读信号
              label(css_class: "axis-label axis-hi num") { money(hi) }
              label(css_class: "axis-label axis-mid num") { money((hi + lo) / 2.0) }
              label(css_class: "axis-label axis-lo num") { money(lo) }

              bars.each_with_index do |bar, i|
                left = i * slot
                up = bar[:close] >= bar[:open]
                color = up ? Format::UP_COLOR : Format::DOWN_COLOR
                if mode == :candle
                  box(css_class: "wick", style: {
                        left: "#{Num.round2(left + slot * 0.48)}%",
                        width: "1px",
                        bottom: chart_pct(bar[:low], lo, range).to_s,
                        height: chart_pct(bar[:high] - bar[:low], 0.0, range).to_s,
                        background: color
                      }) {}
                  body_lo = bar[:open] < bar[:close] ? bar[:open] : bar[:close]
                  body_hi = bar[:open] < bar[:close] ? bar[:close] : bar[:open]
                  box(css_class: "candle", style: {
                        left: "#{Num.round2(left + slot * 0.18)}%",
                        width: "#{Num.round2(slot * 0.64)}%",
                        bottom: chart_pct(body_lo, lo, range).to_s,
                        height: chart_pct(body_hi - body_lo, 0.0, range).to_s,
                        background: color
                      }) {}
                else
                  box(css_class: "minute-bar", style: {
                        left: "#{Num.round2(left + slot * 0.25)}%",
                        width: "#{Num.round2(slot * 0.5)}%",
                        bottom: chart_pct(bar[:close], lo, range).to_s,
                        height: chart_pct(bar[:close] - lo, 0.0, range).to_s,
                        background: color
                      }) {}
                end
              end

              # SMA20 均线点
              sma_dots = bars.map { |b| b[:sma20] }.compact
              unless sma_dots.empty?
                bars.each_with_index do |bar, i|
                  next if bar[:sma20].nil?

                  box(css_class: "sma-dot", style: {
                        left: "#{Num.round2(i * slot + slot * 0.5 - 0.4)}%",
                        bottom: chart_pct(bar[:sma20], lo, range).to_s,
                        width: "4px", height: "4px"
                      }) {}
                end
              end

              # 最新价虚线
              box(css_class: "last-line", style: { bottom: chart_pct(bars.last[:close], lo, range).to_s }) {}
            end

            # 成交量柱（与主图同一档位口径）
            box(css_class: "vol-plot") do
              bars.each_with_index do |bar, i|
                next if max_volume.nil? || max_volume <= 0

                height = max_volume.zero? ? 0.0 : (bar[:volume] / max_volume) * 100.0
                box(css_class: "vol-bar", style: {
                      left: "#{Num.round2(i * slot + slot * 0.18)}%",
                      width: "#{Num.round2(slot * 0.64)}%",
                      height: "#{Num.round2(height)}%",
                      background: bar[:close] >= bar[:open] ? Format::UP_COLOR : Format::DOWN_COLOR
                    }) {}
              end
            end
          end
        end
      end

      # 行情快照数字：读 quote（每 tick 变）→ 纯文本单元
      def render_chart_quote_stats
        box(css_class: "stat-strip") do
          quote = quote_of(selected)
          kv("今开", money(quote[:open]))
          kv("最高", money(quote[:high]))
          kv("最低", money(quote[:low]))
          kv("昨收", money(quote[:prev_close]))
          kv("振幅", pct_abs(quote[:amplitude]))
          kv("成交量", volume(quote[:volume]))
          kv("成交额", amount(quote[:amount]))
          kv("涨停", money(quote[:limit_up]))
          kv("跌停", money(quote[:limit_down]))
        end
      end

      # 技术指标：读序列（每 chart_every 档变）→ 纯文本单元
      def render_chart_tech_stats
        box(css_class: "stat-strip") do
          indicator = indicator_snapshot(selected)
          kv("SMA5", money(indicator[:sma5]), { color: "#f59e0b" })
          kv("SMA20", money(indicator[:sma20]), { color: "#38bdf8" })
          kv("RSI14", money(indicator[:rsi], 1))
          kv("逐档波动", pct_abs(indicator[:volatility]))
          label(css_class: "verdict") { "形态：#{indicator[:verdict]}" }
        end
      end

      # 蜡烛/分时数据准备：统一成 open/high/low/close/volume/sma20 的 bar 列表
      def build_bars(code, series, mode, bucket)
        raw =
          if mode == :candle
            @engine.candles(code, bucket: bucket, limit: 48)
          else
            series.last(60).map { |value| { open: value, high: value, low: value, close: value, volume: 0.0 } }
          end
        # 为每根 bar 计算 SMA20（按该 bar 覆盖到的最后一个价位）
        step = mode == :candle ? bucket : 1
        start = series.size - raw.size * step
        raw.each_with_index.map do |bar, i|
          index = start + i * step + step - 1
          sma = index >= 19 ? Market::Indicators.sma(series[0, index + 1], 20) : nil
          bar.merge(sma20: sma)
        end
      end

      def chart_pct(value, lo, range)
        ratio = range <= 0 ? 0.0 : (value - lo) / range * 100.0
        ratio = 0.0 if ratio < 0
        ratio = 100.0 if ratio > 100
        "#{Num.round2(ratio)}%"
      end
    end
  end
end

# frozen_string_literal: true

require_relative "common"

module Market
  module Views
    # 图表面板（子组件）：纯 div 绘制的蜡烛图 / 分时图 + 均线点 + 成交量柱。
    #
    # 为什么用 div 而不是 Canvas：CanvasRenderer 会独占一整块 canvas 元素，
    # 无法嵌进 DOM 布局里的一个小面板（渲染器之间不能混合，见 FRICTION.md 的 F8）。
    #
    # 取样粒度（mode / bucket）是**本面板自己的 state**：它只影响这张图，与账户、
    # 自选、下单无关，没必要挂在根组件上（F5 落地前只能全挂在 Terminal 上）。
    class Chart < Citrine::Component
      include Common

      PLOT_HEIGHT = 190
      VOLUME_HEIGHT = 46

      prop :selected        # -> { selected }                      当前标的
      prop :quote_for       # ->(code) { quote_of(code) }
      prop :series_for      # ->(code) { series_of(code) }          逐档价序列
      prop :candles_for     # ->(code, bucket) { 聚合后的蜡烛 }
      prop :indicators_for  # ->(code) { indicator_snapshot(code) }

      state :mode, default: :candle
      state :bucket, default: 3

      def view
        panel("panel-chart") do # 容器块：不读信号
          panel_head("行情走势") do # 工具区块：读本面板的 mode / bucket
            chip("蜡烛", mode == :candle, -> { self.mode = :candle })
            chip("分时", mode == :minute, -> { self.mode = :minute })
            chip("细", bucket == 1, -> { self.bucket = 1 })
            chip("中", bucket == 3, -> { self.bucket = 3 })
            chip("粗", bucket == 8, -> { self.bucket = 8 })
          end

          # 标的名 + 大字报价：颜色随涨跌变 → 本块读 quote，内层静态
          box(css_class: "chart-head") do
            quote = quote_for.call(selected.call)
            style = pct_style(quote[:change])
            label(css_class: "chart-name") { "#{quote[:name]} · #{quote[:code]} · #{quote[:sector]}" }
            label(css_class: "chart-last num", style: style) { money(quote[:last]) }
            label(css_class: "chart-delta num", style: style) do
              "#{direction_arrow(quote[:direction])} #{signed_money(quote[:change])}  #{pct(quote[:change_pct])}"
            end
            label(css_class: "chart-flag") { chart_flag(quote) }
          end

          render_canvas
          render_quote_stats
          render_tech_stats
        end
      end

      # 换股时把取样粒度复位（根组件在切换标的时调用：子组件自己拥有 bucket，
      # 只有它知道"复位"意味着什么；框架暂无可从父组件直接改子 state 的原语，见 FRICTION）
      def reset_bucket
        self.bucket = 3
        self
      end

      private

      def chart_flag(quote)
        return "涨停" if quote[:limit_up_hit]
        return "跌停" if quote[:limit_down_hit]

        quote[:direction] == :up ? "上行" : (quote[:direction] == :down ? "下行" : "持平")
      end

      # 绘图区：读 selected / mode / bucket / series → 换股或每 chart_every 档重跑一次
      def render_canvas
        box(css_class: "chart-canvas", direction: :column, gap: 6) do
          code = selected.call
          current_mode = mode
          series = series_for.call(code)
          current_bucket = bucket

          if series.empty?
            label(css_class: "chart-empty") { "等待行情数据…" }
          else
            bars = build_bars(code, series, current_mode, current_bucket)
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
                if current_mode == :candle
                  box(css_class: "wick", style: {
                        left: "#{Num.round_to(left + slot * 0.48, 2)}%",
                        width: "1px",
                        bottom: chart_pct(bar[:low], lo, range).to_s,
                        height: chart_pct(bar[:high] - bar[:low], 0.0, range).to_s,
                        background: color
                      }) {}
                  body_lo = bar[:open] < bar[:close] ? bar[:open] : bar[:close]
                  body_hi = bar[:open] < bar[:close] ? bar[:close] : bar[:open]
                  box(css_class: "candle", style: {
                        left: "#{Num.round_to(left + slot * 0.18, 2)}%",
                        width: "#{Num.round_to(slot * 0.64, 2)}%",
                        bottom: chart_pct(body_lo, lo, range).to_s,
                        height: chart_pct(body_hi - body_lo, 0.0, range).to_s,
                        background: color
                      }) {}
                else
                  box(css_class: "minute-bar", style: {
                        left: "#{Num.round_to(left + slot * 0.25, 2)}%",
                        width: "#{Num.round_to(slot * 0.5, 2)}%",
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
                        left: "#{Num.round_to(i * slot + slot * 0.5 - 0.4, 2)}%",
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
                      left: "#{Num.round_to(i * slot + slot * 0.18, 2)}%",
                      width: "#{Num.round_to(slot * 0.64, 2)}%",
                      height: "#{Num.round_to(height, 2)}%",
                      background: bar[:close] >= bar[:open] ? Format::UP_COLOR : Format::DOWN_COLOR
                    }) {}
              end
              # 分时模式的 volume 全为 0 → 一根柱子都不画：显式返回 nil，别让 each 的数组
              # 变成块的结果（F16 会按 to_s 渲染整串成交量数据）
              nil
            end
          end
        end
      end

      # 行情快照数字：读 quote（每档变）→ 纯文本单元
      def render_quote_stats
        box(css_class: "stat-strip") do
          quote = quote_for.call(selected.call)
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
      def render_tech_stats
        box(css_class: "stat-strip") do
          indicator = indicators_for.call(selected.call)
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
            candles_for.call(code, bucket)
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
        "#{Num.round_to(ratio, 2)}%"
      end
    end
  end
end

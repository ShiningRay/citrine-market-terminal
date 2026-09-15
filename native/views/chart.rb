# frozen_string_literal: true

require_relative "common"
require_relative "chart_data"

module Market
  module Native
    module Views
      # 行情走势面板（原生版）：蜡烛 / 分时 + SMA20 + 成交量。
      #
      # 逻辑与 props 全部沿用 app/views/chart.rb 的 Chart（mode / bucket 仍是**面板自己的
      # state**，reset_bucket 也照旧由根组件在换股时调用）；本类只重写 #view：
      #   · 骨架（模式/粒度按钮、报价与技术指标文字）用原生控件；
      #   · 图形（蜡烛/分时 + SMA 折线 + 成交量柱 + 坐标网格）用 area 自绘。
      # 浏览器版用 div 拼图是因为渲染器不能混用（FRICTION F8），原生侧没有这个限制。
      #
      # 图形几何按面板实际尺寸算（Geometry）：主图在上、成交量带在下、右侧价格轴宽度自适应
      # ——原实现把 500×232 写死，窗口一小就被裁掉一条（成交量柱下沿曾被切 18px）。
      class Chart < ::Market::Views::Chart
        include Common

        PAD_L = 6                      # 左侧留白
        AXIS_W = 62                    # 右侧价格轴标签区（面板窄时按比例缩）
        HEAD_BAND = 38                 # 顶部报价文字带（quote_head 两行画在这里）
        STATS_BAND = 88                # 底部行情/指标文字带（quote_stats 3 行 + tech_stats 2 行）
        PLOT_TOP = HEAD_BAND + 4       # 主图上沿（顶部文字带之下）
        VOL_GAP = 18                   # 主图与成交量带之间
        VOL_H = 44                     # 成交量带的目标高度
        VOL_MIN_H = 16
        BOTTOM = 8                     # 成交量带下方（底部文字带之上）的留白
        MIN_PLOT_H = 24                # 主图再矮就不画了
        TEXT_LINE = 15                 # size 12 文字的行距（顶部/底部带按它排）

        # 面板尺寸 → 各图元的带位（绘制与"柱高/视口"断言都从这里取）
        Geometry = Struct.new(:width, :height, :axis_w, :plot_right, :plot_top, :plot_bottom,
                              :vol_top, :vol_h, :slot, :bars, keyword_init: true) do
          def plot_h = plot_bottom - plot_top
          def vol_bottom = vol_top + vol_h
        end

        def view
          # 三段行情文字（quote_head / quote_stats / tech_stats）**画在 area 里**而不是
          # 原生 label：它们合计 ~119px 的自然高度会把走势图挤扁（Windows 上原生控件
          # 更高，2026-09-15 实测持 3 只时走势图只剩 71px、画不出蜡烛）。Painter.text
          # 自带面板裁剪，"原生 label 不换行会顶高中列最小宽度"的拆行约束也随之消失。
          panel_frame("行情走势") do
            box(direction: :row, gap: 6) do
              state_button(-> { self.mode = :candle }) { mode == :candle ? "蜡烛 ✓" : "蜡烛" }
              state_button(-> { self.mode = :minute }) { mode == :minute ? "分时 ✓" : "分时" }
              state_button(-> { self.bucket = 1 }) { bucket == 1 ? "细 ✓" : "细" }
              state_button(-> { self.bucket = 3 }) { bucket == 3 ? "中 ✓" : "中" }
              state_button(-> { self.bucket = 8 }) { bucket == 8 ? "粗 ✓" : "粗" }
            end
            paint_panel(:chart,
                        watch: -> { draw_dependencies },
                        on_draw: ->(painter) { draw(painter) })
          end
        end

        # ── area 绘制 ─────────────────────────────────────────────

        # 最近一帧的几何（带位/槽宽由面板尺寸算出；测试也用它分类"实体"与"量柱"）
        attr_reader :geometry

        def draw(painter)
          painter.rect(0, 0, painter.width, painter.height, fill: Theme::PANEL, stroke: Theme::LINE)
          draw_quote_text(painter)
          series = series_for.call(selected.call)
          if series.empty?
            @geometry = nil
            cell_text(painter, "等待行情数据…", x: 12, y: PLOT_TOP, w: [painter.width - 24, 200].min, h: 20,
                      color: Theme::DIM)
            return
          end

          bars = ChartData.bars(mode: mode, bucket: bucket, series: series,
                                candles: candles_for.call(selected.call, bucket))
          geometry = geometry_for(painter, bars)
          @geometry = geometry
          return if geometry.plot_h < MIN_PLOT_H || geometry.slot <= 0

          hi = bars.map { |bar| bar[:high] }.max
          lo = bars.map { |bar| bar[:low] }.min
          draw_grid(painter, geometry, hi, lo)
          bars.each_with_index do |bar, index|
            x = PAD_L + index * geometry.slot
            if mode == :candle
              draw_candle(painter, geometry, bar, x, lo, hi)
            else
              draw_minute_bar(painter, geometry, bar, x, lo, hi)
            end
          end
          draw_sma(painter, geometry, bars, lo, hi)
          draw_volume(painter, geometry, bars)
          draw_last_line(painter, geometry, bars.last[:close], lo, hi)
        end

        # watch: 绘制依赖（换股 / 换模式粒度 / 每档行情与指标——顶部/底部文字带都画在这里）
        def draw_dependencies
          code = selected.call
          series_for.call(code)
          quote_for.call(code)
          indicators_for.call(code)
          mode
          bucket
          nil
        end

        private

        # 面板顶部/底部的行情文字带（原先是三个原生 label，现画进面板：
        # 原生 label 的自然高度会把走势图挤扁，且不换行的长行会顶高最小宽度）
        def draw_quote_text(painter)
          head_lines = quote_head.split("\n")
          head_lines.each_with_index do |line, index|
            painter.text(line, x: 12, y: 6 + index * TEXT_LINE, color: Theme::TEXT, size: Theme::SIZE_BASE)
          end
          stats_lines = quote_stats.split("\n") + tech_stats.split("\n")
          band_top = painter.height - STATS_BAND
          stats_lines.each_with_index do |line, index|
            painter.text(line, x: 12, y: band_top + 4 + index * TEXT_LINE, color: Theme::DIM,
                               size: Theme::SIZE_BASE)
          end
        end

        # 面板尺寸 → 带位：右侧轴最多占 25% 宽，成交量带最多吃 22% 高。
        # 高度不够时主图优先（成交量带会被画到面板下沿之外，由视图自己的裁剪兜底）。
        def geometry_for(painter, bars)
          width = painter.width
          height = painter.height
          axis_w = [AXIS_W, (width * 0.25).round].min
          plot_right = [width - axis_w, PAD_L + 1].max
          vol_h = [[VOL_H, (height * 0.22).round].min, VOL_MIN_H].max
          vol_bottom = height - BOTTOM - STATS_BAND
          plot_bottom = vol_bottom - vol_h - VOL_GAP
          if plot_bottom - PLOT_TOP < MIN_PLOT_H
            plot_bottom = PLOT_TOP + MIN_PLOT_H
            vol_bottom = plot_bottom + VOL_GAP + vol_h
          end
          Geometry.new(width: width, height: height, axis_w: axis_w, plot_right: plot_right,
                       plot_top: PLOT_TOP, plot_bottom: plot_bottom, vol_top: vol_bottom - vol_h,
                       vol_h: vol_h, slot: (plot_right - PAD_L) / bars.size.to_f, bars: bars)
        end

        # 图表头：标的名 + 报价（浏览器版是 .chart-head 那几行）。
        # 两行文字画在面板顶部带（HEAD_BAND）里——原先用原生 label，其自然高度会把
        # 走势图挤扁（Windows 实测只剩 71px），且不换行的长行会顶高中列最小宽度。
        def quote_head
          quote = quote_for.call(selected.call)
          "#{quote[:name]} · #{quote[:code]} · #{quote[:sector]}\n" \
            "#{money(quote[:last])} #{direction_arrow(quote[:direction])} " \
            "#{signed_money(quote[:change])} #{pct(quote[:change_pct])} #{chart_flag(quote)}"
        end

        # 行情快照（读 quote，每档变）。三行画在面板底部带（STATS_BAND）里
        def quote_stats
          quote = quote_for.call(selected.call)
          "今开 #{money(quote[:open])} · 最高 #{money(quote[:high])} · 最低 #{money(quote[:low])}\n" \
            "昨收 #{money(quote[:prev_close])} · 振幅 #{pct_abs(quote[:amplitude])}\n" \
            "量 #{volume(quote[:volume])} · 额 #{amount(quote[:amount])} · " \
            "涨停 #{money(quote[:limit_up])} / 跌停 #{money(quote[:limit_down])}"
        end

        # 技术指标（读序列，每档变）；两行画在底部带（与 quote_stats 合计 5 行）
        def tech_stats
          indicator = indicators_for.call(selected.call)
          ind = indicator
          "SMA5 #{money(ind[:sma5])} · SMA20 #{money(ind[:sma20])} · RSI14 #{money(ind[:rsi], 1)}\n" \
            "逐档波动 #{pct_abs(ind[:volatility])} · 形态：#{ind[:verdict]}"
        end

        # 网格 + 右侧价格轴（高/中/低）
        def draw_grid(painter, geometry, hi, lo)
          [hi, (hi + lo) / 2.0, lo].each_with_index do |value, index|
            y = geometry.plot_top + index * (geometry.plot_h / 2.0)
            painter.line(PAD_L, y, geometry.plot_right, y, color: Theme::GRID, width: 1)
            cell_text(painter, money(value), x: geometry.plot_right + 4, y: y - 8,
                      w: [geometry.axis_w - 10, 10].max, h: 16,
                      color: Theme::DIM, size: Theme::SIZE_SMALL, align: :right)
          end
          painter.line(PAD_L, geometry.vol_bottom, geometry.plot_right, geometry.vol_bottom,
                       color: Theme::LINE, width: 1)
        end

        # 蜡烛：影线（line）+ 实体（rect，涨跌着色）
        def draw_candle(painter, geometry, bar, x, lo, hi)
          color = bar[:close] >= bar[:open] ? Theme::UP : Theme::DOWN
          center = x + geometry.slot * 0.5
          painter.line(center, plot_y(bar[:high], lo, hi, geometry.plot_top, geometry.plot_bottom),
                       center, plot_y(bar[:low], lo, hi, geometry.plot_top, geometry.plot_bottom),
                       color: color, width: 1)
          body_lo = bar[:open] < bar[:close] ? bar[:open] : bar[:close]
          body_hi = bar[:open] < bar[:close] ? bar[:close] : bar[:open]
          top = plot_y(body_hi, lo, hi, geometry.plot_top, geometry.plot_bottom)
          bottom = plot_y(body_lo, lo, hi, geometry.plot_top, geometry.plot_bottom)
          height = bottom - top
          height = 1.0 if height < 1.0
          painter.rect(x + geometry.slot * 0.18, top, geometry.slot * 0.64, height, fill: color)
        end

        # 分时：一根收盘价柱（自下沿起）
        def draw_minute_bar(painter, geometry, bar, x, lo, hi)
          color = bar[:close] >= bar[:open] ? Theme::UP : Theme::DOWN
          top = plot_y(bar[:close], lo, hi, geometry.plot_top, geometry.plot_bottom)
          painter.rect(x + geometry.slot * 0.25, top, geometry.slot * 0.5, geometry.plot_bottom - top,
                       fill: color)
        end

        # SMA20 均线（浏览器版是一串 .sma-dot，这里画折线）
        def draw_sma(painter, geometry, bars, lo, hi)
          points = []
          bars.each_with_index do |bar, index|
            next if bar[:sma20].nil?

            points << [PAD_L + index * geometry.slot + geometry.slot * 0.5,
                       plot_y(bar[:sma20], lo, hi, geometry.plot_top, geometry.plot_bottom)]
          end
          painter.polyline(points, color: Theme::SMA, width: 1) if points.size >= 2
        end

        # 成交量柱（与主图同一档位口径；分时模式量全 0 → 一根都不画）
        def draw_volume(painter, geometry, bars)
          max_volume = bars.map { |bar| bar[:volume] }.max
          return if max_volume.nil? || max_volume <= 0

          bars.each_with_index do |bar, index|
            height = bar[:volume] / max_volume * geometry.vol_h
            painter.rect(PAD_L + index * geometry.slot + geometry.slot * 0.18,
                         geometry.vol_bottom - height, geometry.slot * 0.64, height,
                         fill: bar[:close] >= bar[:open] ? Theme::UP : Theme::DOWN)
          end
        end

        # 最新价线（.last-line 的虚线在 Painter 里没有虚线笔，画实线）
        def draw_last_line(painter, geometry, close, lo, hi)
          y = plot_y(close, lo, hi, geometry.plot_top, geometry.plot_bottom)
          painter.line(PAD_L, y, geometry.plot_right, y, color: Theme::LAST_LINE, width: 1)
        end
      end
    end
  end
end

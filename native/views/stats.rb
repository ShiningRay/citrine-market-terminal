# frozen_string_literal: true

require_relative "common"

module Market
  module Native
    module Views
      # 账户统计面板（原生版）：两块指标 + 权益曲线。
      #
      # 逻辑与 props 全部沿用 app/views/stats.rb 的 Stats（账本类指标读 ledger、估值类读
      # computed、曲线读曲线信号），本类只重写 #view：整块交给 area 自绘——
      # 原生 label 没有颜色/对齐，"标签在左、数字右对齐"的账面对不了。
      #
      # 几何全部从 Painter 的尺寸推（见 common.rb 顶部）：左右两栏各占一半宽度、
      # 曲线占下半部分——所以"总资产/累计收益率/浮动盈亏/最大回撤"不会再跑到视口外。
      class Stats < ::Market::Views::Stats
        include Common

        PAD = 8
        ROW_H = 18
        CURVE_BARS = 48      # 与浏览器版同口径（最多画 48 个采样点）
        METRIC_ROWS = 6      # 左栏行数（右栏 4 行：总资产/累计收益率/浮动盈亏/最大回撤）
        CURVE_GAP = 20       # 指标区与曲线之间（给"权益曲线（每 N 档采样）"那行小字）
        LEGEND_H = 18        # 曲线下方的低/高/最新图例
        MIN_CURVE_H = 24     # 再矮就不画曲线了（面板高度是布局给的，可能很小）

        def view
          panel_frame("账户统计") do
            paint_panel(:stats,
                        watch: -> { draw_dependencies },
                        on_draw: ->(painter) { draw(painter) })
          end
        end

        # ── area 绘制 ─────────────────────────────────────────────

        def draw(painter)
          painter.rect(0, 0, painter.width, painter.height, fill: Theme::PANEL, stroke: Theme::LINE)
          col_w = [(painter.width - PAD * 3) / 2.0, 1.0].max
          curve_top = PAD + METRIC_ROWS * ROW_H + CURVE_GAP
          curve_bottom = painter.height - PAD - LEGEND_H
          draw_metrics(painter, col_w)
          draw_curve(painter, curve_top, curve_bottom) if curve_bottom - curve_top >= MIN_CURVE_H
        end

        def draw_dependencies
          ledger.call
          equity.call
          curve.call
          nil
        end

        private

        # 账本类（读 ledger，仅成交时变）+ 估值类（读 computed，每档变）
        def draw_metrics(painter, col_w)
          book = ledger.call
          values = equity.call
          left = [
            ["初始资金", money(book[:initial]), nil],
            ["可用资金", money(book[:available]), nil],
            ["冻结资金", money(book[:frozen]), nil],
            ["已实现盈亏", signed_money(book[:realized]), value_color(book[:realized])],
            ["累计费用", money(book[:fees]), nil],
            ["平仓 / 胜率", "#{book[:closed]} / #{book[:win_rate].nil? ? '—' : pct_abs(book[:win_rate])}", nil]
          ]
          right = [
            ["总资产", money(values[:equity]), nil],
            ["累计收益率", pct(values[:total_return]), value_color(values[:total_return])],
            ["浮动盈亏", signed_money(values[:pnl]), value_color(values[:pnl])],
            ["最大回撤", pct_abs(values[:drawdown]), Theme::WARN]
          ]
          left.each_with_index { |cell, index| draw_kv(painter, PAD, PAD + index * ROW_H, col_w, cell) }
          right.each_with_index do |cell, index|
            draw_kv(painter, PAD * 2 + col_w, PAD + index * ROW_H, col_w, cell)
          end
        end

        # 一格 kv：标签左、数值右（同一栏宽内对齐，栏宽随面板宽度走）
        def draw_kv(painter, x, y, col_w, cell)
          cell_text(painter, cell[0], x: x, y: y, w: col_w, h: ROW_H, color: Theme::DIM, size: Theme::SIZE_SMALL)
          cell_text(painter, cell[1], x: x, y: y, w: col_w, h: ROW_H, color: cell[2] || Theme::TEXT,
                    size: Theme::SIZE_BASE, align: :right)
        end

        # 权益曲线：面积（polygon）+ 折线（polyline）+ 低/高/最新图例。
        # 浏览器版画的是 48 根柱（.curve-bar），原生侧换成面积图——同样的采样口径。
        def draw_curve(painter, top, bottom)
          width = painter.width - PAD * 2
          cell_text(painter, "权益曲线（每 #{sample_every} 档采样）",
                    x: PAD, y: top - 18, w: painter.width - PAD * 2, h: 16,
                    color: Theme::DIM, size: Theme::SIZE_SMALL)
          painter.rect(PAD, top, width, bottom - top, fill: Theme::PANEL_2)
          points = sampled_curve
          if points.size < 2
            cell_text(painter, "采样中…", x: PAD + 4, y: top, w: [width - 8, 120].min, h: bottom - top,
                      color: Theme::DIM, size: Theme::SIZE_SMALL)
            return
          end

          lo = points.min
          hi = points.max
          span = hi - lo
          span = hi.abs * 0.0005 + 0.01 if span <= 0.0001
          lo -= span * 0.05
          hi += span * 0.05
          step = (width - 2) / (points.size - 1).to_f
          coords = points.each_with_index.map do |value, index|
            [PAD + 1 + index * step, plot_y(value, lo, hi, top + 3, bottom - 3)]
          end
          rising = points.last >= points.first
          painter.polygon(coords + [[coords.last[0], bottom], [coords.first[0], bottom]],
                          fill: rising ? "#f6465d33" : "#0ecb8133")
          painter.polyline(coords, color: rising ? Theme::UP : Theme::DOWN, width: 1)
          cell_text(painter, "低 #{money(points.min)} · 高 #{money(points.max)} · 最新 #{money(points.last)}",
                    x: PAD, y: bottom + 2, w: width, h: 16,
                    color: Theme::DIM, size: Theme::SIZE_SMALL)
        end

        # 采样：超过 CURVE_BARS 就等间隔抽稀，末尾必须保留（与浏览器版逐点一致）
        def sampled_curve
          values = curve.call
          return values if values.size <= CURVE_BARS

          step = Num.idiv(values.size, CURVE_BARS)
          points = []
          index = 0
          while index < values.size
            points << values[index]
            index += step
          end
          points << values.last if points.last != values.last
          points
        end
      end
    end
  end
end

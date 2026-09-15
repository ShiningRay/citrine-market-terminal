# frozen_string_literal: true

require_relative "common"

module Market
  module Native
    module Views
      # 成交记录 / 挂单面板（原生版）。
      #
      # 逻辑与 props 全部沿用 app/views/logs.rb 的 Logs（标签页是本面板自己的 state，
      # 撤单动作经 on_cancel 交回根组件），本类只重写 #view：
      #   · 标签页按钮用原生控件；
      #   · 两张表（成交 / 挂单）用 area 自绘 —— 挂单表的「操作」列是**行内可点**的单元格，
      #     命中测试与绘制共用同一份几何（**当次绘制的 Layout**，列宽随面板宽度走），
      #     列下标由常量给出，不靠文案比对。
      class Logs < ::Market::Views::Logs
        include Common

        ROW_H = 22
        HEADER_H = 24
        CANCEL_COLUMN = 6 # 挂单表的「操作」列（行内撤单）

        # 列 = [权重, 对齐, 表头, 排序键]（权重取自原来那组像素列宽；实际列宽按比例分配）
        TRADE_GRID = Grid.new(
          [
            [38, :left,  "档位", nil],
            [68, :left,  "标的", nil],
            [40, :left,  "方向", nil],
            [68, :right, "成交价", nil],
            [58, :right, "数量", nil],
            [58, :right, "费用", nil],
            [82, :right, "已实现盈亏", nil]
          ],
          row_height: ROW_H, header_height: HEADER_H
        )

        ORDER_GRID = Grid.new(
          [
            [38, :left,  "档位", nil],
            [68, :left,  "标的", nil],
            [40, :left,  "方向", nil],
            [68, :right, "限价", nil],
            [58, :right, "数量", nil],
            [78, :right, "冻结资金", nil],
            [62, :left,  "操作", nil]
          ],
          row_height: ROW_H, header_height: HEADER_H
        )

        def view
          panel_frame("成交与挂单") do
            box(direction: :row, gap: 6) do
              state_button(-> { self.tab = :trades }) { tab == :trades ? "成交记录 ✓" : "成交记录" }
              state_button(-> { self.tab = :orders }) { tab == :orders ? "挂单 ✓" : "挂单" }
            end
            paint_panel(:logs,
                        watch: -> { draw_dependencies },
                        on_draw: ->(painter) { draw(painter) },
                        on_click: ->(event) { handle_click(event) })
          end
        end

        # ── area 绘制 ─────────────────────────────────────────────

        # 最近一帧的几何（绘制写它、命中测试读它；两个标签页共用一条字段，切换时会重画）
        attr_reader :layout

        def draw(painter)
          grid = tab == :orders ? ORDER_GRID : TRADE_GRID
          @layout = grid.layout(painter.width, painter.height)
          painter.rect(0, 0, painter.width, painter.height, fill: Theme::PANEL, stroke: Theme::LINE)
          tab == :orders ? draw_orders(painter) : draw_trades(painter)
        end

        # 行内撤单：只有挂单表的「操作」列接点击，其余位置不响应
        def handle_click(event)
          return self unless event.type == "click" && tab == :orders && layout
          return self unless layout.column_at(event.x) == CANCEL_COLUMN

          index = layout.row_at(event.y)
          order = index && orders.call[index]
          on_cancel.call(order.id) if order
          self
        end

        def draw_dependencies
          tab
          trades.call
          orders.call
          nil
        end

        private

        def draw_trades(painter)
          draw_header(painter)
          list = trades.call
          if list.empty?
            draw_empty(painter, "还没有成交记录 · 下单后在这里出现")
            return
          end

          list.first(layout.rows_in).each_with_index do |trade, index|
            top = layout.row_top(index)
            realized_color = trade.side == :sell ? value_color(trade.realized) : Theme::DIM
            draw_cells(painter, layout, [
                         [trade.tick.to_s, Theme::DIM],
                         [trade.code, Theme::TEXT],
                         [side_label(trade.side), trade.side == :buy ? Theme::UP : Theme::DOWN],
                         [money(trade.price), Theme::TEXT],
                         [qty(trade.quantity), Theme::TEXT],
                         [money(trade.fee + trade.tax), Theme::DIM],
                         [trade.side == :sell ? signed_money(trade.realized) : "—", realized_color]
                       ], top, size: Theme::SIZE_SMALL)
            draw_row_line(painter, top)
          end
        end

        def draw_orders(painter)
          draw_header(painter)
          list = orders.call
          if list.empty?
            draw_empty(painter, "无挂单 · 限价单会在这里排队等待成交")
            return
          end

          list.first(layout.rows_in).each_with_index do |order, index|
            top = layout.row_top(index)
            draw_cells(painter, layout, [
                         [order.placed_tick.to_s, Theme::DIM],
                         [order.code, Theme::TEXT],
                         [side_label(order.side), order.side == :buy ? Theme::UP : Theme::DOWN],
                         [money(order.limit), Theme::TEXT],
                         [qty(order.quantity), Theme::TEXT],
                         [money(order.frozen), Theme::DIM],
                         ["撤单", Theme::ACCENT]
                       ], top, size: Theme::SIZE_SMALL)
            draw_row_line(painter, top)
          end
        end

        def draw_header(painter)
          layout.columns.each_with_index do |column, index|
            cell_text(painter, column[2], x: layout.content_x(index), y: 0,
                      w: layout.content_width(index), h: layout.header_height,
                      color: Theme::DIM, size: Theme::SIZE_SMALL,
                      weight: :bold, align: layout.align_of(index))
          end
          painter.line(0, layout.header_height - 1, painter.width, layout.header_height - 1,
                       color: Theme::LINE, width: 1)
        end

        def draw_row_line(painter, top)
          painter.line(layout.pad, top + layout.row_height - 1, painter.width - layout.pad,
                       top + layout.row_height - 1, color: Theme::GRID, width: 1)
        end

        def draw_empty(painter, text)
          cell_text(painter, text, x: 8, y: HEADER_H, w: painter.width - 16, h: 20, color: Theme::DIM)
        end
      end
    end
  end
end

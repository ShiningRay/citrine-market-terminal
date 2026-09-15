# frozen_string_literal: true

require_relative "common"

module Market
  module Native
    module Views
      # 自选行情面板（原生版）。
      #
      # 逻辑与 props 全部沿用 app/views/watchlist.rb 的 Watchlist（行情/选中/持仓都是根组件
      # 通过取值 Proc 下发的），本类只重写 #view，并把行情表整块交给 area 自绘：
      #   · 骨架（面板标题、排序按钮）用原生控件；
      #   · 表格（10 行行情：代码/名称/最新/涨跌/涨跌幅/量额，涨跌红绿）用 Painter 画；
      #   · 点击命中测试与绘制共用同一份几何 —— **当次绘制的 Layout**（列宽由面板实际宽度
      #     算出）既是画表的依据，也是 #handle_click 的依据。面板宽度不是常量，是布局给的。
      class Watchlist < ::Market::Views::Watchlist
        include Common

        # 列 = [权重, 对齐, 表头, 排序键]（排序键与 Terminal#apply_sort 认的键一致）。
        # 权重取自原来那组像素列宽（比例不变）；实际列宽 = 权重 / 权重和 × 面板宽。
        #
        # 这组权重是 MARKET-1d 按**最小窗口（1160 → 面板 368）下的真实文字宽度**重排的
        # （实测过程与结论见 native/README.md「最小宽度下的可读性」）：
        #   · 两个量额列各 +~11px：成交量/成交额在 1160 下原本只剩 55px，而 "2,388.3 万"
        #     要 58.8px → 10 行里 7 行的**单位被截掉**（丢单位 = 差 4 个数量级）；
        #   · 权重和仍是 458（natural_width 不变：466）——"自然宽度下不截断"那条测试的口径不变；
        #   · 数值列不能瘦：最新价 "1,373.62" 要 47.8px，加上 Grid::NUM_GAP 的呼吸位后，
        #     1160 下每列内容宽都还剩 1~4px 余量（逐格真窗口量过，见 README）。
        GRID = Grid.new(
          [
            [123, :left,  "标的",   :code],
            [70,  :right, "最新",   nil],
            [67,  :right, "涨跌",   nil],
            [68,  :right, "涨跌幅", :change],
            [65,  :right, "成交量", nil],
            [65,  :right, "成交额", :amount]
          ],
          row_height: 22, header_height: 26
        )

        # 「持」徽标与名称之间的最小间隙（徽标让位：名称的可写宽度里扣掉徽标宽 + 这个值）
        BADGE_GAP = 4

        def view
          panel_frame("自选行情") do
            box(direction: :row, gap: 6) do
              sort_button("代码", :code)
              sort_button("涨跌幅", :change)
              sort_button("成交额", :amount)
            end
            paint_panel(:watchlist, # 聚焦用（window_key 由聚焦的 area 转发，见 design 2.3）+ 测试取句柄
                        watch: -> { draw_dependencies },
                        on_draw: ->(painter) { draw(painter) },
                        on_click: ->(event) { handle_click(event) })
          end
        end

        # ── area 绘制（设计文档 2.2 的 Painter）────────────────────

        # 最近一帧的几何（绘制写它、命中测试读它：面板宽度变了，两边一起变）
        attr_reader :layout

        def draw(painter)
          @layout = GRID.layout(painter.width, painter.height)
          draw_header(painter)
          codes.call.each_with_index do |code, index|
            break if index >= layout.rows_in

            draw_row(painter, code, index)
          end
        end

        # 命中测试与绘制同一套几何：表头 → 排序，行 → 切标的。
        # （面板是矩形的，应用自己知道布局，见设计文档 2.3；不依赖任何控件级命中。）
        # 还没画过就没有几何可命中——真窗口里"点得到"必然意味着已经画过一帧。
        def handle_click(event)
          return self unless event.type == "click" && layout

          if layout.header?(event.y)
            column = layout.column_at(event.x)
            key = column && layout.sort_key_of(column)
            on_sort.call(key) if key
          else
            index = layout.row_at(event.y)
            code = index && codes.call[index]
            on_pick.call(code) if code
          end
          self
        end

        # watch: 声明的绘制依赖（渲染器把它跑在 area 节点的 Effect 里 → 变化即标脏重绘）
        def draw_dependencies
          sort_key.call
          codes.call.each do |code|
            quote_for.call(code)
            active_for.call(code)
            held_for.call(code)
          end
          nil
        end

        private

        def sort_button(text, key)
          state_button(-> { on_sort.call(key) }) { sort_key.call == key ? "#{text} ✓" : text }
        end

        def draw_header(painter)
          active = sort_key.call
          layout.columns.each_with_index do |column, index|
            on = column[3] == active
            cell_text(painter, on ? "#{column[2]} #{sort_mark(active)}" : column[2],
                      x: layout.content_x(index), y: 0, w: layout.content_width(index),
                      h: layout.header_height,
                      color: on ? Theme::ACCENT : Theme::DIM, size: Theme::SIZE_SMALL, weight: :bold,
                      align: layout.align_of(index))
          end
          painter.line(0, layout.header_height - 1, painter.width, layout.header_height - 1,
                       color: Theme::LINE, width: 1)
        end

        def draw_row(painter, code, index)
          top = layout.row_top(index)
          quote = quote_for.call(code)
          color = value_color(quote[:change])
          if active_for.call(code)
            painter.rect(layout.pad, top, painter.width - layout.pad * 2, layout.row_height,
                         fill: Theme::PANEL_2)
          end
          held = held_for.call(code)
          draw_cells(painter, layout, [
                       ["#{code} #{name_for.call(code)}", Theme::TEXT],
                       [money(quote[:last]), color],
                       [signed_money(quote[:change]), color],
                       [pct(quote[:change_pct]), color],
                       [volume_cell(quote[:volume]), Theme::DIM],
                       [amount_cell(quote[:amount]), Theme::DIM]
                     ], top, reserve: held ? { 0 => badge_width(painter) + BADGE_GAP } : nil)
          draw_held_badge(painter, top) if held
          painter.line(layout.pad, top + layout.row_height - 1, painter.width - layout.pad,
                       top + layout.row_height - 1, color: Theme::GRID, width: 1)
        end

        # 持仓标记（浏览器版是 .badge-hold 的「持」），画在标的列右端。
        # 名称那一格在 draw_row 里按 badge_width + BADGE_GAP 让位（否则两者会重叠，
        # 真窗口实测 5.3px：OCR 读成 "600519 贵州.持1,392.08"）。
        def draw_held_badge(painter, top)
          cell_text(painter, "持", x: layout.content_x(0), y: top, w: layout.content_width(0),
                    h: layout.row_height, color: Theme::ACCENT, size: Theme::SIZE_SMALL, align: :right)
        end

        def badge_width(painter)
          painter.measure_text("持", size: Theme::SIZE_SMALL, weight: :normal)[0]
        end

        # 量额单元格：原生表比浏览器表窄得多（最小窗口下成交量列只有 ~50px），
        # **单位不能丢**——"2,388.3 万" 被截成 "2,388.3…" 就是差 4 个数量级（真窗口实测
        # 10 行里 7 行丢了单位）。所以在**这一张表里**把 Format 的写法收紧两处：
        #   · 去掉数字与 万/亿 之间的空格（-3.5px）
        #   · 万位以上不留小数（"2,388.3 万" → "2,388万"，再省 ~10px；小数在自选表里是噪声）
        # 量级与单位都还在，读法不变（"2,388万" = 2,388 万）。格式化仍是 Format 的，
        # 只有这两处收紧；图表/下单面板的 label 不窄，照旧用 volume/amount 的完整写法。
        def compact_unit(text)
          text.sub(" ", "").sub(/(\d{1,3}(?:,\d{3})+)\.\d+(?=万)/) { Regexp.last_match(1) }
        end

        def volume_cell(value) = compact_unit(volume(value))
        def amount_cell(value) = compact_unit(amount(value))

        # 排序方向标记：apply_sort 里涨跌幅/成交额是降序、代码是升序
        def sort_mark(key)
          key == :code ? "▲" : "▼"
        end
      end
    end
  end
end

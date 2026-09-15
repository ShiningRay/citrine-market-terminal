# frozen_string_literal: true

require_relative "test_helper"

module Market
  module Native
    # 自选行情面板（area 自绘）：表头、10 行行情、涨跌色、选中行、持仓标记、排序标记，
    # 以及"点行切标的 / 点表头排序"的真实派发路径（Memory 桩后端合成指针事件）。
    #
    # 几何一律取**当次绘制的 Layout**（列宽由面板宽度算出）：面板尺寸由布局给，测试不能再
    # 拿面板类的像素常量当坐标——那正是"左列塌陷"的成因（MARKET-2 §4）。
    class WatchlistAreaTest < NativeScreenTest
      GRID = Views::Watchlist::GRID
      NATURAL_WIDTH = GRID.natural_width # 6 列各按原比例刚好装下的面板宽（= 466）

      def test_panel_takes_its_size_from_the_layout
        assert_nil @backend.area_size(area_widget(:watchlist)),
                   "自绘面板不应声明固定尺寸：size: 只设滚动内容尺寸、不参与布局，声明了就会与" \
                   "真实可见区脱钩（自选表 6 列只看得见 2 列的成因）"
        refute @backend.scrolling?(area_widget(:watchlist)),
               "面板铺满自己的格子（scroll: false + flex_grow），不靠滚动条看数据"
      end

      def test_columns_share_the_panel_width
        draw(:watchlist)
        layout = watchlist_layout
        assert_in_delta NATURAL_WIDTH, layout.width, 0.001
        assert_in_delta layout.width, layout.x(5) + layout.width_of(5) + layout.pad, 0.001,
                        "末列右缘应贴住面板右缘（列宽按权重分完整个宽度）"
        weights = GRID.columns.map { |column| column[0] }
        weights.each_with_index do |weight, index|
          ratio = weight.to_f / weights.sum
          assert_in_delta ratio, layout.width_of(index) / (layout.width - layout.pad * 2), 0.001
        end
      end

      def test_columns_follow_a_narrower_panel
        draw(:watchlist, width: 300, height: 252)
        narrow = watchlist_layout
        assert_in_delta 300, narrow.width, 0.001
        assert_operator narrow.width_of(0), :<, GRID.layout(NATURAL_WIDTH).width_of(0),
                        "面板变窄时列宽跟着变，而不是把内容画到看不见的地方"

        shown = texts(area_painting)
        assert(shown.any? { |text| text.start_with?("标的") })
        assert(shown.any? { |text| text.start_with?("成交额") }, "最后一列的表头仍应画出来")
        area_painting.calls_of(:text).each do |call|
          assert_operator call[:x], :<, 300, "文字不应画到面板右缘之外：#{call.inspect}"
        end
      end

      def test_every_column_is_fully_visible_at_the_natural_width
        shown = texts(draw(:watchlist))
        GRID.columns.each do |column|
          assert(shown.any? { |text| text.start_with?(column[2]) },
                 "#{column[2]} 应整列可见（不截断）：#{shown.inspect}")
        end
        assert_empty shown.grep(/…/), "自然宽度下不该有截断：#{shown.inspect}"
      end

      def test_header_labels_drawn
        shown = texts(draw(:watchlist))
        GRID.columns.each do |column|
          assert(shown.any? { |text| text.start_with?(column[2]) }, "表头应有 #{column[2]}：#{shown.inspect}")
        end
      end

      def test_all_rows_drawn_in_row_order
        draw(:watchlist)
        recording = area_painting
        layout = watchlist_layout
        term.row_order.each_with_index do |code, index|
          row = texts_between(recording, layout.row_top(index), layout.row_top(index) + layout.row_height)
          assert(row.any? { |text| text.start_with?(code) }, "第 #{index} 行应画 #{code}：#{row.inspect}")
        end
      end

      def test_change_cells_use_up_down_colors
        draw(:watchlist)
        recording = area_painting
        layout = watchlist_layout
        term.row_order.each_with_index do |code, index|
          colors = text_ops_between(recording, layout.row_top(index), layout.row_top(index) + layout.row_height)
                   .map { |call| call[:color] }
          expected = rgb(value_color(term.quote_of(code)[:change]))
          assert_equal 3, colors.count(expected), "#{code} 的最新/涨跌/涨跌幅三格应为涨跌色"
        end
      end

      def test_selected_row_highlight_follows_selection
        draw(:watchlist)
        layout = watchlist_layout
        index = term.row_order.index(term.selected)
        highlighted = area_painting.calls_of(:rect).find { |call| call[:fill] == rgb(Theme::PANEL_2) }
        assert highlighted, "选中行应有底色"
        assert_equal layout.row_top(index), highlighted[:y]
        assert_equal layout.width - layout.pad * 2, highlighted[:w]

        other = term.row_order[(index + 1) % term.row_order.size]
        click(:watchlist, layout.x(1) + 4, layout.row_top(term.row_order.index(other)) + 4)
        assert_equal other, term.selected
        draw(:watchlist)
        moved = area_painting.calls_of(:rect).find { |call| call[:fill] == rgb(Theme::PANEL_2) }
        assert_equal layout.row_top(term.row_order.index(other)), moved[:y]
      end

      def test_held_badge_appears_only_for_held_codes
        term.submit_order(:buy, :market, "100", "")
        draw(:watchlist)
        layout = watchlist_layout
        recording = area_painting
        held_index = term.row_order.index(term.selected)
        assert_includes texts_between(recording, layout.row_top(held_index),
                                      layout.row_top(held_index) + layout.row_height), "持"

        free_code = term.row_order.find { |code| term.position_of(code).nil? }
        free_index = term.row_order.index(free_code)
        refute_includes texts_between(recording, layout.row_top(free_index),
                                      layout.row_top(free_index) + layout.row_height), "持"
      end

      def test_sort_marker_follows_sort_key
        assert_includes texts(draw(:watchlist)), "标的 ▲"

        click_button("涨跌幅")
        assert_equal :change, term.sort_key
        shown = texts(draw(:watchlist))
        assert_includes shown, "涨跌幅 ▼"
        refute_includes shown, "标的 ▲"
      end

      def test_click_row_selects_symbol
        draw(:watchlist)
        target = term.row_order[2]
        click(:watchlist, watchlist_layout.x(1) + 4, watchlist_layout.row_top(2) + 4)
        assert_equal target, term.selected
      end

      def test_click_sort_header_sorts
        draw(:watchlist)
        codes = term.row_order.dup
        click(:watchlist, watchlist_layout.x(3) + 4, 6)
        assert_equal :change, term.sort_key
        assert_equal codes.max_by { |code| term.quote_of(code)[:change_pct] }, term.row_order.first
      end

      def test_click_non_sortable_header_keeps_order
        draw(:watchlist)
        before = term.row_order.dup
        click(:watchlist, watchlist_layout.x(1) + 4, 6)
        assert_equal :code, term.sort_key
        assert_equal before, term.row_order
      end

      def test_click_blank_area_is_ignored
        draw(:watchlist)
        layout = watchlist_layout
        selected = term.selected
        click(:watchlist, layout.x(0) + 4, layout.row_top(layout.rows_in) + 2)
        assert_equal selected, term.selected
      end

      def test_click_before_the_first_draw_is_ignored
        selected = term.selected
        click(:watchlist, 20, 40) # 还没画过 → 没有几何可命中
        assert_equal selected, term.selected
      end

      # ── MARKET-1d 的可读性收口（真窗口在最小窗口下量出来的两条）──────

      # 量额列不丢单位：最小窗口下成交量列只剩 ~50px，Format 的 "2,388.3 万"（58.8px）会被
      # 截成 "2,388.3…"——单位没了就是差 4 个数量级。所以原生这张表把写法收紧（见 Watchlist
      # 的 compact_unit）：去空格 + 万位以上不留小数（"2,388.3 万" → "2,388万"）。
      def test_volume_and_amount_cells_keep_their_unit
        watch = term.panels[:watchlist]
        assert_equal "2,388万", watch.send(:compact_unit, "2,388.3 万")
        assert_equal "9,999万", watch.send(:compact_unit, "9,999.9 万")
        assert_equal "21.19亿", watch.send(:compact_unit, "21.19 亿")
        assert_equal "154.3万", watch.send(:compact_unit, "154.3 万"),
                     "四位以下保留小数（1,000万 以内的精度还在手上）"
        assert_equal "1.00亿", watch.send(:compact_unit, "1.00 亿")

        # 逐行核对（最小窗口的面板宽 368 = 声明下限 1160 下每列 ~368）：每行的量额格都带单位
        draw(:watchlist, width: 368, height: 215)
        narrow = watchlist_layout
        term.row_order.first(narrow.rows_in).each_with_index do |code, index|
          quote = term.quote_of(code)
          next if quote[:volume] < 10_000 # 不足万就是纯数字（没有单位可丢）

          cells = texts_between(area_painting, narrow.row_top(index),
                                narrow.row_top(index) + narrow.row_height)
          assert(cells.any? { |text| text.end_with?("万") || text.end_with?("亿") },
                 "第 #{index} 行（#{code}）的量额格应带 万/亿 单位，不该被截断：#{cells.inspect}")
        end
      end

      # 徽标让位：名称被截断时不能压到「持」上（真窗口实测重叠 5.3px，
      # 像素 OCR 读成 "600519 贵州.持1,392.08"）。名称格的可写宽度里扣掉徽标宽 + BADGE_GAP。
      def test_held_badge_reserves_room_in_the_name_cell
        term.submit_order(:buy, :market, "100", "")
        draw(:watchlist, width: 368, height: 215)
        layout = watchlist_layout
        index = term.row_order.index(term.selected)
        top = layout.row_top(index)
        cells = text_ops_between(area_painting, top, top + layout.row_height)
        name = cells.find { |call| call[:text].start_with?(term.selected) }
        badge = cells.find { |call| call[:text] == "持" }
        assert name && badge, "持仓行应有名称与「持」徽标：#{cells.map { |call| call[:text] }.inspect}"
        width = painter_stub.measure_text(name[:text], size: name[:size], weight: name[:weight])[0]
        assert_operator name[:x] + width, :<=, badge[:x],
                        "名称（#{name[:text]}）的右缘 #{name[:x] + width} 不该压到「持」徽标（x=#{badge[:x]}）"
      end

      # 右对齐数值列之间的呼吸位（Grid::NUM_GAP）：真窗口实测相邻数值格只隔 0.4~2.3px，
      # 像素 OCR 把它们读成一串（"+0.22%1,605.3." —— 见 native/README.md）。
      #
      # 两条互补的断言：
      #   ① **最坏情况的间隙**（左格填满自己的内容框、右格也填满）= NUM_GAP，因为它俩的右缘
      #      都贴列缘、右格的左缘从 content_x 起 → 与具体数值无关的硬保证；
      #   ② **最小窗口下装得下最宽的真实值**：常数是真窗口量出来的文字宽度（同一份 README），
      #      权重调瘦或 NUM_GAP 调大都会让某个真实值被截断（丢单位/表头被切）。
      REAL_TEXT_WIDTHS = [
        [1, "1,373.62", 47.75],  # 最新价：四位数 + 两位小数（茅台那档）
        [2, "+150.00", 45.84],   # 涨跌：随机游走能走到的最大变化
        [3, "涨跌幅 ▼", 48.34],  # 涨跌幅：带排序标记的表头（这一列最宽的一格）
        [4, "9,999万", 46.61],   # 成交量：万位上限（再大就进「亿」档，反而更窄）
        [5, "9,999万", 46.61]    # 成交额：同上
      ].freeze

      def test_adjacent_numeric_columns_cannot_touch
        grid = Views::Watchlist::GRID.layout(368) # 368 = 声明下限窗口 1160 下的面板宽
        (1..5).each_cons(2) do |left, right|
          worst = grid.content_x(right) - (grid.content_x(left) + grid.content_width(left))
          assert_operator worst, :>=, 4,
                          "「#{grid.columns[left][2]}」与「#{grid.columns[right][2]}」在最坏情况下" \
                          "（两格都填满）仍应留 ≥4px 间隙，实际 #{worst.round(2)}px"
        end
      end

      def test_numeric_columns_fit_the_widest_real_cell_at_the_minimum_window
        grid = Views::Watchlist::GRID.layout(368)
        REAL_TEXT_WIDTHS.each do |index, text, width|
          assert_operator grid.content_width(index), :>=, width,
                          "最小窗口下「#{grid.columns[index][2]}」列的内容宽 " \
                          "#{grid.content_width(index).round(2)}px 要装得下 #{text.inspect}（#{width}px）" \
                          "——否则真窗口里它会被截断（数值丢单位/表头被切）"
        end
      end

      private

      # 与桩后端同一个度量的 painter（Recording 的 measure_text 与绘制走同一份估算）
      def painter_stub = @painter_stub ||= Citrine::Native::Painter::Recording.new(width: 368, height: 215)

      # 最近一次绘制的记录（draw 会把它存进桩后端）
      def area_painting = @backend.painting(area_widget(:watchlist))
      def watchlist_layout = layout(:watchlist)
    end
  end
end

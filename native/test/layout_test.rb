# frozen_string_literal: true

require_relative "test_helper"

module Market
  module Native
    # 布局契约（MARKET-1c 的修复面）：**拉伸式布局**是这套原生视图的骨架，
    # 这几条测试锁的就是"改回固定尺寸/漏掉 flex_grow 就会塌"的那些点：
    #
    #   · 三列各 flex_grow: 1（libui 的 stretchy 孩子均分剩余宽度）——不给就只有第一列
    #     能拿到天然宽度（真窗口实测左列 207px，自选表 6 列只看得见 2 列）
    #   · 含自绘 area 的面板必须 stretchy（否则拿不到 Draw）；纯原生控件面板**不能**
    #     stretchy（libui 的 box 最小高度 = stretchy 孩子数 × 最大天然高度，会让窗口缩不小）
    #   · 面板不声明固定尺寸（size: 只设滚动内容尺寸、不参与布局）
    #   · 任何一个 box 都不能是空的（空容器会吸走整列的剩余空间：实测下单面板里的空容器
    #     212 高、下面的成交/挂单表被挤成 0 高）
    class LayoutTest < NativeScreenTest
      # 窗口留白 + 两条列间距（与 native/app.rb 的根 box / 三列 row 一致）
      CHROME = 40 + 10 * 2
      # 三列里最宽的一行原生控件：下单面板的"输入框 + 100/500/1000/全部"（真窗口实测 327.5px）
      WIDEST_CONTROL_ROW = 327.5

      def root_box = @root.dom.children.first
      def rows = root_box.children
      def columns = rows[1].children # [0] 顶部条 [1] 三列 [2] 埋点条

      def stretchy?(widget) = widget.instance_variable_get(:@stretchy) == true

      def test_the_three_columns_stretch
        assert_equal 3, columns.size, "主区应是三列（自选+统计 / 走势+持仓 / 下单+成交）"
        columns.each_with_index do |column, index|
          assert stretchy?(column), "第 #{index + 1} 列必须 flex_grow: 1 —— libui 只把剩余宽度分给 " \
                                    "stretchy 的孩子（不给就退回内容天然宽度，左列会塌成 207px）"
        end
      end

      def test_area_panels_stretch_and_control_panels_do_not
        expected = { watchlist: true, stats: true, chart: true, logs: true, ticket: false, positions: false }
        panels = { watchlist: columns[0].children[0], stats: columns[0].children[1],
                   chart: columns[1].children[0], positions: columns[1].children[1],
                   ticket: columns[2].children[0], logs: columns[2].children[1] }
        expected.each do |name, stretch|
          assert_equal stretch, stretchy?(panels[name]),
                       "#{name} 面板的 flex_grow 应为 #{stretch}（含 area 的要吃空间；" \
                       "纯原生控件的面板不吃，否则窗口最小高度按最高面板翻倍）"
        end
      end

      def test_no_empty_container_anywhere
        empties = []
        walk = lambda do |widget, path|
          empties << path if widget.kind == :box && widget.children.empty?
          widget.children.each_with_index { |child, index| walk.call(child, "#{path}/#{index}:#{child.kind}") }
        end
        walk.call(root_box, "root")
        assert_empty empties,
                     "空 box 会吸走所在列的剩余空间（libui 实测：下单面板里的空容器长到 212px，" \
                     "把下面的成交/挂单表挤成 0 高）——条件内容要保证容器里始终有东西：#{empties.inspect}"
      end

      def test_area_panels_do_not_declare_fixed_sizes
        %i[watchlist stats chart logs].each do |name|
          widget = area_widget(name)
          assert_nil @backend.area_size(widget),
                     "#{name} 面板不应声明 size:（滚动面板的 size: 只是滚动内容尺寸，不参与布局）"
          refute @backend.scrolling?(widget), "#{name} 面板应铺满自己的格子，而不是靠滚动条"
          assert stretchy?(widget), "#{name} 的 area 自己也要 flex_grow，否则拿不到 Draw"
        end
      end

      def test_minimum_window_keeps_every_column_usable
        min_width, min_height = WindowSize::MIN_CONTENT
        usable = 3 * WIDEST_CONTROL_ROW + CHROME
        assert_operator min_width, :>=, usable,
                        "最小窗口宽度要放得下三列里最宽的原生控件行（下单面板 #{WIDEST_CONTROL_ROW}px）"
        assert_operator min_height, :>=, 600, "最小窗口高度要能让四个面板都留出可读高度"
      end

      # ── 走势图的高度预算（MARKET-1d 的 P1）────────────────────────
      # 中列 = [走势图（stretchy）+ 持仓（固定几行原生控件）]。libui 先把天然高度给非 stretchy
      # 的孩子，剩下的才给 stretchy 的——所以**持仓面板的天然高度一旦跟着持仓数增长，走势图
      # 就会被吃光**：真窗口实测（默认窗口 1440×860，修复前）持 0/1/2/3/4/5/6 只时走势图高
      # 340/300/236/172/108/44/**0**，6 只起 0×0、一个图元都不画（探针 /tmp/m1d/probe_rows.rb）。
      # 修法是让持仓列表有界（每页 PAGE_SIZE 行 + 翻页，见 views/positions.rb），下面两条把
      # "预算"钉住：谁把 PAGE_SIZE 或面板 chrome 加上去，这里先红。
      #
      # 常数都是真窗口实测值（与 README 的尺寸表同源，探针 /tmp/m1d/probe_tree.rb）：
      #   · 中列在默认窗口 1440×860 分到 620px 高（扣掉顶部条 / 埋点条 / 间距 / 窗口留白）
      #   · 走势图面板自己的固定部分（标题 / 五档按钮行 / 四行报价与指标）= 192px
      #   · 持仓面板的固定部分（标题行含翻页 + 一键清仓与汇总行）= 64px
      #   · 一行持仓 = 64px（56px 的三行 label + 按钮行，加上 8px 行距）
      # 拟合校验（真窗口）：持 1 只 → 620-8-192-(64+64) = 292（实测 292）；
      # 持 3 只 → 620-8-192-(64+192) = 164（实测 164）。
      COLUMN_BUDGET = 620
      CHART_CHROME = 192
      POSITIONS_CHROME = 64
      POSITION_ROW = 64

      # 真窗口实测：持 10 只（目录里全部标的）时走势图仍有 164px；这条把预算钉住——
      # 谁取消持仓分页（行数重新随持仓增长）或给中列加 chrome，这里就先红。
      def test_chart_keeps_usable_height_with_many_holdings
        term.row_order.each do |code|
          term.select_symbol(code)
          term.submit_order(:buy, :market, "100", "")
        end
        assert_equal 10, term.account_positions.size, "应当持有全部 10 只（少于 10 只说明现金不够）"

        rendered = widgets(:button).count { |widget| widget.text == "平仓" }
        assert_equal Views::Positions::PAGE_SIZE, rendered,
                     "持仓面板一页只画 #{Views::Positions::PAGE_SIZE} 行（真渲染的行数，不是公式）：" \
                     "去掉分页的话 10 只全画出来 → 下面的高度预算会变成负数"

        height = POSITIONS_CHROME + rendered * POSITION_ROW
        margin = COLUMN_BUDGET - CHART_CHROME - height - 8 # 8 = 中列两个面板之间的间距
        assert_operator margin, :>=, 150,
                        "默认窗口下持仓装满一页时走势图剩余高度应 ≥150px（模型给出 #{margin}）：" \
                        "真窗口实测 164px（持 3 / 10 / 12 / 20 只都是 164，因为有界）"
      end

      # 桩后端/非 macOS 上如实返回 false（不假装设上了）；真窗口里由 WindowSize 实测（见 README）
      def test_window_minimum_reports_failure_instead_of_raising
        assert_includes [true, false], WindowSize.available?
        refute WindowSize.enforce(nil), "拿不到窗口时应返回 false"
        refute WindowSize.enforce(area_widget(:watchlist)), "句柄不是窗口时应返回 false"
      end
    end
  end
end

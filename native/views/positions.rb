# frozen_string_literal: true

require_relative "common"

module Market
  module Native
    module Views
      # 持仓行（原生版，key = 股票代码）：一行 label + 平仓/撤挂单按钮，第二行是实时列。
      #
      # 沿用 app/views/positions.rb 的 PositionRow：行内的取值 Proc、以及 position / quote /
      # position_value / position_pnl / position_pnl_pct 这几个私有计算**都是继承来的**，
      # 本类只把它们排成原生控件（原生 label 没有颜色，涨跌色不出现在这里）。
      class PositionRow < ::Market::Views::PositionRow
        include Common

        def view
          box(direction: :column, gap: 0) do
            # 三行：代码+名称 / 快照 / 实时。按钮单独跟在代码行后面。
            # 一行放不下（代码 + 快照 + 两个按钮 ≈ 540px）——而 libui 里 label 的天然宽度
            # 就是所在列（进而整窗）的**宽度下限**：持有 1 只时窗口就再也缩不到最小尺寸
            # （实测：有持仓时把内容尺寸请求成 1060×780，被顶回 1415×780）。
            # 拆行后这一行的天然宽度 ≈ 208，整个面板 ≈ 322（< 下单面板的输入行 327.5）。
            box(direction: :row, gap: 10) do
              label { "#{code} #{name}" }
              button(on_click: -> { on_close.call(code) }) { "平仓" }
              button(on_click: -> { on_cancel_orders.call(code) }) { "撤挂单" }
            end
            label { snapshot_line }
            label { live_line }
          end
        end

        private

        # 快照列（读 ledger，仅成交时变）。position 为 nil 只可能出现在"已平仓、这一行还没被
        # 移除"的瞬间——原生窗口里让 label 崩掉就是整个应用退出，所以这里显式兜住。
        def snapshot_line
          return "已不在持仓（等待刷新）" unless position

          "持仓 #{qty(position[:quantity])} · 可用 #{qty(position[:available])} · 成本 #{money(position[:avg_cost])}"
        end

        # 实时列（读该标的行情信号，每档变；与浏览器版 .pos-live 同口径）
        def live_line
          return "" unless position

          "现价 #{money(quote[:last])} · 市值 #{money(position_value)} · " \
            "浮盈 #{signed_money(position_pnl)}（#{pct(position_pnl_pct)}）"
        end
      end

      # 持仓面板（原生版）：汇总文字 + 一键清仓按钮 + keyed 明细行
      # （**有界**：每页 PAGE_SIZE 行 + 翻页，见 PAGE_SIZE 的说明）。
      class Positions < ::Market::Views::Positions
        include Common

        # ── 为什么持仓列表必须有界（MARKET-1d 的 P1）──
        # 持仓行是原生控件（代码行 + 快照 + 实时 ≈ 3 行 label + 一个按钮行，实测 62px/行），
        # 而 **libui 的 box 先把天然高度分给非 stretchy 的孩子，剩下的才给 stretchy 的**：
        # 持仓行数一多，中列的走势图就被吃光。真窗口实测（默认窗口 1440×860，同一份代码）：
        #
        #   持仓只数   0     1     2     3     4     5     6+
        #   走势图高  340   300   236   172   108    44    0     ← 6 只起 0×0，一个图元都不画
        #
        # 而且窗口会被内容顶高（860 → 880 / 944 / 1008…）却救不回走势图（它的天然高度是 0）。
        # 框架层表达不了"最小高度"（citrine-native 只映射 gap / flex_grow；area 的 size:
        # 只对滚动面板生效，而滚动面板的内容尺寸会与视口脱钩——那是 MARKET-1c 踩过的坑），
        # 所以答案在应用侧：**一页 PAGE_SIZE 行 + 翻页**——面板天然高度被钉在 ~4 行
        # （≈250px），走势图必然拿到剩余高度；每只持仓的「平仓/撤挂单」仍然点得到
        # （可能在第 2、3 页）。实测阶梯与预算见 native/README.md「窗口尺寸」一节，
        # 回归守卫见 native/test/positions_widget_test.rb 与 libui_smoke.rb（冒烟里会真买 6 只）。
        PAGE_SIZE = 3

        # 面板自己的状态：当前页（与图表的 mode/bucket、日志的 tab 同类）。
        # 记账用 0 基，展示与断言用 1 基（"第 2/4 页"）。
        state :page, default: 0

        def view
          # stretch: false —— 这个面板是固定几行原生控件，没有可拉伸的数据区；
          # 让它 stretchy 会把窗口最小高度按"最高的 stretchy 兄弟"翻倍（见 Common#panel_frame）。
          # header: 翻页控件放进标题行（标题行本来就 16px、按钮 24px，合并只多 8px；
          # 单开一行要多 ~30px，那是走势图的高度预算）。
          panel_frame("持仓", stretch: false, header: -> { page_controls }) do
            box(direction: :row, gap: 10) do
              state_button(on_close_all) { "一键清仓" }
              label { summary_line }
            end

            # 行带 key（股票代码）：买入/卖出/清仓只增删受影响的行，其余行的控件与订阅原样保留。
            # 本块读 positions / page 两个信号 → 它是 Effect：持仓或页码一变就重排
            # （keyed 复用命中 key 的行仍是"移动真实节点"，见 native/views/common.rb 顶部）。
            box(direction: :column, gap: 2) do
              rows = positions.call
              if rows.empty?
                label { "暂无持仓 · 在右侧下单面板买入试试" }
              else
                page_rows(rows).each do |code|
                  render(PositionRow, code: code, name: name_for.call(code), key: code,
                                      quote_for: quote_for, position_for: position_for,
                                      on_close: on_close, on_cancel_orders: on_cancel_orders)
                end
              end
            end
          end
        end

        private

        # 当前页要画的代码（页码按实际持仓数钳制：卖出后页码越界不会画出一片空白）
        def page_rows(rows)
          codes = rows.keys
          start = page_index(codes.size) * PAGE_SIZE
          codes[start, PAGE_SIZE] || []
        end

        def page_index(total)
          [[page.to_i, 0].max, last_page(total)].min
        end

        def last_page(total)
          total <= 0 ? 0 : (total - 1) / PAGE_SIZE
        end

        # 标题行右侧的翻页控件：两个按钮 + 一个页码标签。
        # 按钮**不读信号**（只在点击时求值），只有页码标签那块是 Effect。
        def page_controls
          state_button(-> { turn_page(-1) }) { "‹ 上页" }
          label { page_label }
          state_button(-> { turn_page(1) }) { "下页 ›" }
        end

        def turn_page(delta)
          total = positions.call.size
          self.page = [[page_index(total) + delta, 0].max, last_page(total)].min
        end

        # "第 1/4 页 · 共 10 只"（持仓数读的是同一个信号，跟着更新）
        def page_label
          total = positions.call.size
          "第 #{page_index(total) + 1}/#{last_page(total) + 1} 页 · 共 #{total} 只"
        end

        # 汇总拆两行：原生 label 不换行，单行 ~400px 会把中列的天然宽度顶高，
        # 而"三列等宽"的最小窗口宽度 = 3 × 最宽的列天然宽度（见 native/README.md）
        def summary_line
          stats = summary.call
          "市值 #{money(stats[:market])} · 浮盈 #{signed_money(stats[:pnl])}\n" \
            "可用 #{money(stats[:available])} · 冻结 #{money(stats[:frozen])}"
        end
      end
    end
  end
end

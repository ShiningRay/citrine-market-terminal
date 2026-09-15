# frozen_string_literal: true

require_relative "test_helper"

module Market
  module Native
    # 成交/挂单（area 自绘）：两张表、标签页切换（真实按钮）、行内撤单的真实派发路径。
    class LogsAreaTest < NativeScreenTest
      ORDER_GRID = Views::Logs::ORDER_GRID
      TRADE_GRID = Views::Logs::TRADE_GRID
      CANCEL_COLUMN = Views::Logs::CANCEL_COLUMN

      def place_limit_buy
        quote = term.quote_of(term.selected)
        limit = (quote[:bid] * 0.97).round(2)
        term.submit_order(:buy, :limit, "100", limit.to_s)
        assert_equal 1, term.account_orders.size, "限价买单应挂上（限价远低于市价，不会即时成交）"
        limit
      end

      def test_empty_hints
        assert_includes texts(draw(:logs)), "还没有成交记录 · 下单后在这里出现"
        click_button("挂单")
        assert_includes texts(draw(:logs)), "无挂单 · 限价单会在这里排队等待成交"
      end

      def test_trade_row_after_submitting_from_the_ticket_panel
        submit_button.fire(:click)
        trade = term.account_trades.first
        assert_equal 1, term.account_trades.size

        shown = texts(draw(:logs))
        assert_includes shown, "成交价"
        assert_includes shown, term.selected
        assert_includes shown, "买入"
        assert_includes shown, money(trade.price)
        assert_includes shown, qty(trade.quantity)
      end

      def test_sell_trade_shows_realized_pnl_in_color
        term.submit_order(:buy, :market, "100", "")
        term.run_ticks(1)
        term.submit_order(:sell, :market, "100", "")
        sells = term.account_trades.select { |trade| trade.side == :sell }
        assert_equal 1, sells.size

        realized = sells.first.realized
        op = draw(:logs).calls_of(:text).find { |call| call[:text] == signed_money(realized) }
        assert op, "卖出成交应画已实现盈亏"
        assert_equal rgb(value_color(realized)), op[:color]
      end

      def test_orders_tab_lists_and_cancels_inline
        limit = place_limit_buy
        click_button("挂单")
        shown = texts(draw(:logs))
        assert_includes shown, "撤单"
        assert_includes shown, money(limit)

        draw(:logs) # 命中测试用的是"当次绘制的几何"，先画一帧（真窗口里同样先有绘制）
        click(:logs, layout(:logs).x(CANCEL_COLUMN) + 4, layout(:logs).row_top(0) + 4)
        assert_empty term.account_orders, "点「操作」列的撤单应撤销该笔挂单"
        assert_match(/已撤单/, term.alert[:text])
      end

      def test_click_outside_cancel_column_does_nothing
        place_limit_buy
        click_button("挂单")
        draw(:logs)
        click(:logs, layout(:logs).x(1) + 4, layout(:logs).row_top(0) + 4)
        assert_equal 1, term.account_orders.size
      end

      # 列间呼吸位：右对齐的「冻结资金」数值顶在列右缘，接着就是「操作」列的「撤单」——
      # 没有任何间隙时两格会贴成"123,631.90撤单"（MARKET-2 记录的症状）
      def test_cancel_cell_does_not_touch_the_frozen_amount_column
        place_limit_buy
        click_button("挂单")
        recording = draw(:logs)
        grid = layout(:logs)
        cancel = recording.calls_of(:text).find { |call| call[:text] == "撤单" }
        assert cancel, "挂单行应有「撤单」单元格"
        boundary = grid.x(CANCEL_COLUMN)
        assert_operator cancel[:x], :>=, boundary + Views::Common::Grid::CELL_GAP,
                        "「撤单」不应紧贴上一列的数值（冻结资金列的右缘在 #{boundary}）"
        assert_equal grid.content_x(CANCEL_COLUMN), cancel[:x], "左对齐的列应统一让出呼吸位"

        frozen = recording.calls_of(:text).find { |call| call[:text] == money(term.account_orders.first.frozen) }
        assert frozen, "挂单行应有冻结资金数值"
        assert_operator frozen[:x], :<, boundary, "冻结资金数值应在「操作」列左边"
        # 右对齐的列改口径（MARKET-1d）：内容框左侧让出 NUM_GAP（呼吸位），但**右缘仍贴列缘**
        # ——左邻列的数值与它之间因此至少有 NUM_GAP 的间隙（此前是"右列刚好填满就贴死"）。
        assert_equal grid.x(5) + grid.width_of(5), grid.content_x(5) + grid.content_width(5),
                     "右对齐的列右缘仍贴列缘（右对齐不变），只是内容框左边让出呼吸位"
        assert_in_delta Views::Common::Grid::NUM_GAP, grid.content_x(5) - grid.x(5), 0.001
      end

      def test_trades_tab_ignores_clicks
        term.submit_order(:buy, :market, "100", "")
        draw(:logs)
        click(:logs, layout(:logs).x(6) + 4, layout(:logs).row_top(0) + 4)
        assert_equal 1, term.account_trades.size
      end
    end
  end
end

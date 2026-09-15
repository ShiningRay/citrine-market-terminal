# frozen_string_literal: true

require_relative "test_helper"

module Market
  module Native
    # 根组件逻辑（不挂窗口）：心跳倍速/暂停、定时器装配、交易动作。
    # 这些断言与渲染目标无关——浏览器与原生共享同一份 Market::Terminal 逻辑。
    class TerminalLogicTest < NativeUnitTest
      def test_beat_advances_one_tick_per_speed_delay
        before = term.tick_value
        term.set_speed(4)          # 一档 = 850/4 = 212ms
        term.beat
        assert_equal before, term.tick_value, "一次 200ms 心跳还不够一档"
        term.beat
        assert_equal before + 1, term.tick_value
      end

      def test_paused_beats_do_not_advance
        before = term.tick_value
        term.set_speed(4)
        term.pause
        10.times { term.beat }
        assert_equal before, term.tick_value

        term.toggle_pause
        refute term.paused
        2.times { term.beat }
        assert_equal before + 1, term.tick_value
      end

      def test_heartbeat_wiring_uses_native_timer
        with_timer_stub do |timer|
          before = term.tick_value
          term.start_heartbeat
          assert_equal Market::Terminal::BEAT_MS, timer.interval_ms,
                       "心跳节拍必须仍是 BEAT_MS（200ms），一档的快慢由 speed 决定"
          term.set_speed(4)
          timer.fire(2)
          assert_equal before + 1, term.tick_value

          term.toggle_pause
          timer.fire(10)
          assert_equal before + 1, term.tick_value, "暂停后心跳不再推进档位"

          term.stop_heartbeat
          assert timer.stopped?
          assert_nil term.instance_variable_get(:@heartbeat_handle)
        end
      end

      def test_market_order_and_position_snapshot
        term.submit_order(:buy, :market, "500", "")
        position = term.position_of(term.selected)
        assert_equal 500, position[:quantity]
        assert_equal 0, position[:available], "当日买入受 T+1 限制"
        assert_operator term.account_fees, :>, 0
      end

      def test_limit_order_freezes_and_cancel_releases
        quote = term.quote_of(term.selected)
        term.submit_order(:buy, :limit, "100", (quote[:bid] * 0.97).round(2).to_s)
        assert_equal 1, term.account_orders.size
        assert_operator term.account_frozen, :>, 0

        term.cancel_order(term.account_orders.first.id)
        assert_empty term.account_orders
        assert_equal 0.0, term.account_frozen
      end

      def test_close_position_and_close_all
        term.submit_order(:buy, :market, "100", "")
        term.close_position(term.selected)
        assert_match(/暂无可卖持仓/, term.alert[:text], "当日买入当日不可卖")
        term.run_ticks(1)
        term.close_position(term.selected)
        assert_empty term.account_positions
        assert_operator term.account_realized, :!=, 0.0

        term.close_all_positions
        assert_match(/当前没有持仓/, term.alert[:text])
      end
    end

    # 全局键盘（window_key）：原生没有 window 级 keydown，按键由**收到事件的 area**
    # 转发给组件（设计 2.3）。这里走真实的桩后端派发路径：fire_key(area, " ")。
    #
    # handle_window_key 支持的键（app/terminal.rb）：
    #   空格 暂停/继续 · 1/2/3 → 1x/2x/4x · ↑↓ 换一档标的 · b/B 买 · s/S 卖 ·
    #   Enter 提交下单 · Esc 清提示（输入框内的按键在 DOM 侧被忽略；原生侧 entry 根本收不到键）
    class KeyboardForwardingTest < NativeScreenTest
      def test_space_toggles_pause
        key(:watchlist, " ")
        assert term.paused
        key(:chart, " ") # 任何聚焦面板都能转发同一条全局快捷键
        refute term.paused
      end

      def test_digits_switch_speed
        key(:watchlist, "2")
        assert_equal 2, term.speed
        refute term.paused, "变速会恢复运行"
        key(:watchlist, "3")
        assert_equal 4, term.speed
        key(:watchlist, "1")
        assert_equal 1, term.speed
      end

      def test_arrows_step_symbol_and_reset_chart_bucket
        chart_panel = term.chart_panel
        chart_panel.bucket = 8
        codes = term.row_order
        key(:watchlist, "ArrowDown")
        assert_equal codes[1], term.selected
        assert_equal 3, chart_panel.bucket, "换股后图表取样粒度复位（面板自己的状态）"
        key(:watchlist, "ArrowUp")
        assert_equal codes[0], term.selected
      end

      def test_buy_sell_and_enter_are_forwarded_to_the_ticket_panel
        key(:watchlist, "b")
        assert_equal :buy, term.ticket_panel.side
        key(:watchlist, "s")
        assert_equal :sell, term.ticket_panel.side
        key(:watchlist, "b")

        key(:watchlist, "Enter")
        assert_equal 1, term.account_positions.size, "Enter 应走面板的 #submit"
      end

      def test_escape_clears_notice
        key(:watchlist, "b")
        key(:watchlist, "Enter")
        refute_empty term.notice[:text]
        key(:watchlist, "Escape")
        assert_equal "", term.notice[:text]
      end

      def test_unhandled_keys_are_ignored
        before = term.tick_value
        key(:watchlist, "q")
        assert_equal before, term.tick_value
        assert_equal :buy, term.ticket_panel.side
      end
    end
  end
end

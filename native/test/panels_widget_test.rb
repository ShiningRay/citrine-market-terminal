# frozen_string_literal: true

require_relative "test_helper"

module Market
  module Native
    # 原生控件面板的装配与交互：顶部条（暂停/倍速/自动交易/重置）、下单面板（模式/方向/数量
    # 输入/提交）、持仓行（平仓）、心跳定时器。全部走真实控件（Memory 桩后端，fire 模拟用户操作）。
    #
    # 这一层正是"原生控件面板"与自绘面板的分界：能点的都是真按钮，能打字的都是真 entry
    # （libui 的 entry 拿不到 Enter，所以提交必须有点得动的按钮——见 Views::Ticket 的注释）。
    class PanelsWidgetTest < NativeScreenTest
      def test_area_handles_are_reachable_from_the_root
        %i[watchlist stats chart logs].each do |name|
          handle = area(name)
          assert_kind_of Citrine::Native::AreaHandle, handle, "#{name} 面板句柄应是 AreaHandle"
          assert_includes areas, handle.handle
        end
      end

      # 启动即需键盘（设计 2.3）：挂载后应把焦点给自选面板（桩后端会记录 focused）
      def test_keyboard_focus_is_taken_on_mount
        assert @backend.focused?(area_widget(:watchlist)), "挂载后应聚焦自选面板（window_key 由聚焦的 area 转发）"
      end

      def test_heartbeat_uses_native_timer
        assert_equal Market::Terminal::BEAT_MS, timer.interval_ms
        assert_respond_to term.instance_variable_get(:@heartbeat_handle), :stop
      end

      def test_pause_and_speed_buttons
        click_button("⏸ 暂停")
        assert term.paused
        assert button("▶ 继续"), "暂停后按钮文案应变成继续"

        click_button("2x")
        assert_equal 2, term.speed
        refute term.paused
      end

      def test_auto_trade_and_reset_buttons
        click_button("自动交易 关")
        assert term.auto_trade
        assert button("自动交易 开 ✓")

        submit_button.fire(:click)
        assert_equal 1, term.account_positions.size
        click_button("重置账户")
        assert_empty term.account_positions
        assert_in_delta term.initial_cash, term.account_cash, 0.01
      end

      def test_sort_buttons
        click_button("涨跌幅")
        assert_equal :change, term.sort_key
        click_button("成交额")
        assert_equal :amount, term.sort_key
      end

      # 下单：数量输入框（受控）→ 提交按钮（点击提交，不依赖 Enter）
      def test_quantity_entry_drives_draft_and_submit
        assert_equal "100", term.ticket_panel.qty_text
        assert_equal "100", @backend.get_value(entry)

        type_into(entry, "500")
        assert_equal "500", term.ticket_panel.qty_text

        submit_button.fire(:click)
        assert_equal 500, term.position_of(term.selected)[:quantity]
        assert_match(/成交：买入 500 股/, term.alert[:text])
      end

      def test_quick_quantity_buttons
        click_button("1000")
        assert_equal "1000", term.ticket_panel.qty_text
        click_button("全部")
        filled = term.ticket_panel.qty_text.to_i
        assert_operator filled, :>, 0, "「全部」按最大可买填"
        assert_equal 0, filled % 100, "整手"
        price = term.quote_of(term.selected)[:ask]
        assert_operator filled * price, :<=, term.account_available_cash + 0.01, "最大可买不该超出可用资金"
      end

      def test_side_and_kind_switches
        click_button("卖出")
        assert_equal :sell, term.ticket_panel.side
        click_button("买入")
        assert_equal :buy, term.ticket_panel.side

        click_button("限价")
        assert_equal :limit, term.ticket_panel.order_kind
        assert_equal 2, entries.size, "限价模式多出一个价格输入框"
        click_button("市价")
        assert_equal 1, entries.size
      end

      def test_limit_order_via_widgets_freezes_and_cancels
        quote = term.quote_of(term.selected)
        click_button("限价")
        type_into(entries.last, (quote[:bid] * 0.97).round(2).to_s)
        submit_button.fire(:click)
        assert_equal 1, term.account_orders.size
        assert_operator term.account_frozen, :>, 0

        click_button("挂单")
        draw(:logs) # 命中测试用的是"当次绘制的几何"，先画一帧
        click(:logs, layout(:logs).x(Views::Logs::CANCEL_COLUMN) + 4,
                     layout(:logs).row_top(0) + 4)
        assert_empty term.account_orders
        assert_equal 0.0, term.account_frozen
      end

      def test_estimate_and_feedback_labels
        type_into(entry, "200")
        quote = term.quote_of(term.selected)
        assert label_matching(/预估成交价 #{Regexp.escape(money(quote[:ask]))}/), "预估明细应随数量更新"
        assert label_matching(/最大可买/)

        submit_button.fire(:click)
        assert label_matching(/委托结果：成交：买入 200 股/), "下单结果应显示在面板里"
        assert label_matching(/提示：成交：买入 200 股/)
      end

      def test_position_row_close_button
        submit_button.fire(:click)
        term.run_ticks(1) # T+1：次档才可卖
        click_button("平仓")
        assert_empty term.account_positions
      end

      def test_position_row_cancel_orders_button
        submit_button.fire(:click)             # 先建一个持仓，才有持仓行与「撤挂单」按钮
        quote = term.quote_of(term.selected)
        click_button("限价")
        type_into(entries.last, (quote[:bid] * 0.97).round(2).to_s)
        submit_button.fire(:click)
        assert_equal 1, term.account_orders.size

        click_button("撤挂单")
        assert_empty term.account_orders
      end

      def test_debug_bar_reports_rounds
        term.run_ticks(1)
        assert label_matching(/本档 Effect 重跑 \d+/), "埋点条应显示本档重跑数"
        assert label_matching(/信号对象数 \d+/)
      end

      # 自绘面板的绘制用法全部合法（颜色写法、align 用法…都由 Painter 归一，
      # 归一里发现问题会记进 warnings——测试里直接断言"一条都没有"）
      def test_painting_raises_no_warnings
        %i[watchlist chart stats logs].each do |name|
          recording = draw(name)
          assert_empty recording.warnings, "#{name} 面板的绘制有未支持用法：#{recording.warnings.values.inspect}"
        end
      end
    end
  end
end

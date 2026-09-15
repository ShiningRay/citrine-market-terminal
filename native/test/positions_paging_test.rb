# frozen_string_literal: true

require_relative "test_helper"

module Market
  module Native
    # 持仓面板的**有界分页**（MARKET-1d 的 P1 修复面）。
    #
    # 这条不变量的来由：持仓行是原生控件，一行实测 62px；libui 的 box 先把天然高度分给
    # 非 stretchy 的孩子，剩下的才给 stretchy 的——持仓行数不设上限时，中列的走势图会被吃成
    # 0×0（默认窗口 1440×860 下持 6 只就发生，阶梯 340/300/236/172/108/44/0…）。
    # 所以持仓面板每页只画 PAGE_SIZE 行 + 翻页；这里守的就是"无论持有多少只，一行都不会多画"，
    # 真窗口下的高度守卫在 libui_smoke.rb（会真买 6 只）与 layout_test.rb 的高度预算。
    class PositionsPagingTest < NativeScreenTest
      PAGE_SIZE = Views::Positions::PAGE_SIZE

      # 逐只买入（每只 100 股，市价）。行序 = 建仓顺序（Hash 保序），所以"第几页显示谁"是确定的。
      def buy(count)
        term.row_order.first(count).each do |code|
          term.select_symbol(code)
          term.submit_order(:buy, :market, "100", "")
        end
        assert_equal count, term.account_positions.size, "应买到 #{count} 只（现金不足会少买）"
        term.account_positions.keys
      end

      # 当前可见的持仓行：借「平仓」按钮的父框拿行首的「代码 名称」label
      # （原生一行 = box{ box{ label; 平仓; 撤挂单 }; label(快照); label(实时) }）
      def visible_rows
        widgets(:button).select { |widget| widget.text == "平仓" }.map do |button|
          button.parent.children.first.text
        end
      end

      def page_label
        widgets(:label).map(&:text).find { |text| text.include?("页 · 共") }
      end

      def test_holds_are_paged_instead_of_all_rendered
        codes = buy(9)
        rows = visible_rows
        assert_equal PAGE_SIZE, rows.size,
                     "无论持有多少只，一页只画 #{PAGE_SIZE} 行：行数不设上限会把中列走势图吃成 0×0" \
                     "（真窗口实测：持 6 只时走势图 0×0）"
        codes.first(PAGE_SIZE).each_with_index do |code, index|
          assert rows[index].start_with?(code), "第 #{index} 行应是 #{code}，实际 #{rows[index].inspect}"
        end
      end

      def test_next_page_shows_the_next_rows_and_prev_goes_back
        codes = buy(7)
        click_button("下页 ›")
        assert_equal codes[PAGE_SIZE, PAGE_SIZE].map { |code| text_code(code) },
                     visible_rows.map { |text| text_code(text) }, "下页应显示第 2 页的持仓"
        assert_match(/第 2\/3 页/, page_label)

        click_button("‹ 上页")
        assert_equal codes.first(PAGE_SIZE).map { |code| text_code(code) },
                     visible_rows.map { |text| text_code(text) }, "上页应回到第 1 页"
        assert_match(/第 1\/3 页/, page_label)
      end

      def test_last_page_shows_the_remainder
        codes = buy(7)
        click_button("下页 ›")
        click_button("下页 ›")
        assert_equal codes.last(1).map { |code| text_code(code) },
                     visible_rows.map { |text| text_code(text) }, "末页只显示剩下的行"
        assert_match(/第 3\/3 页 · 共 7 只/, page_label)

        click_button("下页 ›")
        assert_match(/第 3\/3 页/, page_label, "末页再点下页停在末页（不越界成空白）")
        assert_equal 1, visible_rows.size
      end

      def test_page_clamps_when_holdings_shrink
        buy(7)
        click_button("下页 ›")
        click_button("下页 ›")
        assert_match(/第 3\/3 页/, page_label)

        term.run_ticks(1) # T+1：次档才可卖
        term.close_all_positions
        assert_empty term.account_positions
        assert_nil visible_rows.first, "清仓后不该有持仓行"
        assert_match(/第 1\/1 页 · 共 0 只/, page_label, "页码要按实际持仓数钳制（不越界、不空白）")
        assert label_matching(/暂无持仓/), "空持仓时仍显示空状态说明"
      end

      def test_first_page_has_no_previous
        buy(4)
        click_button("‹ 上页")
        assert_match(/第 1\/1 页|第 1\/2 页/, page_label, "第 1 页再点上页仍停在首页")
        assert_equal 3, visible_rows.size
      end

      def test_paging_does_not_disturb_the_panels_state_ownership
        buy(4)
        # 翻页是**面板自己的 state**（与图表的 mode/bucket、日志的 tab 同类）：不动全局选中标的
        before = term.selected
        click_button("下页 ›")
        assert_equal before, term.selected, "翻页不该改变全局选中的标的"
      end

      def text_code(text) = text.to_s[0, 6]
    end
  end
end

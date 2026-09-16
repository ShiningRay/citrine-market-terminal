# frozen_string_literal: true

require_relative "common"

module Market
  module Views
    # 自选行（子组件，key = 股票代码）。
    #
    # 行里所有会变的东西都通过**取值 Proc** 取：`quote_for.call(code)` 读该标的行情信号、
    # `active_for.call(code)` 读根组件的选中标的。调用点在行内的叶子块/响应式属性里，
    # 于是订阅落在**这一行这一格**的 Effect 上——每档行情只重设文字与 style，
    # 行节点与整棵子树都不动（F6 落地前这里是"父块读 quote 后整块重建"）。
    #
    # 行本身没有 state：选中态是根组件的状态、行情是引擎的信号，行只是它们的读取点。
    class WatchRow < Citrine::Component
      include Common

      prop :code              # 股票代码（值的形式：它永不变化）
      prop :name              # 名称（同上）
      prop :quote_for         # ->(code) { quote_of(code) }    该标的行情快照
      prop :active_for        # ->(code) { selected == code }  是否当前选中
      prop :held_for          # ->(code) { 是否持仓 }
      prop :on_pick           # ->(code) { select_symbol(code) }

      def view
        # 选中态：本行自己的响应式 css_class（换股只重设两行的 class，不重建行）
        box(css_class: -> { active_for.call(code) ? "wl-row is-active" : "wl-row" },
            on_click: -> { on_pick.call(code) }) do
          box(css_class: "wl-name", direction: :column) do
            label(css_class: "wl-code") { code }
            label(css_class: "wl-cn") { name }
            # 持仓标记：读 ledger（仅成交时变化）
            box(css_class: "wl-badge-slot") do
              Beryl::Badge.new(text: "持", css_class: "badge-hold").view if held?
            end
          end

          # 价格组：颜色随涨跌变化。容器块不读信号，三个数字各自的响应式 style
          # 在本节点的属性 Effect 里求值 → 每档只重设 style/文字，0 个新建节点
          box(css_class: "wl-price") do
            label(css_class: "wl-c-last num", style: -> { quote_style }) { money(quote[:last]) }
            label(css_class: "wl-c-chg num", style: -> { quote_style }) { signed_money(quote[:change]) }
            label(css_class: "wl-c-pct num", style: -> { quote_style }) { pct(quote[:change_pct]) }
          end

          # 成交量/成交额：无色变化 → 叶子块读，只改文字
          label(css_class: "wl-c-vol num") { volume(quote[:volume]) }
          label(css_class: "wl-c-amt num") { amount(quote[:amount]) }
        end
      end

      private

      def quote
        quote_for.call(code)
      end

      def quote_style
        pct_style(quote[:change])
      end

      def held?
        held_for.call(code)
      end
    end

    # 自选行情面板（子组件）：表头 + keyed 行列表 + 排序工具。
    class Watchlist < Citrine::Component
      include Common

      components WatchRow

      prop :codes             # -> { row_order }                 行顺序（排序键的产物）
      prop :name_for          # ->(code) { engine_name(code) }   非响应式读取（名称不随档位变）
      prop :quote_for         # ->(code) { quote_of(code) }
      prop :active_for        # ->(code) { selected == code }
      prop :held_for          # ->(code) { 是否持仓 }
      prop :sort_key          # -> { sort_key }
      prop :on_sort           # ->(key) { apply_sort(key) }
      prop :on_pick           # ->(code) { select_symbol(code) }

      def view
        panel("panel-watch") do # 容器块：不读信号
          panel_head("自选行情") do # 工具区块：读 sort_key
            current = sort_key.call
            chip("代码", current == :code, -> { on_sort.call(:code) })
            chip("涨跌幅", current == :change, -> { on_sort.call(:change) })
            chip("成交额", current == :amount, -> { on_sort.call(:amount) })
          end

          box(css_class: "wl-head") do # 静态表头（不读信号）
            label(css_class: "wl-c-code") { "标的" }
            label(css_class: "wl-c-last num") { "最新" }
            label(css_class: "wl-c-chg num") { "涨跌" }
            label(css_class: "wl-c-pct num") { "涨跌幅" }
            label(css_class: "wl-c-vol num") { "成交量" }
          end

          # 行集合：只在 row_order 变化（排序）时重跑。
          # 重跑 ≠ 重建：每行都带 key（股票代码）且 keyed 子组件按 key 复用——
          # 行实例、行内 DOM、行内订阅全部保留，重排只是把真实节点移动位置。
          # 换股不经过这里：选中态是行自己的响应式 css_class。
          box(css_class: "wl-body", direction: :column) do
            codes.call.each do |code|
              watch_row(code: code, name: name_for.call(code), key: code,
                        quote_for: quote_for, active_for: active_for, held_for: held_for,
                        on_pick: on_pick)
            end
          end
        end
      end
    end
  end
end

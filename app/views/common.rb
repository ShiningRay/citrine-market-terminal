# frozen_string_literal: true

require_relative "../format"

# 视图公共构件 + 视图层纪律。
#
# 面板自 P0-1（FRICTION F5/F6 已落地）起是**真正的子组件**（`Citrine::Component` 子类），
# 这些构件仍以 mixin 提供：它们只产出元素节点，不持有状态，也不关心宿主是哪个组件。
#
# ── 仍然成立的纪律（与框架的块级重建语义直接相关，改视图前先读）──
#   1. **容器块的 block 不读信号** → 结构不随逐档行情打散；会变的数字放到最内层小块里读
#      （读在叶子块 → 更新只改 textContent，**0 个元素重建**）。
#      子组件同理：props 里不要放"会变的值"，也不要在子组件 view 的容器块里替它读。
#   2. **随值变的外观用响应式属性**（`css_class:` / `style:` 传 Proc）：求值落在该节点
#      自己的属性 Effect 上，重跑只重设属性、不重建子树（F4 的落地方案）。没有响应式
#      表示的场景（改的是子节点集合/结构）才退回"块读信号并重建"。
#   3. **父组件不把"会变的值"读出来传给子组件**——props 一变，keyed 子组件会**重建**
#      （框架 S1 语义：`ReusePool` 按非 Proc props 判等），实例 state 与 DOM 一起丢，
#      整行换节点；而且父块读信号还会让整棵树跟着调和。
#      做法是传**取值 Proc**（在父组件 view 里定义，闭包 self = 父组件），
#      子组件在**最内层**才 `.call`：订阅就落在子组件那个叶子/属性 Effect 上。
#      唯一例外：**永不变化的值**（股票代码、名称）可以当值传。
#   4. **快照类数据由父块读出后以局部变量传给子块** —— 父块重建时自然刷新，子块保持静态。
#
# ── 已退休的纪律 ──
#   · "输入框所在的块绝不能读信号"（F6 时代的绕法）：keyed/位置复用落地后，重跑的块会命中
#     同一批节点，输入框不再被销毁重建，焦点与输入法状态因此不再丢。下单草稿现在按正常
#     写法写在 `app/views/ticket.rb`（其所在的块也照常读自己需要的信号）。
module Market
  module Views
    module Common
      include Format

      private

      def panel(css_class, &block)
        box(css_class: "panel #{css_class}", direction: :column, &block)
      end

      # 面板标题栏；右侧工具区由调用方 block 填充（该 block 里可以读信号，
      # 重建范围仅限于工具区）
      def panel_head(title, &tools)
        box(css_class: "panel-head") do
          label(css_class: "panel-title") { title }
          if tools
            box(css_class: "panel-tools", direction: :row, gap: 6) { tools.call }
          else
            box(css_class: "panel-tools", direction: :row, gap: 6) {}
          end
        end
      end

      def chip(text, active, handler)
        button(on_click: handler, css_class: active ? "chip is-on" : "chip") { text }
      end

      # 单行指标：调用方在 block 里求值（读信号由调用方负责）
      def kv(label_text, value_text, value_style = nil)
        box(css_class: "kv", direction: :row) do
          label(css_class: "kv-k") { label_text }
          label(css_class: "kv-v num", style: value_style) { value_text }
        end
      end

      # 纵向指标卡
      def metric(label_text, value_text, value_style = nil)
        box(css_class: "metric", direction: :column) do
          label(css_class: "metric-k") { label_text }
          label(css_class: "metric-v num", style: value_style) { value_text }
        end
      end

      def pct_style(value)
        { color: value_color(value) }
      end

      def dir_style(direction)
        { color: direction_color(direction) }
      end
    end
  end
end

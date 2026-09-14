# frozen_string_literal: true

# 视图公共构件。
#
# 视图层纪律（对应 citrine 的块级重建语义 + 响应式属性，务必遵守）：
#   1. 容器块的 block **不读任何信号** → 结构不会被 tick 打散；
#   2. 会变的数字放在最内层小块里读 → 更新只改文字，0 个元素重建；
#   3. **随值变的外观（颜色/类名）用响应式属性**：`css_class:` / `style:` 传 Proc，
#      求值发生在该节点自己的属性 Effect 里，只重设属性、不重建子树
#      （F4 的落地方案）。没有响应式表示的场景才退回"外层块读信号并重建"，
#      此时内层标签绝不再读同一信号（祖先与后代订阅同一信号曾触发框架崩溃，
#      见 FRICTION.md 的 F1，已修复但仍应避免）；
#   4. 快照类数据（持仓数量/成本等）由父块读出后以局部变量传给子块，
#      父块重建时局部变量自然刷新。
#
# 注意：下面这些构件（kv / metric / kpi）收的是**值**而不是 Proc——
# 调用方在 block 里求值时就把订阅带进了外层块。要它们支持"只改文字不重建"，
# 得把 value_text 也改成 Proc（本次迁移未做，改动面见 FRICTION.md 第七节）。
module Market
  module Views
    module Common
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

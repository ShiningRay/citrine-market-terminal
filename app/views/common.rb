# frozen_string_literal: true

# 视图公共构件。
#
# 视图层纪律（对应 citrine v1 的块级重建语义，务必遵守）：
#   1. 容器块的 block **不读任何信号** → 结构不会被 tick 打散；
#   2. 会变的数字放在最内层小块里读 → 更新只改文字，0 个元素重建；
#   3. 需要随值改颜色/类名的单元，让**外层块**读信号并重建（颜色是 props，
#      props 只在挂载时应用）→ 内层标签只放静态文字，绝不再读同一信号
#      （祖先与后代订阅同一信号会触发框架崩溃，见 FRICTION.md 的 F1）；
#   4. 快照类数据（持仓数量/成本等）由父块读出后以局部变量传给子块，
#      父块重建时局部变量自然刷新。
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

# frozen_string_literal: true

require_relative "common"

module Market
  module Views
    # 底部埋点条（子组件）：展示"一个 tick 触发多少重算、重建多少 DOM 节点、耗时多少"。
    # 框架没有官方 DevTools（FRICTION.md 的 F9 仍未解决），数据靠 demo 自建埋点
    # （telemetry.rb + test_api.rb 的 RenderInstrumentation）。
    class DebugBar < Citrine::Component
      include Common

      prop :report            # -> { debug_report }（每档更新）
      prop :signal_count      # -> { signal_inventory }（不能叫 signals：那是 Component 自己的信号缓存）

      def view
        box(css_class: "dbg", direction: :column) do # 容器块：不读信号
          box(css_class: "dbg-head") do
            label(css_class: "dbg-title") { "信号与渲染埋点" }
            label(css_class: "dbg-note") do
              "统计口径：一轮 tick 内 Effect 重跑次数与 document.createElement 次数（含本面板自身的重建）"
            end
          end
          box(css_class: "dbg-grid") do # 读 debug_report（每档）
            current = report.call
            kv("本档 Effect 重跑", current[:effect_runs].to_i.to_s)
            kv("本档新建 DOM 节点", current[:node_creates].to_i.to_s)
            kv("本档耗时", "#{current[:elapsed_ms].to_i} ms")
            kv("累计重跑 / 节点", "#{current[:total_effect_runs].to_i} / #{current[:total_node_creates].to_i}")
            kv("已完成档数", current[:rounds].to_i.to_s)
            kv("信号对象数", signal_count.call.to_s)
          end
        end
      end
    end
  end
end

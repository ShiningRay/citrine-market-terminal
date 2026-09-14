# frozen_string_literal: true

require_relative "common"

module Market
  module Views
    # 底部埋点条：展示"一个 tick 触发多少重算、重建多少 DOM 节点、耗时多少"。
    # v1 没有官方 DevTools，数据靠 demo 自建埋点（telemetry.rb + browser_glue.rb）。
    module DebugBar
      include Common

      private

      def render_debug
        box(css_class: "dbg", direction: :column) do # 容器块：不读信号
          box(css_class: "dbg-head") do
            label(css_class: "dbg-title") { "信号与渲染埋点" }
            label(css_class: "dbg-note") do
              "统计口径：一轮 tick 内 Effect 重跑次数与 document.createElement 次数（含本面板自身的重建）"
            end
          end
          box(css_class: "dbg-grid") do # 读 debug_report（每档）
            report = debug_report
            kv("本档 Effect 重跑", report[:effect_runs].to_i.to_s)
            kv("本档新建 DOM 节点", report[:node_creates].to_i.to_s)
            kv("本档耗时", "#{report[:elapsed_ms].to_i} ms")
            kv("累计重跑 / 节点", "#{report[:total_effect_runs].to_i} / #{report[:total_node_creates].to_i}")
            kv("已完成档数", report[:rounds].to_i.to_s)
            kv("信号对象数", signal_inventory.to_s)
          end
        end
      end
    end
  end
end

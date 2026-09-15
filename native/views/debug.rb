# frozen_string_literal: true

require_relative "common"

module Market
  module Native
    module Views
      # 底部埋点条（原生版，纯原生控件）：一个 tick 触发多少次效应重算、耗时多少。
      #
      # 沿用 app/views/debug.rb 的 DebugBar（report / signal_count 两个 prop 都是取值 Proc）。
      # 原生侧只有一处不同：**没有 createElement**，"新建节点数"不适用（浏览器版统计的是
      # document.createElement 次数），所以这一栏不显示，避免把 0 读成"原生更省"。
      class DebugBar < ::Market::Views::DebugBar
        include Common

        def view
          box(direction: :column, gap: 2) do
            # 说明文字拆两行：原生 label 不换行，单行 ~1400px 会顶高窗口最小宽度（见 native/README.md）
            label { "信号与渲染埋点（原生后端：Effect 重跑 / 耗时 / 累计 / 档数）" }
            label { "新建控件数不适用——那是 DOM 侧 createElement 的计数" }
            box(direction: :row, gap: 16) do
              label { report_line }
              label { "信号对象数 #{signal_count.call}" }
            end
          end
        end

        private

        def report_line
          current = report.call
          "本档 Effect 重跑 #{current[:effect_runs].to_i} · 本档耗时 #{current[:elapsed_ms].to_i} ms · " \
            "累计重跑 #{current[:total_effect_runs].to_i} · 已完成档数 #{current[:rounds].to_i}"
        end
      end
    end
  end
end

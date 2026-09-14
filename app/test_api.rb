# backtick_javascript: true
# frozen_string_literal: true

# 浏览器侧剩下的两件"外挂"：渲染埋点 + 桩验收驱动接口（demo 专用，非框架 API）。
#
# 这里从前是 `browser_glue.rb`——128 行的浏览器外挂层：setInterval 心跳、
# window 级快捷键、beforeunload 清理、渲染计数、验收 API。前三样在 Citrine 0.1.1
# 之后都有了框架入口（FRICTION.md 的 F7 / F10 → 框架 G-9 / G-10）：
#   · 心跳定时器 → `Terminal` 的 `on_mount :start_heartbeat` / `on_unmount :stop_heartbeat`
#   · 全局快捷键 → `Terminal` 的 `window_key :handle_window_key`（事件是 Citrine::KeyEvent）
#   · 卸载清理   → `Citrine.unmount` 会解绑 window 监听并跑 on_unmount，入口不必再挂 beforeunload
# 只剩下面两样还没有框架形态，所以文件改名成更诚实的 test_api.rb：
#   · 渲染器埋点：F9 仍未解决（框架还没有 telemetry 钩子，这里只能自己 class_eval）
#   · 无头验收的驱动钩子（见 test/market_stub_check.js）
require "native"
require "citrine"
require_relative "telemetry"

module Market
  # 渲染器埋点：包装 DomRenderer#create_dom 计数（纯 Ruby 侧包装，不动 JS DOM API）。
  #
  # ⚠ 这是"框架缺口"（F9：没有 DevTools / 埋点钩子），不是推荐姿势：
  # 理想形态是框架内置 `Citrine.telemetry = { on_effect_run:, on_node_create: }`。
  # 姊妹仓库 citrine-sheets 的同款埋点也在等这个钩子——两个真实应用各 hack 了一遍。
  module RenderInstrumentation
    def self.install!
      return if Citrine::DomRenderer.method_defined?(:create_dom_without_telemetry)

      Citrine::DomRenderer.class_eval do
        alias_method :create_dom_without_telemetry, :create_dom
        define_method(:create_dom) do |node|
          Citrine::Telemetry.count_node
          create_dom_without_telemetry(node)
        end
      end
    end
  end

  module TestApi
    module_function

    def install!
      RenderInstrumentation.install!
      true
    end

    # 暴露给 Node 桩验收脚本（见 market_stub_check.js）
    def expose(terminal)
      `window.citrineTestApi = {
         runTicks: function (n) { #{terminal}.$run_ticks(n); return #{terminal}.$test_state_text(); },
         state: function () { return #{terminal}.$test_state_text(); },
         fireTick: function () { return #{terminal}.$run_ticks(1); },
         pause: function () { #{terminal}.$pause(); },
         resume: function () { #{terminal}.$resume(); },
         stopTimer: function () { #{terminal}.$stop_heartbeat(); }
       }`
      self
    end
  end
end

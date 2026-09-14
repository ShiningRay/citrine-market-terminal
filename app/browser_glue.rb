# backtick_javascript: true
# frozen_string_literal: true

# 浏览器外挂层：citrine v1 没有定时器、全局键盘事件、挂载/卸载钩子，
# 也没有 DevTools 钩子，所以这些都得在框架外用 Opal 的原生互操作补齐：
#   - 用 window.setInterval 驱动 tick（固定 200ms 心跳 + 按倍速累积，支持暂停/变速）
#   - 用 window.addEventListener("keydown") 做快捷键
#   - 用 class_eval 包装 DomRenderer#create_dom 统计"本轮新建了多少 DOM 节点"
#   - 用 window.citrineTestApi 暴露给 Node 桩验收脚本（无头驱动）
# 这些都是 FRICTION.md 里记的框架缺口（F7 / F9 / F10），不是推荐姿势。
require "native"
require "citrine"
require_relative "telemetry"

module Market
  # 渲染器埋点：包装 DomRenderer#create_dom 计数（纯 Ruby 侧包装，不动 JS DOM API）
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

  class BrowserGlue
    BEAT_MS = 200          # 心跳间隔（固定的调度节拍）
    DEFAULT_TICK_MS = 850  # 1x 速度下一档的间隔

    def initialize(component, tick_ms: DEFAULT_TICK_MS)
      @component = component
      @tick_ms = tick_ms
      @window = Native(`window`)
      @accumulated = 0
      @handle = nil
      @in_tick = false
      RenderInstrumentation.install!
      install_shortcuts
    end

    def start
      @handle = @window.setInterval(-> { beat }, BEAT_MS)
      self
    end

    def stop
      @window.clearInterval(@handle) if @handle
      @handle = nil
      self
    end

    # 一次心跳：按倍速累积时间，够一档就推进（暂停时只是不累积）
    def beat
      return self if @component.paused

      @accumulated += BEAT_MS
      delay = Num.idiv(@tick_ms, @component.speed) # 整数除法必须走 Num.idiv（Opal 的 / 返回浮点）
      return self if @accumulated < delay

      @accumulated = 0
      fire_tick
      self
    end

    def fire_tick
      return self if @in_tick

      @in_tick = true
      Citrine::Telemetry.reset_round!
      started = `Date.now()`
      @component.tick!
      elapsed = `Date.now()` - started
      @component.report_tick!(elapsed)
      self
    ensure
      @in_tick = false
    end

    # 暴露给 Node 桩验收脚本（见 market_stub_check.js）
    def expose_test_api
      component = @component
      `window.citrineTestApi = {
         runTicks: function (n) { #{component}.$run_ticks(n); return #{component}.$test_state_text(); },
         state: function () { return #{component}.$test_state_text(); },
         fireTick: function () { return #{component}.$run_ticks(1); },
         pause: function () { #{component}.$pause(); },
         resume: function () { #{component}.$resume(); },
         stopTimer: function () { #{@window}.$clearInterval(#{@handle}); }
       }`
      self
    end

    private

    def install_shortcuts
      @window.addEventListener("keydown", ->(event) { handle_key(Native(event)) })
    end

    def handle_key(event)
      target = event[:target]
      tag = target ? target[:tagName].to_s.upcase : ""
      # 输入框内的按键交给控件自身（Enter 由 text_input 的 on_enter 处理）
      return if tag == "INPUT"

      key = event[:key].to_s
      case key
      when " "
        event.preventDefault
        @component.toggle_pause
      when "1" then @component.set_speed(1)
      when "2" then @component.set_speed(2)
      when "3" then @component.set_speed(4)
      when "ArrowUp" then @component.step_symbol(-1)
      when "ArrowDown" then @component.step_symbol(1)
      when "b", "B" then @component.set_side(:buy)
      when "s", "S" then @component.set_side(:sell)
      when "Enter" then @component.submit_order
      when "Escape" then @component.clear_notice
      end
      self
    end
  end
end

# frozen_string_literal: true

# 原生窗口入口（CRuby + libui）。
#
#   bin/native
#
# 与浏览器入口 app/market.rb 的分工：**逻辑一行不重写**——根组件是
# `Market::Native::Terminal < Market::Terminal`，只覆盖平台相关的四处：
#   · #view —— 用原生控件 + 自绘面板重写（props 装配与浏览器版一一对应）
#   · 心跳钩子 —— Native(window).setInterval → Citrine::Native.every
#   · #fire_tick 里的时钟 —— `Date.now()` → Process.clock_gettime
#   · 挂载时取键盘焦点 —— window_activate + AreaHandle#focus（设计 2.3 的转发前提）
# 面板同样是"浏览器面板类的子类 + 只重写 view"（见 native/views/*），
# 于是面板自己的 state（下单草稿 / 取样粒度 / 标签页）与动作方法全部原样继承。
#
# CRuby 下让 app/terminal.rb 顶部的 `require "native"`（Opal 的 JS 桥 gem）静默通过：
# 那次 require 只为两个心跳钩子里的反引号 JS 服务，而两个钩子在本文件被覆盖，
# 方法体永远不会执行；`# backtick_javascript: true` 只是给 Opal 编译器的注释。
begin
  require "native"
rescue LoadError
  $LOADED_FEATURES << "native.rb"
end

require "citrine"
require "citrine-native"
require "terminal"
require "telemetry"
require_relative "views/header"
require_relative "views/watchlist"
require_relative "views/chart"
require_relative "views/ticket"
require_relative "views/positions"
require_relative "views/logs"
require_relative "views/stats"
require_relative "views/debug"
require_relative "window_size"

module Market
  module Native
    # 原生窗口下的根组件：全局模型状态、computed、交易动作、全局键盘全部继承自
    # Market::Terminal（心跳的起停仍由 `on_mount :start_heartbeat` /
    # `on_unmount :stop_heartbeat` 驱动，`window_key :handle_window_key` 也照旧声明）。
    class Terminal < ::Market::Terminal
      # 窗口默认值：终端内容宽（三栏：自选+统计 / 图表+持仓 / 下单+成交）
      WINDOW = { title: "Citrine 行情终端 · 模拟盘（原生）", width: 1440, height: 860 }.freeze

      # 键盘：启动即用（设计 2.3 —— window_key 的快捷键由**聚焦中的 area** 转发）。
      on_mount :focus_keyboard_target

      # 窗口下限：libui 不裁剪、只会把控件挤重叠，所以给窗口一个"再小就不好用"的硬边界
      # （macOS 走 [NSWindow setContentMinSize:]；别的平台如实失败，见 native/window_size.rb）
      on_mount :apply_window_minimum

      # 面板实例：（自绘面板的 ref: 登记在**产出该元素的组件**上，不在根组件上，
      # 所以根组件要留着面板实例才能拿到 area 句柄。）
      #
      # panels 是公开读的：自绘面板的**几何**（表格 Layout / 图表 Geometry）住在面板里，
      # 测试要按"这一次绘制用的几何"去点、去断言（面板宽度由布局决定，不是常量）。
      attr_reader :panels

      def initialize(props = {})
        @panels = {}
        super
      end

      def area_handle(name)
        panel = @panels[name]
        panel&.refs&.[](name)
      end

      # 组件树。与浏览器版 Terminal#view 逐项对应，差别只在渲染目标：
      #   · 骨架（顶部条 / 持仓 / 下单 / 埋点）→ 原生控件
      #   · 数据密集区（自选表 / 走势图 / 统计与权益曲线 / 成交挂单）→ 自绘面板（area）
      # 树里**不读任何信号**（会变的值仍以取值 Proc 下发），因此本块永不重跑。
      def view
        # 根元素**必须自己声明 flex_grow: 1**（与 sheets 的 NativeApp#view 同一条 F11 判据）：
        # macOS 对窗口直系子元素宽容（不声明也把剩余空间分给 stretchy 孙辈），**Windows 的
        # libui box 是严格的**——根 box 不是 stretchy 时里面的 stretchy 子控件只按自然尺寸
        # 布局（2026-09-15 Windows 实测：三列的 area 全部塌成 0 高、Draw 一次都不触发）。
        # 声明它对 macOS 无行为差异（窗口直系子元素本来就吃满 client 区）。
        box(direction: :column, gap: 10, style: { flex_grow: 1 }) do
          render(Views::Header,
                 tick: -> { tick_value },
                 equity: -> { equity },
                 pnl: -> { unrealized_pnl },
                 total_return: -> { total_return },
                 paused: -> { paused },
                 speed: -> { speed },
                 auto_trade: -> { auto_trade },
                 on_toggle_pause: -> { toggle_pause },
                 on_speed: ->(value) { set_speed(value) },
                 on_toggle_auto: -> { toggle_auto_trade },
                 on_reset: -> { reset_account })

          # 三列：每列 flex_grow: 1 —— libui 的 stretchy 孩子**均分**剩余宽度（与各自
          # 的内容天然宽度无关），所以三列在这个窗口下各约 (窗口宽 - 留白 - 2*间距) / 3。
          # 早先不给 flex_grow 时宽度由列里原生控件的天然宽度决定（实测左 207 / 中 786 /
          # 右 395），左列的自选表 6 列只看得见 2 列 —— 见 native/views/common.rb 顶部。
          # 三列所在的 row 同样**必须 stretchy**：Windows 的严格 stretchy 链要求
          # "参与拉伸的 box 自己在父容器里有 stretchy 尺寸，逐层成立"（F11；macOS 宽容、
          # Windows 不容断链——row 不声明则三列全部回到自然高度，area 塌成 0）。
          box(direction: :row, gap: 10, style: { flex_grow: 1 }) do
            box(direction: :column, gap: 8, style: { flex_grow: 1 }) do
              @panels[:watchlist] = render(Views::Watchlist,
                                           codes: -> { row_order },
                                           name_for: ->(code) { engine_name(code) },
                                           quote_for: ->(code) { quote_of(code) },
                                           active_for: ->(code) { selected == code },
                                           held_for: ->(code) { !position_of(code).nil? },
                                           sort_key: -> { sort_key },
                                           on_sort: ->(key) { apply_sort(key) },
                                           on_pick: ->(code) { select_symbol(code) }).rendered_component
              @panels[:stats] = render(Views::Stats,
                                       ledger: -> { ledger_snapshot },
                                       equity: -> { equity_snapshot },
                                       curve: -> { account_curve },
                                       sample_every: CURVE_EVERY).rendered_component
            end

            box(direction: :column, gap: 8, style: { flex_grow: 1 }) do
              @panels[:chart] = @chart_panel = render(Views::Chart,
                                                      selected: -> { selected },
                                                      quote_for: ->(code) { quote_of(code) },
                                                      series_for: ->(code) { series_of(code) },
                                                      candles_for: ->(code, bucket) {
                                                        @engine.candles(code, bucket: bucket, limit: 48)
                                                      },
                                                      indicators_for: ->(code) { indicator_snapshot(code) }).rendered_component
              render(Views::Positions,
                     positions: -> { account_positions },
                     position_for: ->(code) { position_of(code) },
                     name_for: ->(code) { engine_name(code) },
                     quote_for: ->(code) { quote_of(code) },
                     summary: -> { position_summary },
                     on_close: ->(code) { close_position(code) },
                     on_cancel_orders: ->(code) { cancel_orders_for(code) },
                     on_close_all: -> { close_all_positions })
            end

            box(direction: :column, gap: 8, style: { flex_grow: 1 }) do
              @panels[:ticket] = @ticket_panel = render(Views::Ticket,
                                                        selected: -> { selected },
                                                        quote_for: ->(code) { quote_of(code) },
                                                        name_for: ->(code) { engine_name(code) },
                                                        position_for: ->(code) { position_of(code) },
                                                        alert: -> { alert },
                                                        notice: -> { notice },
                                                        estimate: ->(side, quantity, price) {
                                                          @account.estimate(side, quantity, price)
                                                        },
                                                        max_buy_for: ->(price) { @account.max_buy_quantity(price) },
                                                        available_for: ->(code) {
                                                          @account.available(code, @engine.tick)
                                                        },
                                                        parse_qty: ->(text) { parse_quantity(text) },
                                                        parse_px: ->(text) { parse_price(text) },
                                                        on_submit: ->(side, kind, qty_text, limit_text) {
                                                          submit_order(side, kind, qty_text, limit_text)
                                                        }).rendered_component
              @panels[:logs] = render(Views::Logs,
                                      trades: -> { account_trades },
                                      orders: -> { account_orders },
                                      on_cancel: ->(order_id) { cancel_order(order_id) }).rendered_component
            end
          end

          render(Views::DebugBar, report: -> { debug_report }, signal_count: -> { signal_inventory })
        end
      end

      # ── 平台钩子（浏览器版在 app/terminal.rb 里做同样三件事）──

      # 启动即需键盘（设计 2.3）：先激活应用，再把焦点交给自选面板。
      #   · 激活：macOS 下 uiControlShow 之后窗口不是 key window，一个键也收不到
      #     （citrine-native 的实测结论，能力暴露为 Widgets#window_activate）
      #   · 聚焦：area 句柄的 #focus（AreaHandle）→ 平台给不了就返回 false
      # 两步都可能"平台不支持"，如实失败即可——退化行为是用户先点一下面板。
      # 键位与取舍见 native/README.md。
      def focus_keyboard_target
        widgets = renderer&.widgets
        widgets&.window_activate(renderer.window)
        area_handle(:watchlist)&.focus
        self
      end

      # 最小可用窗口（值见 WindowSize::MIN_CONTENT 与 native/README.md）：
      # 低于它 OS 就拒绝缩小——这是"小窗口叠压"（MARKET-2 缺陷 B）的结构性答案：
      # 布局本身已经全拉伸自适应（面板几何从自己的尺寸推），而叠压来自 libui 在空间
      # 不够时不做裁剪，只能在窗口这一层设边界。平台不支持时返回 false，不假装成功。
      def apply_window_minimum
        window = renderer&.window
        WindowSize.enforce(window) if window
        self
      end

      # 心跳：浏览器是 `Native(window).setInterval(-> { beat }, BEAT_MS)`，原生是 every。
      # 线程模型（设计文档 2.5 + GOALS 4.4）：every 只是"后台线程 sleep + 把块排回主线程"，
      # 因此 #beat 里的信号写入与随之而来的渲染永远在主线程发生——libui 的单线程约束成立。
      def start_heartbeat
        @heartbeat_handle = Citrine::Native.every(BEAT_MS) { beat }
        self
      end

      # 句柄 #stop（on_unmount 由框架调用）；句柄可能是 nil（未挂载/已停）
      def stop_heartbeat
        @heartbeat_handle&.stop
        @heartbeat_handle = nil
        self
      end

      # 平台时钟：浏览器版 #fire_tick 里读 `Date.now()`（terminal.rb 里唯一残留的 JS），
      # CRuby 下反引号会去执行 shell 命令。原生侧换成单调时钟，其余管线（重入保护、
      # Telemetry.reset_round!、tick!、report_tick!）与原版逐行对应。
      def fire_tick
        return self if @in_tick

        @in_tick = true
        Citrine::Telemetry.reset_round!
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        tick!
        report_tick!(Num.round_to((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000, 2))
        self
      ensure
        @in_tick = false
      end
    end
  end
end

# 埋点（demo 专用，见 app/telemetry.rb）：原生这条路径同样没有框架钩子，
# 装上 Effect#run 计数，DebugBar 才有数可看。幂等；"新建控件数"不适用（无 createElement）。
Citrine::Telemetry.install!

# frozen_string_literal: true

# native 测试公共入口。
#
#   ruby native/test/run.rb                              # 跑全部（不开窗口、不需要 libui）
#   ruby -I native/test native/test/chart_data_test.rb   # 只跑一个文件
#
# 两层：
#   NativeUnitTest   —— 不挂载：纯逻辑（数据准备、心跳/交易/键盘语义）
#   NativeScreenTest —— 挂载整棵组件树到 citrine-native 的 **Memory 桩后端**：
#                       自绘面板用框架的 Painter::Recording 断言"画了什么"，
#                       指针/键盘用桩后端的 fire_click / fire_key 合成（形状与 libui 后端一致）
# 纪律与框架侧一致：**测试不开真窗口**（GOALS 风险 3）。真窗口的视觉与真实键鼠投递
# 只在 bin/native 里人工验收（设计文档 4.2：area 的事件投递需人手一次）。
root = File.expand_path("../..", __dir__)
citrine_root = ENV["CITRINE_ROOT"] || File.expand_path("../citrine", root)
native_root = ENV["CITRINE_NATIVE_ROOT"] || File.expand_path("../citrine-native", root)
libui_root = ENV["CITRINE_NATIVE_LIBUI_ROOT"] || File.expand_path("../citrine-native-libui", root)
beryl_lib = ENV["BERYL_PATH"] || File.expand_path("../beryl/lib", root)
$LOAD_PATH.unshift(File.join(root, "app"), File.join(citrine_root, "lib"),
                   File.join(native_root, "lib"), File.join(libui_root, "lib"),
                   beryl_lib)

require "minitest/autorun"
require_relative "../app"

# 原生渲染器的开发期提醒（未支持样式键等）在测试里是噪音；需要断言提醒的用例自己打开
Citrine.dev_mode = false

module Market
  module Native
    module TestSupport
      # 定时器替身：接住 Citrine::Native.every（设计文档 2.5），让"心跳 → beat → 推进档位"
      # 这条链不依赖真实时间（真定时器是后台线程，会让断言看运气）。只替换调度，不动 beat 语义。
      class FakeTimer
        attr_reader :interval_ms

        def initialize
          @stopped = false
          @block = nil
        end

        def install(interval_ms, block)
          @interval_ms = interval_ms
          @block = block
          self
        end

        def stop
          @stopped = true
          self
        end

        def stopped? = @stopped

        def fire(times = 1)
          times.times { @block.call }
          self
        end
      end

      def with_timer_stub
        timer = FakeTimer.new
        singleton = Citrine::Native.singleton_class
        original = Citrine::Native.method(:every)
        singleton.send(:define_method, :every) { |ms, &block| timer.install(ms, block) }
        yield timer
      ensure
        singleton.send(:define_method, :every) { |ms, &block| original.call(ms, &block) }
      end

      # 颜色断言：Painter 把颜色归一成 [r, g, b, a]（0..1 浮点，见 painter.rb），
      # 测试里仍按主题里的十六进制写，读起来才对得上 market.html 的 CSS 变量。
      def rgb(hex)
        digits = hex.delete_prefix("#")
        r, g, b = digits.scan(/../).map { |pair| pair.to_i(16) / 255.0 }
        [r, g, b, 1.0]
      end
    end

    # 不挂载的用例基类（纯逻辑）
    class NativeUnitTest < Minitest::Test
      include TestSupport
      include Format

      attr_reader :term

      def setup
        @term = Terminal.new
        @term.run_ticks(3)
      end

      def engine = @term.instance_variable_get(:@engine)
      def account = @term.instance_variable_get(:@account)
    end

    # 挂真桩后端的用例基类：整棵组件树 + 四个自绘面板
    class NativeScreenTest < Minitest::Test
      include TestSupport
      include Format

      attr_reader :backend, :renderer, :term, :root, :timer

      def setup
        @backend = Citrine::Native::Widgets::Memory.new
        @renderer = Citrine::Native::Renderer.new(widgets: @backend)
        with_timer_stub do |timer|
          @timer = timer
          @term = Terminal.new
          @root = @renderer.mount_component(@term, { title: "test" })
        end
        @term.run_ticks(3)
      end

      def teardown
        Citrine.unmount(@term) if @term&.root
      end

      # ── 自绘面板 ──
      # 两层句柄：应用侧拿到的是 AreaHandle（ref: 登记在产出该元素的**面板组件**上，
      # 所以走 Terminal#area_handle），桩后端的 fire_* 要的是它包着的裸控件句柄。
      #
      # 面板尺寸是**布局给的**（真窗口里由 libui 的 box 分配，见 native/README.md），
      # 桩后端没有布局引擎，所以这里显式给一份"窗口/列分配下来"的视口：
      # 取各面板原先的声明尺寸（466/252、500/232、466/236、420/190）——那组数字现在的
      # 含义是"三列等宽 + 默认窗口下的列宽"，正好也是"不截断"的舒适尺寸。
      VIEWPORTS = { watchlist: [466, 252], stats: [466, 236], chart: [500, 232], logs: [420, 190] }.freeze

      def viewport(name) = VIEWPORTS.fetch(name)

      def areas = @areas ||= @backend.find_all(@root.dom, kind: :area)

      def area(name) = @term.area_handle(name)
      def area_widget(name) = area(name)&.handle

      def draw(name, width: nil, height: nil)
        default_width, default_height = viewport(name)
        @backend.fire_draw(area_widget(name), width: width || default_width, height: height || default_height)
      end

      # 最近一帧的几何（面板自己算的；绘制与命中测试共用它）
      def layout(name) = @term.panels.fetch(name).layout
      def chart_geometry = @term.panels.fetch(:chart).geometry

      def click(name, x, y)
        @backend.fire_click(area_widget(name), x, y)
      end

      def key(name, key, **modifiers)
        @backend.fire_key(area_widget(name), key, modifiers: modifiers)
      end

      # ── 绘制记录（Recording）的读法 ──

      def texts(recording) = recording.calls_of(:text).map { |call| call[:text] }

      def text_ops_between(recording, from, to)
        recording.calls_of(:text).select { |call| call[:y] >= from && call[:y] < to }
      end

      def texts_between(recording, from, to)
        text_ops_between(recording, from, to).map { |call| call[:text] }
      end

      # ── 原生控件 ──

      def widget(kind, text = nil) = @backend.find(@root.dom, kind: kind, text: text)
      def widgets(kind) = @backend.find_all(@root.dom, kind: kind)
      def button(text) = widget(:button, text)
      def entry = widget(:entry) # 桩后端的控件种类名是 :entry（元素名才是 text_input）
      def entries = widgets(:entry)

      def click_button(text)
        target = button(text)
        refute_nil target, "找不到按钮：#{text}"
        target.fire(:click)
      end

      # 模拟在输入框里打字（受控输入：写值 + 触发 change，渲染器负责写回 Signal）
      def type_into(target, value)
        @backend.set_value(target, value)
        target.fire(:change)
      end

      def label_matching(pattern) = widgets(:label).find { |label| label.text.to_s.match?(pattern) }
      def submit_button = widgets(:button).find { |widget| widget.text.to_s.start_with?("提交") }
    end
  end
end

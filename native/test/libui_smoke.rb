# frozen_string_literal: true

# 真窗口冒烟（**不是单测**：它会开一个真窗口，几秒后自己关掉）。
#
#   export PATH="$HOME/.asdf/shims:$PATH"      # libui 只装在 asdf 的 Ruby 3.4.8 上
#   ruby native/test/libui_smoke.rb            # SMOKE_SECONDS=5 可调观测时长
#
# 为什么要它：Memory 桩后端能证明"画了什么"，证明不了"真窗口里画得出来"。这里起真 libui
# 窗口、跑**真主循环**（uiMain），几秒后用定时器收集读数并退出，覆盖设计文档 4.2 里可自动化的部分：
#   · 四个自绘面板在真 Painter 上确实产出了图元（数 emit_* 的调用）
#   · 心跳在真主循环里推进档位（后台线程 → uiQueueMain → beat）
#   · 每档收敛都排了重绘（面板随行情重画，图元数随时间增长）
#   · 有序拆解（unmount → 关窗 → uiUninit）无异常
#
# 注意：不要用 LibUI.main_step 自己泵循环——本机 libui 0.2.4 的 uiMainStep 直接段错误
# （最小复现：起一个窗口 + 一个按钮 + main_step(0) 就崩），所以这里走正常 uiMain + 定时器退出。
# 投递真实键鼠事件无法自动化（libui 的事件由 OS 产生，设计文档 4.2 也列为"人手一次"），
# 键鼠路径由 native/test 里的桩后端派发覆盖，真窗口里靠人手点一遍。
#
# 想直接看窗口：bin/native（阻塞在主循环里，关窗或 Ctrl+C 退出）。
root = File.expand_path("../..", __dir__)
citrine_root = ENV["CITRINE_ROOT"] || File.expand_path("../citrine", root)
native_root = ENV["CITRINE_NATIVE_ROOT"] || File.expand_path("../citrine-native", root)
$LOAD_PATH.unshift(File.join(root, "app"), File.join(citrine_root, "lib"), File.join(native_root, "lib"))

require "citrine-native-libui"
require_relative "../app"

SECONDS_TO_RUN = (ENV["SMOKE_SECONDS"] || 5).to_f
# 冒烟的场景（MARKET-1d）：**先买 6 只，再看四个面板**。空账户跑 4 秒的冒烟看不见
# "持仓一多走势图就没了"这类缺陷（复审用它反证过：把场景换成 6 只持仓，冒烟立刻红）。
POSITIONS = (ENV["SMOKE_POSITIONS"] || 6).to_i
BUY_AFTER_MS = 1200
# 走势图的最小可用高度：真窗口实测（持 3 / 6 / 10 / 12 / 20 只都是 164px，默认窗口 1440×860）。
# 150 给字体度量留一点余量，同时仍挡得住"持仓把中列吃光"——修复前持 6 只就是 0。
CHART_MIN_HEIGHT = 150
STDOUT.sync = true # 冒烟输出边跑边看（重定向到文件时 puts 默认是块缓冲）

# 图元计数器：真 Painter 只有一个实现类，数它调了多少次 emit_* 就知道画没画
EMITTED = Hash.new(0)
%i[emit_rect emit_line emit_polyline emit_polygon emit_text].each do |name|
  Citrine::Native::Painter.class_eval do
    alias_method :"#{name}_without_count", name
    define_method(name) do |*args, **kwargs|
      EMITTED[name] += 1
      send(:"#{name}_without_count", *args, **kwargs)
    end
  end
end

Citrine.dev_mode = true # 绘制期的"未支持用法"提醒直接打在 stderr 上：冒烟时要看见它
app = Citrine::Native.start(Market::Native::Terminal, **Market::Native::Terminal::WINDOW)
terminal = app.component
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# 逐面板计数：**每个自绘面板每档都要真的产出图元**。
# 为什么单看总数不够（MARKET-2 §7 的教训）：框架侧改动会让某个面板的 Draw 抛异常，
# 异常被适配层的 safe 吞掉，结果是"总量不为 0、但某个面板一个图元都没有"——
# 只看总量发现不了。这里按面板分别数 draws 与图元，并记下每次绘制拿到的尺寸。
PANEL_DRAWS = Hash.new(0)
PANEL_OPS = Hash.new(0)
PANEL_SIZE = {}
# 只看**自绘面板**（有 area 句柄的四个）：下单面板是纯原生控件，本来就没有 Draw
PANELS = terminal.panels.keys.select { |name| terminal.area_handle(name) }.freeze
PANELS.each do |name|
  panel = terminal.panels.fetch(name)
  panel.singleton_class.prepend(Module.new do
    define_method(:draw) do |painter|
      before = EMITTED.values.sum
      PANEL_DRAWS[name] += 1
      PANEL_SIZE[name] = [painter.width, painter.height]
      super(painter)
      PANEL_OPS[name] += EMITTED.values.sum - before
    end
  end)
end

failures = []
bought = []

# 场景：逐只买入（默认 6 只）。买完持仓面板走分页、中列仍要给走势图留高度——
# 这正是 MARKET-1d 那条 P1 的现场（修复前持 6 只时走势图 0×0）。
Citrine::Native.after(BUY_AFTER_MS) do
  terminal.row_order.first(POSITIONS).each do |code|
    terminal.select_symbol(code)
    terminal.submit_order(:buy, :market, "100", "")
    bought << code if terminal.position_of(code)
  end
  puts "场景：买入 #{bought.size} 只（每只 100 股）"
end

Citrine::Native.after((SECONDS_TO_RUN * 1000).to_i) do
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  ticks = terminal.tick_value
  draws = EMITTED.values.sum
  areas = app.renderer.widgets.instance_variable_get(:@areas).size

  puts "真主循环跑了 #{elapsed.round(2)} 秒"
  puts "档位：#{ticks}（心跳 200ms 一拍，1x 约 850ms 一档）"
  puts "持仓：#{terminal.account_positions.size} 只（计划 #{POSITIONS}）"
  puts "真 Painter 图元：#{EMITTED.map { |name, count| "#{name.to_s.delete_prefix('emit_')}=#{count}" }.join(' ')}"
  puts "自绘面板数：#{areas}"
  PANELS.each do |name|
    puts format("  %-10s draws=%d 图元=%d 最近一次尺寸=%s", name, PANEL_DRAWS[name], PANEL_OPS[name],
                PANEL_SIZE[name]&.map { |value| value.round(1) }.inspect)
  end

  failures << "行情没有跳动（档位仍为 #{ticks}）：心跳/定时器没接上？" if ticks < 1
  failures << "真 Painter 一次图元都没画：自绘面板没有收到 Draw 回调？" if draws.zero?
  failures << "自绘面板数应为 4（自选/统计/走势/成交挂单），实际 #{areas}" unless areas == 4
  failures << "自绘面板应恰好 4 个，实际 #{PANELS.size}" unless PANELS.size == 4
  expected = [POSITIONS, terminal.row_order.size].min
  failures << "买入场景没生效（只买到 #{bought.size} 只，计划 #{expected}）：持仓相关的断言就没意义了" if bought.size < expected
  PANELS.each do |name|
    failures << "#{name} 面板一次都没画（draws=0）" if PANEL_DRAWS[name].zero?
    failures << "#{name} 面板画了但一个图元都没有（draw 抛异常被 safe 吞掉？）" if PANEL_OPS[name].zero?
    width, height = PANEL_SIZE[name] || [0, 0]
    failures << "#{name} 面板拿到了 0 尺寸（#{width}×#{height}）：布局没把空间分给它" unless width.positive? && height.positive?
  end
  chart_height = (PANEL_SIZE[:chart] || [0, 0])[1]
  unless chart_height >= CHART_MIN_HEIGHT
    failures << "持 #{terminal.account_positions.size} 只时走势图只有 #{chart_height.round(1)}px 高" \
                "（应 ≥#{CHART_MIN_HEIGHT}）：中列被持仓面板吃光——持仓列表要有界（每页 " \
                "#{Market::Native::Views::Positions::PAGE_SIZE} 行 + 翻页），见 views/positions.rb"
  end
  app.quit
end

app.widgets.main_loop # 真主循环：绘制与定时器回调都在这里面发生
app.teardown

if failures.empty?
  puts "✅ 真窗口冒烟通过（键鼠投递需人手一次，见文件头）"
else
  failures.each { |message| warn "❌ #{message}" }
  exit 1
end

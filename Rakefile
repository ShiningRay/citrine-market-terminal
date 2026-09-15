# frozen_string_literal: true

# Citrine 行情终端 —— 任务入口（零依赖：只用 Ruby 标准库 + opal + node）
#
#   rake test      CRuby 内核单测（引擎 / 指标 / 账户 / 交易规则）
#   rake build     编译 app/market.rb → app/market.js
#   rake stubs     build + Node DOM 桩验收（60 项交互断言）
#   rake parity    CRuby 与 Opal 两侧内核输出逐字节比对
#   rake check     test + stubs + parity（提交前跑）
#   rake dev       启动开发服务器（热刷新）
require "rake/testtask"

ROOT = File.expand_path(__dir__)
APP = File.join(ROOT, "app")
# citrine 框架位置：与本站同级目录，或用 CITRINE_ROOT 指定
CITRINE_ROOT = ENV["CITRINE_ROOT"] || File.expand_path("../citrine", ROOT)
CITRINE_LIB = File.join(CITRINE_ROOT, "lib")

OPAL = ENV["OPAL"] || "opal"

def check_citrine!
  return if File.directory?(CITRINE_LIB)

  abort <<~MSG
    找不到 citrine 框架：#{CITRINE_ROOT}
    请把本仓库与 citrine 仓库放在同一父目录下，或设置环境变量：
      export CITRINE_ROOT=/path/to/citrine
  MSG
end

Rake::TestTask.new do |t|
  t.libs << APP
  t.libs << CITRINE_LIB
  t.test_files = FileList["test/*_test.rb"]
  t.warning = false
end

desc "编译 app/market.rb → app/market.js"
task :build do
  check_citrine!
  Dir.chdir(APP) do
    sh "#{OPAL} -c -I#{CITRINE_LIB} -I. -o market.js market.rb"
  end
end

desc "编译并运行 Node DOM 桩验收（无需浏览器）"
task stubs: :build do
  sh "node test/market_stub_check.js"
end

desc "CRuby 与 Opal 两侧内核输出一致性检查（跨平台语义回归防护）"
task :parity do
  check_citrine!
  require "tmpdir"
  cruby_out = File.join(Dir.tmpdir, "market_parity_cruby.txt")
  opal_out = File.join(Dir.tmpdir, "market_parity_opal.txt")

  Dir.chdir(APP) do
    sh "ruby -I#{CITRINE_LIB} parity.rb > #{cruby_out}"
    sh "#{OPAL} -c -I#{CITRINE_LIB} -I. -o #{File.join(Dir.tmpdir, 'market_parity.js')} parity.rb"
  end
  sh "node #{File.join(Dir.tmpdir, 'market_parity.js')} > #{opal_out}"

  if File.read(cruby_out) == File.read(opal_out)
    lines = File.readlines(cruby_out).size
    puts "✅ CRuby 与 Opal 两侧输出逐字节一致（#{lines} 行）"
  else
    sh "diff #{cruby_out} #{opal_out}"
    abort "❌ 两侧输出不一致（见上）"
  end
end

desc "提交前检查：单测 + 桩验收 + 跨平台一致性"
task check: %i[test stubs parity]

# 原生窗口移植（native/）的测试：不需要窗口、不需要 libui，只需要 citrine-native 仓库。
# 刻意不进 `check`：`check` 守的是浏览器路径，不该因为另一仓库（citrine-native）不在就红。
namespace :native do
  desc "原生视图层单测（Memory 桩后端 + Painter::Recording；需 citrine-native）"
  task :test do
    sh "ruby #{File.join(ROOT, 'native/test/run.rb')}"
  end

  desc "真窗口冒烟（会开一个真窗口，几秒后自己关；需要 libui）"
  task :smoke do
    sh "ruby #{File.join(ROOT, 'native/test/libui_smoke.rb')}"
  end
end

desc "启动 Citrine 开发服务器（热刷新；端口默认 4403）"
task :dev do
  check_citrine!
  require File.join(CITRINE_LIB, "citrine/dev_server")
  Citrine::DevServer.run!([APP, "-p", "4403"])
end

task default: :check

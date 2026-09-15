# backtick_javascript: true
# frozen_string_literal: true

# 浏览器入口：Citrine dev server 请求 market.js 时编译本文件。
#
#   bin/dev                             → 打开 http://localhost:4403/market.html
#
# 挂载完成即由组件的 on_mount 起 200ms 心跳（app/terminal.rb），全局快捷键由
# `window_key` 声明——入口本身不再持有定时器/监听器，也就没有 beforeunload 清理。
require "citrine/browser"
require_relative "tokens"
require_relative "telemetry"
require_relative "terminal"
require_relative "test_api"

# 设计令牌注入：app/tokens.rb 是唯一来源（原生 native/theme.rb 与 Format 也从它
# 派生），这里在挂载前把 :root 变量写进页面，app/styles.css 的规则全部经 var(--x) 引用。
token_style = `document.createElement("style")`
`#{token_style}.textContent = #{Market::Tokens.css_root_block}`
`document.head.appendChild(#{token_style})`

Citrine::Telemetry.install!
Market::TestApi.install!

terminal = Market::Terminal.new
Citrine::DomRenderer.mount_at("app", terminal)

Market::TestApi.expose(terminal)

# backtick_javascript: true
# frozen_string_literal: true

# 浏览器入口：Citrine dev server 请求 market.js 时编译本文件。
#
#   bin/dev                             → 打开 http://localhost:4403/market.html
require "citrine/browser"
require_relative "telemetry"
require_relative "terminal"
require_relative "browser_glue"

Citrine::Telemetry.install!

terminal = Market::Terminal.new
Citrine::DomRenderer.mount_at("app", terminal)

glue = Market::BrowserGlue.new(terminal)
glue.start
glue.expose_test_api

# 页面卸载时清掉定时器（框架无 on_unmount，只能自己挂事件）
Native(`window`).addEventListener("beforeunload", ->(_event) { glue.stop })

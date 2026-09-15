# frozen_string_literal: true

module Market
  # 设计令牌唯一来源：浏览器 CSS、浏览器视图内联样式、原生自绘三处共用。
  #
  # - 浏览器：入口（market.rb）在挂载前把 `css_root_block` 注入为
  #   `<style>:root{…}</style>`；app/styles.css 的规则全部经 var(--x) 引用，
  #   样式表里不再出现字面量色值（罕见的浏览器表现层小技巧除外，见 styles.css 注释）。
  # - 共享逻辑：Format::UP_COLOR / DOWN_COLOR 从这里取值（红涨绿跌只定义一次）。
  # - 原生：native/theme.rb 从这里派生常量，自绘代码照旧引用 Theme::XXX。
  #
  # 为什么是 Ruby 而不是 CSS：原生后端没有 CSS（样式矩阵 L1/L2 之外不可着色），
  # 令牌放 CSS 里原生就拿不到——放 Ruby 里则 Opal 与 CRuby 都能加载，天然两栖。
  # 改配色只改这一个文件；机器守卫在 test/tokens_test.rb
  # （HTML 不内联样式 / CSS 引用的每个 --var 都有令牌 / 令牌都有去向）。
  module Tokens
    MAP = {
      bg: "#070b14",
      panel: "#101827",
      panel_2: "#162034",
      line: "#1e2b45",
      text: "#e7edf7",
      dim: "#78859c",
      up: "#f6465d",    # A 股惯例：红涨
      down: "#0ecb81",  # 绿跌
      accent: "#5b8cff",
      warn: "#f0a03c",
      sma: "#38bdf8"    # 分时图的 SMA5 均线点（浏览器 .sma-dot / 原生走势图同色）
    }.freeze

    def self.[](name)
      MAP.fetch(name)
    end

    # 注入页面用的 `:root` 块（键名 snake_case → CSS 的 kebab-case）
    def self.css_root_block
      rows = MAP.map { |name, value| "  --#{name.to_s.tr('_', '-')}: #{value};" }
      ":root {\n#{rows.join("\n")}\n}"
    end
  end
end

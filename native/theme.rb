# frozen_string_literal: true

require_relative "../app/tokens"
require "format"

module Market
  module Native
    # 深色主题令牌——**常量全部从 app/tokens.rb 派生**，本文件不再出现字面量色值：
    # 设计令牌的唯一来源是 Tokens（浏览器 CSS、Format 同吃这一份），改配色只改
    # app/tokens.rb。个别只在原生存在的色值留在本文件并注明缘由（GRID）。
    #
    # 为什么要有这一层：原生后端没有 CSS（libui 的 box 没有背景/边框，label 没有颜色），
    # 视觉全部落在 Painter 调用里；令牌散在四五个自绘面板里就再也改不动了。
    module Theme
      PANEL = Tokens[:panel]
      PANEL_2 = Tokens[:panel_2]
      LINE = Tokens[:line]
      TEXT = Tokens[:text]
      DIM = Tokens[:dim]
      ACCENT = Tokens[:accent]
      WARN = Tokens[:warn]

      # 涨跌色不在这里重新定义：Format 是唯一来源（UP/DOWN/FLAT 与 value_color 都在那里，
      # 而 Format 又取自 Tokens）。自绘代码经 Common include Format，直接写
      # value_color(...) / pct_style(...) 即可。
      UP = Format::UP_COLOR       # A 股惯例：红涨
      DOWN = Format::DOWN_COLOR   # 绿跌

      # 图表网格（比 --line 更暗）：原生走势图独有，浏览器没有对应物，留在本地
      GRID = "#16233c"
      SMA = Tokens[:sma]          # 与浏览器 .sma-dot 同源
      # 最新价线：浏览器 .last-line 是 accent 的 dashed；Painter 无虚线，画实线 accent
      LAST_LINE = Tokens[:accent]

      SIZE_BASE = 12
      SIZE_SMALL = 11
    end
  end
end

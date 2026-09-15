# frozen_string_literal: true

require "format"

module Market
  module Native
    # 深色主题令牌：与 app/market.html 的 CSS 变量**同名同值**（--panel/--panel-2/--line/
    # --text/--dim/--accent/--warn），自绘代码集中引用这里的常量。
    #
    # 为什么要有这一层：原生后端没有 CSS（libui 的 box 没有背景/边框，label 没有颜色），
    # 视觉全部落在 Painter 调用里；令牌散在四五个自绘面板里就再也改不动了。
    module Theme
      PANEL = "#101827"     # --panel
      PANEL_2 = "#162034"   # --panel-2（单元格/图表底）
      LINE = "#1e2b45"      # --line
      TEXT = "#e7edf7"      # --text
      DIM = "#78859c"       # --dim
      ACCENT = "#5b8cff"    # --accent
      WARN = "#f0a03c"      # --warn

      # 涨跌色不在这里重新定义：Format 是唯一来源（UP/DOWN/FLAT 与 value_color 都在那里）。
      # 自绘代码经 Common include Format，直接写 value_color(...) / pct_style(...) 即可。
      UP = Format::UP_COLOR       # A 股惯例：红涨
      DOWN = Format::DOWN_COLOR   # 绿跌

      GRID = "#16233c"            # 图表网格（比 --line 更暗）
      SMA = "#38bdf8"             # 与 market.html 的 .sma-dot 同色
      LAST_LINE = "#5b8cff"       # 最新价线（.last-line 的 dashed 用实线替代：Painter 无虚线）

      SIZE_BASE = 12
      SIZE_SMALL = 11
    end
  end
end

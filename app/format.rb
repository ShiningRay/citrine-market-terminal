# frozen_string_literal: true

# 格式化（纯 Ruby；不使用 sprintf，规避 CRuby / Opal 的差异）
require_relative "tokens"

module Market
  module Format
    # 涨跌色唯一来源在 Tokens（浏览器 CSS 的 --up/--down、原生 theme 同吃这一份）
    UP_COLOR = Tokens[:up]     # A 股惯例：红涨
    DOWN_COLOR = Tokens[:down] # 绿跌
    FLAT_COLOR = "#8b95a8"

    module_function

    def grouped(integer)
      text = integer.to_s
      negative = text.start_with?("-")
      digits = negative ? text[1, text.length - 1] : text
      parts = []
      while digits.length > 3
        parts.unshift(digits[digits.length - 3, 3])
        digits = digits[0, digits.length - 3]
      end
      parts.unshift(digits)
      body = parts.join(",")
      negative ? "-#{body}" : body
    end

    # 1523.4 → "1,523.40"
    def money(value, digits = 2)
      return "—" if value.nil?

      negative = value.negative?
      factor = 10**digits
      scaled = (value.abs * factor).round
      whole = Num.idiv(scaled, factor)
      frac = scaled - whole * factor
      body = grouped(whole)
      body = "#{body}.#{frac.to_s.rjust(digits, '0')}" if digits > 0
      negative ? "-#{body}" : body
    end

    # 带符号金额：+1,234.56 / -12.30
    def signed_money(value, digits = 2)
      return "—" if value.nil?

      "#{value > 0 ? '+' : ''}#{money(value, digits)}"
    end

    # 比例 → "+1.23%"（入参是小数，如 0.0123）
    def pct(value, digits = 2)
      return "—" if value.nil?

      "#{value > 0 ? '+' : ''}#{money(value * 100, digits)}%"
    end

    # 绝对值百分比（振幅等）
    def pct_abs(value, digits = 2)
      return "—" if value.nil?

      "#{money(value * 100, digits)}%"
    end

    # 股数：1,000
    def qty(value)
      grouped(value.to_i)
    end

    # 成交量：4567 万 / 12.3 亿
    def volume(value)
      if value >= 100_000_000
        "#{money(value / 100_000_000.0, 2)} 亿"
      elsif value >= 10_000
        "#{money(value / 10_000.0, 1)} 万"
      else
        grouped(value.to_i)
      end
    end

    # 成交额（元）
    def amount(value)
      if value >= 100_000_000
        "#{money(value / 100_000_000.0, 2)} 亿"
      else
        "#{money(value / 10_000.0, 0)} 万"
      end
    end

    # 档位 → 交易时段时刻（A 股：09:30-11:30 / 13:00-15:00，每档 1 分钟，共 240 档）
    def session_minute(tick)
      tick % 240
    end

    def session_time(tick)
      minute = session_minute(tick)
      if minute < 120
        clock(9 * 60 + 30 + minute)
      else
        clock(13 * 60 + (minute - 120))
      end
    end

    def session_phase(tick)
      session_minute(tick) < 120 ? "上午盘" : "午后盘"
    end

    def clock(total_minutes)
      hour = Num.idiv(total_minutes, 60)
      minute = total_minutes - hour * 60
      "#{hour.to_s.rjust(2, '0')}:#{minute.to_s.rjust(2, '0')}"
    end

    def direction_arrow(direction)
      case direction
      when :up then "▲"
      when :down then "▼"
      else "—"
      end
    end

    def value_color(value)
      return FLAT_COLOR if value.nil? || value.zero?

      value > 0 ? UP_COLOR : DOWN_COLOR
    end

    def direction_color(direction)
      case direction
      when :up then UP_COLOR
      when :down then DOWN_COLOR
      else FLAT_COLOR
      end
    end

    def side_label(side)
      side == :buy ? "买入" : "卖出"
    end

    def kind_label(kind)
      kind == :market ? "市价" : "限价"
    end
  end
end

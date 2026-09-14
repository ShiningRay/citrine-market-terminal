# frozen_string_literal: true

# 数值工具（纯 Ruby）
#
# ⚠ 跨平台陷阱（CRuby vs Opal，实测于 Opal 1.8.3）：
#   1. 整数除法 `7 / 2` 在 Opal 下返回 3.5（Opal 的 Numeric#/ 就是 JS 除法，
#      见 opal/corelib/number.rb:102），CRuby 返回 3 —— **静默**语义差异。
#      凡需要整数商，一律走 Num.idiv（内部用 Integer#div，两侧语义一致）。
#   2. `(-1.5).round` CRuby 为 -2（远离零），Opal 为 -1（JS Math.round 朝 +∞）。
#      故取整一律先取绝对值再回贴符号（见 Num.round_to），保证两侧一致。
module Market
  module Num
    module_function

    # 整数除法（Ruby 语义：向负无穷取整）
    def idiv(value, divisor)
      value.div(divisor)
    end

    # digits 位小数取整，结果与 CRuby 一致（Opal 的负数 half 行为不同，故按绝对值取整）
    def round_to(value, digits)
      factor = 10**digits
      sign = value.negative? ? -1 : 1
      (value.abs * factor).round / factor.to_f * sign
    end

    def round2(value)
      round_to(value, 2)
    end

    def round1(value)
      round_to(value, 1)
    end

    def round0(value)
      round_to(value, 0)
    end
  end
end

# frozen_string_literal: true

# 技术指标（纯函数，输入数组 → 输出数值；无状态、无 DOM、可 CRuby 单测）
module Market
  module Indicators
    module_function

    # 最新一条的 N 期均线；数据不足返回 nil
    def sma(values, period)
      return nil if values.size < period

      slice = values[values.size - period, period]
      slice.inject(0.0) { |sum, v| sum + v } / period
    end

    # N 期指数均线（最新值）
    def ema(values, period)
      return nil if values.empty?

      k = 2.0 / (period + 1)
      values.inject(nil) do |prev, v|
        prev.nil? ? v.to_f : v * k + prev * (1 - k)
      end
    end

    # Wilder RSI
    def rsi(values, period = 14)
      return nil if values.size < period + 1

      gains = 0.0
      losses = 0.0
      (1..period).each do |i|
        delta = values[i] - values[i - 1]
        if delta >= 0
          gains += delta
        else
          losses -= delta
        end
      end
      avg_gain = gains / period
      avg_loss = losses / period
      i = period + 1
      while i < values.size
        delta = values[i] - values[i - 1]
        gain = delta > 0 ? delta : 0.0
        loss = delta < 0 ? -delta : 0.0
        avg_gain = (avg_gain * (period - 1) + gain) / period
        avg_loss = (avg_loss * (period - 1) + loss) / period
        i += 1
      end
      return 50.0 if avg_loss.zero? && avg_gain.zero?
      return 100.0 if avg_loss.zero?

      100.0 - 100.0 / (1.0 + avg_gain / avg_loss)
    end

    # 最大回撤（正比例：0.12 表示曾从峰值回撤 12%）
    def max_drawdown(curve)
      peak = nil
      worst = 0.0
      curve.each do |v|
        peak = v if peak.nil? || v > peak
        next if peak.nil? || peak <= 0

        drawdown = (peak - v) / peak
        worst = drawdown if drawdown > worst
      end
      worst
    end

    # 收益率标准差（逐档）
    def volatility(values)
      return 0.0 if values.size < 2

      returns = []
      i = 1
      while i < values.size
        prev = values[i - 1]
        returns << (values[i] - prev) / prev if prev > 0
        i += 1
      end
      return 0.0 if returns.empty?

      mean = returns.inject(0.0) { |a, v| a + v } / returns.size
      variance = returns.inject(0.0) { |a, v| a + (v - mean)**2 } / returns.size
      Math.sqrt(variance)
    end

    # 金叉/死叉/超买/超卖/中性 的粗判（演示用，不讲投资建议）
    def verdict(short_ma, long_ma, rsi_value)
      return "数据积累中" if short_ma.nil? || long_ma.nil?
      return "超买（RSI > 70）" if rsi_value && rsi_value > 70
      return "超卖（RSI < 30）" if rsi_value && rsi_value < 30
      return "多头排列（SMA5 > SMA20）" if short_ma > long_ma

      "空头排列（SMA5 < SMA20）"
    end
  end
end

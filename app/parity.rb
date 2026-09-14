# frozen_string_literal: true

# 跨平台一致性检查：同一份内核（引擎 / 指标 / 账户 / 格式化）在
# CRuby 与 Opal(JS) 下应给出相同输出。
#
#   rake parity          # CRuby 与 Opal 两侧编译比对（见 Rakefile）
#
# 存在意义：demo 开发中实测到一类**静默**语义差异（Opal 的整数除法返回
# Float、负数 round 方向不同），CRuby 单测全绿但浏览器里输出乱码。
# 这个脚本是那类差异的回归防护。
require_relative "engine"
require_relative "account"
require_relative "format"

def num(value, digits = 6)
  Market::Format.money(value, digits)
end

def line(label, value)
  puts "#{label}=#{value}"
end

engine = Market::Engine.new(seed: 20_260_914)
engine.advance!(60)
engine.codes.each do |code|
  q = engine.quote(code)
  series = engine.series(code)
  puts "#{code}|last=#{num(q[:last])}|chg=#{num(q[:change])}|pct=#{num(q[:change_pct])}|" \
       "high=#{num(q[:high])}|low=#{num(q[:low])}|vol=#{q[:volume]}"
  puts "  sma5=#{num(Market::Indicators.sma(series, 5))}|sma20=#{num(Market::Indicators.sma(series, 20))}|" \
       "rsi=#{num(Market::Indicators.rsi(series))}"
  closes = engine.candles(code, bucket: 5).map { |c| num(c[:close], 2) }
  puts "  candles=#{closes.join(',')}"
end

account = Market::Account.new(cash: 1_000_000.0)
buy = account.place_market(code: "600519", side: :buy, quantity: 500, price: 1_500.0, tick: 1)
line "buy", buy[:ok]
account.refresh!(2)
sell = account.place_market(code: "600519", side: :sell, quantity: 200, price: 1_520.0, tick: 2)
line "sell", sell[:ok]
line "sell_realized", num(sell[:trade].realized)
limit = account.place_limit(code: "000001", side: :buy, quantity: 1_000, limit: 10.5, tick: 2, current_price: 11.0)
line "limit", limit[:ok]
line "frozen", num(account.frozen)
fills = account.match_orders!({ "000001" => 10.4 }, tick: 3)
line "fills", fills.size
line "cash", num(account.cash)
line "positions", account.positions.keys.sort.join(",")
line "available", num(account.positions["600519"][:available], 0)
line "win_rate", num(account.win_rate)
account.mark!(1_000_000.0)
account.mark!(1_010_000.0)
account.mark!(990_000.0)
line "max_drawdown", num(Market::Indicators.max_drawdown(account.curve))
line "money", Market::Format.money(1_234_567.891)
line "money_neg", Market::Format.money(-987_654.321)
line "pct", Market::Format.pct(0.0123)
line "volume", Market::Format.volume(123_456_789)
line "time_130", Market::Format.session_time(130)
line "time_0", Market::Format.session_time(0)
line "max_buy", account.max_buy_quantity(97.5)
line "rsi_flat", num(Market::Indicators.rsi(Array.new(30) { 100.0 }))
line "round_neg", num(Market::Num.round_to(-1.005, 2))
line "grouped", Market::Format.grouped(-1_234_567)

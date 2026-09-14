# frozen_string_literal: true

# 行情终端的内核单测（纯 CRuby，不需要 Opal / 浏览器）
#
#   rake test
#
# 覆盖：模拟引擎的可复现性与涨跌停、K 线聚合、指标数学、
#       交易账户的 T+1 / 费用 / 限价撮合 / 冻结资金 / 权益曲线
require "minitest/autorun"
require "citrine"
require_relative "../app/engine"
require_relative "../app/account"

class MarketEngineTest < Minitest::Test
  def engine(seed = 7)
    Market::Engine.new(seed: seed, history: 60)
  end

  def test_same_seed_reproduces_same_series
    a = engine(11).series("600519")
    b = engine(11).series("600519")
    c = engine(12).series("600519")
    assert_equal a, b, "同 seed 必须复现同一段行情（跨平台一致）"
    refute_equal a, c, "不同 seed 应给出不同行情"
  end

  def test_warmup_leaves_full_history_and_zero_tick
    eng = engine
    assert_equal 60, eng.series("600519").size
    assert_equal 0, eng.tick
    eng.advance!(3)
    assert_equal 3, eng.tick
    assert_equal 60, eng.series("600519").size, "序列长度应稳定在 HISTORY（滑动窗口）"
  end

  def test_price_clamped_by_limit_band
    eng = engine
    eng.advance!(200)
    eng.codes.each do |code|
      q = eng.quote(code)
      assert q[:last] <= q[:limit_up] + 0.011, "#{code} 超过涨停：#{q[:last]} > #{q[:limit_up]}"
      assert q[:last] >= q[:limit_down] - 0.011, "#{code} 跌破跌停：#{q[:last]} < #{q[:limit_down]}"
    end
  end

  def test_quote_day_stats_are_consistent
    eng = engine
    eng.advance!(50)
    eng.codes.each do |code|
      q = eng.quote(code)
      assert q[:high] >= q[:last] - 0.011, "#{code} 最高价应不低于现价"
      assert q[:low] <= q[:last] + 0.011, "#{code} 最低价应不高于现价"
      assert q[:high] >= q[:open] - 0.011
      assert q[:low] <= q[:open] + 0.011
      assert q[:volume] > 0, "#{code} 成交量应随时间累积"
      assert_in_delta q[:change], q[:last] - q[:prev_close], 0.02
    end
  end

  def test_candles_aggregate_ohlc_and_volume
    eng = engine
    eng.advance!(30)
    candles = eng.candles("300750", bucket: 5)
    series = eng.series("300750")
    assert_equal 12, candles.size
    candles.each do |c|
      assert c[:high] >= c[:low]
      assert c[:high] >= c[:open] && c[:high] >= c[:close]
      assert c[:low] <= c[:open] && c[:low] <= c[:close]
      assert c[:volume] > 0
    end
    last_slice = series[series.size - 5, 5]
    assert_in_delta last_slice.max, candles.last[:high], 1e-9
    assert_in_delta last_slice.min, candles.last[:low], 1e-9
    assert_in_delta series.last, candles.last[:close], 1e-9
  end

  def test_signals_publish_latest_quote
    eng = engine
    signal = eng.quote_signal("000001")
    eng.advance!(4)
    assert_in_delta eng.price("000001"), signal.get[:last], 0.011
    assert_equal eng.tick, signal.get[:tick]
  end

  def test_unknown_symbol_raises
    assert_raises(ArgumentError) { engine.price("NOPE") }
  end
end

class MarketIndicatorsTest < Minitest::Test
  def test_sma
    values = (1..10).to_a
    assert_in_delta 8.0, Market::Indicators.sma(values, 5), 1e-9
    assert_nil Market::Indicators.sma(values, 11), "数据不足应返回 nil"
  end

  def test_rsi_bounds
    rising = (1..30).map { |i| 100.0 + i }
    falling = (1..30).map { |i| 200.0 - i }
    assert_in_delta 100.0, Market::Indicators.rsi(rising), 1e-9, "单边上涨 RSI 应为 100"
    assert Market::Indicators.rsi(falling) < 5.0, "单边下跌 RSI 应接近 0"
    assert_in_delta 50.0, Market::Indicators.rsi(Array.new(30) { 100.0 }), 1e-9, "横盘 RSI 应为 50"
    assert_nil Market::Indicators.rsi([1.0, 2.0]), "样本不足应返回 nil"
  end

  def test_max_drawdown
    assert_in_delta 0.25, Market::Indicators.max_drawdown([100.0, 120.0, 90.0, 130.0]), 1e-9
    assert_in_delta 0.0, Market::Indicators.max_drawdown([100.0, 110.0, 120.0]), 1e-9
  end

  def test_volatility_zero_for_flat_series
    assert_in_delta 0.0, Market::Indicators.volatility([100.0, 100.0, 100.0]), 1e-9
  end

  def test_verdict_branches
    assert_equal "超买（RSI > 70）", Market::Indicators.verdict(10.0, 9.0, 80.0)
    assert_equal "超卖（RSI < 30）", Market::Indicators.verdict(9.0, 10.0, 20.0)
    assert_equal "多头排列（SMA5 > SMA20）", Market::Indicators.verdict(10.0, 9.0, 55.0)
    assert_equal "空头排列（SMA5 < SMA20）", Market::Indicators.verdict(8.0, 9.0, 45.0)
    assert_equal "数据积累中", Market::Indicators.verdict(nil, nil, nil)
  end
end

class MarketAccountTest < Minitest::Test
  def account(cash: 1_000_000.0)
    Market::Account.new(cash: cash)
  end

  def test_initial_state
    acc = account(cash: 50_000.0)
    assert_in_delta 50_000.0, acc.cash, 1e-9
    assert_in_delta 50_000.0, acc.available_cash, 1e-9
    assert_empty acc.positions
    assert_nil acc.win_rate
  end

  def test_market_buy_updates_cash_and_position
    acc = account(cash: 100_000.0)
    result = acc.place_market(code: "600519", side: :buy, quantity: 100, price: 100.0, tick: 1)
    assert result[:ok], result[:message]
    # 佣金 = max(100*100*0.00025=2.5, 最低 5) = 5
    assert_in_delta 100_000.0 - 10_005.0, acc.cash, 1e-9
    position = acc.positions["600519"]
    assert_equal 100, position[:quantity]
    assert_equal 0, position[:available], "T+1：当日买入的批次不可用"
    assert_in_delta 100.05, position[:avg_cost], 1e-9
    assert_in_delta 5.0, acc.fees, 1e-9
  end

  def test_quantity_validation
    acc = account
    bad = acc.place_market(code: "600519", side: :buy, quantity: 150, price: 100.0, tick: 1)
    refute bad[:ok]
    assert_includes bad[:message], "整数倍"
    refute acc.place_market(code: "600519", side: :buy, quantity: 0, price: 100.0, tick: 1)[:ok]
    refute acc.place_market(code: "600519", side: :buy, quantity: -100, price: 100.0, tick: 1)[:ok]
    assert_in_delta 1_000_000.0, acc.cash, 1e-9, "校验失败不应动账"
  end

  def test_insufficient_funds_rejected
    acc = account(cash: 1_000.0)
    result = acc.place_market(code: "600519", side: :buy, quantity: 100, price: 100.0, tick: 1)
    refute result[:ok]
    assert_includes result[:message], "资金不足"
    assert_in_delta 1_000.0, acc.cash, 1e-9
  end

  def test_t_plus_one_blocks_same_day_sell
    acc = account(cash: 100_000.0)
    acc.place_market(code: "600519", side: :buy, quantity: 100, price: 100.0, tick: 5)
    blocked = acc.place_market(code: "600519", side: :sell, quantity: 100, price: 110.0, tick: 5)
    refute blocked[:ok]
    assert_includes blocked[:message], "T+1"

    acc.refresh!(6)
    assert_equal 100, acc.positions["600519"][:available], "次日该批次解锁"
    sold = acc.place_market(code: "600519", side: :sell, quantity: 100, price: 110.0, tick: 6)
    assert sold[:ok], sold[:message]
  end

  def test_sell_realizes_profit_and_closes_position
    acc = account(cash: 100_000.0)
    acc.place_market(code: "600519", side: :buy, quantity: 100, price: 100.0, tick: 1)
    acc.refresh!(2)
    result = acc.place_market(code: "600519", side: :sell, quantity: 100, price: 110.0, tick: 2)
    assert result[:ok], result[:message]
    trade = result[:trade]
    # 净收入 = 11000 - 佣金 5 - 印花税 5.5 = 10989.5；成本 10005 → 已实现 984.5
    assert_in_delta 984.5, trade.realized, 1e-9
    assert_in_delta 5.5, trade.tax, 1e-9
    assert_empty acc.positions, "清仓后不应再持有该标的"
    assert_in_delta 1.0, acc.win_rate, 1e-9
    assert_equal 1, acc.closed_trades
    assert_in_delta 984.5, acc.realized, 1e-9
    assert_in_delta 100_000.0 + 984.5, acc.cash, 1e-6
  end

  def test_sell_without_position_rejected
    acc = account
    result = acc.place_market(code: "600519", side: :sell, quantity: 100, price: 100.0, tick: 1)
    refute result[:ok]
    assert_includes result[:message], "未持有"
  end

  def test_limit_order_freezes_funds_and_fills_on_cross
    acc = account(cash: 100_000.0)
    order = acc.place_limit(code: "600519", side: :buy, quantity: 100, limit: 90.0,
                            tick: 1, current_price: 100.0)
    assert order[:ok], order[:message]
    assert_equal 1, acc.orders.size
    assert_in_delta 9_002.25, acc.frozen, 1e-9, "限价买单应冻结 limit*数量*(1+佣金率)"
    assert_in_delta 100_000.0 - 9_002.25, acc.available_cash, 1e-9

    fills = acc.match_orders!({ "600519" => 95.0 }, tick: 2)
    assert_empty fills, "价格未触及限价不应成交"
    assert_equal 1, acc.orders.size

    fills = acc.match_orders!({ "600519" => 89.5 }, tick: 3)
    assert_equal 1, fills.size
    trade = fills.first
    assert_equal :buy, trade.side
    assert_in_delta 89.5, trade.price, 1e-9, "以限价与市价中更有利者成交"
    assert_empty acc.orders
    assert_in_delta 0.0, acc.frozen, 1e-9, "成交后应解冻"
    assert_equal 100, acc.positions["600519"][:quantity]
  end

  def test_limit_order_with_touch_price_fills_immediately
    acc = account(cash: 100_000.0)
    result = acc.place_limit(code: "600519", side: :buy, quantity: 100, limit: 105.0,
                             tick: 1, current_price: 100.0)
    assert result[:ok], result[:message]
    assert_includes result[:message], "即时成交"
    assert_empty acc.orders
    assert_in_delta 100.0, acc.trades.first.price, 1e-9
  end

  def test_cancel_order_releases_frozen_funds
    acc = account(cash: 100_000.0)
    acc.place_limit(code: "600519", side: :buy, quantity: 100, limit: 80.0, tick: 1, current_price: 100.0)
    id = acc.orders.first.id
    result = acc.cancel_order(id, tick: 1)
    assert result[:ok], result[:message]
    assert_empty acc.orders
    assert_in_delta 0.0, acc.frozen, 1e-9
    assert_in_delta 100_000.0, acc.available_cash, 1e-9
    refute acc.cancel_order(id, tick: 1)[:ok], "重复撤单应失败"
  end

  def test_frozen_funds_cannot_be_double_spent
    acc = account(cash: 10_000.0)
    first = acc.place_limit(code: "600519", side: :buy, quantity: 100, limit: 90.0, tick: 1, current_price: 100.0)
    assert first[:ok], first[:message]
    second = acc.place_limit(code: "000001", side: :buy, quantity: 100, limit: 60.0, tick: 1, current_price: 100.0)
    refute second[:ok], "冻结资金后应不再有足够可用资金"
    assert_includes second[:message], "资金不足"
  end

  def test_limit_price_outside_band_rejected
    acc = account(cash: 100_000.0)
    result = acc.place_limit(code: "600519", side: :buy, quantity: 100, limit: 200.0, tick: 1,
                             current_price: 100.0, band: { up: 110.0, down: 90.0 })
    refute result[:ok]
    assert_includes result[:message], "涨跌停"
  end

  def test_max_buy_quantity_respects_lot_size_and_fees
    acc = account(cash: 10_000.0)
    qty = acc.max_buy_quantity(97.5)
    assert_equal 100, qty
    assert qty % 100 == 0
    assert acc.estimate(:buy, qty, 97.5)[:total] <= 10_000.0
  end

  def test_minimum_commission_applies_to_small_orders
    acc = account(cash: 100_000.0)
    acc.place_market(code: "000001", side: :buy, quantity: 100, price: 10.0, tick: 1)
    assert_in_delta 5.0, acc.fees, 1e-9, "小额成交佣金应为最低 5 元"
  end

  def test_ledger_snapshot_skips_identical_values
    acc = account(cash: 100_000.0)
    acc.place_market(code: "600519", side: :buy, quantity: 100, price: 100.0, tick: 1)
    snapshot = acc.ledger
    acc.refresh!(1)
    assert snapshot.equal?(acc.ledger), "快照无变化时 Signal#set 应跳过、对象身份不变"
    acc.refresh!(2)
    refute snapshot.equal?(acc.ledger), "T+1 解锁后可用数量变化，应发布新快照"
  end

  def test_equity_curve_is_bounded
    acc = account
    300.times { |i| acc.mark!(1_000_000.0 + i) }
    assert_equal Market::Account::CURVE_LIMIT, acc.curve.size
    assert_in_delta 1_000_060.0, acc.curve.first, 1e-9, "应保留最近的 240 个采样点"
    assert_in_delta 1_000_299.0, acc.curve.last, 1e-9
  end

  def test_metrics_without_curve
    acc = account
    metrics = acc.metrics
    assert_in_delta 0.0, metrics[:max_drawdown], 1e-9
    assert_nil metrics[:win_rate]
    assert_equal 0, metrics[:closed]
  end
end

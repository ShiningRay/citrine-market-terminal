# frozen_string_literal: true

# 模拟交易账户（纯 Ruby：不含 Opal / DOM 依赖，可在 CRuby 下单测）
#
# 业务规则（按 A 股现货惯例简化）：
#   - 100 股整手，佣金万 2.5、最低 5 元，卖出加收千 0.5 印花税
#   - T+1：当日买入的批次当日不可卖（Lot#buy_tick < 当前档位 才可用）
#   - 限价单挂单时冻结资金；成交/撤单解冻；市价单即时成交
#   - 全部状态以快照 Hash 经 Citrine::Signal 发布：值不变时 Signal#set 自动跳过
require "citrine"
require_relative "num"
require_relative "format"
require_relative "indicators"

module Market
  # 持仓批次：cost 为该批次总成本（含买入费用）
  Lot = Struct.new(:quantity, :cost, :buy_tick)

  # 委托：frozen 为挂单冻结资金（仅买入限价单）
  Order = Struct.new(:id, :code, :side, :quantity, :limit, :placed_tick, :frozen)

  # 成交回报：realized 仅卖出有值
  Trade = Struct.new(:id, :code, :side, :quantity, :price, :fee, :tax, :realized, :tick)

  class Account
    COMMISSION_RATE = 0.00025
    MIN_COMMISSION = 5.0
    STAMP_TAX_RATE = 0.0005
    LOT_SIZE = 100
    MAX_QUANTITY = 1_000_000
    TRADE_LIMIT = 40
    CURVE_LIMIT = 240

    attr_reader :initial_cash

    def initialize(cash: 1_000_000.0, tick: 0)
      @initial_cash = cash.to_f
      @cash = @initial_cash
      @frozen = 0.0
      @lots = {}
      @realized = 0.0
      @realized_by_code = {}
      @fees = 0.0
      @closed = 0
      @wins = 0
      @orders = []
      @trades = []
      @curve = []
      @order_seq = 0
      @trade_seq = 0
      @ledger_signal = Citrine::Signal.new(build_ledger(tick))
      @orders_signal = Citrine::Signal.new([])
      @trades_signal = Citrine::Signal.new([])
      @curve_signal = Citrine::Signal.new([])
    end

    # ── 响应式读取（在 block / computed 中读取即建立依赖）──────────

    def ledger
      @ledger_signal.get
    end

    def cash
      ledger[:cash]
    end

    def available_cash
      ledger[:available_cash]
    end

    def frozen
      ledger[:frozen]
    end

    def positions
      ledger[:positions]
    end

    def position_codes
      ledger[:positions].keys
    end

    def realized
      ledger[:realized]
    end

    def fees
      ledger[:fees]
    end

    def closed_trades
      ledger[:closed]
    end

    def win_rate
      closed = ledger[:closed]
      closed.zero? ? nil : ledger[:wins].to_f / closed
    end

    def orders
      @orders_signal.get
    end

    def trades
      @trades_signal.get
    end

    def curve
      @curve_signal.get
    end

    def frozen_amount
      @frozen
    end

    # 埋点用：账本 / 挂单 / 成交 / 曲线 四个信号 + 组件内动态信号
    def signal_count
      4
    end

    # ── 查询 ────────────────────────────────────────────────

    # 可用（可卖）数量：T+1 下当日买入不可用
    def available(code, tick)
      lots = @lots[code]
      return 0 if lots.nil?

      total = 0
      lots.each { |lot| total += lot.quantity if lot.buy_tick < tick }
      total
    end

    def quantity_of(code)
      lots = @lots[code]
      return 0 if lots.nil?

      total = 0
      lots.each { |lot| total += lot.quantity }
      total
    end

    def estimate(side, quantity, price)
      gross = Num.round_to(quantity * price, 2)
      fee = commission(gross)
      tax = side == :sell ? Num.round_to(gross * STAMP_TAX_RATE, 2) : 0.0
      {
        gross: gross, fee: fee, tax: tax,
        total: side == :buy ? Num.round_to(gross + fee, 2) : Num.round_to(gross - fee - tax, 2)
      }
    end

    # 最大可买（按整手向下取整）
    def max_buy_quantity(price)
      return 0 if price.nil? || price <= 0

      budget = available_cash
      per_lot = price * LOT_SIZE * (1 + COMMISSION_RATE)
      return 0 if per_lot <= 0

      lots = (budget / per_lot).floor
      [lots * LOT_SIZE, MAX_QUANTITY].min
    end

    # ── 交易 ────────────────────────────────────────────────

    def place_market(code:, side:, quantity:, price:, tick:)
      error = validate_quantity(quantity)
      return failure(error) if error

      execute(code: code, side: side, quantity: quantity, price: price, tick: tick, kind: :market)
    end

    def place_limit(code:, side:, quantity:, limit:, tick:, current_price: nil, band: nil)
      error = validate_quantity(quantity)
      return failure(error) if error
      error = validate_limit(limit, band)
      return failure(error) if error

      limit = Num.round_to(limit, 2)
      frozen = side == :buy ? Num.round_to(limit * quantity * (1 + COMMISSION_RATE), 2) : 0.0
      if side == :buy && frozen > available_cash
        return failure("可用资金不足：需冻结 #{Num.round_to(frozen, 2)}，可用 #{Num.round_to(available_cash, 2)}")
      end
      if side == :sell && quantity > available(code, tick)
        return failure(sell_error(code, quantity, tick))
      end

      @order_seq += 1
      order = Order.new(@order_seq, code, side, quantity, limit, tick, frozen)
      @orders << order
      @frozen += frozen
      publish!(tick)

      filled = current_price ? match_orders!({ code => current_price }, tick: tick) : []
      trade = filled.find { |f| !f.is_a?(Hash) }
      if trade
        success("限价单即时成交：#{Format.side_label(side)} #{Format.qty(quantity)} 股 @ #{Format.money(trade.price)}")
      else
        success("已挂单：#{Format.side_label(side)} #{Format.qty(quantity)} 股 @ 限价 #{Format.money(limit)}")
      end
    end

    def cancel_order(order_id, tick:)
      order = @orders.find { |o| o.id == order_id }
      return failure("委托不存在或已成交") if order.nil?

      @orders.delete(order)
      @frozen -= order.frozen
      @frozen = 0.0 if @frozen < 0
      publish!(tick)
      success("已撤单：#{Format.side_label(order.side)} #{Format.qty(order.quantity)} 股 @ #{Format.money(order.limit)}")
    end

    # 逐档撮合挂单：价格触及即成交（以限价与市价中更有利者成交）
    def match_orders!(prices, tick:)
      return [] if @orders.empty?

      fills = []
      changed = false
      @orders.dup.each do |order|
        price = prices[order.code]
        next if price.nil?

        hit = order.side == :buy ? price <= order.limit : price >= order.limit
        next unless hit

        exec_price = order.side == :buy ? [order.limit, price].min : [order.limit, price].max
        result = execute(code: order.code, side: order.side, quantity: order.quantity,
                         price: Num.round_to(exec_price, 2), tick: tick, kind: :limit,
                         unfreeze: order.frozen)
        @orders.delete(order)
        changed = true
        if result[:ok]
          fills << result[:trade]
        else
          fills << { rejected: order, reason: result[:message] }
        end
      end
      publish!(tick) if changed
      fills
    end

    # 追加权益曲线采样点
    def mark!(equity)
      @curve << Num.round_to(equity, 2)
      @curve.shift if @curve.size > CURVE_LIMIT
      @curve_signal.set(@curve.dup)
      self
    end

    # T+1 解锁等"随时间变化"的派生状态：重建快照（值不变时 Signal#set 自动跳过）
    def refresh!(tick)
      publish!(tick)
      self
    end

    def metrics
      {
        max_drawdown: Indicators.max_drawdown(curve),
        win_rate: win_rate,
        closed: closed_trades,
        realized: realized,
        fees: fees
      }
    end

    private

    def execute(code:, side:, quantity:, price:, tick:, kind:, unfreeze: 0.0)
      if side == :buy
        est = estimate(:buy, quantity, price)
        return failure("可用资金不足：需 #{Format.money(est[:total])}，可用 #{Format.money(available_cash + unfreeze)}") if est[:total] > available_cash + unfreeze

        @cash -= est[:total]
        @frozen -= unfreeze
        @frozen = 0.0 if @frozen < 0
        @fees += est[:fee]
        (@lots[code] ||= []) << Lot.new(quantity, est[:total], tick)
        trade = Trade.new(next_trade_id, code, :buy, quantity, price, est[:fee], 0.0, 0.0, tick)
        @trades.unshift(trade)
        @trades = @trades.first(TRADE_LIMIT)
        publish!(tick)
        return success("成交：买入 #{Format.qty(quantity)} 股 @ #{Format.money(price)}（手续费 #{Format.money(est[:fee])}）", trade)
      end

      available_qty = available(code, tick)
      return failure(sell_error(code, quantity, tick)) if quantity > available_qty

      est = estimate(:sell, quantity, price)
      cost_part = consume_lots(code, quantity, tick)
      realized = Num.round_to(est[:total] - cost_part, 2)
      @cash += est[:total]
      @fees += est[:fee] + est[:tax]
      @realized += realized
      @realized_by_code[code] = Num.round_to((@realized_by_code[code] || 0.0) + realized, 2)
      @closed += 1
      @wins += 1 if realized > 0
      trade = Trade.new(next_trade_id, code, :sell, quantity, price, est[:fee], est[:tax], realized, tick)
      @trades.unshift(trade)
      @trades = @trades.first(TRADE_LIMIT)
      publish!(tick)
      success("成交：卖出 #{Format.qty(quantity)} 股 @ #{Format.money(price)}" \
              "（已实现盈亏 #{Format.signed_money(realized)}，费用 #{Format.money(est[:fee] + est[:tax])}）", trade)
    end

    # FIFO 消耗可用批次（跳过 T+1 锁定的批次），返回消耗掉的成本
    def consume_lots(code, quantity, tick)
      lots = @lots[code] || []
      remaining = quantity
      cost = 0.0
      kept = []
      lots.each do |lot|
        if remaining > 0 && lot.buy_tick < tick
          take = lot.quantity < remaining ? lot.quantity : remaining
          unit_cost = lot.cost / lot.quantity
          cost += unit_cost * take
          remaining -= take
          left = lot.quantity - take
          kept << Lot.new(left, lot.cost - unit_cost * take, lot.buy_tick) if left > 0
        else
          kept << lot
        end
      end
      @lots[code] = kept
      Num.round_to(cost, 2)
    end

    def commission(gross)
      value = gross * COMMISSION_RATE
      value = MIN_COMMISSION if value < MIN_COMMISSION
      Num.round_to(value, 2)
    end

    def validate_quantity(quantity)
      return "数量必须是正整数" unless quantity.is_a?(Integer) && quantity > 0
      return "单笔数量超过上限 #{Format.qty(MAX_QUANTITY)} 股" if quantity > MAX_QUANTITY
      return "数量须为 #{LOT_SIZE} 股（1 手）的整数倍" if quantity % LOT_SIZE != 0

      nil
    end

    def validate_limit(limit, band)
      return "限价必须是正数" unless limit.is_a?(Numeric) && limit > 0

      if band && (limit > band[:up] || limit < band[:down])
        return "限价超出涨跌停区间 #{Format.money(band[:down])} ~ #{Format.money(band[:up])}"
      end

      nil
    end

    def sell_error(code, quantity, tick)
      held = quantity_of(code)
      if held.zero?
        "未持有 #{code}，无法卖出"
      else
        locked = held - available(code, tick)
        if locked > 0 && quantity <= held
          "可用持仓不足：持仓 #{Format.qty(held)} 股，其中 #{Format.qty(locked)} 股为当日买入（T+1 次日可卖）"
        else
          "可用持仓不足：可用 #{Format.qty(available(code, tick))} 股，委托 #{Format.qty(quantity)} 股"
        end
      end
    end

    def build_ledger(tick)
      positions = {}
      @lots.each do |code, lots|
        next if lots.empty?

        quantity = 0
        cost = 0.0
        usable = 0
        lots.each do |lot|
          quantity += lot.quantity
          cost += lot.cost
          usable += lot.quantity if lot.buy_tick < tick
        end
        next if quantity.zero?

        positions[code] = {
          code: code, quantity: quantity, available: usable,
          cost: Num.round_to(cost, 2), avg_cost: Num.round_to(cost / quantity, 2),
          realized: @realized_by_code[code] || 0.0
        }
      end
      {
        cash: Num.round_to(@cash, 2),
        frozen: Num.round_to(@frozen, 2),
        available_cash: Num.round_to(@cash - @frozen, 2),
        positions: positions,
        realized: Num.round_to(@realized, 2),
        fees: Num.round_to(@fees, 2),
        closed: @closed,
        wins: @wins
      }
    end

    def publish!(tick)
      @ledger_signal.set(build_ledger(tick))
      @orders_signal.set(@orders.dup)
      @trades_signal.set(@trades.dup)
    end

    def publish_orders!
      @orders_signal.set(@orders.dup)
    end

    def next_trade_id
      @trade_seq += 1
    end

    def success(message, trade = nil)
      { ok: true, message: message, trade: trade }
    end

    def failure(message)
      { ok: false, message: message }
    end
  end
end

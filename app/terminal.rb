# backtick_javascript: true
# frozen_string_literal: true

# 行情终端主组件。
#
# 本组件同时是**唯一的挂载根**与**心跳的所有者**：tick 快慢取决于 paused / speed
# 两个 state，所以定时器跟着状态走（on_mount 起、on_unmount 停），不再由外挂层
# 持 window 引用代管（从前是 app/browser_glue.rb，见 FRICTION.md 的 F7/F10）。
#
# 架构说明（citrine v1 的两个硬约束决定了这里的分工）：
#   1. **无组件嵌套**：所有面板都是本组件的私有方法（views/ 下按面板拆成 module
#      mixin），状态只能全部挂在这一个类上。相关缺口见同仓库 FRICTION.md 的 F5。
#   2. **块级重建的粒度 = 信号读取的层级**：读在叶子 block 里 → 更新只改
#      textContent（0 个元素重建）；读在容器 block 里 → 整个子树重建。
#      本文件因此严格遵守两条纪律：
#        - 根 view / 各面板容器块**不读任何信号**，保证结构不随 tick 抖动；
#        - 每个会变的数字都在最内层的小块里读（价格、盈亏…）；需要随值变的
#          外观（颜色/选中态）用**响应式属性**（`css_class:` / `style:` 传 Proc）
#          落在该节点自己的属性 Effect 上，只重设属性、不重建子树（F4 → G-2 落地）。
require "native"
require "citrine"
require_relative "engine"
require_relative "account"
require_relative "indicators"
require_relative "format"
require_relative "num"
require_relative "telemetry"
require_relative "views/common"
require_relative "views/header"
require_relative "views/watchlist"
require_relative "views/chart"
require_relative "views/ticket"
require_relative "views/positions"
require_relative "views/logs"
require_relative "views/stats"
require_relative "views/debug"

module Market
  class Terminal < Citrine::Component
    include Format
    include Views::Header
    include Views::Watchlist
    include Views::ChartPanel
    include Views::Ticket
    include Views::Positions
    include Views::Logs
    include Views::Stats
    include Views::DebugBar

    SEED = 20_260_914
    INITIAL_CASH = 1_000_000.0
    CURVE_EVERY = 3          # 权益曲线采样间隔（档）
    AUTO_TRADE_EVERY = 5     # 自动交易间隔（档）
    NOTICE_TICKS = 40        # 提示信息存活档数
    BEAT_MS = 200            # 心跳间隔（固定的调度节拍）
    TICK_MS = 850            # 1x 速度下一档的间隔

    # 生命周期与全局键盘（F7/F10 → G-9/G-10）：心跳的起停与 window 键盘的绑定
    # 都交给框架，卸载时自动解绑——从前这两件事由 app/browser_glue.rb 代管。
    on_mount :start_heartbeat
    on_unmount :stop_heartbeat
    window_key :handle_window_key

    state :paused, default: false
    state :speed, default: 1
    state :selected, default: "600519"
    state :side, default: :buy
    state :order_kind, default: :market
    state :qty_text, default: "100"
    state :limit_text, default: ""
    state :chart_mode, default: :candle
    state :chart_bucket, default: 3
    state :log_tab, default: :trades
    state :sort_key, default: :code
    state :auto_trade, default: false
    state :row_order, default: []
    state :notice, default: { kind: :info, text: "本地模拟盘：数据为随机生成，与真实行情无关" }
    state :alert, default: nil
    state :debug_report, default: {}

    # 只读派生：全部由 ledger 快照 + 各标的行情信号驱动（依赖自动收集）
    computed(:market_value) do
      @account.positions.values.inject(0.0) { |sum, p| sum + p[:quantity] * price_of(p[:code]) }
    end

    computed(:equity) { @account.cash + market_value }

    computed(:unrealized_pnl) do
      @account.positions.values.inject(0.0) do |sum, p|
        sum + p[:quantity] * (price_of(p[:code]) - p[:avg_cost])
      end
    end

    computed(:total_return) { equity / INITIAL_CASH - 1.0 }

    computed(:max_drawdown) { Market::Indicators.max_drawdown(@account.curve) }

    def initialize(props = {})
      super
      @engine = Market::Engine.new(seed: SEED)
      @account = Market::Account.new(cash: INITIAL_CASH)
      @trader_rng = Market::Rng.new(SEED + 7)
      @notice_expire = 0
      @beat_accumulated = 0   # 心跳累积毫秒（够一档才推进，见 #beat）
      @heartbeat_handle = nil
      @in_tick = false
      self.row_order = @engine.codes
      @account.mark!(equity_now)
    end

    def view
      box(css_class: "term", direction: :column, gap: 12) do
        render_header
        box(css_class: "term-grid", direction: :row, gap: 12) do
          box(css_class: "col col-left", direction: :column, gap: 12) do
            render_watchlist
            render_stats
          end
          box(css_class: "col col-mid", direction: :column, gap: 12) do
            render_chart
            render_positions
          end
          box(css_class: "col col-right", direction: :column, gap: 12) do
            render_ticket
            render_logs
          end
        end
        render_debug
      end
    end

    # ── tick 管线（由本组件的心跳驱动；SSR / 桩测试手动调用 tick! / run_ticks）──

    # 心跳的起停跟着组件生命周期（F7 → G-10）：挂载后由框架调用，卸载时自动停。
    #
    # 定时器状态（累积毫秒 / 重入标记）留在本组件上——它们是"这个盘口跑到哪儿了"
    # 的一部分，只有持有 paused / speed 的对象才能正确解释（从前由外挂层代管）。
    def start_heartbeat
      @heartbeat_handle = Native(`window`).setInterval(-> { beat }, BEAT_MS)
      self
    end

    def stop_heartbeat
      Native(`window`).clearInterval(@heartbeat_handle) if @heartbeat_handle
      @heartbeat_handle = nil
      self
    end

    # 一次心跳：按倍速累积时间，够一档就推进（暂停时只是不累积）
    def beat
      return self if paused

      @beat_accumulated += BEAT_MS
      delay = Num.idiv(TICK_MS, speed) # 整数除法必须走 Num.idiv（Opal 的 / 返回浮点）
      return self if @beat_accumulated < delay

      @beat_accumulated = 0
      fire_tick
      self
    end

    def fire_tick
      return self if @in_tick

      @in_tick = true
      Citrine::Telemetry.reset_round!
      started = `Date.now()`
      tick!
      report_tick!(`Date.now()` - started)
      self
    ensure
      @in_tick = false
    end

    def tick!
      return self if paused

      @engine.advance!(1)
      @account.refresh!(@engine.tick)
      fills = @account.match_orders!(@engine.prices, tick: @engine.tick)
      @account.mark!(equity_now) if (@engine.tick % CURVE_EVERY).zero?
      auto_trade_step if auto_trade && (@engine.tick % AUTO_TRADE_EVERY).zero?
      announce(fills)
      expire_notice
      self
    end

    def advance!(steps)
      steps.times { tick! }
      self
    end

    def report_tick!(elapsed_ms)
      self.debug_report = Citrine::Telemetry.snapshot!(elapsed_ms)
      self
    end

    def run_ticks(count)
      count.to_i.times { tick! }
      self
    end

    # 桩验收脚本读取的状态快照（demo 专用，非框架 API）
    def test_state_text
      position = position_of(selected)
      [
        "tick=#{@engine.tick}",
        "paused=#{paused}",
        "speed=#{speed}",
        "selected=#{selected}",
        "side=#{side}",
        "kind=#{order_kind}",
        "qty=#{qty_text}",
        "cash=#{money(account_cash)}",
        "available_cash=#{money(account_available_cash)}",
        "frozen=#{money(account_frozen)}",
        "equity=#{money(equity_now)}",
        "positions=#{account_positions.size}",
        "held=#{position ? position[:quantity] : 0}",
        "held_available=#{position ? position[:available] : 0}",
        "orders=#{account_orders.size}",
        "trades=#{account_trades.size}",
        "realized=#{money(account_realized)}",
        "fees=#{money(account_fees)}",
        "alert=#{alert ? alert[:text] : ''}",
        "notice=#{notice[:text]}",
        "sort=#{sort_key}",
        "last=#{num_for_state(@engine.quote(selected)[:last])}",
        "bid=#{num_for_state(@engine.quote(selected)[:bid])}",
        "ask=#{num_for_state(@engine.quote(selected)[:ask])}",
        "effects=#{Citrine::Telemetry.last_effect_runs.to_i}",
        "nodes=#{Citrine::Telemetry.last_node_creates.to_i}",
        "elapsed=#{Citrine::Telemetry.last_elapsed_ms.to_i}"
      ].join("|")
    end

    def equity_now
      total = @account.cash
      @account.positions.each_value { |p| total += p[:quantity] * price_of(p[:code]) }
      total
    end

    # ── 响应式读取（视图层唯一入口）─────────────────────────

    def tick_value
      @engine.tick_signal.get
    end

    def quote_of(code)
      @engine.quote_signal(code).get
    end

    def series_of(code)
      @engine.series_signal(code).get
    end

    def price_of(code)
      @engine.price(code)
    end

    def indicator_snapshot(code)
      series = series_of(code)
      sma5 = Market::Indicators.sma(series, 5)
      sma20 = Market::Indicators.sma(series, 20)
      rsi = Market::Indicators.rsi(series)
      {
        sma5: sma5, sma20: sma20, rsi: rsi,
        volatility: Market::Indicators.volatility(series),
        verdict: Market::Indicators.verdict(sma5, sma20, rsi)
      }
    end

    def account_positions
      @account.positions
    end

    def account_cash
      @account.cash
    end

    def account_available_cash
      @account.available_cash
    end

    def account_frozen
      @account.frozen
    end

    def account_realized
      @account.realized
    end

    def account_fees
      @account.fees
    end

    def account_win_rate
      @account.win_rate
    end

    def account_closed_trades
      @account.closed_trades
    end

    def account_curve
      @account.curve
    end

    def account_orders
      @account.orders
    end

    def account_trades
      @account.trades
    end

    def position_of(code)
      @account.positions[code]
    end

    def selected_position
      position_of(selected)
    end

    def initial_cash
      INITIAL_CASH
    end

    def engine_name(code)
      @engine.name(code)
    end

    # 非响应式读取：用于事件处理器（点击时才求值，不建立依赖）
    def live_quote(code = nil)
      @engine.quote(code || selected)
    end

    # ── 全局键盘（F10 → G-9）────────────────────────────────
    #
    # 从前这段在 app/browser_glue.rb 里自持 window 引用 + 靠 beforeunload 清理；
    # 现在用 `window_key :handle_window_key` 声明，随卸载由框架自动解绑。
    # 事件是平台无关的 Citrine::KeyEvent（ev.key / ev.prevent_default）；
    # 只有"按下的目标是不是输入框"这件事没有平台无关表示，走 ev.raw 读原生事件。
    def handle_window_key(ev)
      target = ev.raw ? ev.raw[:target] : nil
      tag = target ? target[:tagName].to_s.upcase : ""
      # 输入框内的按键交给控件自身（Enter 由 text_input 的 on_enter 处理）
      return self if tag == "INPUT"

      case ev.key
      when " "
        ev.prevent_default
        toggle_pause
      when "1" then set_speed(1)
      when "2" then set_speed(2)
      when "3" then set_speed(4)
      when "ArrowUp" then step_symbol(-1)
      when "ArrowDown" then step_symbol(1)
      when "b", "B" then set_side(:buy)
      when "s", "S" then set_side(:sell)
      when "Enter" then submit_order
      when "Escape" then clear_notice
      end
      self
    end

    # ── 交互动作 ────────────────────────────────────────────

    def select_symbol(code)
      self.selected = code
      self.chart_bucket = 3
      self
    end

    def set_side(value)
      self.side = value
      self
    end

    def set_order_kind(value)
      self.order_kind = value
      self
    end

    def set_chart_mode(mode)
      self.chart_mode = mode
      self
    end

    def set_chart_bucket(bucket)
      self.chart_bucket = bucket
      self
    end

    def set_log_tab(tab)
      self.log_tab = tab
      self
    end

    def toggle_pause
      self.paused = !paused
      self
    end

    def pause
      self.paused = true
      self
    end

    def resume
      self.paused = false
      self
    end

    def set_speed(value)
      self.speed = value
      self.paused = false
      self
    end

    def toggle_auto_trade
      self.auto_trade = !auto_trade
      set_notice(auto_trade ? :info : :info, auto_trade ? "自动交易已开启（每 5 档随机下单）" : "自动交易已关闭")
      self
    end

    def apply_sort(key)
      self.sort_key = key
      quotes = @engine.codes.map { |code| @engine.quote(code) }
      sorted =
        case key
        when :change then quotes.sort_by { |q| -q[:change_pct] }.map { |q| q[:code] }
        when :amount then quotes.sort_by { |q| -q[:volume] }.map { |q| q[:code] }
        else quotes.map { |q| q[:code] }
        end
      self.row_order = sorted
      self
    end

    def set_quantity(text)
      self.qty_text = text
      self
    end

    def set_limit_price(text)
      self.limit_text = text
      self
    end

    def step_symbol(delta)
      order = row_order
      index = order.index(selected) || 0
      target = (index + delta) % order.size
      select_symbol(order[target])
    end

    def fill_quantity_with(quantity)
      self.qty_text = quantity.to_s
      self
    end

    def use_max_quantity
      quote = @engine.quote(selected)
      quantity = if side == :buy
                   @account.max_buy_quantity(quote[:ask])
                 else
                   @account.available(selected, @engine.tick)
                 end
      self.qty_text = quantity.to_s
      self
    end

    def submit_order
      quantity = parse_quantity(qty_text)
      if quantity.nil?
        self.alert = { ok: false, text: "数量无效：请输入 100 的整数倍（如 100 / 500 / 1000）" }
        return self
      end

      quote = @engine.quote(selected)
      exec_price = side == :buy ? quote[:ask] : quote[:bid]
      result =
        if order_kind == :market
          @account.place_market(code: selected, side: side, quantity: quantity,
                                price: exec_price, tick: @engine.tick)
        else
          limit = parse_price(limit_text)
          if limit.nil?
            { ok: false, message: "限价无效：请输入正数价格（当前买一 #{money(quote[:bid])}）" }
          else
            @account.place_limit(code: selected, side: side, quantity: quantity, limit: limit,
                                 tick: @engine.tick, current_price: exec_price,
                                 band: { up: quote[:limit_up], down: quote[:limit_down] })
          end
        end
      self.alert = { ok: result[:ok], text: result[:message] }
      set_notice(result[:ok] ? :ok : :warn, result[:message])
      self
    end

    def cancel_order(order_id)
      result = @account.cancel_order(order_id, tick: @engine.tick)
      self.alert = { ok: result[:ok], text: result[:message] }
      set_notice(result[:ok] ? :info : :warn, result[:message])
      self
    end

    def close_position(code)
      quantity = @account.available(code, @engine.tick)
      if quantity <= 0
        self.alert = { ok: false, text: "#{code} 暂无可卖持仓（T+1 锁定或未持有）" }
        return self
      end

      result = @account.place_market(code: code, side: :sell, quantity: quantity,
                                     price: @engine.bid(code), tick: @engine.tick)
      self.alert = { ok: result[:ok], text: result[:message] }
      set_notice(result[:ok] ? :ok : :warn, result[:message])
      self
    end

    def reset_account
      @account = Market::Account.new(cash: INITIAL_CASH)
      @account.mark!(equity_now)
      @trader_rng = Market::Rng.new(SEED + 7)
      self.alert = nil
      set_notice(:info, "账户已重置为初始资金 #{money(INITIAL_CASH)}")
      self
    end

    # 一键清仓：卖出全部可卖持仓（当日买入受 T+1 限制，卖不掉）
    def close_all_positions
      codes = @account.position_codes
      if codes.empty?
        self.alert = { ok: false, text: "当前没有持仓" }
        return self
      end

      sold = 0
      codes.each do |code|
        quantity = @account.available(code, @engine.tick)
        next if quantity <= 0

        result = @account.place_market(code: code, side: :sell, quantity: quantity,
                                       price: @engine.bid(code), tick: @engine.tick)
        sold += 1 if result[:ok]
      end
      if sold.positive?
        set_notice(:ok, "已清仓 #{sold} 只标的的可卖持仓")
      else
        set_notice(:warn, "没有可卖持仓：当日买入受 T+1 限制，次档才可卖")
      end
      self
    end

    def cancel_orders_for(code)
      orders = @account.orders.select { |order| order.code == code }
      if orders.empty?
        self.alert = { ok: false, text: "#{code} 当前没有挂单" }
        return self
      end

      orders.each { |order| @account.cancel_order(order.id, tick: @engine.tick) }
      set_notice(:info, "已撤销 #{code} 的 #{orders.size} 笔挂单")
      self
    end

    def curve_sample_every
      CURVE_EVERY
    end

    def signal_inventory
      @engine.signal_count + @account.signal_count
    end

    def clear_notice
      self.notice = { kind: :info, text: "" }
      self
    end

    private

    def auto_trade_step
      codes = @engine.codes
      code = codes[(@trader_rng.next_float * codes.size).to_i]
      quote = @engine.quote(code)
      available = @account.available(code, @engine.tick)
      if @trader_rng.next_float < 0.45 && available >= 100
        quantity = 100 * (1 + (@trader_rng.next_float * 4).to_i)
        quantity = available if quantity > available
        @account.place_market(code: code, side: :sell, quantity: quantity,
                              price: quote[:bid], tick: @engine.tick)
      else
        affordable = @account.max_buy_quantity(quote[:ask])
        ratio = 0.15 + @trader_rng.next_float * 0.25
        quantity = Num.idiv((affordable * ratio).to_i, 100) * 100
        return if quantity < 100

        @account.place_market(code: code, side: :buy, quantity: quantity,
                              price: quote[:ask], tick: @engine.tick)
      end
    end

    def announce(fills)
      return if fills.empty?

      fill = fills.last
      if fill.is_a?(Hash)
        order = fill[:rejected]
        set_notice(:warn, "限价单未成交已自动撤销：#{fill[:reason]}（#{order.code}）")
      else
        set_notice(:ok, "挂单成交：#{side_label(fill.side)} #{fill.code} #{qty(fill.quantity)} 股 @ #{money(fill.price)}")
      end
    end

    def set_notice(kind, text)
      @notice_expire = @engine.tick + NOTICE_TICKS
      self.notice = { kind: kind, text: text }
    end

    def expire_notice
      return if notice[:text].to_s.empty?
      return if @engine.tick < @notice_expire

      self.notice = { kind: :info, text: "" }
    end

    def parse_quantity(text)
      cleaned = text.to_s.strip.gsub(",", "")
      return nil unless cleaned.match(/\A\d+\z/)

      value = cleaned.to_i
      value.zero? ? nil : value
    end

    def parse_price(text)
      cleaned = text.to_s.strip.gsub(",", "")
      return nil unless cleaned.match(/\A\d+(\.\d{1,2})?\z/)

      value = cleaned.to_f
      value.positive? ? value : nil
    end

    # 桩验收用：去掉千分位，便于 JS 侧直接 parseFloat
    def num_for_state(value)
      money(value).delete(",")
    end
  end
end

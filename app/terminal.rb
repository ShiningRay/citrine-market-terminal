# backtick_javascript: true
# frozen_string_literal: true

# 行情终端根组件：**模型状态的唯一所有者** + 组件树的根。
#
# 组件结构（P0-1 落地：面板是真正的子组件，不再是"单类 + mixin"，见 FRICTION F5/F6）：
#
#   Terminal ──┬── Header                    顶部：时段 / 账户总览 / 运行控制（只读）
#              ├── Watchlist ── WatchRow×10  自选行情（key = 股票代码）
#              ├── Stats                     账户统计 + 权益曲线
#              ├── Chart                     蜡烛 / 分时（取样粒度 = 面板自己的 state）
#              ├── Positions ── PositionRow×N 持仓（key = 股票代码）
#              ├── Ticket                    下单草稿 = 面板自己的 state
#              ├── Logs ── TradeRow / OrderRow 成交与挂单（key = 成交号 / 委托号）
#              └── DebugBar                  每档埋点
#
# 分工：
#   · 本组件持有**全局模型状态**——engine / account / 心跳（paused·speed·auto_trade）/
#     选中标的 / 排序键与行顺序 / 提示与告警 / 埋点报告——以及全部交易动作。
#   · 面板自己的 UI 局部状态（下单草稿、图表取样粒度、日志标签页、行内展示）归面板，
#     相关事件与校验就近处理；根组件只在需要时转发（如 Enter → 面板 #submit）。
#   · 面板通过**取值 Proc** 读模型（props 里放 `->(code) { quote_of(code) }` 这类闭包，
#     闭包 self = 本组件）：读信号发生在面板自己的叶子块/属性 Effect 里，订阅就落在那里。
#     ——**不要**改成"本组件把值读出来再传下去"：props 一变，keyed 子组件就会重建
#       （框架 S1 语义），而且父块读信号会让整棵树跟着调和，逐档行情下这是明确的退化。
#       唯一可以传值的是永不变化的东西（股票代码、名称）。
#
# 仍然成立的纪律（块级重建语义，改视图前先读 app/views/common.rb）：
#   1. 根 view / 各面板容器块**不读任何信号**，结构不随逐档行情抖动；
#   2. 会变的数字在最内层的小块里读（价格、盈亏…）→ 只改文字、0 个元素重建；
#   3. 随值变的外观用**响应式属性**（css_class: / style: 传 Proc），落在该节点自己的
#      属性 Effect 上，只重设属性、不重建子树（F4 → G-2 落地）。
#   已退休的纪律：**输入框所在的块不读信号**——keyed/位置复用落地后，重跑的块会命中同一批
#   节点，输入框不再被重建（见 app/views/ticket.rb）。
#
# 心跳的起停跟着组件生命周期（on_mount / on_unmount）：tick 快慢取决于 paused / speed
# 两个 state，所以定时器跟着状态走，不再由外挂层持 window 引用代管
# （从前是 app/browser_glue.rb，见 FRICTION.md 的 F7/F10）。
require "native"
require "citrine"
require "beryl"
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

    # 子组件（P0-1 写法 A）：`components Watchlist` → view 里用 `watchlist(…)` 渲染。
    components Views::Header
    components Views::Watchlist
    components Views::Stats
    components Views::Chart
    components Views::Positions
    components Views::Ticket
    components Views::Logs
    components Views::DebugBar

    SEED = 20_260_914
    INITIAL_CASH = 1_000_000.0
    CURVE_EVERY = 3          # 权益曲线采样间隔（档）
    AUTO_TRADE_EVERY = 5     # 自动交易间隔（档）
    BEAT_MS = 200            # 心跳间隔（固定的调度节拍）
    TICK_MS = 850            # 1x 速度下一档的间隔

    # 生命周期与全局键盘（F7/F10 → G-9/G-10）：心跳的起停与 window 键盘的绑定
    # 都交给框架，卸载时自动解绑——从前这两件事由 app/browser_glue.rb 代管。
    on_mount :start_heartbeat
    on_unmount :stop_heartbeat
    window_key :handle_window_key

    # ── 全局模型状态 ────────────────────────────────────────
    # 面板自己的 UI 状态不在这里（下单草稿在 Ticket、取样粒度在 Chart、标签页在 Logs）。
    state :paused, default: false
    state :speed, default: 1
    state :selected, default: "600519"
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
      @toasts = Citrine.signal_list([])   # 瞬时通知队列（push_bounded 封顶，F9）
      @beat_accumulated = 0   # 心跳累积毫秒（够一档才推进，见 #beat）
      @heartbeat_handle = nil
      @in_tick = false
      @chart_panel = nil      # 挂载时由 view 记下面板实例（换股时要复位图表取样粒度）
      @ticket_panel = nil     # 同上（键盘与验收读数要读面板自己的草稿状态）
      self.row_order = @engine.codes
      @account.mark!(equity_now)
    end

    # 组件树。这里只传**取值 Proc 与回调**，不读任何信号：
    # 本方法所在的块因此永不重跑，面板也不会因为"父块重跑"而整棵调和。
    def view
      box(css_class: "term", direction: :column, gap: 12) do
        header(
          tick: -> { tick_value },
          equity: -> { equity },
          pnl: -> { unrealized_pnl },
          total_return: -> { total_return },
          paused: -> { paused },
          speed: -> { speed },
          auto_trade: -> { auto_trade },
          on_toggle_pause: -> { toggle_pause },
          on_speed: ->(value) { set_speed(value) },
          on_toggle_auto: -> { toggle_auto_trade },
          on_reset: -> { reset_account }
        )

        box(css_class: "term-grid", direction: :row, gap: 12) do
          box(css_class: "col col-left", direction: :column, gap: 12) do
            watchlist(
              codes: -> { row_order },
              name_for: ->(code) { engine_name(code) },
              quote_for: ->(code) { quote_of(code) },
              active_for: ->(code) { selected == code },
              held_for: ->(code) { !position_of(code).nil? },
              sort_key: -> { sort_key },
              on_sort: ->(key) { apply_sort(key) },
              on_pick: ->(code) { select_symbol(code) }
            )
            stats(
              ledger: -> { ledger_snapshot },
              equity: -> { equity_snapshot },
              curve: -> { account_curve },
              sample_every: CURVE_EVERY
            )
          end

          box(css_class: "col col-mid", direction: :column, gap: 12) do
            @chart_panel = chart(
              selected: -> { selected },
              quote_for: ->(code) { quote_of(code) },
              series_for: ->(code) { series_of(code) },
              candles_for: ->(code, bucket) { @engine.candles(code, bucket: bucket, limit: 48) },
              indicators_for: ->(code) { indicator_snapshot(code) }
            ).rendered_component
            positions(
              positions: -> { account_positions },
              position_for: ->(code) { position_of(code) },
              name_for: ->(code) { engine_name(code) },
              quote_for: ->(code) { quote_of(code) },
              summary: -> { position_summary },
              on_close: ->(code) { close_position(code) },
              on_cancel_orders: ->(code) { cancel_orders_for(code) },
              on_close_all: -> { close_all_positions }
            )
          end

          box(css_class: "col col-right", direction: :column, gap: 12) do
            @ticket_panel = ticket(
              selected: -> { selected },
              quote_for: ->(code) { quote_of(code) },
              name_for: ->(code) { engine_name(code) },
              position_for: ->(code) { position_of(code) },
              alert: -> { alert },
              estimate: ->(side, quantity, price) { @account.estimate(side, quantity, price) },
              max_buy_for: ->(price) { @account.max_buy_quantity(price) },
              available_for: ->(code) { @account.available(code, @engine.tick) },
              parse_qty: ->(text) { parse_quantity(text) },
              parse_px: ->(text) { parse_price(text) },
              on_submit: ->(side, kind, qty_text, limit_text) { submit_order(side, kind, qty_text, limit_text) }
            ).rendered_component
            logs(
              trades: -> { account_trades },
              orders: -> { account_orders },
              on_cancel: ->(order_id) { cancel_order(order_id) }
            )
          end
        end

        debug_bar(report: -> { debug_report }, signal_count: -> { signal_inventory })
        toast_stack
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

    # 桩验收脚本读取的状态快照（demo 专用，非框架 API）。
    # 下单草稿（side / kind / qty）现在归 Ticket 面板所有，读数从面板取。
    def test_state_text
      position = position_of(selected)
      [
        "tick=#{@engine.tick}",
        "paused=#{paused}",
        "speed=#{speed}",
        "selected=#{selected}",
        "side=#{ticket_panel.side}",
        "kind=#{ticket_panel.order_kind}",
        "qty=#{ticket_panel.qty_text}",
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

    # 子组件句柄：键盘路径与验收读数需要调用面板自己的方法
    def chart_panel
      @chart_panel
    end

    def ticket_panel
      @ticket_panel
    end

    def equity_now
      total = @account.cash
      @account.positions.each_value { |p| total += p[:quantity] * price_of(p[:code]) }
      total
    end

    # ── 响应式读取（视图层唯一入口）─────────────────────────
    # 这些方法由面板的取值 Proc 调用；读信号发生在**面板的块**里，订阅也就落在那里。

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

    # 面板用的快照聚合：一次调用读齐一组信号，订阅落在调用它的那个块上
    def ledger_snapshot
      {
        initial: initial_cash,
        available: account_available_cash,
        frozen: account_frozen,
        realized: account_realized,
        fees: account_fees,
        closed: account_closed_trades,
        win_rate: account_win_rate
      }
    end

    def equity_snapshot
      {
        equity: equity,
        total_return: total_return,
        pnl: unrealized_pnl,
        drawdown: max_drawdown
      }
    end

    def position_summary
      {
        market: market_value,
        pnl: unrealized_pnl,
        available: account_available_cash,
        frozen: account_frozen
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
    #
    # 涉及下单草稿的键（B/S/Enter）转发给 Ticket 面板——草稿状态归它所有。
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
      when "b", "B" then ticket_panel.set_side(:buy)
      when "s", "S" then ticket_panel.set_side(:sell)
      when "Enter" then ticket_panel.submit
      when "Escape" then clear_notice
      end
      self
    end

    # ── 交互动作（全局性的：选中标的 / 排序 / 心跳 / 账户）────────

    def select_symbol(code)
      self.selected = code
      chart_panel.reset_bucket # 换股后图表取样粒度复位（面板自己的状态由面板复位）
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

    def step_symbol(delta)
      order = row_order
      index = order.index(selected) || 0
      target = (index + delta) % order.size
      select_symbol(order[target])
    end

    # ── 交易动作（账户状态与提示都在本组件）──────────────────

    # Ticket 面板通过 on_submit 回调把草稿交过来：撮合与提示在这里。
    def submit_order(side, kind, quantity_text, limit_text)
      quantity = parse_quantity(quantity_text)
      if quantity.nil?
        self.alert = { ok: false, text: "数量无效：请输入 100 的整数倍（如 100 / 500 / 1000）" }
        return self
      end

      quote = @engine.quote(selected)
      exec_price = side == :buy ? quote[:ask] : quote[:bid]
      result =
        if kind == :market
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

    # 右下角 toast 堆叠：ListSignal 快照枚举 + 到期按序号删（beryl demo 同款）
    def toast_stack
      @toasts.each_with_index do |t, i|
        Beryl::Toast.new(msg: t["text"], kind: t["kind"], duration_ms: 3500,
                         on_expire: -> { @toasts.delete_at(i) }).view
      end
    end

    def clear_notice
      @toasts.replace([])
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

    # 瞬时通知：镜像写进 notice（test_state_text / 调试读数用），渲染走 toast 队列
    # （Beryl::Toast 的 auto_dismiss 到期自删，不再按 tick 数手写过期）
    def set_notice(kind, text)
      self.notice = { kind: kind, text: text }
      @toasts.push_bounded({ "kind" => TOAST_KINDS.fetch(kind, "info"), "text" => text }, 4)
      self
    end

    TOAST_KINDS = { info: "info", ok: "success", warn: "warn" }.freeze

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

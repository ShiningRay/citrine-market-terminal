# frozen_string_literal: true

# 行情模拟引擎（纯 Ruby：不含 Opal / DOM 依赖，可在 CRuby 下单测）
#
# 设计：
#   - 每只标的一条随机游走（几何布朗 + 波动聚集 + 小概率跳空），±10% 涨跌停夹紧
#   - 逐档保留最近 HISTORY 档的价格与成交量，蜡烛图按 bucket 现场聚合
#   - 行情以 Citrine::Signal 发布（Signal 属平台无关核心），UI 只读信号
require "citrine"
require_relative "num"

module Market
  # 可复现随机源（MINSTD / Lehmer）。
  # 不用 Kernel#rand / Random.new：Opal 侧的 Random 与 CRuby 实现不一致；
  # 48271 * 2^31 ≈ 1.04e14 < 2^53，CRuby 与 JS 数值语义一致，同一 seed 结果相同。
  class Rng
    MODULUS = 2_147_483_647
    MULTIPLIER = 48_271

    def initialize(seed)
      state = seed.to_i % MODULUS
      state = 1 if state <= 0
      @state = state
    end

    def next_float
      @state = (@state * MULTIPLIER) % MODULUS
      @state / MODULUS.to_f
    end

    def gaussian
      u1 = next_float
      u1 = 1e-9 if u1 < 1e-9
      Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math::PI * next_float)
    end

    def chance(probability)
      next_float < probability
    end
  end

  # 标的定义：code / name / sector / base 基准价 / vol 逐档波动 / drift 漂移 / lot_volume 每档基础成交量
  Spec = Struct.new(:code, :name, :sector, :base, :vol, :drift, :lot_volume)

  CATALOG = [
    Spec.new("600519", "贵州茅台", "白酒", 1520.00, 0.0042, 0.00012, 26_000),
    Spec.new("000858", "五粮液", "白酒", 138.60, 0.0048, 0.00010, 120_000),
    Spec.new("300750", "宁德时代", "新能源", 226.30, 0.0061, 0.00015, 260_000),
    Spec.new("002594", "比亚迪", "新能源", 268.40, 0.0056, 0.00014, 180_000),
    Spec.new("601318", "中国平安", "金融", 48.72, 0.0039, 0.00008, 420_000),
    Spec.new("600036", "招商银行", "金融", 36.15, 0.0031, 0.00007, 380_000),
    Spec.new("000001", "平安银行", "金融", 11.28, 0.0034, 0.00005, 560_000),
    Spec.new("601899", "紫金矿业", "有色", 17.86, 0.0052, 0.00011, 700_000),
    Spec.new("688981", "中芯国际", "半导体", 52.40, 0.0072, 0.00016, 520_000),
    Spec.new("600030", "中信证券", "券商", 24.65, 0.0058, 0.00012, 620_000)
  ].freeze

  class Engine
    HISTORY = 120            # 保留的逐档数（也是预热档数）
    LIMIT_PCT = 0.10         # 涨跌停 ±10%
    JUMP_PROB = 0.012        # 单档跳空概率
    JUMP_SCALE = 3.2         # 跳空力度
    SPREAD_RATE = 0.0004     # 买卖价差（市价单按买一/卖一成交）

    # 单只标的的行情状态（纯数据，不参与响应式）
    class Book
      attr_reader :spec, :prices, :volumes
      attr_accessor :last, :prev, :prev_close, :open, :high, :low, :volume, :vol_state, :ticks

      def initialize(spec)
        @spec = spec
        @last = spec.base.to_f
        @prev = @last
        @prices = []
        @volumes = []
        @volume = 0.0
        @vol_state = 1.0
        @ticks = 0
        @high = @last
        @low = @last
        @open = @last
        @prev_close = @last
      end

      # 预热结束、正式开盘：以当前价作为昨收/开盘，当日统计清零
      def open_session!
        @prev_close = @last
        @open = @last
        @high = @last
        @low = @last
        @volume = 0.0
      end

      def direction
        return :up if @last > @prev
        return :down if @last < @prev

        :flat
      end
    end

    attr_reader :tick

    def initialize(seed: 20_260_914, specs: CATALOG, history: HISTORY)
      @rng = Rng.new(seed)
      @history = history
      @tick = 0
      @books = {}
      @quote_signals = {}
      @series_signals = {}
      @tick_signal = Citrine::Signal.new(0)
      specs.each do |spec|
        @books[spec.code] = Book.new(spec)
      end
      warmup
    end

    def codes
      @books.keys
    end

    def spec(code)
      book(code).spec
    end

    def name(code)
      spec(code).name
    end

    # 最新价（普通读取，不建立依赖）
    def price(code)
      book(code).last
    end

    # 卖一价（买入成交价）
    def ask(code)
      Num.round2(book(code).last * (1 + SPREAD_RATE / 2))
    end

    # 买一价（卖出成交价）
    def bid(code)
      Num.round2(book(code).last * (1 - SPREAD_RATE / 2))
    end

    # 响应式：档位计数信号
    def tick_signal
      @tick_signal
    end

    # 埋点用：已创建的信号对象数
    def signal_count
      1 + @quote_signals.size + @series_signals.size
    end

    def prices
      out = {}
      @books.each { |code, b| out[code] = b.last }
      out
    end

    def series(code, limit = @history)
      book(code).prices.last(limit)
    end

    # 响应式：最新行情快照信号（每档更新）
    def quote_signal(code)
      @quote_signals[code] ||= Citrine::Signal.new(quote(code))
    end

    # 响应式：序列快照信号（节流用：仅每 chart_every 档更新一次）
    def series_signal(code)
      @series_signals[code] ||= Citrine::Signal.new(series(code))
    end

    def quote(code)
      b = book(code)
      spec = b.spec
      change = b.last - b.prev_close
      volume = b.volume.round
      {
        code: spec.code, name: spec.name, sector: spec.sector,
        last: Num.round2(b.last), prev_close: Num.round2(b.prev_close),
        open: Num.round2(b.open), high: Num.round2(b.high), low: Num.round2(b.low),
        change: Num.round2(change),
        change_pct: b.prev_close.zero? ? 0.0 : change / b.prev_close,
        amplitude: b.prev_close.zero? ? 0.0 : (b.high - b.low) / b.prev_close,
        volume: volume,
        amount: Num.round0(volume * b.last),
        bid: Num.round2(b.last * (1 - SPREAD_RATE / 2)),
        ask: Num.round2(b.last * (1 + SPREAD_RATE / 2)),
        direction: b.direction,
        limit_up: Num.round2(b.prev_close * (1 + LIMIT_PCT)),
        limit_down: Num.round2(b.prev_close * (1 - LIMIT_PCT)),
        limit_up_hit: b.last >= Num.round2(b.prev_close * (1 + LIMIT_PCT)) - 0.01,
        limit_down_hit: b.last <= Num.round2(b.prev_close * (1 - LIMIT_PCT)) + 0.01,
        tick: @tick
      }
    end

    # OHLC 聚合（从逐档序列现场聚合，bucket = 每根蜡烛的档数）
    def candles(code, bucket: 3, limit: 40)
      b = book(code)
      prices = b.prices
      volumes = b.volumes
      count = Num.idiv(prices.size, bucket)
      count = limit if count > limit
      out = []
      start = prices.size - count * bucket
      count.times do |i|
        base = start + i * bucket
        slice = prices[base, bucket]
        vol = volumes[base, bucket].inject(0.0) { |sum, v| sum + v }
        out << { open: slice.first, high: slice.max, low: slice.min,
                 close: slice.last, volume: vol }
      end
      out
    end

    # 推进 steps 档，并发布全部行情信号
    def advance!(steps = 1, chart_every: 3)
      steps.times { step! }
      publish!(chart_every)
      self
    end

    private

    def book(code)
      @books.fetch(code) { raise ArgumentError, "未知标的: #{code}" }
    end

    def warmup
      @history.times { |i| step!(silent: true) }
      @books.each_value(&:open_session!)
      @tick = 0
      publish!(1)
    end

    def step!(silent: false)
      @tick += 1 unless silent
      @books.each_value do |b|
        spec = b.spec
        z = @rng.gaussian
        shock = @rng.chance(JUMP_PROB) ? @rng.gaussian * JUMP_SCALE : 0.0
        # 波动聚集：高波动之后仍是高波动
        b.vol_state = b.vol_state * 0.985 + 0.015 * (1.0 + z.abs)
        ret = spec.drift + spec.vol * b.vol_state * (z + shock)
        price = clamp_limit(b.last * Math.exp(ret), b)
        price = Num.round2(price)
        price = b.last if price <= 0
        b.prev = b.last
        b.last = price
        b.high = price if price > b.high
        b.low = price if price < b.low
        b.ticks += 1 unless silent
        tick_volume = volume_for(b, ret)
        b.volume += tick_volume
        b.prices << price
        b.volumes << tick_volume
        b.prices.shift if b.prices.size > @history
        b.volumes.shift if b.volumes.size > @history
      end
    end

    # 单档成交量：基础量 × 噪声 × 相对波动强度（放量跟随波动）
    def volume_for(book, ret)
      base = book.spec.lot_volume
      noise = 0.35 + @rng.next_float * 1.3
      intensity = 1.0 + 6.0 * ret.abs / book.spec.vol
      base * noise * intensity
    end

    def clamp_limit(price, book)
      up = book.prev_close * (1 + LIMIT_PCT)
      down = book.prev_close * (1 - LIMIT_PCT)
      return up if price > up
      return down if price < down

      price
    end

    def publish!(chart_every)
      @tick_signal.set(@tick)
      @books.each do |code, _b|
        @quote_signals[code]&.set(quote(code))
        next if @tick % chart_every != 0

        @series_signals[code]&.set(series(code))
      end
    end
  end
end

# frozen_string_literal: true

require_relative "../theme"

module Market
  module Native
    module Views
      # 原生视图层的公共构件（DOM 版对应 app/views/common.rb）。
      #
      # 与 DOM 版的根本差别：libui 的 label 没有颜色/字号，box 没有背景/边框，
      # 所以分工是——
      #   · **骨架**（面板标题、按钮、输入框、汇总文字）用原生控件拼；
      #   · **数据密集区**（表格、图表、曲线）用 area 自绘（设计文档 2.1/2.2）。
      # 本模块只提供这两侧的公共小件：骨架构件（panel_frame / state_button / paint_panel）、
      # 自绘表格几何（Grid / Grid::Layout）、单元格文本与值域映射（cell_text / plot_y）。
      #
      # ── 布局是**拉伸式**的：没有一处固定像素宽（MARKET-1c 的教训）──
      # libui 的 box 只认两件事：`gap`（间距）与 stretchy（孩子要不要吃掉剩余空间）。
      # 没有 CSS 意义上的 width/height：`size:` 只对**滚动面板**生效，而且只设"滚动内容
      # 尺寸"，不参与布局占位——所以"面板就是 SIZE 那么大"曾经是个错误假设：三列宽度
      # 只由列里原生控件（label/button）的**天然宽度**决定，实测左列只拿到 207px（声明
      # 466），自选表 6 列只看得见 2 列、账户统计右半全在视口外（真窗口证据见
      # MARKET-2 §4）。修法是两条，都在 app 侧：
      #   1. **三列各自 flex_grow: 1**（app.rb）：libui 的 stretchy 孩子**均分**剩余空间，
      #      与各自的天然宽度无关 → 1440 窗口下三列各约 466；
      #   2. **面板不声明尺寸、不自绘到固定宽度**：area 用 `scroll: false` + flex_grow
      #      撑满所在格子，绘制与命中测试的几何从当次 Painter 的尺寸推出
      #      （painter.width/height，即设计 2.2 的 content_size；非滚动面板下它等于
      #      clip_rect，就是这块面板的可见区）。窗口变化时面板尺寸跟着变，绘制的列宽
      #      按权重重新分配，超出列宽的文字自己截断——**不会**再有"内容比视口宽，
      #      要靠鼠标横向滚动才看得见"的半盲状态。
      #
      # ── 哪些面板要 flex_grow（真窗口量出来的规则）──
      # 含自绘面板（area）的框**必须** stretchy：libui 的 box 只把空间分给 stretchy 的孩子，
      # 而"面板框"（box）与"自绘面板"（area）的自然尺寸都是 0——不给自己要空间，每列就只有
      # 第一个面板能被分配尺寸、后面的面板永远收不到 Draw 回调（真窗口实测：四个面板里
      # 只有自选与走势被画）。反过来，纯原生控件的面板（下单/持仓）**不能** stretchy：
      # libui 的 box 最小尺寸 ≈ stretchy 孩子数 ×（其中最大的天然高度），把下单面板也算进去
      # 会让窗口最小高度翻倍（实测：全部 stretchy 时内容下限 1264×936，窗口几乎缩不动）。
      # 分界就是 panel_frame 的 stretch: 参数：**这块面板是数据区，还是固定几行控件**。
      #
      # ── watch: 为什么保留（尽管今天的兜底已经够用）──
      # 消融实验：把四个 watch: 全删掉，桩测试全绿、真窗口每 4 秒的图元数逐项相同——
      # 粗粒度兜底确实覆盖了它，但那依赖一个隐含前提："每档都有块在读 tick"（顶部的档位
      # label）。watch: 是设计 2.4 的第一条路径、也是"这个面板依赖什么"的显式声明，
      # 代价是每个面板一个 lambda。
      module Common
        include Format

        # 自绘表格：**列权重 + 行高 + 表头高**（不再是列宽常量——面板宽度由布局决定，
        # 见本文件顶部）。三张表（自选 / 成交 / 挂单）共用这一份几何定义；
        # `#layout(width)` 把它落到某块面板的实际宽度上，**绘制与命中测试都从同一个
        # Layout 取坐标**——各写一套是"点得动的格子画错位置"的唯一来源。
        #
        # 列 = [权重, 对齐, 表头文案, 排序键（nil = 不可排序）]，权重是相对宽度
        # （原实现里那一组像素列宽，直接当权重用：比例不变，宽度随面板走）。
        class Grid
          # 列间呼吸位：**左对齐的列**统一往右让出这么多（见 Layout#content_x）。
          # 起因：右对齐的数值顶在列右缘，紧接着就是下一列的第一个字——会贴成
          # "123,631.90撤单"（MARKET-2 记录的「冻结资金|操作 表头粘连、撤单单元格紧贴数字」）。
          CELL_GAP = 10

          # 右对齐数值列**左侧**的呼吸位（MARKET-1d 的 P3）。
          # 症状与量法：两个相邻的右对齐列，左列的数值顶在自己列右缘、右列的数值几乎填满
          # 自己的列宽 → 真实间隙只剩 0.4~2.3px，像素 OCR 直接把它们读成一串
          # （"+0.22%1,605.3."）。间隙 = 右列自己的余量，所以"右列刚好填满"时归零。
          # 这里给每个右对齐列的**内容框**留 NUM_GAP：文字仍然贴住列右缘（右对齐不变），
          # 但列内可写宽度少 NUM_GAP → 与左邻列的数值之间至少有 NUM_GAP 的间隙。
          NUM_GAP = 4

          attr_reader :columns, :row_height, :header_height, :pad

          def initialize(columns, row_height:, header_height:, pad: 4)
            @columns = columns
            @row_height = row_height
            @header_height = header_height
            @pad = pad
          end

          # 这个面板宽度下的具体几何（每次绘制/命中测试各取一次；纯计算、可缓存）
          def layout(width, height = nil)
            Layout.new(self, width, height)
          end

          def total_weight = @columns.sum { |column| column[0] }
          def natural_width = total_weight + pad * 2

          # 列宽 = 权重 × (面板宽 - 左右留白)；最后一列吃掉取整误差（右缘对齐面板右缘）
          class Layout
            attr_reader :grid, :width, :height

            def initialize(grid, width, height = 0.0)
              @grid = grid
              @width = width.to_f
              @height = height.to_f
              @widths = layout_widths
            end

            def columns = grid.columns
            def row_height = grid.row_height
            def header_height = grid.header_height
            def pad = grid.pad

            def width_of(index) = @widths[index]
            def x(index) = pad + @widths[0, index].sum
            def align_of(index) = columns[index][1]
            def sort_key_of(index) = columns[index][3]

            # 文字的实际位置/宽度：内容框各自让出呼吸位（左对齐让 CELL_GAP、右对齐让 NUM_GAP），
            # 让出的方向不同但效果一致——**与相邻列的最后一个/第一个字之间总有间隙**：
            #   · 左对齐：文字从 x + CELL_GAP 起画（避免紧跟前一列贴右缘的数值 → "123,631.90撤单"）
            #   · 右对齐：文字仍贴住列右缘（x + w），但可写宽度少 NUM_GAP → 文字左端不会顶到
            #     前一列的数值（见 Grid::NUM_GAP 的实测：0.4~2.3px 的间隙会被 OCR 读成一串）
            # 命中测试的列带仍用 width_of —— 点哪一格不变，只是文字不贴着格边画。
            def content_x(index) = x(index) + gap_of(index)
            def content_width(index) = [width_of(index) - gap_of(index), 1.0].max

            # 第一列不让位：它的左边只有面板留白（pad），让出来的 10px 是白扔的——
            # 而"标的"列恰恰是最需要宽度的一列（长名称在最小窗口下本来就会被截断）。
            def gap_of(index)
              return 0 if index.zero?

              align_of(index) == :right ? Grid::NUM_GAP : Grid::CELL_GAP
            end

            # 表头区（y 在表头带内）
            def header?(y) = y < header_height

            # 行带内 → 行号；表头/空白 → nil
            def row_at(y)
              return nil if header?(y) || y.negative?

              ((y - header_height) / row_height).to_i
            end

            def row_top(index) = header_height + index * row_height

            # 列带内 → 列号；列外（左右留白）→ nil
            def column_at(x)
              offset = pad
              columns.each_with_index do |column, index|
                return index if x >= offset && x < offset + @widths[index]

                offset += @widths[index]
              end
              nil
            end

            # 能装下几行（面板高度不够就不画；高度就是这一帧的可见高度）
            def rows_in
              rows = ((height - header_height - pad) / row_height).to_i
              [rows, 0].max
            end

            private

            def layout_widths
              inner = [width - pad * 2, 0.0].max
              total = grid.total_weight.to_f
              return columns.map { 0.0 } unless total.positive?

              widths = columns.map { |column| column[0] / total * inner }
              # 末列补齐到右缘：浮点误差不能让表格右边差一两个像素
              slack = inner - widths.sum
              widths[-1] = [widths[-1] + slack, 0.0].max if widths.any?
              widths
            end
          end
        end

        # 面板骨架：标题 label + 调用方内容。原生没有边框，用间距分层。
        #
        # stretch: 这块面板要不要 flex_grow（= 吃掉所在列多余的高度）。
        # 规则与实测依据见本文件顶部「哪些面板要 flex_grow」：数据区（有 area）必须 true，
        # 固定几行原生控件的面板必须 false —— 后者若 stretchy，窗口最小高度会按
        # "最高的 stretchy 面板"翻倍（实测：全部 stretchy 时内容下限 1264×936）。
        #
        # header: 标题行右侧的附加控件（持仓面板的翻页）。放进标题行而不是单开一行：
        # 标题行 16px、按钮 24px 合并后只多 8px，单开一行要多 ~30px——而中列的高度是
        # 走势图的预算（见 native/views/positions.rb 的 PAGE_SIZE）。
        def panel_frame(title, stretch: true, header: nil, &body)
          style = stretch ? { flex_grow: 1 } : {}
          box(direction: :column, gap: 6, style: style) do
            if header
              box(direction: :row, gap: 8) do
                label { title }
                header.call
              end
            else
              label { title }
            end
            body.call
          end
        end

        # 自绘面板：撑满所在格子（`scroll: false` + flex_grow），几何从 Painter 的尺寸推。
        #
        # 这里刻意**不给 size:**：滚动面板的 size: 是"滚动内容尺寸"，会让视口与内容宽度
        # 脱钩（正是左列塌陷的成因）；非滚动面板又用不了 uiAreaSetSize。不给尺寸时
        # libui 的 Draw 报的是布局尺寸（ui.h：only defined for nonscrolling areas），
        # Painter 的 width/height/clip_rect 三者一致，就是这块面板的可见区。
        #
        # 底板（深色背景 + 描边）走**视觉样式**（citrine-native L2 起 area 自动消费）：
        # 以前每个面板的 draw 里都手写一行 `painter.rect(0, 0, w, h, fill: Theme::PANEL,
        # stroke: Theme::LINE)`，现在由框架在 on_draw 之前画，应用只管内容。
        def paint_panel(ref, watch:, on_draw:, on_click: nil)
          element(:area,
                  ref: ref,
                  style: { flex_grow: 1, background: Theme::PANEL,
                           border: "1px solid #{Theme::LINE}" },
                  watch: watch,
                  on_draw: on_draw,
                  on_click: on_click)
        end

        # 选中态按钮：原生控件没有样式位（REACTIVE_PROPS 不含 disabled/css_class），
        # 选中态只能用文案标记。块里的信号读取订阅在按钮自己的块 Effect 上（原地改文字）。
        def state_button(handler, &text)
          button(on_click: handler) { text.call }
        end

        # 表格行：cells 与列一一对应，元素是 [文本, 颜色]（nil 文本 = 该格留空）。
        #
        # reserve: {列下标 => 像素}——从该格的可写宽度里再扣掉这么多（自选表的「持」徽标
        # 需要占用标的列右端：不扣的话被截断的名称会**填满**列宽、与徽标重叠，
        # 真窗口实测重叠 5.3px，OCR 读成 "600519 贵州.持1,392.08"，见 native/README.md）。
        def draw_cells(painter, layout, cells, row_top, size: Theme::SIZE_BASE, weight: :normal, reserve: nil)
          cells.each_with_index do |cell, index|
            next if cell.nil? || cell[0].nil?

            width = layout.content_width(index)
            width -= reserve.fetch(index, 0) if reserve
            cell_text(painter, cell[0],
                      x: layout.content_x(index), y: row_top, w: [width, 1.0].max,
                      h: layout.row_height,
                      color: cell[1] || Theme::TEXT, size: size, weight: weight,
                      align: layout.align_of(index))
          end
        end

        # 单元格文本：先量再画，自己算对齐与竖直居中；量出来超宽就截断成省略号。
        #
        # 为什么要截断：面板宽度随窗口变，数值列窄到装不下时，画出去的文字会**压到下一列**
        # （Painter 的 text 不受 w 约束）。表格里"看得懂的半截数字 + 完整表头"比"两列文字
        # 叠在一起"有用得多（DOM 版对应 overflow: hidden）。
        #
        # 为什么不直接用 Painter 的 align:/width: 参数：冻结文档（2.2）没有定死
        # "对齐是相对 x 还是相对 x+width"，也没有定死 y 是文本顶部还是基线。
        # 自绘统一走 measure_text + 显式坐标，两种解释下文本都落在格子里。
        def cell_text(painter, text, x:, y:, w:, h:, color:, size: Theme::SIZE_BASE,
                      weight: :normal, align: :left)
          text = fit_text(painter, text, w, size: size, weight: weight) if w.positive?
          text_width, text_height = painter.measure_text(text, size: size, weight: weight)
          offset = align == :right ? w - text_width : 0
          painter.text(text, x: x + offset, y: y + (h - text_height) / 2.0,
                       color: color, size: size, weight: weight)
        end

        ELLIPSIS = "…"

        # 截断到宽度 w 内（最多量 log2(n) 次：文字长度是几十个字符）
        def fit_text(painter, text, w, size:, weight:)
          return text if text_width(painter, text, size, weight) <= w

          fits = 0
          low = 0
          high = text.length
          while low <= high
            middle = (low + high) / 2
            candidate = "#{text[0, middle]}#{ELLIPSIS}"
            if text_width(painter, candidate, size, weight) <= w
              fits = middle
              low = middle + 1
            else
              high = middle - 1
            end
          end
          return ELLIPSIS if fits.zero? && text_width(painter, ELLIPSIS, size, weight) <= w

          "#{text[0, fits]}#{ELLIPSIS}"
        end

        def text_width(painter, text, size, weight)
          painter.measure_text(text, size: size, weight: weight)[0]
        end

        # 值 → 像素 y：value ∈ [lo, hi] 映射到 [bottom, top]（图表与权益曲线共用）
        def plot_y(value, lo, hi, top, bottom)
          span = hi - lo
          return (top + bottom) / 2.0 if span <= 0

          y = bottom - (value - lo) / span * (bottom - top)
          return top if y < top
          return bottom if y > bottom

          y
        end
      end
    end
  end
end

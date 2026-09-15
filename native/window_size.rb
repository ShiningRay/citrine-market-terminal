# frozen_string_literal: true

require "fiddle"

module Market
  module Native
    # 窗口下限（**app 侧**）：给窗口一个"再小就不好用"的硬边界，并把边界写进 README。
    #
    # 为什么需要它：libui 的 box 布局在空间不够时**不裁剪**，而是把子控件挤到重叠
    # （MARKET-2 §4 的 700×380 截图就是这种状态：工具条、面板标题、排序按钮叠在一起）。
    # citrine-native 至今没有暴露"窗口最小尺寸"（Widgets 协议里没有 set_min_size，
    # `render()` 的 width/height 只是初始尺寸），所以这里在 app 侧补上：
    # macOS 上拿到 NSWindow 直接发 `setContentMinSize:`（Fiddle 直通 libobjc），
    # 其他平台/拿不到窗口就如实返回 false——libui 自己的内容自然尺寸仍然兜着一条更低的地板
    # （实测：内容天然下限 1046×664，低于它 OS 也不让缩，见 README 的窗口尺寸那一节）。
    #
    # ⚠️ 这个下限**只约束交互式缩放**：AppKit 由它推出 minSize（= 内容 + 标题栏），用户拖不出
    # 更小的窗口；但程序化 setContentSize/setFrame 不经过它，能压到 libui 的天然下限
    # （MARKET-2b §5 的实测，本轮复验：空账户 1046×664、持 10 只 1084×696，那时
    # 「成交与挂单」先被挤成 0 高）。dev_mode 下会打一条提醒，见 WindowSize.warn_scope。
    #
    # 取 NSWindow 的办法：`LibUI.control_handle(uiWindow*)` 返回的就是 uiprivNSWindow*
    # （实测：与 [NSApp windows][0] 同一个指针）。注意**不要**直接给 uiWindow*（libui 的
    # 结构体指针）发 objc 消息——会段错误（MARKET-2 §4 记过这一笔）。
    module WindowSize
      # 最小可用窗口（内容区，像素）：三列各 ~368 宽、四个面板都有可读高度
      #   · 宽 1160：既 ≥ 3 × 327.5（最宽的一列控件行：下单面板的"输入框 + 100/500/1000/全部"）
      #     + 两条列间距 + 窗口留白，也 ≥ **有数据时** libui 自己的内容天然下限（本轮实测：
      #     空账户 1046、持 10 只（持仓列表有界后）1084）——应用的下限要压得住框架的下限，
      #     否则"最小尺寸"这个数就不作数（用户会被框架顶回更大的窗口）。
      #     注：MARKET-1d 之前持仓行数不设上限，持 6 只就能把天然下限顶到 1136×880
      #     （高于 1160×790 的声明），所以这条只在"持仓列表有界"之后才真正成立。
      #   · 高 790 → 三列分到 ~546 的行高：左列两个面板各 ~215 / ~247、中列走势图 262（无持仓）
      #     或 94（持仓 ≥3 只，走分页）、右列下单（360 固定）+ 成交挂单 126（表格 4 行）
      # 实测（真窗口，最终代码、持 6 只 + 成交 + 挂单）：四个面板 368×215 / 368×247 / 368×94 /
      # 368×126，都不为 0、不叠压，六列表头齐全（长标的与长数值截断成省略号，量额单位保留）；
      # 尺寸表与截图核对过程见 native/README.md
      MIN_CONTENT = [1160, 790].freeze

      class << self
        # 给窗口设内容区下限；成功 true，平台不支持/拿不到窗口 false
        def enforce(window, width: MIN_CONTENT[0], height: MIN_CONTENT[1])
          target = native_window(window)
          return false unless target

          bridge.set_content_min_size(target, width, height)
          warn_scope(width, height)
          true
        rescue StandardError
          false
        end

        # 这个数**只约束交互式缩放**（AppKit 由它推出 minSize = 内容下限 + 标题栏）。
        # 程序化 setContentSize/setFrame 走的是另一条路，落在 libui 的内容天然下限上
        # （实测：空账户 1046×664；持 10 只 1084×696——见 native/README.md）。
        # dev_mode 下把这条边界直接说出来，免得下一个人把 1160×790 当成"内容永远不小于它"。
        def warn_scope(width, height)
          return unless Citrine.dev_mode?
          return if @warned

          @warned = true
          warn "[market-native] 窗口内容区下限已设为 #{width}×#{height}（[NSWindow setContentMinSize:]）：" \
               "它只约束**用户拖拽/系统缩放**，程序化 setContentSize / setFrame 不经过它——" \
               "实测能压到 libui 的内容天然下限（空账户 ≈1046×664、持 10 只 ≈1084×696），" \
               "那时「成交与挂单」面板会先被挤成 0 高（框架的 dev_mode 也会报 0 尺寸）。" \
               "想让内容本身也压不下去，只能让内容不吃高度（持仓列表的有界分页就是这样，见 " \
               "native/views/positions.rb）。"
        end

        # 这台机器上能不能做（macOS + 动态库里能找到 libobjc）
        def available? = bridge.available?

        private

        # LibUI 的 uiWindow* → NSWindow*（拿不到 → nil）
        def native_window(window)
          return nil unless window

          handle = ::LibUI.control_handle(window)
          handle.to_i.zero? ? nil : handle
        rescue StandardError
          nil
        end

        def bridge = @bridge ||= Bridge.new
      end

      # 只干一件事：把宽高写进 [NSWindow contentMinSize]。Fiddle 拿不到 32 字节的结构体
      # 返回值（我们只需要传参，NSSize 是 2 个 double，arm64 走 v0/v1），所以够用。
      class Bridge
        def initialize
          @library = Fiddle.dlopen(nil)
          @send_doubles = Fiddle::Function.new(@library["objc_msgSend"],
                                               [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                                                Fiddle::TYPE_DOUBLE, Fiddle::TYPE_DOUBLE],
                                               Fiddle::TYPE_VOID)
          @register = Fiddle::Function.new(@library["sel_registerName"], [Fiddle::TYPE_VOIDP],
                                           Fiddle::TYPE_VOIDP)
          @selector = @register.call("setContentMinSize:")
          @available = !@selector.to_i.zero?
        rescue StandardError
          @available = false
        end

        def available? = @available

        def set_content_min_size(window, width, height)
          @send_doubles.call(window, @selector, width.to_f, height.to_f)
        end
      end
    end
  end
end

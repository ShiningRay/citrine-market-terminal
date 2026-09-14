# Citrine v1 摩擦记录（用真实应用 dogfooding 得到）

> 记录时间：2026-09-14 ｜ 框架版本：Citrine 0.1.0（M0–M4a，commit 期 2026-09-14）
> 来源：在本仓库（Citrine 行情终端，10 个源文件 / 约 2700 行）实际开发过程中的踩坑，
> 叠加一份**独立审计**（`docs/citrine-v1-audit.md`，20 项静默失败入口 + 真机 Chrome 实测证据，
> 探针与原始输出在 `docs/probes/`）。
> 每条都标注了证据等级：【实测】= 本仓库或审计跑出过来输出；【定位】= 源码位置。

本文不是抱怨清单，而是**可执行的改进提案**：每条给出「现象 → 证据 → 位置 → 建议改法」，
并按"投入产出比"排了优先级（第六节）。

---

## 零、框架侧响应状态（2026-09-14 更新，Citrine 0.1.1）

针对本记录，框架已落地的修复（citrien 仓库，分支保护流程合入）：

| 项 | 状态 | 说明 |
|---|---|---|
| F1 | ✅ 已修复 | `Effect#run`/`#dispose` 增加 dispose 守卫（幂等、广播快照安全），并有 CRuby 回归测试 `test_disposed_effect_in_broadcast_snapshot_is_safe` 锁定。本文建议的"`@deps = []` 不变量"实现为"`@deps = nil` + `run` 头部守卫"，语义等价 |
| F2 | ✅ 最小修复 | `DomRenderer.mount_at` 复用已有 DomRenderer 实例（不再"最后挂载者胜出"）；`Renderer#mount` 无父节点时抛出**可读**异常（指明多根挂载的正确姿势），有测试锁定 |
| F16 | ✅ 已修复 | 内容 block 返回非字符串 → 按 `to_s` 渲染（不再静默为空），每类型提醒一次建议插值；`nil` 仍渲染为空 |
| F17 | ✅ 已修复 | `Style.normalize` 按属性白名单推断单位（`width`/`border_radius`/`padding` 等 Numeric → `"Npx"`；`flex`/`opacity`/`font_weight` 等保持无单位），**nil 值剔除**。官方示例里"真机失效"的 `border_radius: 20` / `width: 18` 由此生效 |
| F19 | ✅ 已修复 | `check_box(checked: signal)` 读取信号并保持响应（Effect 订阅），不再恒为 true |
| F20 | ✅ 已修复 | `text_input(value: "字面量")` 初值落到 DOM，与 SSR 输出一致 |
| F12–F14 | ✅ 文档已补 | README「技术备忘」置顶：整数除法、负数取整、`::Signal` 遮蔽三条跨平台陷阱 |
| F3/F4/F5/F6/F7 | ⏳ 路线中 | 对应 Roadmap v2 P0（批量更新 / props 重应用 / 组合三件套 / 生命周期）；本文第五节的四条"绕法纪律"在落地前仍属必要 |
| F8/F9/F10/F11/F15/F23 | ⏳ 待办 | 见第六节优先级表；F23（box 默认方向）属行为变更，改前需公告 |

> 注：本文写作时的行号与修后源码可能有偏移；F1 一节的"建议改法"与实际落地实现的差异见上表说明。

---

## 一、阻塞级：会导致崩溃或静默错误

### F1. 祖先块与后代订阅同一信号 → 首次交互即抛异常，子树被拆一半 ★最痛 ✅已修复

**【现象】** 这是最自然不过的写法就踩中的框架崩溃：

```ruby
box(css_class: "crashwrap") do
  t = q                        # ← 容器块订阅了 q
  text_input(value: signal(:q))
  label { "echo=#{t}" }
end
```

敲第一个字符就抛 `NoMethodError: undefined method 'each' for nil`，同时输入框被销毁重建
（焦点与光标位置丢失）。页面"看起来还能用"，控制台持续报错——极难定位。

**【证据】** 本仓库在写下单面板时无意踩中，Node 桩直接崩；审计侧有纯 CRuby 最小复现
（`docs/probes/probe_c_crash.rb`）与真机 Chrome 复现（`docs/probes/browser/out_measure.json` → `Q7_crash`）。

**【定位】** 三处叠加：
- `lib/citrine/signal.rb:24` `@subs.dup.each(&:run)` —— 通知时遍历的是**快照副本**；
- `lib/citrine/signal.rb:74-77` `Effect#dispose` 把 `@deps` 与 `@block` 置为 `nil`；
- `lib/citrine/renderer.rb:66-75` `run_block` 先 `dispose` 全部子节点（连同其 Effect），再执行 block。

于是"先创建、先订阅"的祖先 Effect 重跑时销毁了仍在 `@subs` 快照里的后代 Effect，
快照随后对已销毁的 Effect 调 `run` → `release_deps` 对 `nil` 调 `each`。

**【建议改法】** 一行即可（本仓库已单独验证修复有效，见 `docs/probes/`）：

```ruby
# lib/citrine/signal.rb
def run
  return self if @block.nil?   # 已 dispose：可能仍留在 Signal 的订阅快照里
  release_deps
  ...
end

def dispose
  release_deps
  @block = nil
  @deps = []                   # 不要置 nil：给"陈旧快照"留一个安全的不变量
end
```

更彻底的做法是给 `Signal#set` 加"通知进行中"状态，禁止在通知过程中 dispose 订阅者
（或把 dispose 延后到本轮结束），并在 `dispose` 后把自己从 `@subs` 里摘除。

### F2. 同一页面调用两次 `DomRenderer.mount_at` → 先挂载的组件被清空 ✅已修复（最小方案）

**【现象】** 页面上挂两个独立组件（各自 `mount_at` 一个容器），点第一个组件的按钮：
`NoMethodError: undefined method 'children' for nil`，**该组件整个子树被清空**（彻底死掉）；
点第二个（最后挂载的）正常。

**【证据】**【实测】审计真机复现：`docs/probes/browser/out_measure2.json`。
本仓库没踩中（只挂一个根），但这是"多根应用"的必然路径。

**【定位】** `lib/citrine/dom.rb:17` `Citrine.renderer = new`（每次 `mount_at` 都换全局渲染器，
最后挂载者胜出），而 `lib/citrine/renderer.rb:37` 用新渲染器里空的 `@parents.last` 取父节点。

**【建议改法】** 把"当前父节点"从全局渲染器状态改为跟随 Node 树 / 组件实例
（如 `Component#emit` 从实例上的 `@current_parent` 取父节点，`mount_at` 复用同一渲染器实例）。
最低成本补丁：`mount_at` 仅在 `Citrine.renderer.nil?` 时新建，并在 `mount` 里对
`@parents.last.nil?` 抛出**可读**异常（而不是 `nil.children` 的裸 NoMethodError）。

---

## 二、表达力缺口：能做，但很别扭或形状不对

### F3. 没有批量更新：一次操作 = N 轮渲染，中间态真的进了 DOM

**【现象】** 一个 handler 改 3 个信号 → 订阅方重算 3 次、DOM 重建 3 轮，且有中间值闪烁。

**【证据】**【实测】
- 本仓库：一个 tick 内——`Effect` 重跑 **122 次**、新建 DOM 节点 **84 个**、渲染耗时 ~9–23ms；
  改 3 个动态信号时聚合 computed 重算 **3 次**（本仓库埋点面板实时显示这些数字）。
- 审计：一次 handler 改 a/b/c → `createElement` 增量 **15**（= 3 轮 × 5 节点），
  `set_text` 收到的中间值序列 `["F0|L0","F1|L0","F1|L1"]`（中间态可见）。

**【定位】** `signal.rb:24`（`set` 内同步级联，无事务/合并）、`renderer.rb:66-75`（每次重跑整块重建）。

**【建议改法】** 给 `Signal#set` 加批次窗口：写入只标记脏信号，Effect 入队一次，
在同步调用栈退出后（或 `queueMicrotask`）统一 flush；同时暴露 `Citrine.batch { ... }`
供显式包裹。注意单测依赖同步语义，需要给测试留 `flush!` 入口。

### F4. props 只在挂载时应用 → "颜色随状态变"必须整块重建

**【现象】** `apply_props` 只在 `mount` 时执行一次。所以要让一个数字**变色**，
必须让它所在的块读信号、整块重建；而如果这个块里还嵌着别的块读了同一信号 → 就是 F1 崩溃。

**【证据】**【实测】本仓库把这条约束写成了视图层纪律（见 `app/views/common.rb` 注释）：
"容器块不读信号 / 会变的数字放到最内层小块 / 需要变色就让外层块重建，内层标签绝不再读同一信号"。

**【定位】** `renderer.rb:34-51`（`mount` 里 `apply_props` 一次）、`dom.rb:44-56`。

**【建议改法】** 短期：给 `apply_props` 增加"重跑块时对**已有节点**再应用一次 props"的路径
（哪怕没有 diff，至少让"同一节点改样式"成为可能，可直接用 `element.style.setProperty`）。
中期：配合 keyed 复用做真正的属性增量更新。这是**动画与过渡能否工作**的前提（见 F10）。

### F5. 没有组件嵌套 → 所有面板只能塞进一个类

**【现象】** 无法在 `view` 里渲染另一个组件（Roadmap v2 的 P0-1 已记录）。
本仓库有 7 个面板、10 个文件，但状态与方法全部挂在**同一个 `Terminal` 类**上，
按面板拆的混入模块（`app/views/*.rb`）只是语法上的分文件，不是真正的组合。

**【证据】**【实测】本仓库结构：`app/terminal.rb` 一个类 + 8 个 view mixin。
`prop` 是创建时快照（`component.rb:62-76`），也没有"父传子、子改父"的通道。

**【建议改法】** 按 P0-1 推进，但建议**先只做 `render(child)` + keyed 实例复用**这两步；
props 响应式（父重传 → 子组件读取 props 的块失效重跑）可以放到第二步，
因为它需要在 `prop` 上引入信号语义，改动面比前两者大。

### F6. 没有 keyed 复用 → 列表重建必然丢输入与焦点

**【现象】** 父块重建时列表条目全部换新 DOM 节点：输入框内容与焦点一起丢。
本仓库因此把"数量输入框"的块写成**不读任何信号**（`app/views/ticket.rb`），
才换来"整个会话中输入框是同一个 DOM 节点"。

**【证据】**【实测】审计真机：加一条待办后输入框 `value` 清空、`activeElement` 掉到 `BODY`；
per-row `Signal` 手动 memo 能保住**值**，但 DOM 身份与焦点仍丢。

**【定位】** `renderer.rb:66-75`（一律 dispose + 重建，无 key 概念）。

**【建议改法】** 短期：把"每行一个 Signal（Hash memo + 直接 set）"抬成官方姿势
（`dynamic_state` 宏），并在文档里明示这是唯一可行姿势。
中期：`box(key: item[:id])` + 重建后恢复 `document.activeElement` 与 `selectionStart`。

### F7. 没有生命周期钩子 → 定时器/事件/清理全靠用户自己写

**【现象】** 无 `on_mount` / `on_unmount` / `effect` / `watch`；`Renderer#dispose` 是 private，
组件无法感知自己被销毁。所有外部资源（定时器、全局键盘、beforeunload）都得在框架外挂。

**【证据】**【实测】本仓库 `app/browser_glue.rb` 的自述注释、`app/market.rb:21-22`。
审计实测：框架内 `clearInterval` 被调用 **0** 次，销毁后定时器照跑。

**【建议改法】** 按 P0-2 做**最小可用版**：`Component#on_mount(&)` / `#on_unmount(&)`
（在 `mount_component` 与 `dispose` 处回调），并把 `dispose` 提升为公开的 `Citrine.unmount(root)`。
进一步给"会被自动清理的资源注册器"：`Component#interval(ms) { }` / `#listen(target, event) { }`——
否则每个用户都会各自重写一遍（本仓库就是）。

### F8. 渲染器不能混合 → Canvas 无法嵌进 DOM 布局

**【现象】** 想用 `CanvasRenderer` 画 K 线放进 DOM 页面里的一个面板——做不到：
Canvas 渲染器会接管整块 canvas 元素，不能作为 DOM 树中的一个子区域。

**【证据】**【实测】本仓库改用纯 `div` 绘制蜡烛图/分时图/权益曲线（`app/views/chart.rb`）。

**【建议改法】** 这不是 v1 的 bug（渲染器抽象本来就按"整树单后端"设计），
但值得记成**未来方向**：要么提供 `DomRenderer` 里的子渲染器插槽
（`box(canvas: :kline) { }` 之类的逃逸口），要么明确文档写"单页单后端"。

### F9. 没有 DevTools / 埋点钩子 → 得自己 hack 框架内部

**【现象】** 信号依赖图、Effect 重跑次数、渲染耗时都看不到。
本仓库想量化"块级重建的粒度"，只能：
① `class_eval` + `alias_method` 包裹 `Effect#run`（纯 Ruby）；
② 包裹 `DomRenderer#create_dom` 统计 `createElement` 次数。

**【证据】**【实测】`app/telemetry.rb` + `app/browser_glue.rb:23-35`；
页面底部"信号与渲染埋点"面板实时显示 122 次重跑 / 84 个节点。

**【建议改法】** 把这两个钩子变成官方能力（P1-8 DevTools 的地基）：
`Citrine.telemetry = { on_effect_run:, on_node_create:, on_flush: }`
或至少提供 `Citrine::Effect.on_run` / `Renderer.on_node_create` 的可插拔回调。
**这是"信号式框架"相对 React 的最大可观测性卖点，不该让用户自己 alias_method。**

### F10. 键盘事件只有 Enter → 失焦提交 / Esc 取消做不到

**【现象】** 框架内只能收到 `text_input` 的 Enter；`blur` / `focus` / `Escape` / 普通键一律收不到。

**【证据】**【实测】`dom.rb:69-84`（只有 `ev[:key] == "Enter"` 一条分支）；
审计实测：手动绑 `blur`/`Escape` 能生效，但框架不知道 → `dispose` 不摘监听器（泄漏），
且这些监听器一旦触发重建就踩 F1。

**【建议改法】** 把 `on_enter` 泛化为 `on_key:`（支持 `escape:`/`enter:` 映射）并补 `on_blur:`/`on_focus:`；
`dom.rb` 里已有 `addEventListener("input")` 的基础设施，实现量很小。
同时让 `dispose` 记录并移除**框架自己绑的**监听器（`node.owned_listeners`）。

### F11. 没有属性透传：`id` / `disabled` / `aria` / `data` 全部无效

**【现象】** `button(disabled: true)`、`box(id: "x")`、`aria_label:`、`data_role:` 在 DOM 上完全不存在——
写的人以为生效了，实际没有。这直接堵死了无障碍与 E2E 定位（也无法用 `id` 做锚点）。

**【证据】**【实测】审计真机：`{"id":"","disabled":false,"data_role":null}`；
本仓库只能用 `css_class` 这一个逃生口（`dom.rb:46`、`string_renderer.rb:60`）。

**【建议改法】** 在 `Component#emit` 统一支持 `html_id:` / `disabled:` / `name:` / `aria: {}` / `data: {}`，
DOM 与 StringRenderer 两端都映射（`disabled` 尤其重要：现在**没法禁用按钮**）。

---

### F23. `box` 默认 `flex-direction: row` 且没有任何提示 → 容器默认横排

**【现象】** `box` 的名字读起来像"块级容器"（HTML `div` 的心智模型，默认纵向堆叠），
但 `resolve_style` 无条件给它 `display: flex`，只有传了 `direction:` 才设置方向，
不传就是 **row**。于是"一个面板里堆几个子块"这种最常见的写法，默认会**横向排列**。

本仓库就在这上面栽了一次：`views/common.rb` 的 `panel` 辅助方法漏了 `direction: :column`，
结果六个面板的内部子块全部横排；图表容器因为没有内容宽度直接塌成 **2px**（蜡烛宽度 0px），
但 DOM 结构、文本内容、桩测试**全部正常**——60 项 Node 桩断言全绿，
是到真实浏览器量 `getBoundingClientRect` 才发现布局是坏的。

**【证据】**【实测】修复前后对比（真实浏览器实测）：
- 修复前：`.panel-chart` 子块横排，`.chart-canvas` 宽 **2px**，`.candle` 宽 **0px**
- 修复后：`.plot` 宽 **534px**，`.candle` 宽 **9px**，10 行自选每行 **281px**

**【定位】** `lib/citrine/renderer.rb:87-98`：`style[:display] ||= "flex"`，
`style[:flex_direction] = direction == :column ? "column" : "row"`（未传 direction 时不设置，CSS 默认 row）。

**【建议改法】** 二选一：
1. **`box` 默认 `flex-direction: column`**（贴近"容器/块"语义，且符合 90% 的用法；
   横排是更有意图的布局，应当显式写 `direction: :row`）——代价是改变现有行为，需在 README 标注为 breaking；
2. 或者保留 row 默认，但**要求显式传 direction**：`box` 不带 `direction` 时在 dev 模式告警
   （"box 默认横排，如需纵向堆叠请传 direction: :column"）。

无论选哪个，都建议顺带让**桩测试可覆盖**：现在的 Node DOM 桩没有布局引擎，
`getBoundingClientRect` 不存在，所以"布局塌陷"这类问题在桩测试里是**结构性不可见**的
（这也是本仓库的教训：桩测通过 ≠ 布局正确，真实浏览器验收不能省）。

---

## 三、跨平台语义陷阱（Opal vs CRuby）：CRuby 单测全绿，浏览器里却是乱码

### F12. 整数除法静默返回浮点 ★

**【现象】** `7 / 2` 在 CRuby 是 `3`，在 Opal 是 `3.5`。于是 `123456789 / 100` 变成 `1234567.89`
——金额格式化直接输出 `1,234,567,.89.89` 这种乱码。

**【证据】**【实测】本仓库第一次在 Opal 侧跑就撞上；语义对照见 `docs/probes/`（本仓库 `test/` 有 parity 回归）。
**源码级确认**：Opal 的 `Numeric#/` 就是 JS 除法（`opal/corelib/number.rb:102`）。

**【定位/改法】** 属于 Opal 语义而非 Citrine 代码，但 Citrine 是"面向 Opal 的框架"，
**建议在文档的"技术备忘"里置顶警告**，并考虑在 corelib 之外提供 `Citrine::Num` 之类的工具模块。
本仓库的应对：`app/num.rb` 集中提供 `Num.idiv` / `Num.round_to`，且所有金额格式化都走它。

### F13. 负数取整方向不同

**【现象】** `(-1.5).round`：CRuby `-2`（远离零），Opal `-1`（JS `Math.round` 朝 +∞）。

**【证据】**【实测】同上语义对照。**【改法】** 同上：取整先取绝对值再回贴符号（见 `app/num.rb`）。

### F14. 组件内写裸 `Signal` 会命中 corelib 的 `::Signal`

**【现象】** Ruby 标准库（以及 Opal corelib）里都有一个 `::Signal`（进程信号）。
在组件里写 `Signal.new(...)` 会拿到那个空类，随后报 `undefined method 'get'`——
**错误信息完全不指向真正原因**。审计为此排查了十几分钟。

**【证据】**【实测】审计 `docs/citrine-v1-audit.md` 问题 6。

**【建议改法】** 在 `lib/citrine/component.rb` 里提供 `Component#signal_for(key, default)` /
`dynamic_state` 宏（见 F6），让用户**不必**手写 `Citrine::Signal.new`；
并在文档中把"必须写全限定名"写成显式警告。

### F15. `require_relative` 的入口路径必须相对 CWD（从外部目录编译会失败）

**【现象】** 用绝对路径编译入口文件时，Opal 解析 `require_relative` 失败：
`can't find file: ".../engine"`——即使该目录已在 `-I` 里。开发服务器恰好没问题，
因为它 `chdir` 到源目录、以 `basename` 传参；从别处脚本化编译就会踩。

**【证据】**【实测】本仓库搭建时实测（同一文件两种调用方式，一种成功一种失败）。

**【建议改法】** 在 `bin/citrine` 增加 `citrine build <目录>`（把"正确调用姿势"固化，
并顺带做 P1-6 的 minify），避免用户自己拼 `opal` 命令时踩坑。本仓库的 `Rakefile`
已把正确形态固化（`cd app && opal -c -I<citrine>/lib -I. -o market.js market.rb`）。

---

## 四、可发现性：静默失败入口（最影响开发体验的一类）

审计整理出 **20 个静默失败入口**（`docs/citrine-v1-audit.md` 问题 10 有完整表格与实测输出）。
这里只列对本仓库造成实际影响的：

| # | 写法 | 实际行为 | 影响 |
|---|---|---|---|
| F16 | `label { 42 }` / `{ items.size }` / `{ nil }` | **渲染成空元素，无任何警告** | 极自然写法；本仓库因此强制全部插值 `"#{...}"` |
| F17 | `style: { width: 18 }`（数字） | DOM 静默丢弃整条声明；SSR 输出非法 CSS | 官方 TodoApp 的 `border_radius: 20`、`width: 18` **在真机上全部失效** |
| F18 | `on_change:` 放在 `box/label` 上、`on_input:` 等不存在的名字 | 不绑、不报错 | 本仓库只能用 `on_click` + `on_enter` 两种 |
| F19 | `check_box(checked: some_signal)` | `props[:checked] ? true : false` → **恒为 true** | 想用信号驱动勾选就是错的 |
| F20 | `text_input(value: "字面量")` | DOM 里 value 为空，SSR 里却输出 `value="字面量"` → **两端不一致** | 只有传 `signal(:x)` 才一致 |
| F21 | `style: { font_wieght: "600" }`（拼错键） | SSR 照打印，DOM 静默失效 | 打字错误零反馈 |
| F22 | 构造器校验严（未声明 prop 报错）vs DSL 零校验 | 边界不一致 | 用户不知道该期待哪种行为 |

**【建议改法】**（都在 `component.rb:148-153` 的 `emit` 一个点上做）
1. **按 widget 类型做 prop/事件白名单**，未知键在 dev 抛 `ArgumentError`（列出合法键），生产 `warn`；
2. `set_text` 改为"显式 `nil` 才算无文本，其余 `to_s`"（`renderer.rb:71`），
   并对 Numeric/Symbol/Array 返回值**告警一次**（提示用插值）；
3. `Style.normalize_value` 增加**按属性白名单的单位推断**（`width`/`height`/`padding`/`font_size`/`border_radius`…
   加 `px`，`flex`/`line_height`/`opacity`/`z_index` 保持无单位），并对 `nil` 值剔除；
4. `style:` 非 Hash 时给出可读错误（现在报 `each_with_object for String`）。

---

## 五、本仓库采用的"绕法纪律"（其它开发者可直接抄）

在 v1 约束下写出不崩、不卡、不闪的应用，本仓库总结出四条纪律（`app/views/common.rb` 有注释版）：

1. **容器块不读信号** —— 保证结构不随高频信号打散；会变的数字放到**最内层**小块里读
   （读在叶子块 → 更新只改 `textContent`，**0 个元素重建**，这是 v1 性能的关键）。
2. **需要变色/换 class 的单元，让外层块读信号并重建；内层标签绝不再读同一信号**
   —— 前者是 props 非响应式所迫（F4），后者是为了避开 F1 崩溃。
3. **输入框所在的块不读任何信号** —— 否则每档都被重建，丢焦点与输入法状态。
4. **快照数据由父块读出后以局部变量传给子块** —— 父块重建时自然刷新，子块保持静态。

---

## 六、优先级建议（按投入产出比）

| 优先级 | 项 | 理由 |
|---|---|---|
| **P0（几行代码，防崩溃）** | F1、F2 | 都是崩溃级，F1 的修复是 2 行；F2 至少改成可读异常 |
| **P0（体验断层）** | F3 批量更新、F4 props 重应用 | F3 决定有无闪烁与性能上限；F4 决定动画能不能做（F10 依赖它） |
| **P1（表达力）** | F5 组件嵌套、F6 keyed 复用 + `dynamic_state`、F7 生命周期宏 | 这三个决定"能不能写正常规模的应用"；本仓库就是被它们挤成"单类 + mixin" |
| **P1（可观测性，差异化卖点）** | F9 telemetry 钩子 | 信号式框架的天然优势，现在却要用户 `alias_method` 框架内部 |
| **P1（错误可发现性）** | F16–F22 一批静默失败 | 一次 `emit` 层校验 + `set_text` 语义修正 + 样式单位推断，能消掉绝大多数"我明明写了却没生效" |
| **P2（生态）** | F8 渲染器插槽、F11 属性透传、F15 `citrine build`、F23 `box` 默认方向 | 影响范围明确、可延后；F11 里的 `disabled` 建议提前（现在没法禁用按钮）；F23 是"换默认值 or dev 告警"的取舍，改前需公告 |
| **文档（今天就能做）** | F12、F13、F14 置顶写入 README「技术备忘」 | 跨平台语义陷阱（尤其整数除法）会让"CRuby 单测全绿"的应用在浏览器里出错 |

**一句话总结**：v1 的**内核语义**（信号 + 块级重建）是成立的，本仓库能在它上面跑出
122→125 次重跑/84→87 节点的确定性开销、以及逐字节跨平台一致的内核；
真正的摩擦集中在**三个边界**——① 更新粒度与 props 静态化带来的"视图层纪律"（F3/F4）、
② 组合与生命周期缺失带来的"单类应用"（F5/F6/F7）、③ Opal 语义、静默失败与默认值带来的"排查成本"（F12/F16/F23）。
这三处都不需要重写内核，属于可以逐个点掉的具体工作。

> 附加一条方法论教训（给框架的验收清单）：本仓库的 60 项 Node DOM 桩断言在
> **布局已经塌成 2px** 的状态下依然全绿——因为桩里没有布局引擎（F23）。
> 框架自身的示例验收同样只做"文本/结构断言"，因此**建议把"真实浏览器量尺寸"
> 补进 CI**（headless Chrome 足够，不需要视觉回归），否则一类布局 bug 会长期不可见。

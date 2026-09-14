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
| F4 | ✅ 已落地 | **响应式属性**：`css_class:` / `placeholder:` / `style:` / `direction:` / `gap:` 的值可传 Proc，在**该节点自己的属性 Effect** 内求值，重跑只重设属性、不重建子树。"颜色随状态变必须整块重建"不再成立，本文第五节的纪律 2 已据此改写（本仓库落地情况见第七节） |
| F7 | ✅ 已落地 | `on_mount :method` / `on_unmount { }`（类宏、子类继承）+ `ref: :name` → `component.refs[:name]`；`Citrine.unmount(component)` 公开卸载。本仓库的 200ms 心跳定时器已从外挂层迁到组件（第七节） |
| F10 | ✅ 已落地 | 类宏 `window_key :handler`（window 级 keydown，随卸载自动解绑）+ 元素级 `on_key:` / `on_focus:` / `on_blur:`（`on_key` 支持 Symbol / Proc / `{ "Escape" => :cancel, else: :fallback }`）。处理器收到平台无关的 `Citrine::KeyEvent`（`ev.key` / `ev.shift?` / `ev.meta?` / `ev.command?` / `ev.prevent_default` / `ev.raw`）。本仓库的全局快捷键已迁入（第七节） |
| F16 | ✅ 已修复 | 内容 block 返回非字符串 → 按 `to_s` 渲染（不再静默为空），每类型提醒一次建议插值；`nil` 仍渲染为空 |
| F17 | ✅ 已修复 | `Style.normalize` 按属性白名单推断单位（`width`/`border_radius`/`padding` 等 Numeric → `"Npx"`；`flex`/`opacity`/`font_weight` 等保持无单位），**nil 值剔除**。官方示例里"真机失效"的 `border_radius: 20` / `width: 18` 由此生效 |
| F19 | ✅ 已修复 | `check_box(checked: signal)` 读取信号并保持响应（Effect 订阅），不再恒为 true |
| F20 | ✅ 已修复 | `text_input(value: "字面量")` 初值落到 DOM，与 SSR 输出一致 |
| F12–F13 | ✅ 已落地 | 框架提供 `Citrine::Num`：`idiv`（floor 语义）、`round_to`（半值远离零，digits≤0 → Integer / >0 → Float）、`round` / `integral?` / `finite?` / `percent`，并自带语义测试。本仓库那份手写实现（原 `app/num.rb`，39 行）已删除，只留 `Num = Citrine::Num` 别名（第七节） |
| F14 | ✅ 文档已补 | README「技术备忘」置顶：整数除法、负数取整、`::Signal` 遮蔽三条跨平台陷阱 |
| F3/F5/F6 | ✅ F5/F6 已落地，F3 仍待办 | **组件嵌套 + keyed 复用**已进 main（citrine PR #15，2026-09-14）：`render(Child, **props, key:)` 原语 + `components` 类宏 + 调和（父块重跑时按 key 复用子组件实例与根节点）。本文第五节的绕法纪律随之改写：**"输入框所在的块不读信号"已退休**（keyed/位置复用保证重跑命中同一节点），"容器块不读信号 / 快照由父块下发"仍然成立。F3（批量更新）仍未落地 |
| F8/F9/F11/F15/F23/F25 | ⏳ 待办 | 见第六节优先级表。其中 **F9（可观测性）仍未解决**：本仓库与姊妹仓库 citrine-sheets 各自 `class_eval` 包装框架内部一遍，两处埋点都还在等官方钩子（第七节 7.5）；F23（box 默认方向）属行为变更，改前需公告；**F24 / F25 是本次迁移撞出来的新缺口**（F24：同一位置换组件类型 → 新组件的根元素按位置复用旧组件的根节点；F25：父组件拿不到子组件实例）——**F24 已随 citrine PR #18 修复**（复用按 owner 收口，见第二节），仓库侧规避写法已删；F25 仍待框架给"父可见的子组件引用" |

> 注：本文写作时的行号与修后源码可能有偏移；F1 一节的"建议改法"与实际落地实现的差异见上表说明。
> 第七节是**框架能力落地后的迁移记录**：7.1–7.5 是"把外挂层交还给框架"，
> **7.6 是"把组件树还给组件树"**（组件嵌套 + keyed 复用落地后，含逐档开销对照与真机截图验证）。

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

### F4. props 只在挂载时应用 → "颜色随状态变"必须整块重建 ✅已落地（响应式属性，见第七节 7.4）

**【现象】** `apply_props` 只在 `mount` 时执行一次。所以要让一个数字**变色**，
必须让它所在的块读信号、整块重建；而如果这个块里还嵌着别的块读了同一信号 → 就是 F1 崩溃。

**【证据】**【实测】本仓库把这条约束写成了视图层纪律（见 `app/views/common.rb` 注释）：
"容器块不读信号 / 会变的数字放到最内层小块 / 需要变色就让外层块重建，内层标签绝不再读同一信号"。

**【定位】** `renderer.rb:34-51`（`mount` 里 `apply_props` 一次）、`dom.rb:44-56`。

**【建议改法】** 短期：给 `apply_props` 增加"重跑块时对**已有节点**再应用一次 props"的路径
（哪怕没有 diff，至少让"同一节点改样式"成为可能，可直接用 `element.style.setProperty`）。
中期：配合 keyed 复用做真正的属性增量更新。这是**动画与过渡能否工作**的前提（见 F10）。

### F5. 没有组件嵌套 → 所有面板只能塞进一个类 ✅已落地（citrine PR #15，迁移见第七节 7.6）

**【现象】** 无法在 `view` 里渲染另一个组件（Roadmap v2 的 P0-1 已记录）。
本仓库有 7 个面板、10 个文件，但状态与方法全部挂在**同一个 `Terminal` 类**上，
按面板拆的混入模块（`app/views/*.rb`）只是语法上的分文件，不是真正的组合。

**【证据】**【实测】本仓库结构：`app/terminal.rb` 一个类 + 8 个 view mixin。
`prop` 是创建时快照（`component.rb:62-76`），也没有"父传子、子改父"的通道。

**【建议改法】** 按 P0-1 推进，但建议**先只做 `render(child)` + keyed 实例复用**这两步；
props 响应式（父重传 → 子组件读取 props 的块失效重跑）可以放到第二步，
因为它需要在 `prop` 上引入信号语义，改动面比前两者大。

**【落地情况（2026-09-14，PR #15 → 已进 main）】** 按上面建议的两步落地：
`render(Child, **props, key:)` 原语 + `components` 类宏（`components WatchRow` → view 里
`watch_row(...)`），子组件 view 必须渲染**恰好一个**根元素节点，该节点就是复用/销毁单位。
本仓库的 8 个 mixin 因此变成 12 个真正的子组件（`app/views/*.rb`，8 面板 + 4 行组件），原来的 16 个 state 按归属拆分（7 个下沉、9 个留下）：
全局模型状态留在 `Terminal`，面板自己的 UI 状态（下单草稿 / 图表取样粒度 / 日志标签页）下沉到面板。
**props 仍是"创建时快照"**（S1 语义），所以跨组件传值要传**取值 Proc**，见 7.6。

---

### F6. 没有 keyed 复用 → 列表重建必然丢输入与焦点 ✅已落地（citrine PR #15，迁移见第七节 7.6）

**【现象】** 父块重建时列表条目全部换新 DOM 节点：输入框内容与焦点一起丢。
本仓库因此把"数量输入框"的块写成**不读任何信号**（`app/views/ticket.rb`），
才换来"整个会话中输入框是同一个 DOM 节点"。

**【证据】**【实测】审计真机：加一条待办后输入框 `value` 清空、`activeElement` 掉到 `BODY`；
per-row `Signal` 手动 memo 能保住**值**，但 DOM 身份与焦点仍丢。

**【定位】** `renderer.rb:66-75`（一律 dispose + 重建，无 key 概念）。

**【建议改法】** 短期：把"每行一个 Signal（Hash memo + 直接 set）"抬成官方姿势
（`dynamic_state` 宏），并在文档里明示这是唯一可行姿势。
中期：`box(key: item[:id])` + 重建后恢复 `document.activeElement` 与 `selectionStart`。

**【落地情况（2026-09-14，PR #15 → 已进 main）】** 调和改为"key 优先、无 key 按位置匹配"：
keyed 子组件在父块重跑时**实例、state、Effect、DOM 全部保留**，props 就地更新后重跑 view
把输出调和回同一棵根。本仓库的自选行 / 持仓行 / 成交行 / 挂单行都改成带 key 的子组件
（key = 股票代码 / 成交号 / 委托号），排序重排 = 移动真实节点，新增/删除行不动其它行；
"输入框所在的块不读信号"这条纪律随之退休（`app/views/ticket.rb` 现在按正常写法写）。

---

### F24. 同一位置换组件类型 → 新组件的根元素会按位置复用**旧组件**的根节点 ✅**已修（citrine PR #18）**

**【现象】** 同一个父块里按条件渲染**两种不同类型的子组件**（keyed 列表的"换类型"场景）时抛异常：

```ruby
# Logs 面板：两个标签页各是一串行组件
box(css_class: "log-body", direction: :column) do
  if tab == :orders
    orders.each { |o| order_row(order: o, key: o.id) }   # OrderRow
  else
    trades.each { |t| trade_row(trade: t, key: t.id) }   # TradeRow
  end
end
```

异常：`NameError: undefined local variable or method 'order' for an instance of TradeRow`
（Opal/DOM 侧表现为**页面卡死**：同一个 `run_block` 在异常路径上反复调和）。

**【证据】**【实测】CRuby 最小复现（25 行，ReactiveRenderer + 两个组件类 + 相同根元素 props）：

```
TradeRow#view → box(css_class: "log-row") { label { trade.id } }
OrderRow#view → box(css_class: "log-row") { label { order.id } }
父组件把 [TradeRow,TradeRow] 换成 [OrderRow]（key 不同、元素 props 相同）
→ NameError: undefined local variable or method 'order' for an instance of TradeRow
   renderer.rb:100 in `instance_exec`（mount 的 block_effect）
   renderer.rb:210 in `refresh_node`
   component.rb:323 in `emit`
```

**【定位】** `renderer.rb:190-207`（`reusable_node` / `refresh_node`）与 `renderer.rb:142-153`
（`capture_component_root`）。链条是：

1. 组件层匹配失败（`key` 命中旧节点但 `component_identity` 是另一类型）→ 正确地新建子组件实例；
2. 新建子组件的 view 在**父块的复用池**里 emit 根元素 → 根元素没有 key → 走**位置匹配**，
   命中的却是**另一种组件的根节点**（两者元素 props 恰好相同，如 `css_class: "log-row"`）；
3. `refresh_node` 就地沿用该节点的 `block_effect`，而 Effect 内部是
   `node.owner.instance_exec(&node.block)` —— `owner` 仍是**旧组件实例**，
   `block` 却是**新组件**的 → 新块在老 self 上执行，props 全对不上。

元素身份（`[:element, type]`）与组件身份（`[:component, klass]`）是同一个节点的两种身份，
但**位置匹配只比对元素身份**，于是跨组件类型复用了根节点。

**【建议改法】** 位置匹配（无 key 分支）应把"候选节点是**别的组件**的根"排除掉——
例如 `take` 里对元素身份再加一条 `candidate.rendered_component.nil? || candidate.component_identity == 当前 owner 的组件身份`；
或在 `capture_component_root`（新建子组件、复用池里不可能有它的旧节点）里临时禁用位置匹配。
两条都不影响同类型列表的位置复用语义。

**【框架侧修复】✅ citrine PR #18（`ReusePool#take` 按 owner 收口）**：`take` 引入 `requester`
（本次渲染的组件 = `emit` 的 owner），**元素槽位**（keyed 与位置匹配都算）要求
`candidate.owner` 就是 requester——复用/刷新路径本就不更新 `node.owner`，跨 owner 复用必然错配。
这条约束一次覆盖了同一族的两半：跨类型抢根（会崩）**和**"组件根被普通元素取代"（静默不卸载）。
组件槽位语义不变（候选本来就是旧组件的根，其 owner 天然是那个子组件）。
最小复现已沉淀为框架回归测试（`test/nesting_test.rb` 两条，未修版本实测可复现）。

**【本仓库的规避已删除】** 原先两张表各自包一层带 key 的容器（`box(key: :orders) { … }`），
换 key 即换新节点、行在空容器里新建，从而绕开跨类型复用。框架修好后这层容器已删掉，
两串行直接放在同一层（代码见 `app/views/logs.rb`），98 项桩断言依旧全绿。

（附带教训，仍然有效：容器必须显式 `direction: :column`——`box` 默认横排，漏了会把表头和行
排成一行。当初正是这层规避容器漏写方向，在真机截图里被抓到——F23 那一类"桩测不出来"的事故。）

---

### F25. 父组件拿不到子组件实例 → "父调用子自己的方法"只能绕 `rendered_component` ⏳待办

**【现象】** 状态下沉到面板后，父组件有时需要调用面板自己的方法：本仓库的换股
（`select_symbol`）要复位图表面板的取样粒度（`bucket` 是 Chart 自己的 state），
而 `render(Child, **props)` 只返回节点，没有"父组件可见的子组件引用"。

**【证据】**【实测】`ref: :name` 登记的是**元素**句柄（`renderer.rb:421-426`：`node.owner.refs[name] = node.dom`），
owner 是**子组件自己**，父组件 `refs` 里什么也没有。可用的入口只有节点上的
`rendered_component`（`renderer.rb:157-165` 的 `adopt_root` 写入）：

```ruby
@chart_panel = chart(selected: -> { selected }, ...).rendered_component
@chart_panel.reset_bucket   # 换股时调用
```

**【建议改法】** 给 `render` / `components` 一个"父组件可见的引用"（例如 `ref: :chart` 把句柄登记到
**父**组件的 `refs`），或提供 `component_ref(key)`。有了它，父组件调用子方法、
`on_mount` 里拿子面板做初始化都不用绕。关键事件路径（Enter 提交）本仓库已改成
"面板自己解释自己的键"（`window_key` 转发到 `Ticket#submit`），只有"父驱动的复位"还需要句柄。


### F7. 没有生命周期钩子 → 定时器/事件/清理全靠用户自己写 ✅已落地（`on_mount`/`on_unmount`/`ref:`/`Citrine.unmount`，见第七节 7.2）

**【现象】** 无 `on_mount` / `on_unmount` / `effect` / `watch`；`Renderer#dispose` 是 private，
组件无法感知自己被销毁。所有外部资源（定时器、全局键盘、beforeunload）都得在框架外挂。

**【证据】**【实测】本仓库 `app/browser_glue.rb`（迁移后已删除，见第七节 7.2）的自述注释、`app/market.rb:21-22`。
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

### F9. 没有 DevTools / 埋点钩子 → 得自己 hack 框架内部 ⏳**仍未解决**（迁移后埋点仍是外挂，见第七节 7.5）

**【现象】** 信号依赖图、Effect 重跑次数、渲染耗时都看不到。
本仓库想量化"块级重建的粒度"，只能：
① `class_eval` + `alias_method` 包裹 `Effect#run`（纯 Ruby）；
② 包裹 `DomRenderer#create_dom` 统计 `createElement` 次数。

**【证据】**【实测】`app/telemetry.rb` + `app/browser_glue.rb:23-35`（该段迁移后挪到 `app/test_api.rb`，**仍未解决**）；
页面底部"信号与渲染埋点"面板实时显示 122 次重跑 / 84 个节点。

**【建议改法】** 把这两个钩子变成官方能力（P1-8 DevTools 的地基）：
`Citrine.telemetry = { on_effect_run:, on_node_create:, on_flush: }`
或至少提供 `Citrine::Effect.on_run` / `Renderer.on_node_create` 的可插拔回调。
**这是"信号式框架"相对 React 的最大可观测性卖点，不该让用户自己 alias_method。**

### F10. 键盘事件只有 Enter → 失焦提交 / Esc 取消做不到 ✅已落地（`window_key` / `on_key` / `Citrine::KeyEvent`，见第七节 7.3）

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

### F12. 整数除法静默返回浮点 ★ ✅已落地（框架提供 `Citrine::Num`，见第七节 7.1）

**【现象】** `7 / 2` 在 CRuby 是 `3`，在 Opal 是 `3.5`。于是 `123456789 / 100` 变成 `1234567.89`
——金额格式化直接输出 `1,234,567,.89.89` 这种乱码。

**【证据】**【实测】本仓库第一次在 Opal 侧跑就撞上；语义对照见 `docs/probes/`（本仓库 `test/` 有 parity 回归）。
**源码级确认**：Opal 的 `Numeric#/` 就是 JS 除法（`opal/corelib/number.rb:102`）。

**【定位/改法】** 属于 Opal 语义而非 Citrine 代码，但 Citrine 是"面向 Opal 的框架"，
**建议在文档的"技术备忘"里置顶警告**，并考虑在 corelib 之外提供 `Citrine::Num` 之类的工具模块。
本仓库当年的应对：`app/num.rb` 集中提供 `Num.idiv` / `Num.round_to`，且所有金额格式化都走它。
现在框架已内置同一份实现（`Citrine::Num`），本仓库那份副本已删除，只留 `Num = Citrine::Num` 别名（第七节 7.1）。

### F13. 负数取整方向不同

**【现象】** `(-1.5).round`：CRuby `-2`（远离零），Opal `-1`（JS `Math.round` 朝 +∞）。

**【证据】**【实测】同上语义对照。**【改法】** 同上：取整先取绝对值再回贴符号。`Citrine::Num.round_to` 已是这个语义（`round_to(-1.5, 0) # => -2`）。

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

> **2026-09-14 更新（框架 F4 响应式属性 + F5 组件嵌套 + F6 keyed 复用落地后）**：
> 第 3 条**已退休**（keyed/位置复用保证块重跑命中同一批节点，输入框不再被重建）。
> 第 1、2、4 条仍然成立，但第 1 条的理由变了：容器块读信号不再导致"整树重建"
> （调和会复用节点与子组件），而是让**整棵子树跟着重跑一遍调和**——逐档行情下这仍是浪费，
> 所以"会变的数字放到最内层小块"照旧。第 4 条的理由（快照由父块下发）也变了：
> 现在**不能**把会变的值当 props 传（props 一变 keyed 子组件就重建，见 7.6），
> 传的是**取值 Proc**。
> 心跳与全局键盘也不再需要外挂层（第七节）。

写出不崩、不卡、不闪的应用，本仓库总结出四条纪律（`app/views/common.rb` 有注释版）：

1. **容器块不读信号** —— 结构不随高频信号打散；会变的数字放到**最内层**小块里读
   （读在叶子块 → 更新只改 `textContent`，**0 个元素重建**）。子组件的 view 体也一样：
   在里面读信号，等于每次重跑都要重建它整棵子树的调和（keyed 行仍会复用，但白跑一遍）。
2. **随值变的外观用响应式属性（`css_class:` / `style:` 传 Proc）** —— 订阅落在该节点自己的
   属性 Effect 上，重跑只重设属性；没有响应式表示的场景（改的是子节点集合/结构）才退回
   "块读信号并重建"。**内层标签绝不再读同一信号**——祖先与后代订阅同一信号曾触发框架
   崩溃（F1，已修复，但这类结构仍应避免）。
3. ~~**输入框所在的块不读任何信号**~~ —— **已退休**（F6 keyed 复用落地）：重跑的块按 key/位置
   命中同一批节点，输入框不再被销毁重建，焦点与输入法状态因此不丢。
4. **跨组件传值传"取值 Proc"，不传值** —— props 变化会让 keyed 子组件**重建**（S1 语义），
   而且父块读信号会让整棵树跟着调和。把 `->(code) { quote_of(code) }` 这样的闭包传下去，
   子组件在最内层 `.call`，订阅就落在子组件那个叶子上（唯一例外：永不变化的值）。
   详见 7.6。

---

## 六、优先级建议（按投入产出比）

| 优先级 | 项 | 理由 |
|---|---|---|
| **P0（几行代码，防崩溃）** | F1、F2 | 都是崩溃级，F1 的修复是 2 行；F2 至少改成可读异常 |
| **P0（体验断层）** | F3 批量更新、F4 props 重应用 | F3 决定有无闪烁与性能上限；F4 决定动画能不能做（F10 依赖它） |
| **P1（表达力）** | ~~F5 组件嵌套~~、~~F6 keyed 复用~~、~~F7 生命周期宏~~（均已落地）、~~F24 调和的位置匹配~~（citrine #18 已修）、**F25 子组件引用** | 前三个决定"能不能写正常规模的应用"，本仓库曾因此被挤成"单类 + mixin"；F24 是它们落地后暴露的新缺口，会直接崩（见第二节） |
| **P1（可观测性，差异化卖点）** | F9 telemetry 钩子 | 信号式框架的天然优势，现在却要用户 `alias_method` 框架内部 |
| **P1（错误可发现性）** | F16–F22 一批静默失败 | 一次 `emit` 层校验 + `set_text` 语义修正 + 样式单位推断，能消掉绝大多数"我明明写了却没生效" |
| **P2（生态）** | F8 渲染器插槽、F11 属性透传、F15 `citrine build`、F23 `box` 默认方向 | 影响范围明确、可延后；F11 里的 `disabled` 建议提前（现在没法禁用按钮）；F23 是"换默认值 or dev 告警"的取舍，改前需公告 |
| **文档（今天就能做）** | F12、F13、F14 置顶写入 README「技术备忘」 | 跨平台语义陷阱（尤其整数除法）会让"CRuby 单测全绿"的应用在浏览器里出错 |

**一句话总结**：v1 的**内核语义**（信号 + 块级重建）是成立的，本仓库能在它上面跑出
确定性的每档开销（2026-09-14 组件嵌套迁移后用同 seed 对照实测：**每档 140 次重跑 / 3 个新建节点**，
改动前后逐项相同，见 7.6；耗时都是 8ms 量级，随机器负载浮动，不作为指标）、
以及逐字节跨平台一致的内核；真正的摩擦集中在**三个边界**——① 更新粒度与 props 静态化带来的
"视图层纪律"（F3 仍待办；F4 已用响应式属性消掉大半）、② 组合与生命周期（F5/F6/F7 已落地；
**F24 是组合能力落地后新暴露的调和缺口**）、③ Opal 语义、静默失败与默认值带来的"排查成本"（F12/F16/F23）。

> 附加一条方法论教训（给框架的验收清单）：本仓库的 Node DOM 桩断言（60 → 69 → 98 项）在
> **布局已经塌成 2px** 的状态下依然全绿——因为桩里没有布局引擎（F23）。
> 这次迁移又重演了一次：日志面板的表头和行被排成一行，桩 96 项全绿，
> 是 headless Chrome 截图看出来的（7.6 ⑥）。框架自身的示例验收同样只做"文本/结构断言"，
> 因此**建议把"真实浏览器量尺寸"补进 CI**（headless Chrome 足够，不需要视觉回归），
> 否则一类布局 bug 会长期不可见。

---

## 七、框架能力落地后的迁移记录（2026-09-14）

框架侧 F4（响应式属性）/ F7（生命周期）/ F10（键盘）/ F12–F13（`Citrine::Num`）陆续合并后，
本仓库做了一次"**把外挂层交还给框架**"的迁移（7.1–7.5）。迁移不是把代码搬走就完事——每个新能力都
**简化了一处本仓库的绕法**，外挂层文件 `app/browser_glue.rb`（128 行）因此缩成
`app/test_api.rb`（只剩桩验收钩子与仍无框架形态的渲染埋点）。

随后框架落地了 P0-1（组件嵌套 + keyed 复用，PR #15），本仓库又做了一次
"**把组件树还给组件树**"的迁移（7.6）：面板成为真正的子组件、行成为可复用的 keyed 子组件、
"输入框块不读信号"等绕法纪律退休，并用逐档对照测量确认更新粒度没有退化。

### 7.1 F12–F13：`Citrine::Num` 取代应用内副本

`app/num.rb` 从 39 行的 `idiv` / `round_to` / `round0/1/2` 实现，变成 13 行的
`Num = Citrine::Num` 别名。调用点按名字差异改：`Num.round2(x)` → `Num.round_to(x, 2)`、
`Num.round0(x)` → `Num.round_to(x, 0)`（5 个文件共 51 处：account 21 / engine 16 / chart 10 / stats 3 / parity 1）。

**迁移中要注意的一点**：`round_to` 的返回类型随 `digits` 变（≤0 → Integer，>0 → Float），
所以**不能靠"把 round0/1/2 统一按 round_to(x, 2) 批量替换"**——本次迁移的第一版替换脚本
就把 `Engine#quote` 的 `amount`（成交额，原 `round0`）错写成 2 位小数，靠逐处核对（`rake parity` + 单测）才捞回来。
`rake parity` 的 51 行输出在替换前后逐字节一致（含 `round_neg=-1.000000` 这条负数半值用例）。

### 7.2 F7：心跳定时器交给组件生命周期

`setInterval` 心跳（200ms 一拍、按倍速累积）从外挂层搬进 `Terminal`——它是唯一持有
`paused` / `speed` 的对象，累积毫秒与重入标记只有它能正确解释：

```ruby
class Terminal < Citrine::Component
  on_mount :start_heartbeat
  on_unmount :stop_heartbeat
  window_key :handle_window_key
end
```

- `start_heartbeat` / `stop_heartbeat` 走 `Native(\`window\`).setInterval / clearInterval`（`app/terminal.rb`）
- `app/market.rb` 里那句"框架无 on_unmount，只能自己挂 beforeunload"随之删除
- 入口不再持有定时器，也就不需要"谁来清"的问题：`Citrine.unmount(terminal)` 会跑完 on_unmount

### 7.3 F10：全局键盘从外挂层回到组件声明

window 级 keydown 从 `window.addEventListener` + 自持引用，改成 `window_key :handle_window_key`，
处理器改用框架归一化的 `Citrine::KeyEvent`（`ev.key` / `ev.prevent_default`）。卸载时监听
由框架解绑，不再有"框架不知道的监听器"。

**一处没有平台无关表示、因此仍读原生事件的地方**：快捷键要避让输入框
（在数量框里打 `b` 不该切买入、打空格不该暂停）。这个判断只能写成
`ev.raw[:target]` 取 `tagName` 再比对 `"INPUT"`：

```ruby
target = ev.raw ? ev.raw[:target] : nil
tag = target ? target[:tagName].to_s.upcase : ""
return self if tag == "INPUT"
```

姊妹仓库 citrine-sheets 在迁移时**删掉**了同类判断——那边把键交给输入框自己的
`on_key:` 处理，而这里 `Enter` 的语义是"输入框外提交委托"，输入框内按键本就不该触发，
所以这段判断保留（桩验收里有专门的"输入框内空格不触发暂停"断言锁定它）。

### 7.4 F4：响应式属性让"外观更新"不再重建子树

两处容器块原本只为"把读信号的 props 关进一个块"而读行情，现在改成叶子自己的响应式属性：

```ruby
# 自选行：选中态是行自己的 css_class（从前由父块读 selected 后传入）
box(css_class: -> { selected == code ? "wl-row is-active" : "wl-row" }, on_click: ...)

# 涨跌色：每个数字自己的 style（从前容器块读 quote 后把 style 传给三个标签）
box(css_class: "wl-price") do
  label(css_class: "wl-c-last num", style: -> { quote_style(code) }) { money(quote_of(code)[:last]) }
  ...
end
```

**实测（Node 桩，同 seed 同档位）**：

| 指标 | 迁移前 | 迁移后 |
|---|---|---|
| 每档新建 DOM 节点 | 84 | **54**（少掉的 30 = 10 行 × 3 个价格标签不再重建） |
| 每档渲染耗时 | 6ms | 4–5ms（该项受机器负载影响，只作参考） |
| 每档 Effect 重跑 | 122 | 142（每个响应式属性多一个 Effect；重跑变多、建节点变少是这次交换的本意） |
| 换股（↑↓） | 重建全部 10 行及其子树 | **行节点全部复用**，只重设两行 class |

- 桩断言从"每档新建节点 < 250"**收紧到 < 80**（迁移前 84，会失败；迁移后 54）
- 新增 9 项断言锁定 DOM 身份：价格组/整行/持仓实时列在行情更新后**仍是同一批节点对象**、
  换股后 10 行仍是同一批对象且选中态唯一、且文字确实随行情更新（避免"什么都不更新"也算过）
- 桩断言总数 60 → 69，全绿；`rake test` 29 项 / 238 断言不变
- 本节数字全部来自 `rake stubs`（Node DOM 桩，同一份 Opal 编译产物）；本次迁移**没做真机浏览器实测**（本环境无法起服务给浏览器用），改动涉及 class/style 的重设而非结构变化，仍建议复核时在 Chrome 里点几下自选行

### 7.5 没有改的地方（以及为什么）

- **F9 仍未解决**：`class_eval` 包装 `DomRenderer#create_dom` 的渲染计数仍是外挂层
  (`app/test_api.rb` 的 `RenderInstrumentation`)。框架还没有 telemetry 钩子，而这个 demo
  的卖点之一就是"把每档开销显示在界面上"，所以它留在应用侧，并在文件顶部注明"这是缺口不是推荐姿势"。
  姊妹仓库有一份同款埋点——**两个真实应用各 hack 了一遍，这条摩擦的优先级应该往上提**。
- **`kv` / `kpi` / `metric` 这些构件没改成 Proc**：它们收的是**值**，值由调用方在块里求值，
  于是订阅仍在调用方块上（头部总览、账户统计、图表快照与指标、埋点面板每档都整块重建）。
  要它们也做到"只改文字不重建"，得把 `value_text` 也改成 Proc——
  这是一次跨 6 个面板的 API 改造，**本次刻意没做**（迁移的原则是"不为了用而用"），
  留作下一轮的候选。
- **无纯隔离容器可删**：本仓库没有"只为了关订阅、自己没有布局职责"的容器
  （`wl-price` / `pos-live` / `panel-tools` 都有布局或结构职责），所以这次的收益是
  "容器块不再读信号"，而不是姊妹仓库那种"三层并两层"的结构简化。

### 7.6 F5 + F6：面板变成真子组件、列表改 keyed 复用（2026-09-14，citrine PR #15 之后）

第七节前半段是"把外挂层交还给框架"；这一段是**把组件树还给组件树**：8 个 view mixin
变成 12 个真正的子组件（8 个面板 + 4 个行组件），`Terminal` 从"16 个 state 全塞一个类"变成"只持有 9 个全局模型状态"。

**① 组件树与状态归属**

| 组件 | key | 自己的 state | 从根组件拿到的 props |
|---|---|---|---|
| `Views::Header` | — | — | tick / equity / pnl / total_return / paused / speed / auto_trade + 4 个回调 |
| `Views::Watchlist` → `WatchRow`×10 | 股票代码 | — | codes / name_for / quote_for / active_for / held_for / sort_key / on_sort / on_pick |
| `Views::Chart` | — | `mode` / `bucket` | selected / quote_for / series_for / candles_for / indicators_for |
| `Views::Ticket` | — | `side` / `order_kind` / `qty_text` / `limit_text` | selected / quote_for / name_for / position_for / alert / notice + 估值与解析回调 + `on_submit` |
| `Views::Positions` → `PositionRow`×N | 股票代码 | — | positions / position_for / name_for / quote_for / summary + 3 个回调 |
| `Views::Logs` → `TradeRow` / `OrderRow` | 成交号 / 委托号 | `tab` | trades / orders / on_cancel |
| `Views::Stats` | — | — | ledger / equity / curve / sample_every |
| `Views::DebugBar` | — | — | report / signal_count |

根组件只留：engine / account / 心跳（paused·speed·auto_trade）/ 选中标的 / 排序键与行顺序 /
提示与告警 / 埋点报告 + 全部交易动作。键盘里涉及草稿的键（B/S/Enter）转发给 `Ticket#set_side` /
`Ticket#submit`——草稿归面板所有，就由面板解释这些键。

**② 跨组件传值：传"取值 Proc"，不传值**

props 变化会让 keyed 子组件**重建**（框架 S1 语义：复用按非 Proc props 判等），
而"父块读信号 → 值传下去"还会让整棵树跟着调和。所以会变的数据一律以闭包形式下发：

```ruby
# 根组件：view 里只放 Proc 与回调（本块因此永不重跑）
watchlist(codes: -> { row_order },                # 排序键变了才重跑行集合
          quote_for: ->(code) { quote_of(code) }, # 每档行情：订阅落在调用它的那个叶子
          active_for: ->(code) { selected == code },
          held_for: ->(code) { !position_of(code).nil? },
          on_pick: ->(code) { select_symbol(code) }, ...)

# 行组件：最内层才 call，且响应式属性里也只 call
label(css_class: "wl-c-last num", style: -> { quote_style }) { money(quote[:last]) }
```

**③ 删除的绕法**

- `Terminal` 头部的"v1 无组件嵌套 → 所有面板塞一个类"说明 → 换成组件树与分工说明；
- `app/views/ticket.rb` 的"输入框所在的块**绝不**读信号，否则每档重建丢焦点" → 删除，
  草稿改成本面板的 state，输入框所在的块按正常写法写；
- `app/views/watchlist.rb` 的"行集合只在排序变化时重建 / 换股不再重建行" → 改写为
  "重跑 ≠ 重建：每行带 key，重排只是移动真实节点"；
- `app/views/common.rb` 顶部的四条纪律清单按 7.6 的结论重写（第 3 条退休）。

**④ 更新粒度：没有退化（同 seed 同档位的对照测量）**

对照对象是本次改动前的版本（`git archive HEAD` 到临时目录、同一份框架 main 编译、同一台机器）：

| 指标（每档） | 改动前 | 改动后 |
|---|---|---|
| Effect 重跑（中位数 / 最大） | 140 / 328 | **140 / 328** |
| 新建 DOM 节点（中位数 / 最大） | 3 / 164 | **3 / 164** |
| 渲染耗时（中位数） | 8 ms | 8 ms |
| 挂载时创建节点数 | 514 | 514（F24 修好后删掉了那层规避容器，回到改动前的数字） |

"每档重跑的东西"逐项比对也完全一致：给块/属性 Effect 各打一个标签（`block:label:wl-c-last num=10`
这种）后，两侧在同一档内的重跑集合**逐条相同**（24 条标签，计数一致）——
即"容器块不读信号、会变的数字放最内层"这条纪律在新结构里被逐字保留。
过程中抓到过一次偏离：头部时钟被我写成了在容器块里读档位，多出 1 次每档重跑，
标签比对立刻显形（`block:box:hd-clock=1`），已改回叶子各自读。

**⑤ 真机实测（headless Chrome，`file://` + 场景脚本；本环境没有可交互的浏览器面板）**

- 首页、成交记录页、挂单页三张截图与改动前**肉眼一致**（同一窗口尺寸、同一场景脚本）；
- 脚本化的 DOM 断言（真实 DOM，非桩）：排序重排后 10 行**仍是同一批节点对象**、
  数量输入框**仍是同一节点**、`document.activeElement` **仍是输入框**、草稿值仍在；
  图表切"分时"（面板内部状态）后输入框与焦点同样不受影响；
- 一个有意思的差异：改动前排序**不做节点移动**（位置复用把内容就地换掉，
  `rows_node_order_changed=false`），现在 `=true`——重排真的在移动节点，行实例与行内状态跟着走。

**⑥ 踩到的三件事（都记进正文了）**

- **F24**（✅ 已修，citrine PR #18）：同一位置换组件类型时，新组件的根元素会按位置复用旧组件的根节点（异常/卡死）。
  规避写法：两张表各自包一层**带 key 的容器**。`direction: :column` 不能漏——
  第一版漏了，桩全绿但真机截图里表头和行被排成一行（F23 那类事故），已修。
- **F16 提醒暴露的老毛病**：分时模式下成交量全为 0，`vol-plot` 一根柱子都不画，
  块的结果成了 `bars` 数组，被框架按 `to_s` 渲染并提醒。（这条在改动前就存在，
  只是原来的桩没有点"分时"所以没显形。）现在显式返回 `nil`。
- **缺一个"子组件句柄"（已记为 F25）**：换股时图表取样粒度要复位（`bucket` 是 Chart 自己的 state），
  而框架没有"父组件持有子组件实例"的入口——只能从 `render` 的返回值里取
  `node.rendered_component`（`renderer.rb:157-165` 的 `adopt_root` 写进去的）。
  `ref: :name` 登记的是**元素**句柄、且落在 `node.owner`（子组件）自己的 `refs` 上，
  父组件拿不到。绕法是根组件在 view 里存一句
  `@chart_panel = chart(...).rendered_component`；建议后续给 `render` 一个
  "父组件可见的子组件引用"（或允许 `ref:` 指定登记到父组件），否则键盘/快捷键路径
  想调用面板自己的方法时只能这么绕。

**⑦ 回到测试**

- 桩断言 69 → **98**（新增：重排后行节点身份与 DOM 顺序、插入/删除挂单行不影响其它行、
  新增持仓行不换已有行、面板内部状态更新不重建兄弟面板、排序后输入框身份与草稿仍在…）；
- `rake test` 29 项 / 238 断言、`rake parity` 51 行逐字节一致，均未变；
- 两处测试改动是**测试口径**而非应用行为：限价输入框改为"按需现取"
  （它会随委托类型出现/消失，旧引用在切回限价后指向已摘除的节点），
  以及"成交行数 = min(成交笔数, 14)"（列表本来就只显示最近 14 笔）。


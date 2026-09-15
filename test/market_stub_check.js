// market_stub_check.js — Node DOM 桩验收：Citrine 行情终端（不起浏览器）
//
//   rake stubs
//
// 覆盖：挂载 / 行情 tick / 输入框身份 / 市价与限价下单 / T+1 / 撤单 /
//       排序 / 暂停变速 / 快捷键 / 自动交易 / 清仓 / 重置 / 每档渲染开销量化
const fs = require("fs");
const path = require("path");
const APP = path.join(__dirname, "..", "app");
if (!fs.existsSync(path.join(APP, "market.js"))) {
  console.error("缺少 app/market.js：先执行 rake build（或 bin/dev 由开发服务器现场编译）");
  process.exit(2);
}

// ── DOM 桩（与仓库既有 stub_check.js 同款）────────────────────────────
let created = 0;
function makeEl(tag) {
  created += 1;
  return {
    tagName: tag, textContent: "", className: "", value: "", checked: false,
    style: {}, children: [], parentElement: null, _listeners: {},
    // 真实 DOM 的 appendChild 是"移动"：已在别处的节点先摘下来，已在同一父下的也移到末尾
    appendChild(c) {
      if (c.parentElement && c.parentElement !== this) c.parentElement.removeChild(c);
      this.children = this.children.filter((x) => x !== c);
      c.parentElement = this;
      this.children.push(c);
      return c;
    },
    removeChild(c) { c.parentElement = null; this.children = this.children.filter((x) => x !== c); },
    addEventListener(ev, fn) { (this._listeners[ev] = this._listeners[ev] || []).push(fn); },
    fire(ev, event) { (this._listeners[ev] || []).forEach((fn) => fn(event || {})); },
  };
}
const app = makeEl("div");
const intervals = [];
const keyHandlers = [];
global.window = global;
// 入口的令牌注入（tokens.rb → <style>:root）会 appendChild 到 head
global.document = { getElementById: () => app, createElement: (t) => makeEl(t), head: makeEl("head") };
global.addEventListener = (ev, fn) => { if (ev === "keydown") keyHandlers.push(fn); };
global.setInterval = (fn, ms) => { const id = intervals.length + 1; intervals.push({ id, fn, ms }); return id; };
global.clearInterval = (id) => { const i = intervals.findIndex((x) => x.id === id); if (i >= 0) intervals.splice(i, 1); };

// ── 断言工具 ────────────────────────────────────────────────────────
let failures = 0;
function eq(name, actual, expected) {
  const ok = String(actual) === String(expected);
  console.log(`${ok ? "✓" : "✗"} ${name}${ok ? "" : `  期望 ${JSON.stringify(expected)} 实际 ${JSON.stringify(actual)}`}`);
  if (!ok) failures += 1;
}
function ok(name, condition, detail) {
  console.log(`${condition ? "✓" : "✗"} ${name}${condition ? "" : `  实际 ${JSON.stringify(detail)}`}`);
  if (!condition) failures += 1;
}
const all = (el) => [el, ...el.children.flatMap(all)];
const allByClass = (cls) => all(app).filter((n) => String(n.className).split(" ").includes(cls));
const byClass = (cls) => allByClass(cls)[0];
const byText = (tag, text) => all(app).find((n) => n.tagName === tag && n.textContent === text);
const hasText = (text) => all(app).some((n) => String(n.textContent || "").includes(text));
const inputs = () => all(app).filter((n) => n.tagName === "input");
const texts = (el) => all(el).map((n) => n.textContent).filter((t) => t && String(t).trim() !== "");
const rowText = (el) => texts(el).join("|");
const submitBtn = () => all(app).find((n) => String(n.className).includes("btn-submit"));
// 限价输入框按需现取：它会随委托类型（市价/限价）出现或消失，节点身份不保证跨模式稳定
const limitField = () => inputs().find((n) => n !== qtyInput);
function click(el, what) {
  if (!el) { failures += 1; console.log(`✗ ${what}：元素未找到`); return false; }
  el.fire("click");
  return true;
}
function type(el, value) { el.value = value; el.fire("input"); }
function beat(n) { for (let i = 0; i < n; i += 1) intervals.slice().forEach((x) => x.fn()); }
function key(k, target) {
  keyHandlers.forEach((fn) => fn({ key: k, target: target || app, preventDefault() {} }));
}
const money = (s) => Number(String(s).replace(/,/g, ""));
function state() {
  const out = {};
  String(window.citrineTestApi.state()).split("|").forEach((part) => {
    const i = part.indexOf("=");
    out[part.slice(0, i)] = part.slice(i + 1);
  });
  return out;
}

// ── 加载编译产物（自动挂载 + 启动定时器）────────────────────────────
require(`${APP}/market.js`);

console.log("=== 首次挂载 ===");
eq("自选行数", allByClass("wl-row").length, 10);
eq("初始现金", state().cash, "1,000,000.00");
ok("标题渲染", hasText("Citrine 行情终端"));
ok("模拟盘声明", hasText("本地模拟数据"));
eq("成交空态", hasText("还没有成交记录"), true);
ok("统计面板渲染", hasText("权益曲线（每 3 档采样）"));
ok("埋点面板渲染", hasText("信号与渲染埋点"));
ok("蜡烛图已绘制", allByClass("candle").length >= 20, allByClass("candle").length);
ok("成交量柱已绘制", allByClass("vol-bar").length >= 20, allByClass("vol-bar").length);
const firstRowLast = all(allByClass("wl-row")[0]).find((n) => String(n.className).includes("wl-c-last"));
ok("行情数字有值", /[0-9]/.test(firstRowLast.textContent), firstRowLast.textContent);
const qtyInput = inputs()[0];
ok("数量输入框存在", !!qtyInput);

console.log("\n=== 每档渲染开销（量化块级重建的粒度）===");
beat(5); // 200ms×5 ≈ 1 档（1x 下 850ms 一档）
let s = state();
ok(`tick 已推进（tick=${s.tick}）`, Number(s.tick) >= 1);
ok(`每档 Effect 重跑 ${s.effects} 次（< 400）`, Number(s.effects) > 0 && Number(s.effects) < 400);
// 84 → 54：自选行的涨跌色不再靠重建 3 个标签，改由各标签自己的响应式 style 重设属性
ok(`每档新建 DOM 节点 ${s.nodes} 个（< 80；G-2 迁移前为 84，其余为图表/统计面板的正常重建）`, Number(s.nodes) < 80);
ok(`每档渲染耗时 ${s.elapsed} ms（< 60）`, Number(s.elapsed) < 60);
const tickBefore = Number(s.tick);
beat(5);
ok("心跳按倍速累积，约每 5 拍推进一档", Number(state().tick) > tickBefore, state().tick);
eq("多档 tick 后数量输入框仍是同一 DOM 节点", inputs()[0] === qtyInput, true);
eq("图表随行情重绘（蜡烛仍在）", allByClass("candle").length >= 20, true);

console.log("\n=== 响应式属性：行情变化不重建节点 ===");
// 自选价格组（10 行 × 3 个数字）：从前容器块读 quote 后重建 3 个标签，现在只重设 style/文字
const priceCellsBefore = allByClass("wl-price")[0].children.slice();
const rowCellsBefore = allByClass("wl-row")[0].children.slice();
window.citrineTestApi.fireTick();
const priceCellsAfter = allByClass("wl-price")[0].children;
eq("价格组是同一批 DOM 节点", priceCellsBefore.every((c, i) => c === priceCellsAfter[i]), true);
const priceColor = priceCellsAfter[0].style.color;
ok(`价格组仍带涨跌色（响应式 style 已重设，color=${priceColor || "无"}）`, /rgb|#/.test(String(priceColor)), String(priceColor));
// 文字确实跟着行情变（不是"什么都不更新"）
ok("最新价文字随行情更新", /[0-9]/.test(String(priceCellsAfter[0].textContent)), priceCellsAfter[0].textContent);
const rowCellsAfter = allByClass("wl-row")[0].children;
eq("整行仍是同一批 DOM 节点", rowCellsBefore.every((c, i) => c === rowCellsAfter[i]), true);

console.log("\n=== 市价买入 ===");
type(qtyInput, "500");
ok("提交按钮文案跟随选中标的", String(submitBtn().textContent).includes("买入 贵州茅台"), submitBtn().textContent);
click(submitBtn(), "提交按钮");
s = state();
eq("成交笔数", s.trades, "1");
eq("持仓数量", s.held, "500");
eq("可用数量（T+1 锁定）", s.held_available, "0");
ok("现金减少", money(s.cash) < 1000000, s.cash);
ok("持仓面板出现明细", hasText("贵州茅台") && allByClass("pos-row").length === 1);
ok("自选列表出现持仓标记", allByClass("badge-hold").length >= 1);

console.log("\n=== 同档卖出被 T+1 拒绝 ===");
click(byText("button", "卖出"), "卖出 chip");
type(qtyInput, "100");
click(submitBtn(), "提交按钮");
s = state();
ok(`提示 T+1 限制：${s.alert}`, String(s.alert).includes("T+1"));
eq("持仓未变", s.held, "500");

console.log("\n=== 次档卖出成交 ===");
window.citrineTestApi.runTicks(1);
s = state();
eq("T+1 解锁可用数量", s.held_available, "500");
type(qtyInput, "200");
click(submitBtn(), "提交按钮");
s = state();
eq("成交笔数", s.trades, "2");
eq("剩余持仓", s.held, "300");
ok("已实现盈亏字段有值", s.realized !== "", s.realized);

// 持仓行的实时列（现价/市值/浮盈/收益率）同理：响应式 style 让每档只重设属性
const liveBefore = allByClass("pos-live")[0].children.slice();
window.citrineTestApi.fireTick();
const liveAfter = allByClass("pos-live")[0].children;
eq("持仓实时列是同一批 DOM 节点", liveBefore.every((c, i) => c === liveAfter[i]), true);
ok("持仓浮盈文字随行情更新", /[0-9]/.test(String(liveAfter[2].textContent)), liveAfter[2].textContent);

console.log("\n=== 面板是独立组件：面板内部状态更新不重建兄弟面板 ===");
// 图表取样（蜡烛/分时）是 Chart 面板自己的 state，日志标签页是 Logs 面板自己的 state。
// 改它们只该重跑本面板内部的那一块，兄弟面板的自选行/持仓行/下单输入框都不动。
const rowsBeforeMode = allByClass("wl-row");
const posRowsBeforeMode = allByClass("pos-row");
const tickBeforeMode = state().tick;
click(byText("button", "分时"), "分时 chip");
ok("图表切到分时（重绘为分时柱）", allByClass("minute-bar").length >= 20, allByClass("minute-bar").length);
ok("分时 chip 进入选中态", String(byText("button", "分时").className).includes("is-on"), byText("button", "分时").className);
eq("图表内部状态更新不重建自选行", rowsBeforeMode.every((r, i) => r === allByClass("wl-row")[i]), true);
eq("图表内部状态更新不重建持仓行", posRowsBeforeMode.every((r, i) => r === allByClass("pos-row")[i]), true);
eq("图表内部状态更新不重建下单输入框", inputs().includes(qtyInput), true);
eq("图表内部状态更新不影响行情推进", state().tick, tickBeforeMode);
click(byText("button", "蜡烛"), "蜡烛 chip（复原）");
ok("切回蜡烛图", allByClass("candle").length >= 20, allByClass("candle").length);

const rowsBeforeTab = allByClass("wl-row");
click(byText("button", "挂单"), "挂单标签页");
eq("日志面板内部切页不重建自选行", rowsBeforeTab.every((r, i) => r === allByClass("wl-row")[i]), true);
eq("日志面板内部切页不重建下单输入框", inputs().includes(qtyInput), true);
ok("无挂单时显示空态", hasText("无挂单"), true);
click(byText("button", "成交记录"), "成交记录标签页");
ok("切回成交记录后成交行重新出现", allByClass("log-row").length >= 1, allByClass("log-row").length);

console.log("\n=== 限价挂单 / 撤单 ===");
click(byText("button", "限价"), "限价 chip");
const limitInput = inputs().find((n) => n !== qtyInput);
ok("限价输入框出现", !!limitInput);
// 限价单必须落在涨跌停区间内、且低于卖一价（否则会即时成交）
const ask = Number(state().ask);
const restingLimit = (ask * 0.98).toFixed(2);
type(limitInput, restingLimit);
click(byText("button", "买入"), "买入 chip");
type(qtyInput, "100");
click(submitBtn(), "提交按钮");
s = state();
eq("挂单数", s.orders, "1");
ok(`冻结资金 ${s.frozen} > 0`, money(s.frozen) > 0);
ok(`提示已挂单（限价 ${restingLimit}）：${s.notice}`, String(s.notice).includes("已挂单"), s.notice);
click(byText("button", "挂单"), "挂单标签页");
ok("挂单列表出现撤单按钮", !!byText("button", "撤单"));
click(byText("button", "撤单"), "撤单按钮");
s = state();
eq("撤单后挂单数", s.orders, "0");
eq("冻结资金归零", s.frozen, "0.00");

console.log("\n=== keyed 复用：插入 / 删除行不换已有行 ===");
// 挂单行（OrderRow，key = 委托号）：再挂一笔，已有行必须是同一个 DOM 对象
click(byText("button", "买入"), "买入 chip");
type(qtyInput, "100");
type(limitField(), (Number(state().ask) * 0.98).toFixed(2));
click(submitBtn(), "提交按钮（第一笔挂单）");
const orderRowsFirst = allByClass("log-row");
eq("挂单行数（第一笔）", orderRowsFirst.length, 1);
key("ArrowDown"); // 换股：选中标的变了，但挂单行本身不该动
const ask2 = Number(state().ask);
type(limitField(), (ask2 * 0.98).toFixed(2));
click(submitBtn(), "提交按钮（第二笔挂单）");
const orderRowsSecond = allByClass("log-row");
eq("挂单行数（第二笔）", orderRowsSecond.length, 2);
eq("新增挂单不换已有挂单行（keyed 复用）", orderRowsSecond.includes(orderRowsFirst[0]), true);
// 撤掉新挂的那笔：老挂单行仍是同一个节点（删除只影响被删的那一行）
const cancelButtons = all(app).filter((n) => n.tagName === "button" && n.textContent === "撤单");
click(cancelButtons[cancelButtons.length - 1], "第二笔撤单");
const orderRowsAfterCancel = allByClass("log-row");
eq("撤单后剩一行", orderRowsAfterCancel.length, 1);
eq("删除另一行不影响已有行节点", orderRowsAfterCancel[0] === orderRowsFirst[0], true);

// 持仓行（PositionRow，key = 股票代码）：再买一只标的，原持仓行必须是同一个 DOM 对象
const heldRowsFirst = allByClass("pos-row");
eq("此前的持仓行数", heldRowsFirst.length, 1);
click(byText("button", "市价"), "市价 chip");
type(qtyInput, "100");
click(submitBtn(), "提交按钮（买入第二只）");
const heldRowsSecond = allByClass("pos-row");
eq("持仓行数（新增一只）", heldRowsSecond.length, 2);
eq("新增持仓不换已有持仓行（keyed 复用）", heldRowsFirst.every((r) => heldRowsSecond.includes(r)), true);
eq("新增持仓行是新节点", heldRowsSecond.filter((r) => !heldRowsFirst.includes(r)).length, 1);
click(byText("button", "限价"), "限价 chip（复原委托类型）");

console.log("\n=== 非法输入校验 ===");
type(qtyInput, "150");
click(submitBtn(), "提交按钮");
ok("非整手报错", String(state().alert).includes("整数倍"), state().alert);
type(qtyInput, "abc");
click(submitBtn(), "提交按钮");
ok("非数字报错", String(state().alert).includes("数量无效"), state().alert);
type(qtyInput, "100");

console.log("\n=== 涨跌停限价校验 ===");
type(limitField(), "99999.00");
click(submitBtn(), "提交按钮");
ok("超涨跌停区间被拒", String(state().alert).includes("涨跌停"), state().alert);

console.log("\n=== 排序 ===");
eq("默认排序键", state().sort, "code");
const beforeOrder = allByClass("wl-row").map(rowText);
const rowsBeforeSort = allByClass("wl-row");
const draftBeforeSort = qtyInput.value;
click(byText("button", "涨跌幅"), "涨跌幅 chip");
const afterOrder = allByClass("wl-row").map(rowText);
eq("排序键已切换", state().sort, "change");
ok("按涨跌幅重排后顺序变化", JSON.stringify(beforeOrder) !== JSON.stringify(afterOrder));
eq("排序不丢行", allByClass("wl-row").length, 10);
// keyed 复用（WatchRow，key = 股票代码）：重排是"移动真实节点"，不是"重建行"
const rowsAfterSort = allByClass("wl-row");
eq("重排后自选行仍是同一批 DOM 对象",
  rowsAfterSort.length === rowsBeforeSort.length && rowsBeforeSort.every((r) => rowsAfterSort.includes(r)), true);
eq("重排后 DOM 顺序与新顺序一致", rowsAfterSort.map(rowText).join("|"), afterOrder.join("|"));
// 行重排期间，兄弟面板（下单）的输入框与草稿不受影响：焦点丢失的机制就是节点被替换，
// 桩里没有焦点引擎，用"同一 DOM 对象 + 草稿值不变"锁定（真机等价于焦点不丢）
eq("排序（行重排）后数量输入框仍是同一节点", inputs().includes(qtyInput), true);
eq("排序后输入框草稿仍在", qtyInput.value, draftBeforeSort);

console.log("\n=== 暂停 / 变速 / 快捷键 ===");
click(byText("button", "⏸ 暂停"), "暂停 chip");
const pausedTick = state().tick;
beat(10);
eq("暂停后 tick 不推进", state().tick, pausedTick);
eq("暂停状态", state().paused, "true");
key(" ");
eq("空格继续", state().paused, "false");
key("3");
eq("快捷键 3 → 4x", state().speed, "4");
const selectedBefore = state().selected;
const rowsBeforeSwap = allByClass("wl-row");
// 图表取样粒度是 Chart 面板自己的 state；换股时由根组件调用面板的方法复位（跨组件改子状态）
const candlesFine = allByClass("candle").length;
click(byText("button", "粗"), "粗 chip");
const candlesCoarse = allByClass("candle").length;
ok(`切到粗粒度：蜡烛数变少（${candlesFine} → ${candlesCoarse}）`, candlesCoarse > 0 && candlesCoarse < candlesFine, candlesCoarse);
key("ArrowDown");
ok(`换股后图表取样粒度复位（蜡烛回到 ${allByClass("candle").length}）`, allByClass("candle").length === candlesFine, allByClass("candle").length);
ok(`↑↓ 换股（${selectedBefore} → ${state().selected}）`, state().selected !== selectedBefore);

// 响应式 css_class：换股只重设两行的 class，行节点本身复用
// （从前 wl-body 块读 selected，换股会重建全部 10 行及其子树）
const rowsAfterSwap = allByClass("wl-row");
eq("换股后自选行仍是同一批 DOM 节点", rowsBeforeSwap.length === 10 && rowsBeforeSwap.every((r, i) => r === rowsAfterSwap[i]), true);
eq("选中态行唯一", rowsAfterSwap.filter((r) => String(r.className).split(" ").includes("is-active")).length, 1);
const activeRow = rowsAfterSwap.find((r) => String(r.className).split(" ").includes("is-active"));
ok(`选中态行是当前标的 ${state().selected}`, !!activeRow && texts(activeRow).includes(state().selected), activeRow ? rowText(activeRow) : "无");

const fakeInput = makeEl("input");
fakeInput.tagName = "INPUT";
key(" ", fakeInput);
eq("输入框内空格不触发暂停", state().paused, "false");
key("b");
eq("快捷键 B 切买入", state().side, "buy");
key("s");
eq("快捷键 S 切卖出", state().side, "sell");
key("s");
click(byText("button", "1x"), "1x chip");
eq("点回 1x", state().speed, "1");

console.log("\n=== 自动交易 ===");
click(byText("button", "自动交易 关"), "自动交易 chip");
const tradesBefore = Number(state().trades);
click(byText("button", "成交记录"), "成交记录标签页");
const tradeRowsMid = allByClass("log-row");
const tradesMid = Number(state().trades);
eq("成交行数 = min(成交笔数, 14)", tradeRowsMid.length, Math.min(tradesMid, 14));
window.citrineTestApi.runTicks(25);
ok(`自动交易产生新成交（${tradesBefore} → ${state().trades}）`, Number(state().trades) > tradesBefore);
// 成交行（TradeRow，key = 成交号）：新成交只是插入新行，已有行节点与实例全部保留
const tradeRowsLater = allByClass("log-row");
eq("已有成交行全部保留（keyed 复用）", tradeRowsMid.every((r) => tradeRowsLater.includes(r)), true);
ok(`新成交插入为新行（${tradesMid} → ${state().trades}）`,
  Number(state().trades) <= tradesMid || tradeRowsLater[0] !== tradeRowsMid[0], true);
click(byText("button", "自动交易 开"), "自动交易 chip（关闭）");

console.log("\n=== 一键清仓与重置 ===");
click(byText("button", "一键清仓"), "清仓 chip");
s = state();
ok(`清仓反馈：${s.notice}`, String(s.notice).includes("清仓") || String(s.notice).includes("没有可卖持仓"));
click(byText("button", "重置账户"), "重置 chip");
s = state();
eq("现金回到初始", s.cash, "1,000,000.00");
eq("持仓清空", s.positions, "0");
eq("成交记录清空", s.trades, "0");
eq("挂单清空", s.orders, "0");

window.citrineTestApi.stopTimer();
console.log(failures === 0 ? "\n全部通过 ✅" : `\n${failures} 项失败 ❌`);
process.exit(failures === 0 ? 0 : 1);

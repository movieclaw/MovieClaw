# 订阅模块重构计划（对齐 iOS）

> 目的：把订阅模块（列表页 + 详情页 + 附属页）按 iOS 的**内容 1:1** 重构，UI 全部用鸿蒙原生组件。
> 新会话开工：先读本文件 → 按「开工顺序」逐项做 → 每项改完跑验收流程。

## 0. 现状与目标

iOS 侧订阅模块共 **13 个 Swift 文件（约 4000+ 行）**；鸿蒙侧只有 **5 个 `.ets`**。
所以这不是"改一页"，而是**补齐缺口 + 逐页对齐内容**。

## 1. 文件映射与缺口（先看这张表）

| iOS（`MovieClaw/apps/apple/MovieClaw/Features/Subscriptions/`） | 鸿蒙（`entry/src/main/ets/subscriptions/`） | 状态 |
| --- | --- | --- |
| `SubscriptionsView.swift` + `SubscriptionsHomeSections.swift` + `SubscriptionsHomeHero.swift` | `SubscriptionsPage.ets` | 未逐块比对 |
| `SubscriptionDetailView.swift` + `SubscriptionWantedViews.swift` + `SubscriptionDialogs.swift` | `SubscriptionDetailPage.ets` | **部分对齐**（见 §2） |
| `SubscribeSheet.swift` | `SubscribeSheet.ets` | 未比对 |
| `RuleSetEditorView.swift` + `RuleSetEditorModel.swift` | **缺** | 规则集编辑器，鸿蒙没有 |
| `UpgradeRunSheet.swift` | **缺**（鸿蒙疑似内联在详情页） | 待核 |
| `MediaSourceAnnotationSheet.swift` | **缺** | 待核 |
| `SubscriptionWallView.swift` | **缺** | 待核 |
| `SubscriptionsAPI.swift` | `api/Endpoints.ets` 的 `subscriptions*` | 已补 `PATCH /subscriptions/{id}/tracking-state` |

## 2. 已完成（本会话，勿重做）

- `SubscriptionDetailPage.ets`
  - 收录进度 → iOS `ProgressStrip` 三段式色条（绿=已入库 / 青=洗版中 / 蓝=下载中 / 底轨=缺失）+ 数字图例
  - 加载文案 `正在加载订阅详情…`、失败文案 `未能加载该订阅，可能已被删除。`
  - 新增「暂停追踪 / 恢复追踪」按钮 + iOS 同款二次确认与结果 toast（`subscriptionsSetTrackingState`）
  - **横向溢出修复**：横向留白统一加在页面级 Column（`padding left/right: Theme.pagePadding`），卡片不再自己 `margin`；实测所有内容右缘落在 x=1205（距右 38vp）
- 全站结构（第 8K 轮）：`EntryAbility` 改回 `setWindowLayoutFullScreen(false)`（系统避让安全区）；
  `Theme.statusBarInset = 0`、`Theme.tabBarInset = 72`；沉浸式页面自行 `expandSafeArea` + 读真实 `WindowInsets.top`
- 海报网格列数统一：`Theme.posterColumns()`（2~4 列按屏宽自适应）

## 3. 开工顺序（每步独立可验收）

1. **全局溢出清扫**：搜 `margin({ left: Theme.pagePadding, right: Theme.pagePadding })`，
   凡是「卡片用 margin + 卡片内某行 `width('100%')`」的组合，一律改成
   **横向留白加在页面/区块级**（卡片不带 margin）。这是全站性坑。
2. **`SubscriptionDetailPage.ets` 剩余项**（对照 `SubscriptionDetailView.swift`）：
   - 按钮组补 iOS 的「更多」菜单：自动续订（已开启/已关闭）、取消订阅、（可选）触发搜索
   - 卡内字段：`订阅于 {created_at}`、`规则组`、`收录范围（正片 / 未勾选季 / 洗版中 N）`
   - 取消订阅确认与结果文案：「取消订阅《标题》？」+「将取消你的订阅关注；已经下载或入库的文件不会被删除。」
     + 完成后「已取消订阅，正在后台清理关联内容（可在任务中心查看进度）」
   - 单集状态词表对齐 iOS（`已收齐 · …`、`洗版中（N）`、`正片`、`未勾选季`）
   - `PageTopBar` 组件化（见 §4 坑 1），顺带修掉顶栏标题不刷新
3. **`SubscriptionsPage.ets`**：比对 `SubscriptionsView` + `SubscriptionsHomeSections` + `SubscriptionsHomeHero`
   （Hero 轮播、分组区块、卡片形态、空/加载/失败态文案、右上角菜单项）
4. **`SubscribeSheet.ets`**：比对 `SubscribeSheet.swift` 的字段、校验、提示文案、按钮
5. **缺口三页**：先确认是否真要补（规则集编辑器 / 洗版运行弹层 / 片源标注），
   要补就各自新建页面（走 `router_map.json` 注册 + `NavDestination` 根节点）

## 4. 全站已知坑（踩过，别再踩）

1. **`@Builder` 按值传参不刷新**：`@Builder ScopeSegment(label, selected, …)` 这类点完不更新；
   `PageTopBar(title, onBack)` 这种全局 `@Builder` 会导致「数据加载完标题不刷新」。
   修法：做成 `@ComponentV2` + `@Param`（参考 `common/SettingsControls.ets`）。
2. **卡片 margin + 行内 `width('100%')` = 溢出**：百分比按父级宽度解析，行会顶到屏幕边。
   修法：留白加在页面/区块级，卡片不 margin（见 §3.1）。
3. **沉浸式 vs 系统安全区**：普通页面**不要**自己加状态栏避让（`Theme.statusBarInset` 已是 0）；
   只有沉浸式大图页才 `expandSafeArea` + 用真实 `WindowInsets.top` 做内部偏移。
4. **一个组件只能挂一个 `bindSheet`**：多个弹层要用 `sheetKind` 分发内容（`LogsSection` 是范例）。
5. **`@Builder` 里不能写局部变量/`const`**：要取值就写 `@Builder` 调方法（如 `presetHintOf(id)`）。
6. **ArkTS 是标称类型**：两个同形状的 interface 不能互相赋值（如 `WeixinAccountView` → `ImAccountView`），
   中间加一层自己的类拷贝字段。

## 5. 验收流程（每项都要走完）

```bash
# 1) 静态检查（快）
#    用 arkts_check 工具跑改动过的 .ets
# 2) 构建
"/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw" assembleHap \
  --mode module -p product=default -p buildMode=debug -p isHap=true --no-daemon | grep -E "ERROR|BUILD"
# 3) 装机 + 起应用（模拟器）
HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
$HDC -t 127.0.0.1:5555 install -r entry/build/default/outputs/default/entry-default-signed.hap
# 4) 截图 / 量坐标（判溢出最可靠：uitest dumpLayout 后比 x2 与屏幕宽）
```

**判溢出的硬标准**：`dumpLayout` 里内容节点的右缘要 ≤ `屏幕宽 - 2×16vp×3px`（1320 屏 ≈ 1224，留 16vp 边距），
而不是"看起来还行"。

## 6. 文档约定

每完成一项，往 `docs/harmonyos-port.md` 追加一轮小结（第 8M / 8N …）：
**改了什么 → 为什么 → 实测证据（dump 数字 / 截图结论）→ 没验的部分**。

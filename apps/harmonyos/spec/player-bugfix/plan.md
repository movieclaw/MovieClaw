# Implementation Plan: 播放器与播放详情页缺陷修复（player-bugfix）

**Input**: Feature specification from `spec/player-bugfix/spec.md`

## Summary

修复播放链路 11 项高/中优先级缺陷。核心技术方案：(1) 把 XComponent 视频面从 `showsDetailLayout()` 的 if/else 两个分支中提出为根 Stack 的**常驻子节点**，横竖屏/布局翻转只改尺寸属性、不重建节点，消除位置回退与重复挂载；(2) `attachPlayer` 引入**代际令牌**（最新者胜，过期分支自释放引擎），消除并发泄漏；(3) ReelsPage 在 `initialized` 回调里补 `surfaceId` 绑定并收敛为**单次 prepare**；(4) `stopSession` 清引用、`retryPlayback` 先停旧会话；(5) 方向设置进入时保存、退出时无条件还原；(6) PlayerPrefs 补 `writeEngine` + 设置页加引擎切换行；(7) 控制条交互由"几何禁区排除"改为"事件认领标志"，消除量测滞后导致的点击失效。

## Technical Context

**Language/Version**: ArkTS（API 12+，ArkUI State Management V2）
**Primary Dependencies**: `@kit.MediaKit`（AVPlayer）、libmpv 原生桥（`cpp/mpv_napi.cpp` + `MpvPlayer.ets`）、`@ohos.window`、`@kit.ArkData`（preferences）
**State Management**: 增量修复，沿用项目现有 V2（`@ComponentV2` + `@Local`）；不引入 V1
**Storage**: preferences（`movieclaw_player_prefs`，已有 PlayerPrefs 封装）
**Testing**: `devecocli build` + 模拟器 UI 验证（`arkts_check` 静态检查辅助）
**Target Platform**: HarmonyOS（手机 / 模拟器）
**Project Type**: 已有鸿蒙应用（MovieClaw 客户端）
**Performance Goals**: 任意时刻至多 1 个活跃播放引擎实例；旋转屏幕播放位置保持 ±2s
**Constraints**: 不得改变现有视觉布局与既有功能行为（spec FR-009）；精准修改，不动无关代码
**Scale/Scope**: 涉及 5 个源文件：`PlayerPage.ets`（5299 行）、`ReelsPage.ets`（1420 行）、`PlayerPrefs.ets`、`PlaybackSection.ets`，可能微调 `MpvPlayer.ets`（无计划变更，仅在需要时）

## Project Structure

### Documentation (this feature)

```text
spec/player-bugfix/
├── spec.md              # 已完成（Phase 1）
├── plan.md              # 本文件
└── tasks.md             # Phase 3 产出
```

### Source Code (repository root: `apps/harmonyos`)

```text
entry/src/main/ets/
├── player/
│   ├── PlayerPage.ets        # 主修改点：H1/H2/M1/M2/M3/M5（build 结构、attachPlayer、会话/方向、手势认领）
│   ├── PlayerPrefs.ets       # M4：补 writeEngine + 引擎缓存同步
│   └── MpvPlayer.ets         # 预期不改；若 attachPlayer 串行化需要则微调
├── reels/
│   └── ReelsPage.ets         # H3/H4：surfaceId 绑定 + 单次 prepare
└── settings/
    └── PlaybackSection.ets   # M4：新增「播放引擎」设置行
```

**Structure Decision**: 遵循项目现有架构（功能目录制：`player/`、`reels/`、`settings/`），不引入 MVVM 迁移、不新建文件——全部修复落在既有文件内，符合"精准修改"约束。

## Complexity Tracking

无宪法违规。

## Research & Decisions

### R1: H1 — XComponent 跨布局翻转的存活方式

- **Decision**: 把 `VideoSurface()` 从 `build()` 中 `showsDetailLayout()` 的 if/else 两分支提出，作为根 Stack 的**第一个常驻子节点**（视频永远在最底层）。布局模式变化时只改变其尺寸/位置**属性**（详情模式：宽 100% × `detailVideoHeight()`、贴顶；全屏模式：铺满），ArkUI 属性变化不销毁重建组件节点，XComponent 的 onLoad 只在真正首挂时触发一次。`DetailPane` 在详情模式下叠放在视频面之上（占视频带以下的剩余区域），全屏模式下不渲染。
- **Rationale**: 根因是 XComponent 节点身份随 if/else 分支翻转被销毁重建 → onLoad 二次触发 → `attachPlayer` 重跑 → `pendingSeekMs = session.start_ms` 跳回续播点。保持节点身份是最小且彻底的修法；"重建时保存/恢复位置"的替代方案治标不治本（仍会黑屏一瞬、双次引擎创建）。
- **Alternatives considered**: (a) onAreaChange 持久化 positionMs 并在重建后 seek 恢复——仍有引擎重建开销与黑屏；(b) 冻结 `showsDetailLayout` 一旦确定不再翻转——牺牲竖屏→横屏的详情/全屏形态切换，违背现有交互。
- **注意**: `fitWidth()/fitHeight()` 目前按整层（layerWidth/layerHeight）计算；详情模式下视频面外层容器高为 `detailVideoHeight()`，XComponent 的 fit 尺寸需按**容器实际宽高**（详情模式 = layerWidth × detailVideoHeight）夹紧，避免提出分支后 fit 尺寸仍按全屏算导致画面超出视频带。VideoSurface 内部 Stack 的 `height('100%')` 语义随新容器自动正确。

### R2: H2 — attachPlayer 并发串行化

- **Decision**: 引入**代际令牌** `attachGeneration: number`。`attachPlayer`（与 `attachLocalPlayer`）入口处 `++` 取本代编号，每个 `await` 之后校验 `gen !== this.attachGeneration` 则**释放刚创建的播放器并 return**（防泄漏）；`this.avPlayer = player` 赋值前同样校验。`VideoSurface.onLoad` 的兜底挂载、`negotiate()` 的挂载、切集/重试路径全部经同一令牌仲裁——最新一次请求胜出，旧请求的引擎在下一个 await 点自行释放。
- **Rationale**: 根因是 async attach 无互斥：两次交错执行各自 create，先创建者被 `this.avPlayer` 覆盖后无人 release（mpv 即泄漏原生引擎）。令牌法无需真锁、无死锁风险，且天然处理"onLoad 兜底挂载与 negotiate 挂载竞争"这一实际存在的双入口。
- **Alternatives considered**: (a) 布尔互斥锁 `negotiating` 串行排队——需要队列语义，复杂且易忘记解锁；(b) 只在切集入口防抖——漏掉 onLoad/negotiate 双入口竞争。

### R3: H3/H4 — ReelsPage surfaceId 与 prepare 时序

- **Decision**: `bind()` 的 `stateChange` 监听收敛为唯一状态机：`initialized` → 设置 `player.surfaceId = this.surfaceController.getXComponentSurfaceId()` → `prepare()`；`prepared` → `play()`。删除 `playCurrent()` 里的显式 `await player.prepare()` 与紧随的 `player.play()`（改由 `prepared` 回调驱动起播），`this.playing = true` 与 `startTick()` 移到 `prepared`/`playing` 回调。
- **Rationale**: (H3) AVPlayer 必须在 `initialized` 之后、`prepare` 之前拿到 surfaceId 才有视频输出；当前全文件从未赋值 → 黑屏。(H4) `url` 赋值后状态是异步迁到 `initialized` 的，`playCurrent` 里立即 `await prepare()` 时多半还在 `idle` 态 → 5400102；同时 'initialized' 回调里又 prepare 一次，双 prepare 竞态。AVPlayer 生命周期官方时序即"initialized 设 surfaceId → prepare → prepared 播放"。
- **Alternatives considered**: 保留 `playCurrent` 的显式 prepare、删回调里的——仍然缺 surfaceId 绑定点，且对异步状态迁移时机更脆弱。

### R4: M1/M2 — 会话清理时序

- **Decision**: `retryPlayback()` 开头补 `this.stopSession(); this.releasePlayer();`（先清场再重协商，与 L1471-1473 切集路径对齐）。`stopSession()` 末尾补 `this.session = null;`，使切集/重试期间残留的 report/ping 定时器读到空会话即静默跳过。
- **Rationale**: M1 重试不停止旧会话 → 服务端转码会话残留至超时；M2 停会话不清引用 → `startReport`/`startPingLoop` 的闭包继续拿旧 `session_id` 上报。
- **Alternatives considered**: 在每个定时器回调里比对会话 id——多点防御不如源头清空一处。

### R5: M3 — 方向设置保存/还原

- **Decision**: `onReady` 里在设 `AUTO_ROTATION` **之前**读取并保存当前 `getWindowProperties()` 的方向偏好为成员 `savedOrientation`（读不到则记 `UNSPECIFIED`）；`restoreOrientation()` 改为**无条件**把窗口方向设回 `savedOrientation`（不再以 `landscapeLocked` 为前提），aboutToDisappear 照旧调用。
- **Rationale**: 现状 onReady 无条件 AUTO_ROTATION，退出仅 `landscapeLocked` 时还原——从未点过横屏锁定的用户退出后应用残留"跟随传感器旋转"。保存-还原是最小语义：谁改的谁恢复。
- **Alternatives considered**: 只在退出时统一设回 UNSPECIFIED——若用户进播放器前是竖屏锁定（PORTRAIT），会被错误改掉；保存原值才正确。

### R6: M4 — 引擎偏好写入方 + 设置 UI

- **Decision**: `PlayerPrefs` 补 `static writeEngine(name: string): void`（put `player.engine` + flush + 同步刷新 `engineName` 缓存，非法值归一为 'mpv'）。`PlaybackSection.ets` 的 `TogglesCard` 上方加一张「播放引擎」卡片：两行可选（`mpv`「mpv（默认）」/ `avplayer`「系统播放器」），`aboutToAppear` 里 `loadEngine()` 读初值，点击即 `writeEngine` 并更新本地选中态——改即存、无保存按钮，与该页既有交互一致。
- **Rationale**: `loadEngine()` 读 `player.engine` 但全工程无写入方，avplayer 分支是死代码；设置页是既有偏好入口，最小闭环。
- **Alternatives considered**: 删除死代码固定 mpv——用户已在 Phase 1 明确选择"加设置 UI"。

### R7: M5 — 控制条交互由几何排除改为事件认领

- **Decision**: 在 `Controls` 的三个交互容器（顶栏 Row、中部三键 Row、底栏 Column）上各加 `onTouch`：Down 置 `chromeTouchClaimed = true`，Up/Cancel 置回 false。根 Stack 的 `onGesture` 在 Down 分支最前面检查该标志——已认领则整次触摸不进手势层（与现有 `inChromeExclusion` 同语义但由**事件本身**驱动）。保留 `inChromeExclusion` 几何禁区作为兜底（两道检查取或）。
- **Rationale**: 上个提交自述的"模拟器上暂停键、进度条不可靠"最可疑根因是几何禁区量测滞后：`chromeTopY/chromeCenterY/chromeBottomY` 由 onAreaChange 换算且依赖 `layerOriginY`，旋转/布局变化瞬间或 detail 模式下 band 过期 → 点按钮落进手势层 → handleTap 翻转 `chromeVisible` → Controls 卸载、onClick 丢失（表现为"点了没反应"）。ArkUI 触摸事件自叶向根冒泡：容器 onTouch 先于根 Stack onTouch 收到同一 Down，标志在同事件内可见，不依赖任何量测。无法在无设备环境复现验证，故保留几何兜底、采用加法修复降低回归风险。
- **Alternatives considered**: (a) 仅刷新 band 量测时机——治标，仍存窗口期；(b) 完全移除几何禁区——激进，M5 根因未实证前风险高。

## Data Model

新增/调整的字段均为现有 struct 内的私有成员，无新实体类：

| 成员 | 所在 | 类型语义 | 用途 |
|---|---|---|---|
| `attachGeneration` | PlayerPage | 自增整数令牌 | attachPlayer/attachLocalPlayer 并发仲裁（R2） |
| `savedOrientation` | PlayerPage | `window.Orientation` | 进入播放页前的方向偏好快照（R5） |
| `chromeTouchClaimed` | PlayerPage | 布尔 | 控制条触摸认领标志（R7） |
| `PlayerPrefs.writeEngine(name)` | PlayerPrefs | `'mpv' \| 'avplayer'` → preferences 键 `player.engine` | 引擎偏好写入（R6） |
| `PlaybackSection.engine` | PlaybackSection | `@Local` 字符串 | 设置页引擎选中态（R6） |

ReelsPage 无新成员（surfaceId 在 'initialized' 回调内即时取用）。

## Contracts & Interfaces

- **PlayerPrefs（对内公共契约）**：新增 `static writeEngine(name: string): void`；既有 `loadEngine()/engine()` 语义不变。`name` 仅接受 `'mpv'`/`'avplayer'`，其余值归一为 `'mpv'`。
- **AVPlayer 生命周期时序（ReelsPage）**：`idle →(url)→ initialized →(surfaceId+prepare)→ prepared →(play)→ playing`；任何状态仅前进一次 prepare。
- **PlayerPage attach 契约**：任意时刻至多一个活跃引擎；`attachPlayer/attachLocalPlayer` 可重入，重入时旧调用在最近的 await 点之后自弃权并释放其创建的实例。
- **服务端接口**：不变（`playbackSessionStart/Stop/Ping`、`playbackProgress*`），仅修正客户端调用时序（M1/M2）。

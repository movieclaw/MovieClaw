# Implementation Plan: HarmonyOS TV 端（智慧屏）Apple TV 风格 UI

**Input**: Feature specification from `spec/tv-ui/spec.md`

## Summary

为现有 MovieClaw HarmonyOS 应用新增智慧屏（Mate TV）端：`module.json5` 新增 `tv` 设备类型，`EntryAbility` 按设备类型分流到新增的 TV 根页面；TV UI 全部放在新目录 `entry/src/main/ets/tv/`（产品定制层），视觉与信息架构照 Apple TV 参考项目（`apps/apple/MovieClawTV`）实现，全部使用官方 ArkUI 组件与官方 Kit 能力（AVPlayer + 服务端 HLS），零自绘、零 mpv；交互双轨支持灵犀指向遥控（悬浮/点击/滑动）与方向键焦点导航。复用现有 V2 状态管理与 API 层（`common/AppModel`、`api/*`、`common/*` 存储），手机端现有 104 个组件文件零改动（仅 EntryAbility 一处接线 + 三个清单文件改动）。

## Technical Context

**Language/Version**: ArkTS（ArkTS strict mode），HarmonyOS SDK 6.1.1(24)，compatibleSdkVersion 同现有工程
**Primary Dependencies**: 官方 ArkUI 全量组件、`@kit.MediaKit`（AVPlayer + HLS）、`@kit.NetworkKit`（UDP 局域网发现）、`@kit.ScanKit`（配对二维码生成）、`@kit.ArkUI`（focusControl 焦点控制）、现有工程 `api/*`（ApiClient/Endpoints/Models）、现有 `common/*`（AppModel/TokenVault/SavedServers/ServerAddress/LibraryHomeStore/Formatters/ImageUrls/EventStream）
**State Management**: 沿用项目现状 **State Management V2**（`@ComponentV2` / `@ObservedV2` + `@Trace` / `@Local` / `@Monitor`）。TV 新代码全部 V2；不迁移手机端任何 V1 组件。
**Storage**: 沿用现有持久层（`TokenVault` 令牌、`SavedServers` 服务器与账号快照、Preferences）；新增 TV 本地记忆项（每库排序/只看没看过）走同一 Preferences 通道
**Testing**: 无单元测试基建沿用；验证方式 = `devecocli build` 构建 +（Phase 3 评审门决定是否）模拟器/预览器截图 UI 验证；无 TV 真机（OQ-3 风险已知悉）
**Target Platform**: 华为智慧屏（Mate TV：1280×720 vp，3840×2160 px @3x，固定横屏，系统强制深色，横向断点 lg）；手机/平板/2in1 现有行为零回归
**Project Type**: 现有 HarmonyOS 应用（单 entry HAP）的增量设备形态
**Performance Goals**: 冷启动到首页可操作 ≤ 5s；海报墙大库（万级条目）窗口式分页滚动流畅；大图区切换、行滚动 60fps 级观感（模拟器目测）
**Constraints**: 全部视觉元素由官方组件渲染（FR-019，禁止 Canvas 自绘视觉）；TV 不新增后端接口（FR-004）；TV 固定深色（FR-021）；手机端 UI 回归零变化（FR-020/SC-006）
**Scale/Scope**: 10 个用户故事 / 22 条 FR；TV 新增约 15 个 ArkTS 文件；改动现有文件仅 3 处清单 + 1 处接线（详见 Project Structure）

## Project Structure

### Documentation (this feature)

```text
spec/tv-ui/
├── spec.md              # 需求规格（Phase 1 产物）
├── plan.md              # 本文件（Phase 2 产物）
└── tasks.md             # 任务拆解（Phase 3 产物）
```

### Source Code (repository root: apps/harmonyos)

```text
entry/src/main/
├── module.json5                     # [改动] deviceTypes 增加 "tv"
├── resources/base/profile/
│   └── main_pages.json              # [改动] src 增加 "tv/TvIndex"
├── ets/
│   ├── entryability/
│   │   └── EntryAbility.ets         # [改动] onWindowStageCreate 按 deviceType 分流加载页面
│   ├── (现有 api/ common/ pages/ library/ search/ player/ … 104 文件全部零改动)
│   └── tv/                          # [新增] TV 产品定制层（全部新代码）
│       ├── TvIndex.ets              # @Entry：按 AppModel.phase 切 TV 根视图（对应手机 pages/Index 的 TV 版）
│       ├── theme/
│       │   └── TvTheme.ets          # TV 设计令牌：颜色、字号、间距、圆角、卡片尺寸（1920×1080→1280×720 等比换算）
│       ├── components/              # TV 复用组件（全部官方组件组合，零自绘）
│       │   ├── TvFocusable.ets      # 双态基座：悬浮+焦点统一视觉（onHover/onFocus + 官方 scale/border/亮边动画 + 点击）
│       │   ├── TvCards.ets          # 海报卡/横版剧照卡/库卡/人物卡/分集卡/「查看全部」尾卡（全部经由 TvFocusable）
│       │   ├── TvStage.ets          # 大图区组件（背景大图+左下文案块+按钮行，首页与详情首屏共用）
│       │   └── TvShelf.ets          # 横滑内容行（行标题态联动 + 横滑 List + 焦点分区最近落点）
│       ├── nav/
│       │   └── TvShell.ets          # 主外壳：可收起胶囊侧边栏 + 三页签（账号/搜索/首页）+ 二级页 Stack + 播放器覆盖层
│       ├── welcome/
│       │   └── TvWelcome.ets        # 欢迎流程：局域网发现/手动地址 → 登录（密码/配对码+二维码）→ 状态页
│       ├── accounts/
│       │   └── TvAccountsPage.ets   # 谁在看（头像横排/添加账号/退出确认/关于）
│       ├── home/
│       │   └── TvHomePage.ets       # 首页（大图区防抖切换 + Ken Burns 慢推 + 2 秒大图预告 + 内容行）
│       ├── library/
│       │   └── TvLibraryWall.ets    # 海报墙（5 列 + 排序筛选 + 索引条 + 窗口分页 + 滚动浮标 + 模糊背景）
│       ├── detail/
│       │   └── TvItemDetail.ets     # 详情页（两截结构：首屏大图区 + 分集/演职员/相似/系列/合集）
│       ├── search/
│       │   └── TvSearchPage.ets     # 搜索（系统输入法 + 人物行 + 条目行分页）
│       ├── player/
│       │   ├── TvPlayerPage.ets     # 播放器控制层（传输条 + 信息面板 + 跳过片头/下一集/还在看吗 + 错误态）
│       │   └── TvAvPlayerEngine.ets # AVPlayer+HLS 引擎封装（会话/起播/轨道切换/进度上报/连发快进）
│       └── model/
│           └── TvUiState.ets        # TV 特有 UI 状态：导航路由栈、每库排序筛选记忆、播放器 UI 状态机
```

**Structure Decision**: 本计划**遵循现有项目架构**（特性化目录分层 + V2 状态管理 + 特性内文件聚合，非 MVVM 目录迁移）。TV 端按 Apple TV 参考项目的分层（Shell/Home/Library/Detail/Player/Search/DesignSystem）映射为 `ets/tv/` 下的特性目录：`components/` 承担 DesignSystem 角色（TvFocusable/TvCards/TvStage/TvShelf 四个复用件覆盖全部卡片与大图区），`model/TvUiState.ets` 集中 TV 特有可观察状态，业务数据层（AppModel/ApiClient/存储）全部复用现有 `common/` 与 `api/`，不建 viewmodel/service/data 目录——Apple TV 参考项目正是「共享引擎层 + 重写界面层」的同样结构。预计 15 个新文件：组件复用度高（所有卡片收敛到 TvCards，所有双态交互收敛到 TvFocusable），每个文件对应一个独立 TV 屏幕/职责，拆分由 10 个用户故事的屏幕边界决定，无冗余文件。

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| 双交互模型组件（TvFocusable 单独成文件） | FR-018 要求悬浮+焦点双态统一；不收敛则 10+ 页面各自实现两套事件，必然漂移 | 每页内联处理被否：重复度高、视觉不一致，且组合实现（OQ-2）需集中管理动画令牌 |
| 新建 TvAvPlayerEngine 而非复用 MpvPlayer | FR-012 明确 TV 走 AVPlayer+HLS，mpv 不进 TV 端 | 复用 mpv 被否：用户已决策 AVPlayer 路线；且 TV 无真机无法验证 mpv native 库在 TV SoC 的兼容性 |
| EntryAbility 改动（唯一接线点） | 设备分流必须有单一入口决策点 | 在 Index 页内分流被否：TV 与手机根页面生命周期/初始化差异大，Ability 层分流最干净且手机路径零风险 |

## Research & Decisions

- **Decision（OQ-1 工程分流形态）**: 单 entry HAP + `EntryAbility.onWindowStageCreate` 按 `deviceInfo.deviceType === 'tv'` 分流加载 `tv/TvIndex` 或 `pages/Index`；`module.json5` deviceTypes 增加 `"tv"`。
  **Rationale**: 一个包、一套签名、一条 AGC 上架链路；TV 代码完全隔离在 `ets/tv/` 满足 FR-020；接线点唯一（EntryAbility 一处 if），手机路径零改动；符合官方「一次开发多端部署」与智慧屏指南中「统一 HAP 多端部署」分支（页面结构虽不同但由运行时分流承载）。
  **Alternatives considered**: ① 独立 feature HAP/多目标产物——构建矩阵、签名、AGC 多包管理复杂度显著上升，且无真机迭代期收益为负；② Index 页内按设备切根组件——入口组件需同时承担两端初始化，回归风险高于 Ability 层分流。

- **Decision（OQ-2 焦点/悬浮放大视觉）**: 采用「官方组件 + 官方事件 + 官方动画」组合实现，收敛到 `TvFocusable` 单一复用件：`onHover`/`onFocus`/`onBlur` 事件驱动，`scale`（约 1.06~1.1×）+ 圆角亮边 + 阴影抬升 + `animateTo` 过渡；焦点导航用官方 `focusable`/`defaultFocus`/`focusControl` 与方向走焦。渲染主体仍是官方组件（Stack/Image/Text/Button），不触碰 Canvas 自绘红线。**（本项按用户规则在 Phase 2 评审门提交确认）**
  **Rationale**: ArkUI 无内建「TV 卡片聚焦放大」组件样式；系统默认焦点框视觉偏离 Apple TV 风格，无法满足「照 Apple TV 风格」的核心诉求。
  **Alternatives considered**: 系统默认焦点样式——省工作量但视觉不达标；Canvas 自绘焦点层——违反 FR-019 红线，直接排除。

- **Decision（TV 导航模型）**: TV 端自管轻量路由：`TvShell` 用 `Stack` + `@ObservedV2` 路由状态数组承载二级页（详情/墙/影人），播放器作为顶层覆盖层；**不接入**现有手机端的 `Navigation` + `router_map` 路由表。
  **Rationale**: 与 Apple TV/Android TV 参考实现同构（单栈 + 播放器覆盖层），TV 页面树与手机完全解耦，避免共用路由表带来的手机端回归风险（SC-006）；返回键语义分级（面板→卡片→退出）需要自管栈才能精确实现。
  **Alternatives considered**: 接入系统 Navigation 路由表——TV 与手机共用 router_map 需在两套 UI 间做名字隔离，耦合收益为负。

- **Decision（状态与业务层复用）**: 复用 `common/AppModel`（phase 流程 launching→…→ready 与 TV 需求一一对应）、`api/ApiClient` 全部端点、`TokenVault`/`SavedServers`/`ServerAddress`/`LibraryHomeStore`/`Formatters`/`ImageUrls`。TV 特有状态（路由栈、每库排序筛选记忆、播放器 UI 状态机、首页焦点行）新建 `tv/model/TvUiState.ets` 集中管理。
  **Rationale**: Apple TV 参考项目即「与 iPhone 共享 AppModel + 重写界面」结构，phase 模型两端口径一致；数据层复用保证 TV 不引入后端行为分叉（FR-004）。
  **Alternatives considered**: TV 独立 AppModel——两份 phase 流程必然漂移，账号/服务器恢复逻辑重复实现。

- **Decision（局域网发现协议）**: 对齐 Android TV 参考实现：UDP 7359 端口向本网段逐个单播 `who is MovieClawServer?`（兼容 `who is JellyfinServer?`），应答候选逐个健康检查（`GET /api/v1/health`）后列出；另保留手动输入地址（自动补全协议与常见端口）。
  **Rationale**: 与服务端现有发现协议零改动（FR-004）；单播扫描规避容器/桥接网络广播不可达问题（Android 参考实现已验证）。
  **Alternatives considered**: mDNS/Bonjour（Apple 端在用）——需服务端跨平台 mDNS 支持验证，且官方 Kit 无 Bonjour 浏览 API，收益为负。

- **Decision（播放引擎）**: 新建 `TvAvPlayerEngine` 封装官方 `@kit.MediaKit` AVPlayer：起播走现有 `playback/decide` → `playback/sessions` 取 HLS 地址；轨道（字幕/音轨）用 AVPlayer 轨道选择能力；画质切换重建 HLS 会话；进度按现有 `progress`/`ping` 端点上报；倍速快进用 `setMediaTime`（seek）分档跳点实现（20×→40×→80×→160× 连发）；trickplay 缩略图用服务端既有 trickplay 图 + 官方 Image。
  **Rationale**: FR-012 已定 AVPlayer+HLS；现有 mpv 全链路（MpvPlayer/PlaybackGuard）与 TV 无关，保持手机端不动。
  **Alternatives considered**: 无（用户已决策）。

- **Decision（尺寸令牌换算）**: Apple TV 参考按 1920×1080 pt 画布定义（edge 80 / poster 266 / landscape 416 / 行距 56 / 卡距 32 / 圆角 20 / 焦点放大 1.1×）；Mate TV 画布 1280×720 vp，按 0.667 等比换算（edge≈53 / poster≈177 / landscape≈277 / 行距≈37 / 卡距≈21 / 圆角≈13），海报墙按 1280 宽重算 5 列网格取整；全部收敛进 `TvTheme.ets` 单一令牌源。
  **Rationale**: 保持 Apple TV 视觉节奏不变；单一令牌源便于全局微调。
  **Alternatives considered**: 直接沿用 pt 数值——TV 上会溢出画布约 1/3。

- **Decision（智慧屏已知差异应对）**: ① TV 全部 `List`/滚动容器显式关闭渐隐（`fadingEdge(false)`，官方文档载明默认开启会覆盖 overlay 并影响截图）；② TV 界面固定深色令牌（系统强制深色）；③ 协议/隐私页用官方 Web 组件承载（智慧屏无浏览器）；④ 搜索输入按系统输入法拉起实现，真机表现列为 OQ-3 后续验证项。
  **Rationale**: 均来自华为官方智慧屏开发指南的明确注意事项，提前固化到设计约束。
  **Alternatives considered**: 无（官方约束）。

## Data Model

**复用实体（现有代码，不改结构）**：服务器（ServerAddress/SavedServers）、账号与令牌（AppModel.SavedAccount/TokenVault）、phase 枚举（AppModel.AppPhase）、API 模型（api/Models 全量）、首页行偏好（LibraryHomeStore）。

**新增 TV 实体（tv/model/TvUiState.ets，全部 @ObservedV2/@Trace）**：

- **TvRoute（导航路由）**: 目的地联合——条目详情（库id+条目id）/ 媒体库墙（库id或来源）/ 行墙（标题+来源）/ 影人页 / 关于；`TvShell` 持路由栈数组，返回弹出一层，播放器为独立覆盖态。
- **TvWallOptions（每库排序筛选记忆）**: 库id → { 排序: addedAt|releaseDate|rating|title；只看没看过: boolean }；持久化到 Preferences（key 前缀 tv_wall_）。
- **TvPlayerUiState（播放器 UI 状态机）**: 显示层枚举（无/传输条/信息面板/trickplay 拖动中）、当前轨道选择（字幕/音轨/画质）、情境元素（跳过片头可见、下一集卡、还在看吗）、连发快进档位与计时。
- **TvHomeFocus（首页焦点态）**: 当前焦点行/卡片索引、大图区当前条目、防抖计时（0.16s）、预告播放计时（2s）与状态（剧照/预告中）。
- **TvDiscoveryState（欢迎流程态）**: 发现扫描进行中/候选服务器列表/手动地址/登录方式（密码|配对）/配对会话。

**状态流转**：EntryAbility 分流 → TvIndex 订阅 AppModel.phase（复用手机端 restore() 语义）→ ready 时 TvShell 接管；TV 内部路由/墙/播放器状态变化仅存在于 TvUiState，不回写 AppModel（除账号切换/退出复用 AppModel 既有方法）。

## Contracts & Interfaces

**入口接线契约（对现有代码的唯一改动面）**

- `EntryAbility.onWindowStageCreate`：读 `deviceInfo.deviceType`；`'tv'` → `windowStage.loadContent('tv/TvIndex')`，其余维持 `'pages/Index'`。加载回调内现有逻辑（沉浸式等）仅对非 TV 路径保持原样；TV 路径执行 TV 初始化（深色固定、横屏确认、AVSession 接线）。
- `main_pages.json`：src 增加 `"tv/TvIndex"`（每文件一个 @Entry 的规则不破坏——TvIndex 与 Index 分属两个文件）。
- `module.json5`：deviceTypes 增加 `"tv"`（requestPermissions/abilities 配置不变，TV 无需新增权限；INTERNET/GET_NETWORK_INFO 已覆盖发现与播放）。

**组件契约（tv/ 内部，均为官方组件组合）**

- `TvFocusable`：输入——尺寸令牌（宽/高/圆角）、内容 Builder、点击回调；输出——悬浮态与焦点态视觉（放大+亮边+阴影，动画时长/曲线取自 TvTheme）；行为——`onHover`/`onFocus`/`onBlur` 驱动同一视觉状态（FR-018 双轨统一落点）。
- `TvCards`：海报卡（2:3，caption 策略 always/focused/band 三档）、横版剧照卡（16:9）、库卡、人物卡（2:3 头像+姓名+作品数）、分集卡（剧照+进度+集名+简介+首播）、「查看全部」尾卡；全部接受条目/影人等既有 api/Models 类型 + 点击路由回调。
- `TvStage`：输入——条目（剧照/Logo/标题/事实行/简介/按钮配置）、展示模式（首页|详情首屏）；输出——大图区布局；首页与详情共用（对应参考项目 TVStage 复用）。
- `TvShelf`：输入——行标题、卡列表、行来源（点击「查看全部」回调）、卡片构造器类型；行为——行内焦点分区最近落点、行标题随行内焦点加亮（FR-005/FR-017）。
- `TvShell`：输入——AppModel（phase ready 后）；管理——三页签态、侧边栏胶囊展开态、路由栈、播放器覆盖层显隐；输出——页面装配。

**引擎契约（TvAvPlayerEngine）**

- 生命周期：`prepare(播放决策结果)` → `start()` → `pause()/resume()/stop()/release()`；状态回调（idle/prepared/playing/paused/error/completed）。
- 控制：`seekTo(毫秒)`、`setPlaybackSpeed(倍速)`（倍速快进档位联动）、轨道选择 `selectSubtitle/selectAudio(轨道id)`、`switchQuality(档位)`（内部重建 HLS 会话并续接进度）。
- 上报：进度上报与 ping 保活按现有 playback 端点节奏；`onProgress` 回调驱动传输条与 trickplay。
- 错误：失败回调带归因（网络/解码/会话），播放器页映射为错误弹窗（重试/返回，FR-013）。

**服务端接口（全部复用现有 api/ 层端点，无新增）**：health、auth（device login/authorize/token）、ui preferences、playback up-next/favorites/decide/sessions/progress/ping/resume、libraries（items/facets/showcase/item-index）、items（detail/episodes/similar）、collections、people、search library、marks、trickplay 与预告片段按 Apple TV 端在用的既有路径。

**验收对照契约**：SC-001~007 对应的用户验收用例集在 Phase 3 tasks.md 中按 10 个用户故事逐条生成，验证阶段按所选范围（build-only / build+ui）执行。

# Implementation Plan: HarmonyOS 车机端（Car）适配

**Input**: Feature specification from `spec/car-ui/spec.md`

## Summary

为现有 MovieClaw HarmonyOS 应用新增车机端：`module.json5` 新增 `car` 设备类型，`EntryAbility` 按设备类型分流到新增的车机根页面；车机 UI 全部放在新目录 `entry/src/main/ets/car/`（产品定制层，与 TV 端 `tv/` 平行），按业界车机媒体软件惯例（鸿蒙座舱/Tesla/Android Automotive/CarPlay 媒体类）裁剪改造：扫码配对登录、大卡首页、触屏海报墙、简化详情、**行车锁视频（手动驾驶模式开关兜底）**的播放器、全局常驻 mini 播控条、语音优先搜索、轻量账号。全部官方 ArkUI 组件渲染、固定深色、大触控目标（≥48vp）、层级 ≤3 级。复用现有 V2 状态管理与 API 层（`common/AppModel`、`api/*`、`common/*`），架构沿用 TV 端已验证模式（设备分流 + 特性目录 + 自管路由 + 播放器覆盖层），交互为纯触屏模型（无 TV 焦点体系）。目标画布 Huawei_Car 模拟器（3402×1620 px @432dpi ≈ 1260×600 vp 超宽横屏）。手机端与 TV 端零回归（改动仅 EntryAbility 一处接线 + 两个清单文件）。

## Technical Context

**Language/Version**: ArkTS（ArkTS strict mode），HarmonyOS SDK 6.1.1(24)（compatibleSdkVersion 同现有工程），Huawei_Car 模拟器为 HarmonyOS 7.0.0(26) Beta1（前向兼容运行，实测为准）
**Primary Dependencies**: 官方 ArkUI 全量组件、`@kit.MediaKit`（AVPlayer + HLS，视频锁后音频继续）、`@kit.AVSessionKit`（车机系统播控联动）、`@kit.ScanKit`（配对二维码生成）、`@kit.NetworkKit`（局域网发现）、现有工程 `api/*`（ApiClient/Endpoints/Models）、现有 `common/*`（AppModel/TokenVault/SavedServers/ServerAddress/LibraryHomeStore/Formatters/ImageUrls/EventStream）
**State Management**: 沿用项目现状 **State Management V2**（`@ComponentV2`/`@ObservedV2`+`@Trace`/`@Local`/`@Monitor`）。车机新代码全部 V2；不迁移手机端任何 V1 组件。
**Storage**: 沿用现有持久层（TokenVault 令牌、SavedServers 服务器与账号快照、Preferences）；新增车机本地记忆项（每库排序/筛选、驾驶模式开关状态）走同一 Preferences 通道（key 前缀 `car_`）
**Testing**: 无单元测试基建沿用；验证方式 = `devecocli build` 构建 + Huawei_Car 模拟器 UI 检查（用户已定「先实现 → 构建 → 模拟器检查」顺序，FR-017）
**Target Platform**: 华为车机（Huawei_Car 模拟器：3402×1620 px @432dpi ≈ **1260×600 vp**，17.2" 超宽横屏 2.1:1，断点 lg/xl）；手机/平板/2in1/TV 现有行为零回归
**Project Type**: 现有 HarmonyOS 应用（单 entry HAP）的增量设备形态
**Performance Goals**: 冷启动到首页可操作 ≤5s；海报墙大库分页滚动流畅；页面切换/播控卡切换 60fps 级观感（模拟器目测）
**Constraints**: 全部视觉元素由官方组件渲染（FR-014，禁止 Canvas 自绘）；触控目标 ≥48vp、层级 ≤3、3 秒注视原则（FR-005）；车机不新增后端接口（FR-002）；固定深色（FR-016）；手机端与 TV 端零回归（FR-015）；纯触屏交互模型（FR-006）
**Scale/Scope**: 9 个用户故事 / 17 条 FR；车机新增约 15 个 ArkTS 文件；改动现有文件仅 2 处清单 + 1 处接线（详见 Project Structure）

## Project Structure

### Documentation (this feature)

```text
spec/car-ui/
├── spec.md              # 需求规格（Phase 1 产物）
├── plan.md              # 本文件（Phase 2 产物）
└── tasks.md             # 任务拆解（Phase 3 产物）
```

### Source Code (repository root: apps/harmonyos)

```text
entry/src/main/
├── module.json5                     # [改动] deviceTypes 增加 "car"
├── resources/base/profile/
│   └── main_pages.json              # [改动] src 增加 "car/CarIndex"
├── ets/
│   ├── entryability/
│   │   └── EntryAbility.ets         # [改动] onWindowStageCreate 分流增加 'car' → loadContent('car/CarIndex')
│   ├── (现有 api/ common/ pages/ library/ search/ player/ tv/ … 全部零改动)
│   └── car/                          # [新增] 车机产品定制层（全部新代码）
│       ├── CarIndex.ets              # @Entry：按 AppModel.phase 切车机根视图（TV Index 的车机版）
│       ├── theme/
│       │   └── CarTheme.ets          # 车机设计令牌：颜色（固定深色）、字号、间距、圆角、触控目标尺寸（≥48vp）、卡片尺寸（1260×600 vp 画布基准）
│       ├── components/               # 车机复用组件（全部官方组件组合，零自绘）
│       │   ├── CarCards.ets          # 大卡组件集：继续观看大卡/收藏大卡/海报卡（2:3）/横版卡（16:9）/人物卡/分集卡/「查看全部」尾卡
│       │   ├── CarRows.ets           # 横滑内容行（行标题 + List 横滑 + 尾卡回调）
│       │   └── CarMiniPlayer.ets     # 常驻 mini 播控条（封面/标题/播放暂停/下一集/点击回播放器，无播放隐藏）
│       ├── nav/
│       │   └── CarShell.ets          # 主外壳：左侧固定图标导航栏（首页/媒体库/搜索/账号）+ 页签内容区 + 二级页 Stack + 播放器覆盖层 + 底部 mini 播控条装配
│       ├── welcome/
│       │   └── CarWelcome.ets        # 欢迎流程：扫码配对为主（屏显二维码+配对码）+ 局域网发现 + 手动地址兜底 → 状态页
│       ├── home/
│       │   └── CarHomePage.ets       # 首页：继续观看/收藏大卡置顶（宽屏左信息右内容）+ 内容行；空态引导
│       ├── library/
│       │   └── CarLibraryWall.ets    # 海报墙：大触控目标网格 + 排序筛选大按钮抽屉 + 窗口分页 + 模糊背景
│       ├── detail/
│       │   └── CarItemDetail.ets     # 详情页：首屏大图+操作按钮行（继续/从头/收藏/已看）+ 分集/演职员/相似（宽屏布局，下半截简化）
│       ├── search/
│       │   └── CarSearchPage.ets     # 搜索：大输入框（系统输入法，语音经输入法可达）+ 条目/影人结果大卡列表
│       ├── accounts/
│       │   └── CarAccountPage.ets    # 轻量账号：当前账号/切换已保存账号/退出确认/关于折叠
│       ├── player/
│       │   ├── CarPlayerPage.ets     # 播放器：驻车全屏视频（传输条/信息面板/跳片头/下一集/错误态）+ 行车大控件播控卡（驾驶卡为播放器内模式视图）
│       │   └── CarAvPlayerEngine.ets # AVPlayer+HLS 引擎封装（模式同 TV 引擎 + 视频锁音频继续 + AVSession 上报与指令）
│       └── model/
│           └── CarUiState.ets        # 车机特有可观察状态：路由栈、每库排序筛选记忆、驾驶模式开关与播放模式、mini 播控显隐、播放器 UI 状态机、欢迎流程态
```

**Structure Decision**: 本计划**遵循现有项目架构**（TV 端已验证的特性目录分层 + V2 状态管理 + 特性内文件聚合，非 MVVM 目录迁移）。车机端复用 TV 端的架构骨架（Shell/Welcome/Home/Library/Detail/Search/Accounts/Player/Theme/Model），核心差异按车机惯例落地：**无 TvFocusable/TvFocus 焦点体系**（纯触屏，点击反馈用官方按压态），**新增 CarMiniPlayer**（常驻播控条）与**驾驶模式/播放模式状态**（CarUiState 内，不单独成文件）。业务数据层（AppModel/ApiClient/存储）全部复用现有 `common/` 与 `api/`，不建 viewmodel/service/data 目录。预计 15 个新文件：组件复用度高（所有卡片收敛到 CarCards，所有行收敛到 CarRows），每个文件对应一个独立车机屏幕/职责，拆分由 9 个用户故事的屏幕边界决定，无冗余文件。

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| 新建 CarAvPlayerEngine 而非与 TvAvPlayerEngine 共享提取 | FR-015 要求车机代码隔离且 TV/手机零回归；提取共享引擎需改动 TV 已验证代码（arkts_check 清零状态） | 提取到 common/ 被否：TV 端已完成的静态检查与实现状态会被打破，回归风险大于代码复用收益；引擎差异真实存在（视频锁音频继续、AVSession 播控指令、无焦点联动） |
| 左侧图标导航栏（非底部页签） | 1260×600 vp 超宽画布垂直空间稀缺（600vp），底部页签+mini 播控条+内容行会挤压内容区 | 底部页签被否：垂直空间占用约为左侧栏 2 倍；车机宽屏惯例（鸿蒙座舱/Android Automotive 媒体类）横向富裕时导航靠边 |
| 手动驾驶模式开关（非自动行车检测） | 当前 SDK 未向三方开放行车/车速信号（Car Kit 仅手机↔车互联，见 Research） | 自动检测被否：无公开 API 可依赖；模拟器上更无信号源；接口留位保证真车信号可达时平滑接入 |

## Research & Decisions

- **Decision（OQ-1 行车信号来源）**: 当前 HarmonyOS SDK（6.1.1(24)/7.0.0(26) Beta1 文档面）**未向三方应用开放行车状态/车速信号**（`devecocli docs search 行车 车速` 确认：Car Kit 仅提供手机↔车互联能力，无行车状态查询 API）。落地为：**手动「驾驶模式」开关为主控**（播放器与 Shell 均提供入口，状态持久化），`CarUiState` 内预留 `DriveSignalProvider` 接口位（真车信号可达时自动优先、手动为兜底），播放模式（驻车视频/行车音频锁）由该状态驱动。
  **Rationale**: 无信号 API 则自动检测不可实现；手动开关在模拟器上可完整验证 FR-009/FR-010；接口留位避免未来返工。
  **Alternatives considered**: ① 依赖系统 API 检测行车——不存在；② 仅做视频锁定不做开关——无法在驻车时主动看视频，功能退化。

- **Decision（工程分流形态）**: 沿用 TV 端已验证模式：单 entry HAP + `EntryAbility.onWindowStageCreate` 按 `deviceInfo.deviceType === 'car'` 分流加载 `car/CarIndex`；`module.json5` deviceTypes 增加 `"car"`。
  **Rationale**: 与 TV 分流点同一处 if 扩展，手机/TV 路径零改动；一个包一条构建上架链路。
  **Alternatives considered**: 独立 feature HAP——构建矩阵复杂度上升，无收益。

- **Decision（车机画布与设计令牌）**: 以 Huawei_Car 模拟器实测规格为基准画布：3402×1620 px @432dpi（densityDpi 432 → vp 换算系数 2.7）≈ **1260×600 vp** 超宽横屏（2.1:1）。`CarTheme` 令牌按该画布定义（基准边距 48vp、海报卡宽约 200~240vp、触控目标最小 48vp、大卡直径/高度按 600vp 高度约束反推），但布局全部用弹性/百分比/Grid 实现（FR-016 响应式），真车屏幕差异靠断点内自适应吸收。
  **Rationale**: 令牌有基准才可控（对齐 TV 令牌方法论）；不锁死画布保证真车兼容。
  **Alternatives considered**: 直接复用 TV 令牌（1280×720 基准）——高度差 120vp 且交互密度不同，触控目标规格不通用。

- **Decision（导航模型）**: 车机自管轻量路由（同 TV 决策）：`CarShell` 左侧固定图标导航栏（首页/媒体库/搜索/账号四页签）+ 二级页（详情/墙/行墙）`Stack` 承载 + 播放器为顶层覆盖层；**不接入** `Navigation` + `router_map`。返回键语义分级（面板→二级页→页签→退出确认）自管实现。影人搜索结果点击进入「影人作品行墙」（不建独立影人详情页，控制层级 ≤3）。
  **Rationale**: 与 TV 同构的解耦收益；左侧栏适配超宽画布（垂直空间留给内容与 mini 播控条）。
  **Alternatives considered**: ① 接系统路由表——与手机/TV 共用 router_map 耦合收益为负；② 底部页签——600vp 高度下垂直空间浪费。

- **Decision（纯触屏交互模型）**: 车机端**不引入**焦点/悬浮双态体系（FR-006，与 TV 核心差异）：可点元素用官方 `Button`/`Image`/`Row` 的 `onClick` + 官方按压态反馈（`stateEffect`/`hoverEffect` 限定 touch 场景）；卡片选中态用显式 `@Trace` 状态驱动视觉（海报墙选中浮出片名等）。视觉反馈全部由官方组件属性（`scale`/`border`/`brightness`/`opacity` + `animateTo`）组合。
  **Rationale**: 车机是触屏设备，业界车机无遥控焦点模型；省去 TvFocusable 复杂度。
  **Alternatives considered**: 沿用 TV 焦点体系——交互模型错位，徒增复杂度。

- **Decision（行车锁视频实现）**: 播放模式枚举（`video` / `audioLocked`）由驾驶模式开关驱动：切换到 `audioLocked` 时 **AVPlayer 不停播**，仅隐藏/断开视频输出表面（Surface 显隐），UI 切换为大控件播控卡（大播放暂停/上下集/收藏/进度条 + 「行车中视频已锁定」提示）；切回驻车可手动恢复视频表面。播控卡与传输条共用引擎进度回调。
  **Rationale**: 音频连续不中断是 FR-009 硬要求；Surface 显隐是 AVPlayer 官方支持的操作，无需重建会话。
  **Alternatives considered**: 停播重建会话——音频中断，违反 FR-009 平滑过渡。

- **Decision（AVSession 车机系统集成）**: 参照手机端 `PlaybackGuard.ets` 已验证的 AVSession 模式，在 `CarAvPlayerEngine` 内创建 AVSession：元数据上报（标题/封面/时长/进度）+ 播控指令（play/pause/playNext/playPrevious）回调接线；行车锁视频模式下 AVSession 持续有效（音频仍在播）。
  **Rationale**: FR-013 要求系统级播控联动；PlaybackGuard 模式已在工程内验证过 API 形态，照搬降低风险。
  **Alternatives considered**: 无（手机端既有模式的场景化复制）。

- **Decision（播放引擎新建不共享）**: 新建 `CarAvPlayerEngine`（封装 `@kit.MediaKit` AVPlayer + HLS）：起播走现有 `playback/decide` → `playback/sessions`；轨道（字幕/音轨）、画质切换重建会话、进度上报/ping、倍速快进分档 seek，全部沿用 TV 引擎已验证的 API 调用模式；车机增量 = Surface 显隐（视频锁）+ AVSession 集成。
  **Rationale**: FR-015 隔离红线；引擎行为差异真实存在。
  **Alternatives considered**: 提取共享引擎到 common/——打破 TV 已验证状态，回归风险大于收益（见 Complexity Tracking）。

- **Decision（扫码配对登录）**: 复用 TV 端已验证的配对会话流程与端点（配对码 + ScanKit 二维码屏显 + 轮询授权状态），车机版布局加大：主视图为二维码+配对码（扫码优先），局域网发现与手动地址折叠为次级入口。
  **Rationale**: 与服务端配对协议零改动（FR-002）；车机扫码优先符合 US-001。
  **Alternatives considered**: 账号密码为主——车机打字体验差，违反车机惯例。

- **Decision（搜索输入）**: 搜索页用大尺寸 `TextInput` 拉起系统输入法（车机输入法自带语音入口，经输入法可达即满足「语音优先」的可实现部分）；不引入独立语音识别 Kit。
  **Rationale**: 当前 SDK 面向三方的语音识别能力依赖系统输入法通道，无独立的公开 ASR API 可确保在模拟器可用；spec 已载明模拟器上以系统输入法为主验证路径。
  **Alternatives considered**: 集成独立 ASR Kit——模拟器可用性未知，违背「不虚构 API」与简洁优先。

- **Decision（状态与业务层复用）**: 复用 `common/AppModel`（phase 流程与账号切换/退出）、`api/ApiClient` 全部端点、`TokenVault`/`SavedServers`/`ServerAddress`/`LibraryHomeStore`/`Formatters`/`ImageUrls`。车机特有状态（路由栈、每库排序筛选记忆、驾驶模式与播放模式、mini 播控显隐、播放器 UI 状态机、欢迎流程态）集中 `car/model/CarUiState.ets`（`@ObservedV2`/`@Trace`）。
  **Rationale**: 与 TV 同构（「共享引擎层 + 重写界面层」）；数据层复用保证不引入后端行为分叉（FR-002）。
  **Alternatives considered**: 车机独立 AppModel——两份 phase 流程必然漂移。

- **Decision（mini 播控条装配）**: `CarMiniPlayer` 在 `CarShell` 层装配（所有非播放器页面的底部常驻）：显隐由「引擎在播 && 播放器覆盖层关闭」驱动；点击条体回播放器（行车锁时回播控卡）；内容区列表留底部安全边距防遮挡。
  **Rationale**: Shell 层装配保证全局一致性（FR-011）；单点显隐逻辑避免各页面自行处理。
  **Alternatives considered**: 各页面自行装配——重复且显隐逻辑易漂移。

## Data Model

**复用实体（现有代码，不改结构）**：服务器（ServerAddress/SavedServers）、账号与令牌（AppModel.SavedAccount/TokenVault）、phase 枚举（AppModel.AppPhase）、API 模型（api/Models 全量）、首页行偏好（LibraryHomeStore）。

**新增车机实体（car/model/CarUiState.ets，全部 @ObservedV2/@Trace）**：

- **CarRoute（导航路由）**: 目的地联合——条目详情（库id+条目id）/ 媒体库墙（库id或来源）/ 行墙（标题+来源，含影人作品墙）/ 关于；`CarShell` 持路由栈数组，返回弹出一层，播放器为独立覆盖态。
- **CarWallOptions（每库排序筛选记忆）**: 库id → { 排序: addedAt|releaseDate|rating|title；筛选: 只看没看过 等 }；持久化到 Preferences（key 前缀 `car_wall_`）。
- **CarDriveState（驾驶模式态）**: 手动驾驶模式开关（持久化，key `car_drive_mode`）；播放模式枚举（video / audioLocked）；`DriveSignalProvider` 接口位（预留真车信号，默认空实现回退手动开关）。
- **CarMiniPlayerState（mini 播控条态）**: 显隐（引擎在播 && 播放器覆盖层关闭）、当前条目摘要（封面/标题/是否剧集）、播放/暂停态。
- **CarPlayerUiState（播放器 UI 状态机）**: 显示层枚举（无/传输条/信息面板/seek 拖动中）、当前轨道选择（字幕/音轨/画质）、情境元素（跳过片头可见、下一集卡、错误态与归因）、模式视图（视频模式/行车播控卡）。
- **CarDiscoveryState（欢迎流程态）**: 发现扫描进行中/候选服务器列表/手动地址/配对会话（二维码内容+配对码+轮询状态）。

**状态流转**：EntryAbility 分流 → CarIndex 订阅 AppModel.phase（复用手机端 restore() 语义）→ ready 时 CarShell 接管；车机内部路由/墙/播放器/驾驶模式状态变化仅存在于 CarUiState，不回写 AppModel（除账号切换/退出复用 AppModel 既有方法）。驾驶模式开关变化 → CarDriveState 播放模式切换 → CarPlayerPage/CarAvPlayerEngine 响应（Surface 显隐 + 播控卡切换），mini 播控条显隐联动。

## Contracts & Interfaces

**入口接线契约（对现有代码的唯一改动面）**

- `EntryAbility.onWindowStageCreate`：现有 `deviceInfo.deviceType` 判断处增加 `'car'` 分支 → `windowStage.loadContent('car/CarIndex')`；加载回调内现有逻辑（沉浸式等）仅对非车机路径保持原样；车机路径执行车机初始化（深色固定、横屏确认）。
- `main_pages.json`：src 增加 `"car/CarIndex"`（每文件一个 @Entry 规则不破坏）。
- `module.json5`：deviceTypes 增加 `"car"`（requestPermissions/abilities 不变，INTERNET/GET_NETWORK_INFO 已覆盖发现与播放；无需新增权限）。

**组件契约（car/ 内部，均为官方组件组合）**

- `CarCards`：继续观看大卡（宽幅、进度条、剧名/集数、一键续播回调）、收藏大卡、海报卡（2:3，选中浮出片名·年份策略）、横版卡（16:9）、人物卡（头像+姓名+作品数，点击进影人作品行墙）、分集卡（剧照+进度+集名）、「查看全部」尾卡；全部接受既有 api/Models 类型 + 点击回调；触控目标 ≥48vp 由 CarTheme 令牌保证。
- `CarRows`：输入——行标题、卡列表、卡片构造器类型、「查看全部」回调；输出——横滑行（List）。
- `CarMiniPlayer`：输入——CarMiniPlayerState + 引擎控制接口（播放暂停/下一集）；输出——底部播控条；行为——点击条体回调回播放器。
- `CarShell`：输入——AppModel（phase ready 后）；管理——四页签态（首页/媒体库/搜索/账号）、路由栈、播放器覆盖层显隐、mini 播控条装配与内容区底部安全边距；输出——页面装配与返回键分级（面板→二级页→页签→退出确认）。
- `CarWelcome`：扫码配对主视图（二维码+配对码+轮询）+ 局域网发现次级 + 手动地址兜底；复用配对会话端点。
- `CarLibraryWall`：库id或来源输入；排序筛选大按钮抽屉（条件走 CarWallOptions 持久化）；窗口分页；模糊背景（官方 `backgroundBlur`/`blur` 属性）。
- `CarItemDetail`：条目输入；首屏大图+操作按钮行（继续/从头/收藏/已看即时反馈）+ 季切换分集列表 + 演职员 + 相似推荐（宽屏左信息右内容布局）。
- `CarSearchPage`：大输入框（系统输入法）+ 条目/影人结果分页大卡列表。
- `CarAccountPage`：当前账号展示、已保存账号切换（复用 AppModel）、退出确认弹窗、关于折叠（版本与许可）。

**引擎契约（CarAvPlayerEngine）**

- 生命周期：`prepare(播放决策结果)` → `start()` → `pause()/resume()/stop()/release()`；状态回调（idle/prepared/playing/paused/error/completed）。
- 控制：`seekTo(毫秒)`、倍速快进分档（setMediaTime 连发，20×→40×→80×→160×）、`selectSubtitle/selectAudio(轨道id)`、`switchQuality(档位)`（重建 HLS 会话续接进度）。
- **视频锁**：`setVideoSurfaceVisible(布尔)`——audioLocked 模式仅隐藏视频输出表面，音频链路不重建；恢复可见即回视频。
- AVSession：创建会话（参照 PlaybackGuard 模式）、元数据上报（标题/封面/时长/进度随 onProgress 更新）、指令回调（play/pause/playNext/playPrevious）接引擎控制；引擎释放时会话同步销毁。
- 上报：进度上报与 ping 保活按现有 playback 端点节奏；`onProgress` 回调驱动传输条、播控卡与 mini 播控条。
- 错误：失败回调带归因（网络/解码/会话），播放器页映射为错误视图（重试/返回）。

**服务端接口（全部复用现有 api/ 层端点，无新增）**：health、auth（device login/authorize/token/pairing 配对会话）、ui preferences、playback up-next/favorites/decide/sessions/progress/ping/resume、libraries（items/facets/showcase/item-index）、items（detail/episodes/similar）、collections、people、search library、marks、trickplay 与预告片段——与 TV 端在用集合一致。

**验收对照契约**：SC-001~007 对应的用户验收用例集在 Phase 3 tasks.md 中按 9 个用户故事逐条生成，验证阶段按所选范围（build-only / build+ui）执行，UI 检查目标设备为 Huawei_Car 模拟器（1260×600 vp 画布）。

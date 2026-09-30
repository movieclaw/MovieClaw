# iOS 原生 App 设计

> 状态：已合入 main（2026-09-29，#473；原开发分支 `feat/ios-app` 已删除，之后从 main 开分支）。验收标准：浏览器与 iOS App 同时打开同一台服务器，
> `docs/design/ios-app/parity-inventory.md` 列出的全部功能两端一致。

## 1. 决策

| 事项 | 结论 | 理由 |
|---|---|---|
| 技术栈 | SwiftUI 全原生，iOS 26+ | 液态玻璃标签栏/工具栏/浮层系统自带；网页 PWA 的画中画、全屏、字幕等受 WebKit 所限 |
| 范围 | Web 手机端全部功能原生重写（不内嵌网页） | 用户决定 |
| 播放 | 自研引擎（AetherEngine）放原文件，系统播放器（AVPlayer）放服务端流 | 用户决定（2026-09-28）：本机能解决的一切都由自研引擎解决——原文件在本机换封装进 AVPlayer，画中画 / AirPlay / 杜比视界都是系统的，硬解不了的编码在本机软解；MPV 已移除，理由见 [player-engine.md](player-engine.md) §3.6 |
| 认证 | 设备令牌（`POST /auth/device/login` 用账号密码换，存钥匙串，`Authorization: Bearer`），见 login-devices.md | 长期有效不再满 30 天重登；这台手机是「我的设备」里的一台，可单独注销；多账号完全在本机 |
| 接口层 | 脚本生成（`apps/apple/scripts/gen_api.py`） | 340 个接口、459 个模型手写不可维护 |
| 工程 | XcodeGen（`project.yml`，同步文件夹） | 不提交 .pbxproj，并行加文件不冲突 |
| 外观 | 不提供网页的「外观」设置（主题、背景图、界面质感、导航顺序都只作用于网页），设置里没有这一页；底色固定纯黑（同 Apple Music），App 强制暗色（含启动屏），剧照灯箱不带「设为背景」；账号在网页的外观设置原样保留 | 用户决定（2026-09-26），列为已接受差异 |
| 活动页 | 一页总览，不做网页的「观看 / 任务」分段与二级切片胶囊：大标题下一行实时摘要，分组按紧急程度排（需要处理 → 正在播放 → 正在下载 → 进行中 → 最近播放 → 观看统计 → 最近完成），空分组不出现；历史与统计各露一小段，「查看全部」压栈到二级页（`AppRoute.activityPage`），成员 / 周期 / 范围筛选在二级页右上角；浏览范围只在确有隐藏内容时以分组脚注出现；设备处置走左滑与长按。`/activity?view=plays·stats·history·active` 仍可直达对应二级页 | 用户决定（2026-09-26），列为已接受差异；系统分组列表的左滑、长按、下拉刷新比自绘胶囊更贴 iOS。2026-09-27 网页银玻璃手机端跟进为同一套总览（`components/activity-overview.tsx`），网页桌面仍是两段版式 |
| 订阅页 | 流媒体式版式，按时间与意图拆而不是按类型拆：沉浸 Hero「下一部到手的」（下载中 / 整理中 → 48 小时内刚入库 → 今天 → 最近一次预告，最多 5 张、8 秒轮播，片名用 TMDB Logo，页面底色随当前剧照主色）→ 刚刚入库（16:9 剧照横滑，点一下直接播放，看完即消失）→ 日程（今天起一周的日期条 + 当天议程）→ 剧集 / 电影横滑海报行（在追的在前，已收齐 / 已暂停压暗排在竖排小字分隔线后，标题「›」压栈到完整海报墙 `AppRoute.subscriptionWall`）。不做网页的「全部 / 剧集 / 电影」切换与今日时间轴卡片，链路体检收成右上角琥珀色警示钮。数据依赖后端 `today-arrivals?window=week`、`recent-arrivals` 与订阅条目摘要的 `backdrop_url` / `logo_url`，老服务端上对应版块自动不出现 | 用户决定（2026-09-26）；判定口径在 `Features/Subscriptions/SubscriptionsHomeModel.swift`。2026-09-27 网页银玻璃（桌面与手机）跟进为同一版式，口径一比一移植在 `apps/web/lib/subscriptions-home.ts`，不再是差异（Netflix 主题的订阅页保持原样） |
| 欢迎页 | 不照搬网页的 /login、/setup 两页：没有登录中的账号时先停在首页——写实、克制的深空：纯黑背景上一片按真实星等分布的星空（暗星极多、亮星极少，不闪烁）和一条带尘埃暗缝的淡银河，整片星空约 40 分钟转一圈（Core Animation 图层动画，主线程零开销），偶尔划过一颗流星；画面下方一道行星地平线（屏幕大小的 Canvas 只画可见的弧），大气辉光像轨道日出一样亮起。片名下方像电影字幕一样轮播影史经典台词（68 句，原句 + 中文字幕，点一下换一句，旧句上移淡出、新句浮上来），底部一个液态玻璃按钮（第一次叫「连接服务器」，连过服务器后叫「登录」），点了才升起登录卡片（右上角 × 收起回首页），键盘只在这时自动弹出。服务器地址、用户名、密码在同一张玻璃卡片里一次提交；第一次使用时地址栏会在局域网里自动发现服务器（`Core/Networking/ServerDiscovery.swift`：对本机所在 /24 逐个单播后端 UDP 7359 的 Jellyfin 发现询问——iOS 发广播要额外申请 multicast 权限，单播只需本地网络权限，且能经桥接部署的 `7359:7359/udp` 端口映射进容器；应答地址（桥接部署下是外部访问地址或容器内网 IP）连不通时改用报文来源 IP，并以 `/api/v1/health` 确认是 MovieClaw），找不到就显示示范占位符由用户手填；服务器是全新的就在同一张卡片里补确认密码、创建超管。其余状态直接给卡片、不抢焦点：登录过期是「重新登录」（服务器与用户名预填）、冷启动连不上是「连不上服务器」（重试 / 改地址 / 换账号，不逼人重新登录）、当前服务器上没人了但别的服务器上还有是「选择账号」。可以登录多台服务器，「添加账号」打开同一张卡片、服务器地址可改；动线与机制见 `account-switching.md` §6。不用真实海报（首次打开还没连服务器，也不能把别人的海报打进安装包），台词字体是随包的思源宋体子集（`scripts/subset-welcome-font.py`） | 用户决定（2026-09-27），列为已接受差异。同日网页 /login、/setup 跟进为同一套星空欢迎页（`apps/web/components/welcome-screen.tsx`、`cosmos-backdrop.tsx`，台词与宋体子集与 App 同一份），但卡片里没有服务器地址（网页就是从服务器打开的），也没有选择账号 / 连不上两种卡片 |

## 2. 目录

原生 App 按平台生态放在 `apps/` 下，与 `apps/web`、`apps/extension` 并列：`apps/apple/` 是一个 Xcode 工程，
现在只有 iPhone/iPad 目标，将来的 Apple TV（tvOS）版作为同一工程的另一个目标，共用接口层与播放器
（届时工程内再拆 `Shared/`、`iOS/`、`tvOS/`）；将来的 Android 版放 `apps/android/`（一个 Gradle 工程，手机与
Android TV 两个模块）。各平台共用 Bundle ID / 包名 `io.movieclaw.app`，请求标识为 `MovieClaw-<iOS|tvOS|Android>/<版本>`，
活动页据此显示「MovieClaw iOS / Apple TV / Android」。`pnpm-workspace.yaml` 因此只列 JS 项目、不用 `apps/*` 通配。

```
apps/apple/
  project.yml                 工程定义（xcodegen generate 生成 .xcodeproj，不入库）
  scripts/gen_api.py          生成接口层；后端改了接口就重跑
  scripts/test.sh             跑测试（兜住 xcodebuild 不退出）
  MovieClaw/
    App/                      入口、AppModel（连接/登录状态机）、Routing（路由/导航/全局弹层）
    Core/API/Generated/       生成的模型（命名空间 API.*）与接口函数（APIClient 扩展）——勿手改
    Core/API/*.swift          少量手写补充（multipart 上传、SSE 等生成器跳过的接口）
    Core/Networking/          APIClient、设备令牌钥匙串（TokenVault）、SSE、服务器地址
    Core/Session/             权限、环境值
    DesignSystem/             主题令牌、反馈中心、三态加载、远程图片、占位页、通用组件
    Features/<模块>/           各功能模块
  MovieClawTests/             单元测试 + Generated/LiveDecodeTests（对真实服务器的解码冒烟）
  MovieClawUITests/           UI 自动化（端到端验收）
```

## 3. 约定（所有模块必须遵守）

### 3.1 接口
- 一律用生成的函数：`@Environment(\.api) private var api` → `try await api.librariesList()`。
  函数名 = 后端 operation_id 驼峰化，文档注释里有 HTTP 方法与路径，找接口用
  `grep -n '/libraries/{library_id}/items' Core/API/Generated/Endpoints.swift`。
- 生成器跳过的接口（文件流、SSE、multipart）见 `Endpoints.swift` 末尾清单，在模块内手写
  `nonisolated extension APIClient`，复用 `raw/send/upload/events/perform`。
- 模型字段不对（解码失败）先查后端 schema，**不要改 Generated/**；需要改生成规则告诉集成方。
- 图片：`api.image(item.posterUrl, .posterCard)` → `RemoteImage(url:)`；远程图自动走后端缓存代理。

### 3.2 页面骨架
- 三态：`@State var state: Loadable<T> = .loading` + `AsyncContent(state, retry:) { … }`，
  加载用 `await Loadable.load(into: $state) { try await api.xxx() }`（已有数据时静默刷新，不闪）。
- 空态 `EmptyState`，失败 `ErrorState`（后端中文原因原样显示）。
- 轮询：`.polling(every: 秒) { await reload() }`，自动随页面可见性与前后台启停；间隔同 Web（清单第 13 节）。
- 秒开（标签根页这类「一打开就要整页」的页面）：数据放进跟着账号走的共享对象 + 本机快照（`PageSnapshots`），
  首屏图片提前解码进内存（`FirstScreenImages`），不急的启动工作等首帧（`FirstFrameGate`）；做法、口径与实测数字见
  [ios-page-open.md](ios-page-open.md)，量打开速度用 `scripts/perf/ios_open_bench.py`。
- SSE：`for try await event in api.events("/jobs/stream") { … }` 放在 `.task` 里，离开页面自动断开。
- **弹层**：所有 `.sheet` / `.fullScreenCover` 的内容必须调用 `.sheetFeedback()`——根部的确认框/输入框被 sheet 盖住时弹不出，
  它给弹层配独立的反馈中心，关窗时未消失的 Toast 转交回根部（全局弹层已自动挂上）。
- **命名**：同一个 App target 里 `private` 类型也会和别处的同名类型冲突，模块内新类型一律带模块前缀
  （如 `PlayerUpNextCard`、`LibraryWallCell`），通用名（`UpNextCard`、`Row`、`Header`）禁止使用。
- **模型一致性**：给 `API.*` 模型加 `Identifiable` 等协议一律写在 `Core/API/ModelConformances.swift`（先 grep，别在模块里重复声明）。
- 反馈：`@Environment(Feedback.self)`：`feedback.success/error`、`await feedback.confirm(…)`、`await feedback.prompt(…)`，
  文案照搬 Web。
- 导航：`@Environment(Router.self)`：`router.push(.libraryItem(…))`、`router.open(webPath:)`、
  `router.play(PlayRequest(…))`、`router.present(.subscribe(…))`。
  页面入口类型与参数固定在 `App/Routing/Destinations.swift`，模块只替换自己的占位文件，**不改路由表**。
- 权限：`@Environment(\.permissions)`，入口裁剪口径同 Web `lib/permissions.ts`。
- 视觉：深色，`Theme` 令牌取自 Web 银玻璃主题；列表/按钮/工具栏用系统液态玻璃（`.glassEffect`、`.buttonStyle(.glass)`），
  页面根视图加 `.appBackground()`。不必像素级复刻网页，但**信息与操作必须一致**。
- 中文：所有文案、错误提示用中文；关键类写中文设计注释（CLAUDE.md「注释和日志」）。

### 3.3 文件归属（并行开发的硬规则）
- 只改自己模块目录 `Features/<模块>/` 下的文件；需要新的通用组件放 `DesignSystem/<模块前缀>*.swift` 新文件。
- 不改：`Core/API/Generated/`、`App/Routing/`、其它模块目录、已有 DesignSystem 文件。确需改动写进交付说明，由集成方处理。
- 播放器模块可改 `project.yml` 的 packages（播放引擎的依赖）。

## 4. 播放器架构（多引擎）

```
PlayerScreen（控制层 UI、手势、字幕叠加、选轨、诊断）
  └─ PlaybackController（会话协议：/playback/sessions、ping 15s、progress 10s、降档重试、下一集）
       └─ PlayerEngine 协议
            ├─ NativeEngine     自研引擎（AetherEngine）：原文件在本机换封装进 AVPlayer，杜比视界 / 全景声 / 原盘 / 镜像直推
            └─ AVPlayerEngine   服务端 HLS（转码 / 换封装）：只在自研引擎确定解不了时用；用户限了画质的服务端流也由自研引擎直连放
```
- 引擎选择全自动，用户不选（2026-09-26 用户决定，同 Infuse；2026-09-28 起自研引擎是本机唯一的播放器，MPV 已移除）：只有「解不了」才沿
  兜底阶梯换引擎；网络慢、断线都不换引擎、不自动降码率（一次等满 8 秒或反复卡顿、且线路跟不上时提示一次，换不换画质由用户定）；画质、音轨、字幕按片记，
  非默认的在下次打开时提示几秒。规则见 [player-engine.md](player-engine.md) §3。
- 字幕：自研引擎直出时，内封与外挂字幕都由引擎给出字幕数据、App 按画面矩形摆放（文字用系统字体）；系统播放器放服务端流时，
  文字字幕由 SwiftUI 叠加层画，图形字幕由服务端烧录。画中画两种播放器都在本机完成（自研引擎用它自带的画中画源）。
- 开发期可用启动参数 `-mcSubtitle <轨>` 指定起播字幕、`-mcAutoPiP <秒>` 自动点画中画（引擎不能强制：正式版只有自研引擎，放不了才按兜底阶梯回落）。
- 会话参数（capability、failed_tiers、audio/subtitle track、max_height、downlink_bps）按引擎能力申报。
- 顶栏右侧与起播/缓冲转圈下方那行「↓ 速度」是**实时加载速度**（2026-09-27 用户定，Web 同时改成同一口径，
  见 player-feel.md G3 的改动说明）：在下载就报实际下载速度，没在下载（缓冲满了）就是「0 KB/s」。
  诊断面板的「带宽」是线路能跑多快，也是申报给服务端的 downlink_bps：HLS 按 AVMetrics 逐片计时（首字节→末字节，
  等转码的时间不算），原文件直出用加载速度读数，都取最近 12 秒（至少最近 3 次）里最快的一次——AVPlayer
  会自己放慢读取，按平均算会被拖低，还会比加载速度小。算法与本机限速实测见 `PlayerEngine.swift` 的
  `LoadingSpeedMeter` / `BandwidthMeter`。
- 起播链路与流畅度（2026-09-27 秒开优化）：后台一口气完成决策与开会话、自研引擎申报全解码拿档 0、HLS 列表带 EXT-X-START、AVPlayer 起播不等缓冲等，改法与实测数字见 [playback-startup.md](playback-startup.md)；起播慢先看 NAS 日志里的「起播分段」一行。
- LGPL 合规：AetherEngine 与它自带的 FFmpeg 都以动态框架随包（`AetherCore.framework`、`AetherLib*`）；「我的 → 关于
  MovieClaw」列出各组件的许可、源码地址与许可全文。打包与上架见 [ios-release.md](ios-release.md)。
- 自研引擎（默认且唯一的播放器，`feat/ios-player-engine`）：`NativeEngine` 经 AetherCore 动态框架接入 AetherEngine，本机把原文件换封装成 HLS 交给 AVPlayer；本机解不了（硬解、引擎自己软解都不行）才改走服务端 HLS。方向、兜底阶梯与验证清单见 [player-engine.md](player-engine.md)。

## 5. 验收方法

每个模块交付前自证：
1. `xcodebuild build` 通过、无新增警告级错误；
2. **对照截图**：同一路由分别截网页（`/tmp/mc-shots/shoot.mjs`，iPhone 视口）与 App（Debug 启动参数
   `-mcServer … -mcUser … -mcPass … -mcRoute /web/path` 直达页面后 `simctl io screenshot`），逐项核对清单条目；
3. **交互**：清单里的每个操作在 App 里实际点一遍（XCUITest 放 `MovieClawUITests/<模块>UITests.swift`），
   结果与网页一致（同一台服务器，后端状态是唯一事实来源）；
4. 交付说明列出：已实现条目、未实现/有差异条目及原因。

本地联调环境：`http://localhost:3000`（admin / mclaw-dev-2026，数据为开发副本，可放心增删测试数据，
但不要删除已有媒体库、成员与媒体文件）。

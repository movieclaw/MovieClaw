# Apple TV App 设计（定义稿）

> 状态：已定稿（2026-10-02 用户确认 §8 三项），实施中（分支 `feat/tvos-app`）。
> 关联文档：[ios-app.md](ios-app.md)（iPhone App，本文的底层与它共用）、
> [player-engine.md](player-engine.md)（自研引擎）、[login-devices.md](login-devices.md)（设备令牌）、
> [account-switching.md](account-switching.md) §6（多服务器 × 多账号）、
> [library-home-perspective.md](library-home-perspective.md)（首页的行）、[reels.md](reels.md)（片段）。

## 0. 一句话

**Apple TV 版是客厅里的放映厅**：打开就能接着看；选片、播放、切换「谁在看」都只用遥控器的方向键、
确认键、返回键完成。管理类的事全部留给手机和网页。

## 1. 能不能把 iPhone 的代码直接变成 Apple TV 版

**结论：不能整体照搬，但也不用从零写——底层共用，界面为电视重写。**
这和 [ios-app.md](ios-app.md) §2 当初预留的方向一致：同一个 Xcode 工程加一个 tvOS 目标，共用接口层与播放器。

### 1.1 实测（2026-10-02，Xcode 27 / tvOS 27 SDK，在临时副本里编译，工程本身未改动）

| 层 | 规模 | 编译成 tvOS 的结果 | 结论 |
|---|---|---|---|
| AetherEngine（含我们的 P 系列补丁） | 270 个文件 | **通过**，没有新增警告 | 原样共用。上游本来就支持 tvOS 18+，代码里已有 tvOS 分支 |
| FFmpegBuild / LibDovi（二进制依赖） | 10 个 xcframework | 都带 `tvos-arm64` 与模拟器切片 | 原样共用 |
| AetherCore（引擎外面的动态框架） | 1266 行 | **通过** | 原样共用，`project.yml` 里改成同时面向两个平台 |
| Core（生成的接口层、令牌钥匙串、局域网发现、页面快照） | 1.5 万行（其中生成代码 1.36 万） | 只有 2 处与界面耦合（见 §6.2） | 拆掉两处后共用 |
| 播放器逻辑（会话、进度上报、兜底阶梯、选轨、看门狗、跳过片头……） | 约 6500 行 | 约 10 处平台差异（自动画中画、电池读数、音频会话策略、HDR 判断） | 改动不到 30 行后共用 |
| 播放器界面（控制条、手势、亮度 / 音量 / 方向） | 约 3000 行 | 手势、亮度、方向、状态栏在 tvOS 上都不存在 | 为电视重写 |
| 其余页面 | 约 6 万行 | 整个 App 一起编译共报 310 处不可用 | 只重写电视需要的那几页 |

整个 App 一起编译时，报错最多的几类分别是：`navigationBarTitleDisplayMode` 55 处、文字可选中 37 处、
列表底色 19 处、剪贴板 13 处、左滑操作 10 处、气泡弹窗 7 处。

按去向汇总（iPhone 端 Swift 共约 9.06 万行）：

| 去向 | 规模 | 内容 |
|---|---|---|
| 原样共用，或加少量 `#if` 后共用 | 约 2.9 万行 | AetherCore、Core（含生成的接口层）、播放逻辑、`AppModel`（登录 / 切换状态机）、各页面的数据层（Store / Model）、主题与图片加载 |
| 复用数据层，界面为电视重写 | iPhone 上对应约 1.8 万行 | 外壳、媒体库浏览与详情、搜索、播放控制层、欢迎与登录；二级的发现、订阅、片段 |
| 电视上不需要 | 约 3.4 万行 | 设置、活动、AI 助手、媒体库管理、站点资源搜索与下载、分享、待处理事项 |

### 1.2 为什么不「把报错修完就上」

报错修完只代表能编译，在电视上照样不好用。iPhone 界面是按触摸设计的：竖屏的信息密度、底部弹出的表单、
左滑与长按、下拉刷新、到处都能点的小按钮。在电视上，焦点要能用方向键走到每个元素，字要在三米外看得清，
一屏只放几样东西。这些属于交互模型不同，不是 API 能不能用的问题。所以共用到「数据与播放」为止，
界面按 tvOS 的习惯重写。

## 2. 产品原则

1. **播放第一**：首页第一屏就是「接下来继续」，从任何地方到开始播放，按确认键的次数越少越好。
2. **不让人在电视上打字**：登录用手机扫码 / 批准；搜索支持 Siri 听写和 iPhone 键盘。
3. **一家人共用**：「谁在看」是一等功能，切换不需要密码、不联网。
4. **和系统一致**：焦点效果、返回键语义、播放器的遥控器手感都按 Apple TV 系统的约定来，不自创交互。
5. **电视上只看不管**：不做任何管理操作。只保留和「我」有关的轻操作：标记已看 / 未看、收藏、一键订阅（§3.2）。

## 3. 功能范围

### 3.1 分级

| 功能 | 级别 | Apple TV 上怎么做 | 共用 iPhone 的哪些部分 |
|---|---|---|---|
| 首页 | **主入口** | 「接下来继续」+ 用户在网页自定义的行（按类型的跨库行、各媒体库最近添加……） | `LibraryHomeStore` 与首页透视的数据口径 |
| 媒体库浏览 | **主入口** | 每个媒体库一面海报墙；筛选只保留排序、只看未看、类型 | 接口、筛选口径 |
| 条目详情 | **主入口** | 大剧照 + 片名 Logo；主按钮「继续播放 S1E3 · 剩 23 分钟」；季 / 集横排；版本、音轨、字幕 | 接口、播放请求 |
| 播放 | **核心** | 同一个引擎，电视上重写控制层（§4） | 引擎 + 全部播放逻辑 |
| 搜索 | **主入口** | 系统搜索页（屏幕键盘 + Siri 听写 + iPhone 键盘），**只搜媒体库** | `searchLibraryItems` 接口 |
| 谁在看 / 多账号 | **主入口** | 启动时的「谁在看」；侧边栏顶部的头像随时切换（§5） | `SavedServers`、`TokenVault`、`AppModel` 的切换机制 |
| 发现 | 二级 | 用电视的方式做：大图轮播 + 榜单横排；详情页「订阅」一键提交，「已在库」直接播放 | 发现接口与模型 |
| 我的订阅 | 二级 | 以看为主：刚刚入库（点了就播）、本周日程、在追的海报墙；不做编辑规则、整理、体检 | `SubscriptionsHomeModel` 的判定口径 |
| 片段 | 二级 | 客厅版「随便看看」：全屏自动连播，左右切换下一段，按确认键接着看正片 | `ReelsStore`、片段接口 |
| Top Shelf | 系统入口 | 在主屏选中 MovieClaw 图标时，上方的大图区显示「接下来继续」，选中直接续播 | 首页的数据 |
| 关于 | 收进账号菜单 | 版本号与开源组件许可（**LGPL 合规必需**，不能省） | `About/Licenses` 下的许可文本 |
| 照片类媒体库 | 后续 | 首版不做；以后可以做成幻灯片放映 | — |
| 设置、活动、AI 助手、待处理事项、站点资源搜索 / 下载、媒体库管理（整理 / 删除 / 转移 / 重新识别 / 字幕生成 / 合集编辑）、分享 | **不做** | 在电视上没有意义，或必须大量打字 | — |

### 3.2 订阅为什么是唯一的写操作

在发现页看到想看的片，当场按一下「订阅」是电视上最自然的动作；让人掏出手机重新搜一遍，体验会断掉。
所以只保留**一键订阅（用默认规则）**。调规则、暂停、取消都回手机或网页处理。没有订阅权限的成员看不到这个按钮，
口径同 `Permissions.canSubscribe`。

### 3.3 导航

用 tvOS 的 `TabView` 侧边栏样式，和系统自带的 Apple TV App 一致：

```
（头像）张三     账号菜单：切换账号 / 添加账号 / 关于 / 退出登录
搜索
首页            ← 启动后的默认落点
电影
剧集            ← 当前账号能看到的每个媒体库各占一项，顺序同服务端
纪录片
── 更多 ──
发现
订阅            ← 没有订阅权限时不出现
片段
```

- 浏览内容时侧边栏收起，内容占满全屏；展开方式由系统决定（向左移到边缘，或在根页面按返回键）。
- 媒体库超过 6 个时，多出来的收进一个「全部媒体库」页，避免把「更多」挤出屏幕。

## 4. 播放器：一个引擎，两层皮

### 4.1 分层

```
共享（iPhone 与 Apple TV 同一份代码）
  AetherEngine / AetherCore           原样共用（tvOS 编译已实测通过）
  PlayerEngine 协议
    ├─ NativeEngine                   自研引擎：原文件在本机换封装进 AVPlayer；硬解不了的走 FFmpeg 软解
    └─ AVPlayerEngine                 服务端 HLS，只在自研引擎解不了时用
  PlaybackController                  会话协议、ping / 进度上报、兜底阶梯、选轨记忆、下一集
  PlaybackRouting / PlayerCapability / PlayerTracks / SkipSegments / PlaybackWatchdogs
  PlaybackRecord / NowPlayingBridge / SubtitleOverlay / PlayerPreferences / 测速
平台层
  iOS   PlayerScreen + 控制条 + 手势层 + 亮度 / 音量 / 方向桥（现状不动）
  tvOS  TVPlayerScreen + 遥控器交互 + 信息面板（新写）
```

以后修引擎、改兜底策略、调起播速度，两端同时受益；只有「怎么按、怎么显示」分平台。
两端的能力差异只体现在引擎能力申报（`PlayerCapability`）上：服务端按申报决定给原文件还是转码，
所以 TV 能放什么、走哪条路，和手机用的是同一套判定。

这条接缝现成就有：iPhone 的控制层只和 `PlaybackController`（`@Observable` 的会话模型）打交道，
再经 `PlayerEngine` 协议往下走。播放器目录 9450 行里，约 6500 行（69%）是不含界面的逻辑，
其中不到 30 行需要按平台分支（清单见 §6.2）。算上引擎本体（约 9.6 万行）和 AetherCore，
Apple TV 要新写的只占整个播放栈的 2% 左右。

### 4.2 控制层为什么不用系统播放器（AVPlayerViewController）

系统播放器只能托管 AVPlayer，而自研引擎有一条软解通路（采样缓冲显示层，用于 VP9、MPEG-2、VC-1、
没有硬解的 AV1、隔行片源等）：放进系统播放器只有声音、没有画面。原文件的字幕也是 AetherCore 自己画的，
不经过系统播放器。所以控制层自己写（iPhone 端现在也是自己写的），**但交互严格照搬
tvOS 系统播放器**，用户不需要重新学：

| 遥控器操作 | 行为 |
|---|---|
| 播放 / 暂停键，或按下触控板中心 | 播放 / 暂停；暂停时显示进度条 |
| 点按触控板左 / 右边缘 | 后退 / 前进 10 秒 |
| 在触控板上左右滑动（暂停或进度条显示时） | 拖动进度 |
| 下滑 | 信息面板：字幕、音轨、画质、版本、章节 |
| 返回键 | 有面板时先收起面板；否则退出播放（进度照常上报） |
| 片头 / 片尾时段 | 右下角出现可聚焦的「跳过片头」「下一集」，焦点自动落在上面，按确认键就生效 |

实现要点：
- 播放 / 暂停、方向键点按、返回键分别用 SwiftUI 的 `onPlayPauseCommand`、`onMoveCommand`、`onExitCommand`；
  在触控板上滑动拖进度要用 UIKit 的手势识别器（间接触摸），用一个小的 `UIViewRepresentable` 包起来，
  接到 `PlaybackController` 现有的拖动跟随与跳转接口上。
- 拖动预览沿用服务端下发的缩略图雪碧图（`TrickplayImages`）。
- 「跳过片头」「下一集」的倒计时在 iPhone 上由视图驱动，TV 控制层照做一份。
- 下滑出来的信息面板复用现有的音轨 / 字幕 / 画质菜单数据模型，只重写界面。

### 4.3 电视上才有的事

引擎上游本来就和 Apple TV 客户端一起演进，下面多数事情引擎已经做好，App 只需要别挡路。

- **显示模式匹配（已做好）**：`Display/DisplayCriteriaController.swift`（tvOS 专用）在起播前按片源的帧率和
  动态范围写 `preferredDisplayCriteria`，等电视切换完再开播，播放中还会复查实际刷新率；遵从系统的「匹配内容」开关，
  帧率会吸附到 23.976 / 24 / 25 / 29.97 等标准值。App 只要保证播放器在主窗口里。
  **两个缺口**：① 系统播放器兜底（`AVPlayerEngine` 放服务端 HLS）完全没有显示匹配，要用
  `AVAsset.load(.preferredDisplayCriteria)` 自己写；② 自研引擎直连服务端 HLS 时（用户限了画质），
  只在 HDR 时切换，SDR 片源不匹配帧率。
- **音频会话：TV 上必须交给引擎**。引擎在 tvOS 上用 `.longFormAudio` 路由策略，而且只在需要时才激活会话——
  过早激活会把 HDMI 锁在立体声，5.1 和全景声被降混（上游 #24）。iPhone 端的做法（补丁 P47 由 App 自管类别、
  起播时就激活、策略 `.longFormVideo`）在 tvOS 上不能用，`.longFormVideo` 在 tvOS 上也不存在。
  TV 端保持引擎默认（`hostManagesAudioSessionCategory = false`）。
- **全景声与无损音轨**：EAC3 + JOC（流媒体常见的全景声）原样经 HDMI 输出。TrueHD / DTS 现在固定重编成有损的
  EAC3 5.1（`AetherPlayback.swift` 里写死了 `.surroundCompat`），全景声对象会丢失。
  客厅里接功放的用户更在意这一点，所以 TV 端倾向改用 `.lossless`（重编成 FLAC，以多声道 LPCM 输出，最多 7.1）。
  T0 实测 CPU 占用与稳定性后再定默认值。
- **HDR 能力申报要改**：`PlayerCapability` 用屏幕的 `potentialEDRHeadroom` 判断能不能放 HDR，
  这个值在 tvOS 上恒为 1.00，照搬会申报「不支持 HDR」，服务端就可能给降级的流。
  tvOS 改用 `AVPlayer.eligibleForHDRPlayback` 或引擎的 `displayCapabilities`。
- **「正在播放」**：tvOS 推荐用 `MPNowPlayingSession`，否则暂停后系统会把 App 从「正在播放」里摘掉。
  引擎已经支持，AetherCore 需要把它透出来。
- **软解用得更多**：Apple TV 没有 AV1 硬解，tvOS 的 AVPlayer 也不做去隔行，所以 AV1 和隔行片源在电视上都走软解。
  补丁 P36 / P39 的解码代价参数是按 iPhone Air（A19）标定的，要为 Apple TV 4K（A15）重新标定
  （playback-qoe.md 里已有这条待办）。
- **按主屏键离开再回来**：tvOS 上引擎一进后台就拆掉管线，AetherCore 回前台时原位重建；要验证续播的体验。
- **字幕**：沿用「引擎给字幕数据、App 按画面矩形摆放」的做法，字号按三米观看距离重新定。
- **去掉**：亮度 / 音量手势、方向锁、隔空播放按钮、电池读数、诊断面板里的文字选中。
  画中画首版不做：主通路在 tvOS 上能用，但软解通路的画中画 tvOS 不接受，体验不一致，而且客厅里需求不强。

## 5. 账号与登录

### 5.1 登录：默认扫码，账号密码兜底

1. **找服务器**：沿用 iPhone 的局域网发现（`ServerDiscovery`），列出找到的服务器让人选；找不到再手填地址。
2. **扫码登录（推荐，默认）**：电视显示二维码和配对码 `MCLW-XXXX`。用手机扫码打开网页批准页
   （`verification_uri_complete`），或者在 iPhone App「设置 → 设备」里输入配对码（批准功能已经存在）。
   谁批准，电视就登录成谁（login-devices.md §4）。
   - **服务端与批准页需要小改**：
     - `login_devices.PAIRING_KINDS` 目前只放行 `cli` / `worker`，要加上 `tvos`。
       `tvos` 这种设备类型已经在 `KINDS` 里登记好（人直接操作的客户端，改密时随之下线），
       签发、列表、注销都不用改。
     - 批准卡片上的「类型」和「将获得」文案是按客户端类型写死的，要补上 Apple TV：
       网页 `components/devices-section.tsx`（`clientTypeLabel` / `grantSummary`），
       iPhone `Settings/Sections/DevicesSettingsView.swift`（`DeviceText.clientType` / `grant`）。
   - 客户端这边，生成的接口里已经有 `authDeviceAuthorize` 和 `authDeviceToken`。
3. **账号密码（兜底）**：输入框标注用户名 / 密码类型，这样附近的 iPhone 会弹出「用 iPhone 键盘输入」
   并可以自动填充；接口仍是 `POST /auth/device/login`（`kind: tvos`，服务端已支持）。

### 5.2 谁在看

- 电视上登录过不止一个账号时，启动先显示「谁在看」：大头像横排，焦点放大，按确认键进入。
  支持跨服务器，机制与 iPhone 的切换完全相同：换一枚令牌、不联网、整棵界面树重建。
- 侧边栏顶部是当前账号的头像，点开后可以：切换账号、添加账号、关于、退出登录。
- **跟随 Apple TV 的系统用户**：给 App 加上用户管理权限
  （`com.apple.developer.user-management` = `runs-as-current-user-with-user-independent-keychain`）后：
  - 令牌存进「不分用户的钥匙串」（`kSecUseUserIndependentKeychain`），一个家庭成员登录一次，全家都能用；
  - `UserDefaults` 会由系统按 Apple TV 用户自动分开，用来记住「这位家庭成员上次选的是哪个账号」，
    下次就直接进入、跳过「谁在看」。
  - 由此带来一处存储调整：iPhone 把账号列表（`SavedServers`）存在 `UserDefaults`。在电视上，这个列表也会按系统用户
    分开，「谁在看」就只能看到自己登录过的账号。所以 tvOS 上账号列表和令牌一起放进不分用户的钥匙串，
    `UserDefaults` 只存「我偏好哪个账号」。`TokenVault` 与 `SavedServers` 各加一个 tvOS 分支。

## 6. 工程

### 6.1 结构

- 同一个 `apps/apple/project.yml` 里新增 `MovieClawTV` 目标（tvOS 26.0 起，设备族 3），
  像 iOS 目标一样嵌入 `AetherFFmpegBuild`；`AetherCore` 改成同时面向 iOS 和 tvOS。
  Info.plist 去掉屏幕方向、相机、相册这些 iOS 专属的键。
- AetherCore 给 TV 补几个透传：引擎的 Now Playing 会话、`audioBridgeMode`、`displayCapabilities`，
  以及面板 HDR / 杜比视界的状态选项。
- 素材：tvOS 要分层的 App 图标和 Top Shelf 图，现在的资源目录里只有 iOS 的平面图标。
- 目录：
  - 新建 `apps/apple/Shared/`，放 Core、播放逻辑、各页面的数据层（Store / Model）、主题令牌；
  - `apps/apple/MovieClaw/` 保持现名，作为 iOS 界面层——不按 ios-app.md 当初设想的那样改名为 `iOS/`，
    以免一次改名波及所有并行分支；
  - 新建 `apps/apple/MovieClawTV/` 放 tvOS 界面层。
- 文件搬迁单独提一个 PR，只做 `git mv` 和 §6.2 的解耦，不夹带功能改动；动手前先确认没有其他会话正在改这些文件。
- 标识：沿用 `io.movieclaw.app`（同一条 App Store 记录，一次购买两端通用，ios-app.md §2 已定）；
  请求标识 `MovieClaw-tvOS/<版本>`；设备类型 `tvos`。

### 6.2 共享前要拆的耦合

| 位置 | 问题 | 处理 |
|---|---|---|
| `Core/Session/Permissions.swift` 的 `allows(_ route:)` | 引用了 iOS 的路由表 `AppRoute`（层次倒挂） | 这个函数挪到 iOS 界面层 |
| `DesignSystem/Theme.swift` 的 `appBackground()` | `scrollContentBackground` 在 tvOS 上不存在 | 按平台分支 |
| `App/AppModel.swift` | 登录 / 切换状态机本身可共用，但引用了 iOS 的 `MainTab`、`AppRoute` 里的续播点、`SessionPrewarm` | 把这几处抽成参数或协议，状态机进共享层 |
| `App/Routing/Router.swift` 里的 `PlayRequest`、`PlaybackClip` | 播放逻辑依赖它们，但它们和 iOS 的标签、导航栈写在一起 | 挪进共享层；`Router` 本身各平台各写一份 |
| 客户端标识：`APIClient` 的 User-Agent，`TokenVault` 的 `kind` / `platform` / 安装标识前缀 `ios-`，`PlaybackController`、`PlaybackRecord` 里的上报字段 | 写死了 iOS | 按平台取值（`MovieClaw-tvOS`、`tvos`） |
| `PlayerCapability` 的 HDR 判断 | tvOS 上读数恒为 1.00 | 见 §4.3 |
| `PlaybackController` 的音频会话（P47、提前激活、`.longFormVideo`） | tvOS 上不存在，而且会害全景声 | tvOS 交给引擎默认（§4.3） |
| `NativeEngine`、`AVPlayerEngine` 的自动画中画；`DeviceVitals`、`PlaybackRecord` 的电池读数 | tvOS 上不存在 | `#if os(iOS)` |
| `PlaybackReportQueue` 写在 Application Support | tvOS 只保证 `UserDefaults`（约 500KB）持久，其余数据都可能被系统清理 | tvOS 上改写到 Caches；丢了只是少补报一次 |
| `SavedServers` 存在 `UserDefaults` | 跟随系统用户后会按人分开 | 见 §5.2 |

### 6.3 电视界面层的约定

- 按钮：iPhone 代码里有 195 处 `.buttonStyle(.plain)`，tvOS 上这种样式获得焦点时没有任何视觉变化。
  海报、剧照一律用 `.card` 或统一的焦点样式。
- 长按菜单在 tvOS 上可用（按住触控板），但很少有人会发现，只放次要操作（标记已看、收藏）。
- 搜索用简单版 `.searchable(text:)`，带范围标签的版本在 tvOS 上不可用。
- 液态玻璃的 API 在 tvOS 26 上都可用，但只用在浮层：侧边栏、播放控制条、信息面板，内容本身不加玻璃。
  播放控制条的玻璃不能影响字幕可读性：Infuse 8.2.5 给进度条加了玻璃效果，因为背后的模糊在动、干扰字幕，后来收回了。
- 电视上没有浏览器：`openURL` 打开外链、Safari 看预告片这类入口一律去掉。

### 6.4 发版

- 每个 PR 加一步 tvOS 编译。CI 的 Xcode 是 26.x，先确认它的镜像装了 tvOS 平台。
- 发版 skill 增加 tvOS 的归档与 TestFlight 上传；App Store 截图要用 1920×1080；
  「关于」页的开源许可两端同一份文本。

## 7. 分期与验收

| 阶段 | 内容 | 验收 |
|---|---|---|
| **T0 骨架** | 抽出 `Shared/` 并拆掉 §6.2 的耦合；`MovieClawTV` 空壳加最简播放页；调试参数直达播放（同 iOS 的 `-mcServer -mcUser -mcPass`） | iOS 测试全部通过。Apple TV 4K 真机播完一组样片（沿用网页故障注入实验台的 NAS 测试片）：① HEVC 4K HDR10 与杜比视界，服务端给的是原文件而不是降级的流；② 24 帧片源让电视切到 24Hz；③ 接功放时 EAC3 全景声、TrueHD 7.1 不被降混成立体声；④ 软解的 VP9、AV1、隔行 MPEG-2 在 A15 上不掉帧；⑤ 暂停后「正在播放」仍在；⑥ 按主屏键离开再回来能续播 |
| **T1 能看** | 账号密码登录 + 局域网发现、谁在看、侧边栏、首页、媒体库、详情、播放器、搜索、关于 | 只用方向键、确认键、返回键，能走完「开机 → 选人 → 选片 → 播放 → 下一集 → 返回」；每一页焦点都能走到所有元素 |
| **T2 好用** | 扫码登录（含服务端 `PAIRING_KINDS` 改动）、跟随 Apple TV 系统用户、Top Shelf「接下来继续」 | 全家共用一台 Apple TV 时，换系统用户后直接进入对应账号；主屏选中图标时显示继续观看 |
| **T3 二级功能** | 发现（含一键订阅）、我的订阅、片段 | 二级入口都在侧边栏「更多」分组；三个页面都没有任何需要打字的地方 |

## 8. 已定（2026-10-02 用户确认）

1. **导航用侧边栏**（结构见 §3.3）：侧边栏能装下数量不定的媒体库，二级功能放在底部分组，
   也就满足了「收起来、但找得到」。没选顶部标签栏：媒体库多了会挤。
2. **发现页保留一键订阅**，用默认规则（§3.2）。
3. **最低系统 tvOS 26**：与 iOS 26 起步一致，支持 Apple TV HD 与 Apple TV 4K。液态玻璃只在 4K 第二、三代上
   出现，其余机型是系统自动降级的扁平外观。Apple TV HD 没有 HDR、性能弱，建议「能装能用，但不专门优化」。

## 9. 风险与待验证

- **引擎的 tvOS 分支没有被我们真正跑过**：编译通过只证明 API 都在。显示模式切换、杜比视界、全景声、
  软解性能都要在 T0 用真机过一遍。我们的补丁（P1–P59）和上游基线比对过，没有引入 iOS 独占的 API，
  但起播优化的代价参数是按 iPhone 标定的（§4.3）。
- **侧边栏分组的已知问题**：有开发者报告，tvOS 18 上侧边栏里放 `TabSection` 会让返回键唤不出侧边栏，
  需要在 tvOS 26 上复核；如果仍有问题，「更多」改成一个普通入口页。
- **大海报行的焦点与图片性能**：首页可能有十几行、每行几十张海报。Nuke 的降采样与预取能共用，
  但焦点放大时的重绘需要在真机上测流畅度。
- **tvOS 会清理缓存目录**：页面快照（`PageSnapshots`）和图片磁盘缓存可能被系统清掉，只影响打开速度、
  不影响正确性，可以接受。

## 10. 明确不做

设置页、活动页、AI 助手、待处理事项、站点资源搜索与下载、媒体库与条目管理、字幕生成、合集编辑、分享、
网页同款的外观设置，以及照搬 iPhone 的所有表单类弹层。

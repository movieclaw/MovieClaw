# Mac App 设计（第一版）

> 状态：实施中（分支 `feat/macos-app`）。
> 关联文档：[tvos-app.md](tvos-app.md)（Apple TV 版，本文的底层与它共用、页面逐一对照）、
> [ios-app.md](ios-app.md)、[player-engine.md](player-engine.md)、[login-devices.md](login-devices.md)、
> [account-switching.md](account-switching.md)、[library-home-perspective.md](library-home-perspective.md)。

## 0. 一句话

**Mac 版是书桌上的放映厅**：版式照 macOS 上的 Apple Music（侧边栏 + 内容区 + 液态玻璃浮层），
看片的体验与 Apple TV 版一致；管理类的事仍留给网页。

## 1. 与 iPhone / Apple TV 版的关系

同一个 Xcode 工程加第三个目标 `MovieClawMac`（macOS 26 起），共用 `Shared/`（接口层、登录与账号、
`AppModel`、各页面数据层、播放逻辑）与 `AetherCore`（自研引擎）。只重写界面层，放在 `apps/apple/MovieClawMac/`。

共享层为 Mac 补的平台分支（全部用 `#if os(...)` / `#if canImport(UIKit)` 收口，iPhone 与 Apple TV 行为不变）：

| 位置 | 处理 |
|---|---|
| `AetherCore/AetherPlayback.swift` | 画面容器、字幕层、字幕文字块在 AppKit 上用 `NSView`（左上角原点 `isFlipped`、不接鼠标），引擎的 `AetherPlayerView` 本来两边都有 |
| `Shared/Core/NativePlatform.swift`（新） | `NativeImage` / `NativeView` 两个中性名字（UIImage/NSImage、UIView/NSView），`Image(native:)` |
| `PlayerSurface`、`AVPlayerEngine`、`CosmosBackdrop` | 各加一份 `NSViewRepresentable` / `NSView` 版本 |
| 音频会话（`PlaybackController`、`PlaybackRecord`、`AVPlayerEngine`、`NativeEngine`） | Mac 没有 `AVAudioSession`：不激活、不监听打断，输出口记 `other`；引擎自管（`hostManagesAudioSessionCategory = false`） |
| 前后台通知 | Mac 不会被挂起：改听 `NSApplication.willTerminateNotification`；进度上报不需要后台任务 |
| `ClientPlatform` | `kind = macos`、`MovieClaw-macOS`、`macOS`；文案里对设备的称呼 `deviceNoun`（手机 / Apple TV / 电脑） |
| 机型 | `uname` 的 machine 在 Mac 上只是 `arm64`，改读 `hw.model`（`Mac16,10`） |
| 屏幕读数 | 倍率、尺寸、HDR 能力读 `NSScreen.main`（`backingScaleFactor`、`maximumPotentialExtendedDynamicRangeColorComponentValue`） |
| `AppModel.minimumServerVersion` | Mac 版 0.31.0：以 `macos` 设备类型登录，服务端从这一版起才认 |

服务端：`login_devices` 新增 `macos`（显示名「Mac App」，人直接操作的客户端，账号密码登录与扫码配对都放行），
`DeviceClientInfo.kind` 允许 `macos`，活动页能认出 `MovieClaw-macOS/…` 的 User-Agent。推送本轮不做，`PUSH_KINDS` 不加。

## 2. 范围（2026-10-04 用户定）

本轮只做：**账号切换、搜索、首页、媒体库**（含条目详情、影人页、合集、播放）。
「我的订阅」「发现」不做；设置、活动、AI 助手、媒体库管理这些管理类功能同 Apple TV 版不做。

## 3. 窗口与导航

`NavigationSplitView`：左侧边栏、右内容区，同 Apple Music：

```
┌ 侧边栏 ─────────┐┌ 内容区（工具栏透明，剧照延伸到工具栏与侧边栏底下）
│ 🔍 片名、演员、导演 ││
│ ⌂ 首页            ││
│ ♡ 我的收藏        ││
│ 媒体库            ││
│   电影       622  ││
│   剧集       262  ││
│ 合集              ││   （网页上「显示在首页」的合集）
│   国产电视剧      ││
│ ……               ││
│ (头像) yee  ⌃⌄    ││   ← 当前账号：点开切换 / 添加账号 / 关于 / 退出登录
└──────────────────┘└
```

- 侧边栏每一项各有一个导航栈（`MacRouter.paths`）：切走再切回来还停在原来那一层；再点一次当前项退回根页面。
- 搜索框有字时内容区换成搜索结果（「搜索」自己的栈），清空回到刚才的页面。搜索框排在侧边栏第一行（`searchable(placement: .sidebar)`），
  不用 `TabView(.sidebarAdaptable)` 的搜索页签——那样系统把它固定排在顶层页签之后，做不到 Apple Music 那样排第一。
- 与 Apple TV 版不同，**各个媒体库直接列在侧边栏里**：Mac 窗口放得下，少点一层。首页「我的媒体库」一行照样保留。
- 播放器盖在整个窗口上（同 Apple TV App 的 Mac 版：在主窗口里播），侧边栏与工具栏收起。

### 3.3 菜单栏与快捷键

Mac 用户习惯从菜单栏找功能（Music、TV 都是这样），侧边栏能做的事菜单栏里都有一份：

| 菜单 | 项 |
|---|---|
| MovieClaw | 关于 MovieClaw（独立窗口：版本、开源许可——LGPL 合规必需） |
| 前往 | 首页 ⌘1、我的收藏 ⌘2、各个媒体库 ⌘3…⌘9、返回 ⌘[、搜索 ⌘F |
| 账号 | 本机登录过的全部账号（当前打勾，点一下切换）、退出登录 |

只有一个主窗口（去掉「新建窗口」），避免开出两份播放器与导航状态。播放器自己的快捷键见 §6。

## 4. 页面

### 4.1 首页

- 首屏是「接下来继续」的大图区：剧照铺满（窗口多宽铺多宽，16:9 顶对齐裁剪，高度约为宽度的 0.44、420～760 点），
  延伸到工具栏与侧边栏底下（`backgroundExtensionEffect`），40 秒慢推近；往下渐隐进剧照边缘色（同 Apple TV 版的算法），
  左下一团中性的黑托字、深浅按剧照亮度定。
- 左下：片名 Logo（最宽 460、最高 120）→ 年份 · 类型 · 片长 → 第几集 · 集名 → 两行简介 → 「继续播放」（白底黑字胶囊）
  「详情」（玻璃）+ 剩多久。
- **大图跟着鼠标走**：鼠标在下面「接下来继续」的卡上停稳 0.3 秒，大图换成那一部（Apple TV 版是跟着焦点走，Mac 上焦点就是鼠标）；
  右下一排小圆点也能点着换；不自动轮播。大图正讲的那张卡描一圈亮边。
- 下面的行是 Apple Music 式的「架子」：标题可点（「最近添加的电影 ›」）进完整的海报墙；鼠标移到行上两端浮出玻璃翻页键，一次翻一屏；
  行末「查看全部」卡（行满 20 部时）。「我的媒体库」一行是库卡与合集卡（服务端拼好的货架封面 + 模糊延伸 + 库名与部数）。
- 数据：`LibraryHomeStore`（快照秒开、60 秒轮询、播放器关掉后刷新）+ 网页的首页自定义（`HomeRows`），与各端同一口径。

### 4.2 卡片

- 平时安静：圆角 10 的图 + 0.5 点亮边 + 轻投影，**片名与年份写在图下面**（鼠标没有焦点，认不出的东西不能只在悬停时出现）。
- 悬停：图压暗一层、投影加深；海报左下浮出玻璃播放键、右下「⋯」；横版剧照卡（底部暗带写着第几集、剩多久）播放键居中、「⋯」在右上。
- 右键菜单与「⋯」同一份：播放 / 查看详情（「接下来继续」是继续播放 / 查看详情；分集是播放 / 标为已看）。

### 4.3 海报墙

媒体库、合集、「查看全部」、我的收藏共用 `MacPosterWall`：大标题 + 灰色总数，网格 `adaptive(150…200)` 随窗口宽度多放几列，
分页 60 条、滚到底接着取。媒体库右上一枚玻璃下拉：排序（最近添加 / 最近上映 / 评分 / 片名）+ 方向 + 「只看没看过的」，按库记在本机。

### 4.4 条目详情

- 头图同首页的大图组件（更高一截），左下文字 + 规格小标签（4K / DOLBY VISION / DOLBY ATMOS……在位文件里各挑最好的一档）；
  主按钮写明哪一集、从哪儿接着播（「继续 第 1 季第 3 集 · 12:34」）；「从头播放」；收藏、标为已看是圆形玻璃钮；右下「导演 / 主演」。
- 往下（垫同一张剧照的模糊版）：选季胶囊 → 分集横排（自动滚到头图正讲的那一集，剧照 + 第几集、集名、三行简介、首播日期；
  看到哪 / 进度 / 已看；缺集置灰）→ 电影的作品系列（「已有 7 / 共 8」、本片、未入库）→ 演职员（圆头像，进影人页）→ 所属合集 →
  信息（原名、年份、类型、评分、季数 / 片长、文件数与大小、电影的各个版本），相当于 Apple Music 专辑页底部的发行信息。

### 4.5 搜索与影人页

- 搜索：停 0.35 秒发请求、请求序号防乱序；「人物」一行胶囊（点一个人看他在库里的全部作品）+「影片」网格（写命中依据）；
  空着时显示最近搜过的词（本机按账号记）。
- 影人页：大圆头像 + 姓名 + 「库内 12 部 · 参演 10 · 执导 2」，作品与海报墙同一套网格，海报下写「饰 某某 · 年份」；
  「本片」点了退回上一页；片源已移除的置灰。

## 5. 账号

- 侧边栏底部当前账号（头像、昵称、服务器），点开一块浮层：大头像 + 昵称 + 用户名 · 身份 + 服务器；「切换到」列出本机其他账号
  （跨服务器，换一枚令牌、不联网、不用密码，主界面整棵重建）；添加账号… / 关于 MovieClaw / 退出登录…（确认框说明会在服务器上注销）。
- 菜单栏「账号」菜单同一份。切换、退出后自动切到别的账号时，窗口顶上浮一行提示（`AppModel.takeNotice`）。
- 登录过期被送回登录页：重新登录后回到原来那一页（`captureResume` / `takeResume`）。
- 欢迎与登录：星空背景 + 玻璃卡片；局域网发现 / 手填地址 → 账号密码或扫码（配对码）登录；未初始化、连不上、选人各有一屏。

## 6. 播放器

同一个引擎与 `PlaybackController`，控制层为 Mac 重写：画面铺满窗口，鼠标一动浮出控制层、静止 3 秒淡出并藏起指针；
底部一枚液态玻璃控制胶囊（播放 / ±10 秒 / 进度条与缩略图预览 / 时间 / 音量 / 字幕·音轨·画质 / 全屏）；
「跳过片头」「下一集」右下浮现。键盘：空格、← →、↑ ↓、M、F / ⌃⌘F、Esc（先退全屏再关播放器）、⌘.。

## 7. 开发与验收

- 编译：`xcodebuild -scheme MovieClawMac -destination platform=macOS`。Debug 构建不开沙盒（调试驱动要和外面交换文件），Release 开沙盒
  + 网络进出（局域网发现要收 UDP 应答）。
- 签名：本机开发用 Apple Development 证书手动签名；换签名身份（如临时签名）后，旧的钥匙串条目会弹授权框卡住 App，删掉
  `io.movieclaw.app.*` 的旧条目即可。
- **调试驱动**（`MacDebugDriver`，只在 Debug 构建）：开发会话没有录屏权限、也开不了系统 UI 自动化（XCUITest 跑不起来），
  于是 App 读 `/tmp/movieclaw-mac-debug/inbox/` 里的命令文件，自己截自己的窗口（截进程自己的窗口不需要录屏权限）、
  往自己的窗口合成鼠标 / 键盘 / 滚轮事件、切页签、压栈、起播。环境变量 `MC_FORCE_HOVER=1` 让卡片一直是悬停样子（合成的移动事件
  触发不了系统的悬停追踪）。已知限制：不在前台的窗口里，表格（侧边栏）吞掉第一下点击；SwiftUI 的无障碍树在没有辅助技术连着时是空壳，
  按标识找控件不可用，按截图坐标点。
- 本地网络：新 App 第一次连局域网地址要用户在系统弹框里允许；开发期可经本机端口转发（`ssh -L 13000:127.0.0.1:3000`）连 NAS。
- 调试参数同其他端：`-mcServer -mcUser -mcPass -mcTab -mcRoute`；另有 `-mcClientKind ios`（连还不认 macos 的旧服务器联调用）、
  `-mcDebugDir`（并行开发时每个实例各用一个调试目录）。

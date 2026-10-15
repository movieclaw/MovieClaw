# Android 原生 App 设计

> 状态：开发中（本仓库 `android` 分支，尚未合入 main）。验收口径与 iOS 一致：同一台服务器上，
> 手机端网页、iOS App 与安卓 App 的功能与观感一致；安卓自己的取舍逐条列在 §5。
> 交互与版式的参照是 **iOS App**（[ios-app.md](ios-app.md)）与手机端网页；本文写安卓的决策、
> 目录、约定与验收方法。

## 1. 决策

| 事项 | 结论 | 理由 |
|---|---|---|
| 技术栈 | Kotlin + Jetpack Compose（Material 3），minSdk 26 / target 36（compileSdk 37），只出 `arm64-v8a` | 与 iOS 同样走全原生：播放要硬解、画中画、后台保活（MediaSessionService），网页做不到或做不好 |
| 范围 | 手机端网页的全部功能原生重写（不内嵌网页） | 用户决定 |
| 播放 | 与 TV 版**共用一个引擎**（`apps/android-core`，2026-10 由原 TV 版引擎统一，同 iOS 的 `Shared/`）：Exo + FFmpeg 音频软解 + libass；本机如实申报能力，放不了的走服务端流（换封装 / 转码），失败按兜底阶梯重连 / 改走服务端流 / 逐级降档 | 原手机双内核（Exo + mpv）两套行为难维护；统一后手机与 TV 的兜底、能力探测、看门狗、诊断一致。光盘镜像由服务端读盘换封装，VC-1 等冷门编码交服务端转码 |
| 认证 | 设备令牌（`POST /auth/device/login` 用账号密码换），存 **AndroidKeyStore** 加密的凭据库 | 与 iOS 同一套：这台手机是「我的设备」里的一台，可单独注销；多账号（多服务器）都在本机 |
| 接口层 | 手写 Retrofit 接口 + kotlinx.serialization（SnakeCase、`ignoreUnknownKeys`） | 安卓侧只用得到其中一部分；字段可空、未知字段忽略，对服务端新旧版本宽容（例：字幕轨 `title` 缺失时回落语言码） |
| 工程 | Gradle（Kotlin DSL）+ Hilt/KSP + Media3 + Coil 3 | 一以贯之的官方栈，CI 上 `testDebugUnitTest / assembleDebug / lintDebug` |
| 版本号 | `apps/android/version.properties` 独立管理 `versionName` / 递增 `versionCode` | 单独发 `android-vX.Y.Z` Release，版本独立于服务器与 Apple；见 [发版说明](android-release.md) |
| 原生库 | 统一引擎的 FFmpeg 音频软解按 LGPL-2.1 自编（`apps/android-core/native/ffmpeg/build.sh`，产物不入库，正式包打包时现编）；libass 走 ass-media（Maven） | 与 TV 版同一套（androidtv-app.md §4.3）；mpv 与预编译原生库附件已移除 |
| 包名 | `io.movieclaw.android` | 与 iOS 的 `io.movieclaw.app` 不同，见 §5；请求标识按上游约定 `MovieClaw-Android/<版本>` |
| 外观 | 跟随手机端网页（纯黑底、材质用同一套玻璃令牌）；「底栏液态玻璃」这类本机开关放「我的 → 设置」 | 与 iOS 同为「不做网页的外观编辑」 |
| 文案 | **一律取上游**（网页 / iOS 的现成文案逐字用），不自造 | 三端同一条轨、同一个功能叫同一个名字；代码注释里标了出处 |

## 2. 目录

一个 Gradle 工程，手机端一个模块，另把与 TV 共用的 `apps/android-core/*` 挂成 `:core:*`（播放引擎、生成的播放接口与模型、
FFmpeg 音频扩展）；`app/src/main/java/io/movieclaw/android/` 下按「核心 / 功能」两层：

```
apps/android/
  gradle/libs.versions.toml   手机自己的依赖版本（与 core 共用的在 ../android-core/gradle/shared.versions.toml）
  app/
    build.gradle.kts          版本号
    src/main/java/io/movieclaw/android/
      MainActivity.kt         入口；深链 / 通知落点（mc_route / mc_tab）
      MovieClawApp.kt         Application（Hilt、图片加载器、通知通道）
      routing/                导航图、会话壳、通知路由总线
      core/
        api/                  Retrofit 接口（McApi）+ 通道工厂（普通 / 播放专用，两套连接池）
        model/                手写数据模型（含平台专属：SkipSegments、Playback、SubtitleGen、Llm…）
        network/              ApiClient、SSE（EventStream）、缓存、错误中文化
        session/              连接/登录状态机、设备令牌（KeyStore）、权限、分享链接
        playback/             PlaybackSessionHolder（统一引擎的成员 / 访客身份与后台服务）、TrackLabels、
                              字幕外观、刷片画质与字幕窗口解析
        designsystem/         主题令牌（McType/McMetrics）、玻璃材质、底栏液态玻璃、远程图片
        notify/ discovery/     通知中心、服务发现
      feature/                <模块>：每个页面 + 自己的 ViewModel（account / activity / agent /
                              detail / discover / library / more / notices / onboarding / player /
                              reels / root / search / settings / share / subscriptions）
    src/test/                 单元 / Robolectric 测试（含对 MockWebServer 的协议契约测试）
```

## 3. 约定

### 3.1 接口

- 一切都过 `core/api/McApi`（Retrofit）+ `ApiFactory`（按 origin / 身份取通道）；**不要**在页面里直接拼 URL。
- 播放链路（协商、进度、心跳、停止、字幕）走**播放专用连接池**，不排页面请求后面。
- 新增字段一律**可空 + 有默认值**：老服务端缺字段不能让整个响应解码失败（例：`episode.segments`、字幕轨 `title`）。
- 请求标识 `MovieClaw-Android/<version>`（活动页据此显示客户端）。

### 3.2 页面骨架与设计系统

- 顶栏 / 底栏 / 卡片 / 玻璃材质都取 `core/designsystem`（`McTopBar`、`FlatCard`、`GlassCapsule`…），
  页面不自造一份；悬浮顶栏是这一页的基准（正文给它让位）。
- **播放页做不了真模糊**：视频在 SurfaceView 上（系统合成），Haze 抓不到它的像素，
  所以播放页的玻璃一律是「黑底等价」（半透明深底 + 一圈淡白边）——别在播放页挂 Haze。
- 底栏「液态玻璃」有一枚 A/B 试用开关（「我的 → 设置 → 显示与外观」）：开 = 液态玻璃版（弹簧胶囊 /
  按压辉光 / 高光边 / 拖动擦选），关 = 上一版形态；两边对齐稳定后删一边。

### 3.3 文件归属

- 一个模块一个 `feature/<模块>` 目录：页面 + ViewModel + 该模块专属组件都放在里面，不跨模块引用私有件。
- 共享件放 `core/`；放不下就说明它其实是两个东西。

## 4. 播放器架构（与 TV 共用的统一引擎）

2026-10 起手机与 TV 用同一个播放引擎：`apps/android-core/playback`（原 TV 版引擎，设计见
[androidtv-app.md](androidtv-app.md) §4、[player-engine.md](player-engine.md) §3「兜底阶梯」）。手机只保留控制层。

- **引擎**：`PlaybackController`——如实申报能力（Exo 实际会选的解码器、HDR、杜比视界 profile、`local_tracks`），
  服务端能直连就给原文件、放不了给 HLS；失败按 `FailurePolicy` 走：网络问题同档原地重开，确定解不了改走服务端流，
  服务端流放不了逐级降档；卡顿归因与掉帧看门狗、解码器黑名单、播放记录（含异常退出补报）都在引擎里。
  Exo 由 `UnifiedExo` 统一配置：FFmpeg 音频软解（透传 / 系统解码优先）、libass 特效字幕。
- **手机的宿主差异**（`PlaybackHost`）：切后台接着放（锁屏听、画中画），系统媒体会话由 `PlaybackService` 持有、
  挂 `PlaybackController.player`；设备类型 `android` / UA `MovieClaw-Android/<版本>`。能力申报与电视一致，**不报 `is_mobile`**：
  服务端把「移动端 + 原生 HLS」当成 iOS 系统播放器，会把 5.1 音轨固定转成 AAC 双声道、限制转码画质，Exo 用不着。
- **身份**：`PlaybackSessionHolder` 按成员（`MemberBackend`）/ 访客分享（`ShareBackend`，走 `/share/{slug}/playback/…`）建控制器；
  退出登录、切账号立即停掉成员播放，访客播放不受影响。令牌由本 App 的拦截器按请求上的身份标记附带。
- **轨**：菜单直接用引擎的 `PlayerState.audioOptions` / `subtitles`（放不了的轨置灰写原因）；详情页选好的轨经
  `PlayTarget.preferredAudio / preferredSubtitle` 带进引擎，按用户选择处理。
- **字幕**：直连原文件时内封 / 外挂文本轨由 Exo 本机解出（不再让服务端通读整个容器），服务端流的文本字幕取 VTT；
  两路都由 `SubtitleOverlayLayer` 按用户的字幕外观自己画（不用文件自带样式，所以没有黑框）；图形字幕（PGS）直连时
  Exo 解成位图，服务端流时由服务端压制进画面；ASS 交给 libass 叠加层。
- **跳过段 / 连播**：判定与倒计时都在引擎（`SkipSegments`、`advanceAutoNext`：8 秒、暂停冻住、连播 ≤3 集、任何用户操作清零）。
- **刷片**：`ReelsPlayers` 的编排（当前条、预起下一条、字节预取）不变，每条的播放器换成引擎的 `ClipPlayer`（同一套 Exo 配置）+
  `SourceByteCache`；转码 / 光盘片源借服务端会话（光盘由服务端读盘换封装）。

**统一时相对旧版手机的已知回退**（留到统一引擎上的优化阶段处理；旧版手机「本季播完接下一季」不算回退——iOS、网页、TV
都只在本季内连播，三端保持一致，2026-10 定）：

| 回退 | 说明 |
|---|---|
| 直连时内封字幕不能调时间轴 | Exo 解出的内封字幕时机由引擎定（字幕外观里会说明）；外挂字幕调了时间轴改由叠层取服务端 VTT 来画，照常可调；服务端流的字幕照常可调 |
| 正片不挂片源字节缓存、MKV 精简索引注入 | 刷片仍有字节缓存与预取 |
| 本机读 ISO、VC-1 等冷门编码软解 | 交服务端换封装 / 转码（要服务端能转，占服务端资源） |
| 起播分段计时日志（PlaybackStartupTrace） | 改看引擎播放记录的 startup marks |

## 5. 与 iOS / 网页的已知差异（逐条如实列）

| # | 差异 | 说明 / 后续 |
|---|---|---|
| 1 | 包名 `io.movieclaw.android`（iOS / 上游文档写的是统一 `io.movieclaw.app`） | 若上游要求统一，是一次性重命名（applicationId + 目录 + Hilt 无影响） |
| 2 | 「AI 设定」（各场景默认模型）页面未搬 | 「模型接入」已搬（在「设置 → 服务器」组）；「AI 设定」是 iOS 的另一个分区，安卓暂缺——「模型接入」的判词逐字照抄，会提到它 |
| 3 | 自定义端点下的「自定义模型参数」只做了必填项 | 未做思考强度的方言 / 档位选择，默认 = iOS 的「不可控」档；只影响自建网关的进阶参数 |
| 4 | AI 字幕的进度 / 状态卡与「交给 Agent」只做过编译验证 | 真跑一个生成任务才能看到；验证成本（模型费用）与实际需要由用户决定何时做 |
| 5 | 播放页玻璃是「黑底等价」而非真模糊 | 见 §3.2；iOS 的液态玻璃是系统材质，安卓在 SurfaceView 上拿不到帧 |
| 6 | 底栏液态玻璃是按 A/B 开关的试用形态 | 对齐稳定后删掉旧形态与开关 |
| 7 | 不支持 Android TV / 平板布局 | 手机横屏优先；`verticalSizeClass` 对应的平板档（如连播卡剧照）等适配时再补 |

## 6. 验收方法

1. **真机**：装 `app/build/outputs/apk/release` 的包，对着同一台服务器把手机端网页 / iOS 的动线走一遍；
   视觉以截图对照（发现页 hero、详情页轨道行、播放页控制层与两个覆盖层、活动页、我的页）。
2. **单元 / 协议**：`./gradlew :app:testDebugUnitTest`（含 MockWebServer 的接口契约测试：筛选参数名、
   轨标题、身份隔离等）与 `./gradlew :app:lintDebug`。
3. **端到端（故障注入实验台）**：调试包认一组直达参数（`core/playback/DebugLaunch.kt`，与 TV 版同一套：
   `mc_server / mc_user / mc_pass / mc_route=/play/<条目>[/sXXeYY][?t=秒] / mc_lab`，播放中 `mc_seek_ms / mc_audio /
   mc_subtitle`），`scripts/perf/androidtv_faultlab` 加 `ATV_FAULTLAB_PKG=io.movieclaw.android` 就能驱动手机包
   （判定读引擎每秒打的 `PlaybackProbe` 行；按方向键的场景只对电视有意义）。
4. **CI**：`.github/workflows/android-stability.yml` 对 `main` 与 `android` 分支、`apps/android/**` 与
   `apps/android-core/**` 的改动先编 FFmpeg 音频库，再跑上面两项 + `assembleDebug`，并用临时证书走一遍正式打包校验。
5. 详细的稳定性整改记录（统一引擎之前的双内核时期）见 [../android/stability-validation.md](../android/stability-validation.md)。

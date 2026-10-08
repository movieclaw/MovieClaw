# Android 原生 App 设计

> 状态：开发中（本仓库 `android` 分支，尚未合入 main）。验收口径与 iOS 一致：同一台服务器上，
> 手机端网页、iOS App 与安卓 App 的功能与观感一致；安卓自己的取舍逐条列在 §5。
> 交互与版式的参照是 **iOS App**（[ios-app.md](ios-app.md)）与手机端网页；本文写安卓的决策、
> 目录、约定与验收方法。

## 1. 决策

| 事项 | 结论 | 理由 |
|---|---|---|
| 技术栈 | Kotlin + Jetpack Compose（Material 3），minSdk 26 / target 36，只出 `arm64-v8a` | 与 iOS 同样走全原生：播放要硬解、画中画、后台保活（MediaSessionService），网页做不到或做不好 |
| 范围 | 手机端网页的全部功能原生重写（不内嵌网页） | 用户决定 |
| 播放 | 双内核：**Exo**（默认，服务端直出 / HLS）+ **mpv**（libmpv，兜住 Exo 解不了的） | 与 iOS「本机能解决的一切都由本机引擎解决」同一思路；mpv 负责 ISO/BDMV 原盘直读、VC-1/MPEG-2/TrueHD/PGS 软解、HDR 与 ASS 特效字幕。缺原生库时**干净退回仅 Exo**（`MpvNative.available=false`） |
| 认证 | 设备令牌（`POST /auth/device/login` 用账号密码换），存 **AndroidKeyStore** 加密的凭据库 | 与 iOS 同一套：这台手机是「我的设备」里的一台，可单独注销；多账号（多服务器）都在本机 |
| 接口层 | 手写 Retrofit 接口 + kotlinx.serialization（SnakeCase、`ignoreUnknownKeys`） | 安卓侧只用得到其中一部分；字段可空、未知字段忽略，对服务端新旧版本宽容（例：字幕轨 `title` 缺失时回落语言码） |
| 工程 | Gradle（Kotlin DSL）+ Hilt/KSP + Media3 + Coil 3 | 一以贯之的官方栈，CI 上 `testDebugUnitTest / assembleDebug / lintDebug` |
| 版本号 | `apps/android/version.properties` 独立管理 `versionName` / 递增 `versionCode` | 随服务器 Release 分发 APK，版本独立于服务器与 Apple；见 [发版说明](android-release.md) |
| 原生库 | FFmpeg / mpv / libass 的预编译产物放**独立仓库** [movieclaw-android-libs](https://github.com/anlan-home/movieclaw-android-libs)，构建时下载 + 校验 sha256 | 压缩包约 38MB、解压 116MB，不宜入库；缺包不中断构建（退化成仅 Exo 内核的包，日志写明）。许可（mpv GPL-2.0+、FFmpeg LGPL/GPL、libass ISC、libc++ Apache）与逐项来源见该仓库 README 与包内 `NOTICE.md` |
| 包名 | `io.movieclaw.android` | 与 iOS 的 `io.movieclaw.app` 不同，见 §5；请求标识按上游约定 `MovieClaw-Android/<版本>` |
| 外观 | 跟随手机端网页（纯黑底、材质用同一套玻璃令牌）；「底栏液态玻璃」这类本机开关放「我的 → 设置」 | 与 iOS 同为「不做网页的外观编辑」 |
| 文案 | **一律取上游**（网页 / iOS 的现成文案逐字用），不自造 | 三端同一条轨、同一个功能叫同一个名字；代码注释里标了出处 |

## 2. 目录

一个 Gradle 工程，手机端一个模块；`app/src/main/java/io/movieclaw/android/` 下按「核心 / 功能」两层：

```
apps/android/
  gradle.properties           版本、原生库地址（可被 local.properties / -P 覆盖）
  gradle/libs.versions.toml   依赖版本唯一来源
  app/
    build.gradle.kts          版本号按构建日期；缺 jniLibs 时下载预编译原生库
    src/main/java/io/movieclaw/android/
      MainActivity.kt         入口；深链 / 通知落点（mc_route / mc_tab）
      MovieClawApp.kt         Application（Hilt、图片加载器、通知通道）
      routing/                导航图、会话壳、通知路由总线
      core/
        api/                  Retrofit 接口（McApi）+ 通道工厂（普通 / 播放专用，两套连接池）
        model/                手写数据模型（含平台专属：SkipSegments、Playback、SubtitleGen、Llm…）
        network/              ApiClient、SSE（EventStream）、缓存、错误中文化
        session/              连接/登录状态机、设备令牌（KeyStore）、权限、分享链接
        playback/             PlaybackController（双引擎抽象）、TrackLabels、字幕解析与叠层数据、
                              跳过段判定、片源字节缓存与预取、QoS 上报
        designsystem/         主题令牌（McType/McMetrics）、玻璃材质、底栏液态玻璃、远程图片
        notify/ discovery/     通知中心、服务发现
      feature/                <模块>：每个页面 + 自己的 ViewModel（account / activity / agent /
                              detail / discover / library / more / notices / onboarding / player /
                              reels / root / search / settings / share / subscriptions）
    src/main/cpp/             JNI：mpv_bridge（libmpv dlopen）、iso_native（UDF over HTTP Range）
    src/main/jniLibs/         预编译原生库落点（不入库，构建时下载）
    src/test/                 单元 / Robolectric 测试（含对 MockWebServer 的协议契约测试）
  tests/native/               ASan/UBSan 原生回归（CI 上跑）
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
- **播放页做不了真模糊**：视频在 SurfaceView 上（mpv / PlayerView 都是系统合成），Haze 抓不到它的像素，
  所以播放页的玻璃一律是「黑底等价」（半透明深底 + 一圈淡白边）——别在播放页挂 Haze。
- 底栏「液态玻璃」有一枚 A/B 试用开关（「我的 → 设置 → 显示与外观」）：开 = 液态玻璃版（弹簧胶囊 /
  按压辉光 / 高光边 / 拖动擦选），关 = 上一版形态；两边对齐稳定后删一边。

### 3.3 文件归属

- 一个模块一个 `feature/<模块>` 目录：页面 + ViewModel + 该模块专属组件都放在里面，不跨模块引用私有件。
- 共享件放 `core/`；放不下就说明它其实是两个东西。

## 4. 播放器架构（双引擎）

- **选择**：起播时由服务端决策（`POST /playback/sessions`）拿到 tier / 容器 / 流地址与**候选轨列表**；
  客户端按解码能力选内核：能直出的走 Exo，解不了的（原盘、特殊编码）走 mpv。
- **轨**：音轨 / 字幕菜单的名字由 `TrackLabels` 统一拼（详情页与播放器**必须同名**）；字幕优先用
  文件自带标题，强制轨打「强制」；放不了的轨**置灰写明原因**，不给一个点了没反应的选项。
- **字幕**：服务端旁挂下发（`/playback/files/{id}/subtitles`），客户端解析成纯文本 cue 自己画
  （`SubtitleOverlayLayer`）——文件自带的样式（描边、底框）一律不要，这就是「黑框」从结构上消失的原因。
  内封轨整轨要服务端通读整个容器（实测 5.7GB / 39.7 秒），因此：**先用窗口抽取**（起播点前 10 秒起、
  5 分钟）几秒上屏，整轨到了整表替换；当前集与下一集（片尾卡出现后）都走 `subtitles/preview` 后台预热
  （不随请求断开取消）。
- **跳过段 / 连播**：判定照 iOS `SkipSegments`（服务端整季比对出的段；末尾 3 秒内不出按钮；
  「一直放到结尾」的片尾交给连播卡）；连播卡与倒计时照 iOS `PlayerUpNextCard`（紧凑档），
  倒计时按**帧时钟**逐帧推进、暂停冻住、连播 ≤3 集、任何用户操作清零。
- **放弃也留档**：`SourceByteCache` 与预取（`/reels` 的 `play.prefetch`）落地在磁盘缓存，退版本 / 换源不重下。

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
3. **原生**：`tests/native/run.sh`（ASan/UBSan 回归）。
4. **CI**：`.github/workflows/android-stability.yml` 对 `main` 与 `android` 分支、`apps/android/**`
   的改动跑上面三项 + `assembleDebug`（`-PskipNativeLibsDownload=true`，不下载原生库也能过）。
5. 详细的稳定性整改记录见 [../android/stability-validation.md](../android/stability-validation.md)。

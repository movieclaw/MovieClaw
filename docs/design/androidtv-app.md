# Android TV App 设计（定义稿）

> 状态：已定稿（2026-10-08 用户确认 §9 四项），实施中。分支 `feat/androidtv-app`。
> 关联文档：[tvos-app.md](tvos-app.md)（产品形态的参照）、[player-engine.md](player-engine.md)（终端做重活的原则）、
> [device-auth.md](device-auth.md) / [login-devices.md](login-devices.md)（设备令牌与扫码配对）、
> [library-home-perspective.md](library-home-perspective.md)（首页的行）、[image-sizing.md](image-sizing.md)（图片宽度阶梯）。

## 0. 一句话

**Android TV 版是 Apple TV 版在安卓电视上的同胞**：产品形态、交互原则照 tvos-app.md（播放第一、不让人在电视上打字、
一家人共用、只看不管）；代码是一套**全新独立的工程**，只以服务端协议为准。

## 1. 决策

| 事项 | 结论 | 理由 |
|---|---|---|
| 与现有安卓手机版的关系 | **完全独立**：不复用、不参考 `apps/android` 的代码、依赖版本与设计 | 用户决定（2026-10-08）：手机版由其他开发者贡献，架构与内核的可靠性未经验证。服务端协议以后端代码为准，Apple 端只作行为对照 |
| 技术栈 | Kotlin + Jetpack Compose + **Compose for TV**（`androidx.tv:tv-material`） | Google 当前推荐的电视界面栈，焦点、D-pad、卡片放大都有现成组件 |
| 最低系统 | **minSdk 23（Android 6.0）**，target / compile 取当前最新稳定 SDK | Media3 自 1.9 起 minSdk 23，再往下没有意义；覆盖国产盒子、索尼等厂商电视与 Google TV 设备 |
| CPU 架构 | **arm64-v8a + armeabi-v7a** 都出 | 不少电视芯片是 64 位、系统却是 32 位用户态（Chromecast with Google TV、部分索尼 / 国产电视），只出 arm64 会装不上 |
| 播放内核 | **Media3 ExoPlayer 主引擎** + 服务端 HLS 兜底；用扩展补短板（§4） | 硬解、HDR / 杜比视界、音频透传都直接交给系统，电视端最稳；与 player-engine.md「终端做重活、解不了再走服务端」一致 |
| 依赖注入 | 手写构造注入（一个 `AppGraph`），不上 Hilt | 工程小，少一层注解处理与构建时间；账号切换时整张图重建即可 |
| 网络 | OkHttp + kotlinx.serialization；响应字段一律可空带默认值、`ignoreUnknownKeys` | 新旧服务端双向兼容（api-compat 教训） |
| 接口层 | **从后端生成 Kotlin**（§9 第 4 项） | 字段不漂移，服务端改了重新生成 |
| 图片 | Coil 3（OkHttp 通道，带 `Authorization`），按宽度阶梯取图 | 图片接口要登录；阶梯同后端 `WIDTH_LADDER` |
| 包名 / 标识 | `io.movieclaw.androidtv`；请求标识 `MovieClaw-AndroidTV/<版本> (<型号>; Android <版本>; build <n>)` | 与手机版 `io.movieclaw.android` 并存不冲突，同一台设备可两个都装 |
| 设备类型 | 服务端新增 `androidtv`（§6） | 「我的设备」里要显示成电视、批准页的「将获得」要写对；扫码配对必须登记 |
| 版本号 | `apps/android-tv/version.properties` 独立管理 | 同 android-release.md 给 TV 预留的口径：独立 applicationId、版本文件和附件名 |
| 文案 | 一律取 Apple TV / 网页现成文案，不自造 | 多端同一个功能叫同一个名字 |

## 2. 功能范围（一期）

对齐 Apple TV 首版，**不做发现和订阅**（用户 2026-10-08 定）。

| 功能 | 怎么做 | 用到的接口 |
|---|---|---|
| 找服务器 | 局域网发现（Jellyfin 兼容 UDP 7359，单播扫本网段 /24）+ 手填地址；候选地址过 `GET /health` 才算数；低于最低服务器版本直接说明 | `udp 7359`、`GET /health`、`GET /auth/bootstrap` |
| 扫码登录（默认） | 电视显示二维码 + 配对码，手机扫码批准；按 `interval` 轮询 | `POST /auth/device/authorize`、`POST /auth/device/token`、`GET /auth/me` |
| 账号密码（兜底） | 电视屏幕键盘输入 | `POST /auth/device/login`（`kind: androidtv`） |
| 谁在看 / 多账号 | 侧边栏第一项；跨服务器切换 = 换令牌、不联网、整棵界面树与 `AppGraph` 重建；启动直接进上次的账号 | 本机存储；退出登录 `DELETE /auth/devices/current`（失败入队重试） |
| 首页 | 首屏是跟着焦点走的「接下来继续」大图区，下面接用户在网页自定义的行 | `GET /playback/up-next`、`GET /ui/preferences`（只读）、各行取数（库 / 类型 / 合集 / 收藏 / 按类型找）、`GET /libraries/showcase` |
| 媒体库海报墙 | 从首页「我的媒体库」行进；筛选只留排序、只看未看、类型；每页 60 条、短页即止 | `GET /libraries?scope=all`、`GET /libraries/{id}/items`、`GET /libraries/kinds/{kind}/items` |
| 条目详情 | 大剧照 + 片名 Logo + 事实行 + 主按钮「继续 mm:ss」；季、分集横排、演职员；版本、标记已看 / 收藏 | `GET /libraries/{lid}/items/{id}`、`…/episodes`、`GET /playback/resume`、`GET/POST /playback/marks`、`GET /people/{id}` |
| 搜索 | 屏幕键盘 + 系统语音输入，只搜媒体库 | `GET /search/library` |
| 播放 | §4、§5 | `/playback/sessions` 一族 |
| 关于 | 版本号 + 开源组件许可（**LGPL 合规必需**） | — |
| 不做 | 发现、订阅、片段、大图预告、设置、活动、AI 助手、待处理事项、站点资源、媒体库管理、分享 | — |

导航照 Apple TV 的最终形态：左侧可收起的抽屉（`tv-material` 的 `NavigationDrawer`），只有 **账号 / 搜索 / 首页** 三项；
二级页（详情、海报墙、影人页）压在抽屉之上、盖住整屏，返回键退回。

## 3. 工程

### 3.1 目录

独立的 Gradle 工程，按「核心 / 功能」分模块，核心模块不依赖任何界面：

```
apps/android-tv/
  settings.gradle.kts / build.gradle.kts / gradle/libs.versions.toml（依赖版本唯一来源）
  version.properties
  core/
    model/        接口数据模型（纯 Kotlin，可空带默认值）
    network/      OkHttp 客户端、信封解包、错误中文化、User-Agent、令牌注入
    session/      服务器发现、登录 / 配对状态机、账号库（KeyStore 加密）、权限
    playback/     会话协议、能力探测、引擎抽象（Player 接口）、进度 / 心跳上报、跳过段、选轨
  feature/
    onboarding/ home/ library/ detail/ search/ player/ accounts/ about/
  app/            Application、MainActivity、导航壳、AppGraph
  native/ffmpeg/  LGPL FFmpeg 音频扩展的编译脚本（产物不入库，§4.3）
  tests/          端到端（遥控器按键驱动）
```

模块边界的目的：播放与会话逻辑可以单测、可以换引擎，以后若要做安卓手机界面，`core/*` 原样共用。

### 3.2 约定

- 一切请求都过 `core/network`，页面里不拼 URL；播放链路（会话、进度、心跳）走独立连接池，不排在页面请求后面。
- 新字段可空 + 默认值；枚举类响应字段（如 `segments[].type`）解码时未知值降级为「其他」，不让整包失败。
- 焦点：每一页进来都要有确定的初始焦点；卡片焦点放大统一走一个组件；不用 `rAF` 式的时序假设（Compose 里用 `FocusRequester` + 首帧回调）。
- 电视上没有浏览器：外链、预告片网页入口一律不做。

## 4. 播放内核

### 4.1 分层

```
feature/player     控制层界面（遥控器交互、信息面板、跳过片头 / 下一集卡、拖动预览）
core/playback
  PlaybackController   会话协议、兜底阶梯、看门狗、选轨记忆、下一集、进度上报
  CapabilityProbe      起播前查本机能力：解码器、HDR / 杜比视界、HDMI 透传格式
  Engine（= Media3 Player 接口）
    ├─ ExoEngine       主引擎：原文件直连（Range + 签名 token）或服务端 HLS
    └─ （后期可选）MpvEngine  LGPL 构建的 libmpv，适配同一个 Player 接口，上层不改
```

### 4.2 起播判定

1. 起播前 `CapabilityProbe` 产出能力快照，随 `POST /playback/sessions` 上送（`ClientCapabilityIn`）：
   - 视频：`MediaCodecList` 里**硬件**解码器支持的编码与最大高度（h264 / hevc / av1 / vp9 / mpeg2 / vc1 按机器实际）；
   - HDR：显示设备的 HDR 能力（HDR10 / HDR10+ / HLG / 杜比视界）+ 是否有杜比视界解码器；
   - 音频：本机解码器 + HDMI 透传能力（AC3 / EAC3 / EAC3-JOC / DTS / DTS-HD / TrueHD），有 FFmpeg 扩展时再加软解能覆盖的编码；
   - 容器：Exo 能直接解封装的（mp4 / mkv / webm / ts）；原盘镜像 / 目录不申报（交给服务端）。
2. 服务端给原文件 → Exo 直连 `/playback/files/{id}/stream?token=…`（Range），内封音轨 / 字幕由 Exo 在本机切换；
   给 HLS → 播 `stream_url`，持会话期间每 15 秒心跳。
3. Exo 起播失败（解码器报错、首帧超时）→ 带 `failed_tiers` 重开会话，逐级降档；每次回落带原因上报（`/playback/client-log`）。

**服务端判定的配合（2026-10-08 用户定，已实现）**：原来的判定按浏览器写，不申报 `universal` 时只有 mp4 / mov 能直连，
mkv / ts / webm 一律重封装成 HLS（`containers` 字段服务端从没读过），选了非默认音轨也会被顶成重封装。现改为：
- 文件容器在客户端申报的 `containers` 里也算可直连（`decide._resolve_tier`）；编码、HDR、分辨率仍由服务端核对；
- 新增能力字段 `local_tracks`：播放器能在本机切内封音轨，直连时不因「放的不是默认轨」重封装，计划里的
  `audio.track_ref` 就是要它在本机选中的那条。
现有客户端只申报 mp4 / hls-fmp4、不带 `local_tracks`，行为不变（`tests/playback/test_decide.py` 锁住）。
老服务端会忽略 `local_tracks`、照旧重封装——能播，只是多走一路 HLS。

### 4.3 补短板

| 短板 | 方案 | 许可 |
|---|---|---|
| 电视 / 功放解不了 TrueHD、DTS 等 | **自编** Media3 `decoder_ffmpeg` 扩展（只启用音频解码器：truehd / mlp / dca / ac3 / eac3 / flac / alac 等），透传优先、透传不了才软解 | Media3 胶水代码 Apache 2.0；FFmpeg 按 **LGPL-2.1** 编（不开 `--enable-gpl` / `--enable-nonfree` / `--enable-version3`），编成**独立 `.so` 动态链接** |
| ASS 特效字幕 | libass（`io.github.peerless2012:ass-media`，MIT；libass 本身 ISC） | 宽松许可 |
| PGS / SRT / VTT | Exo 自带 | — |
| 原盘 ISO / BDMV、冷门编码 | 服务端 HLS（一期）；后期视需要挂 LGPL 构建的 libmpv 备用引擎 | libmpv 须 `-Dgpl=false` |

**不用 Jellyfin 发布的 `org.jellyfin.media3:media3-ffmpeg-decoder`**：它声明的许可是 GPL-3.0，链进 App 进程会让整个 APK
落入 GPL，与 MovieClaw 许可的非商用附加条件冲突。（Mac 转码器 / Docker 用的 jellyfin-ffmpeg 是独立进程调用的命令行程序，
不受影响。）

FFmpeg 产物：`native/ffmpeg/build.sh` 固定 FFmpeg 版本与 sha256、用 NDK 交叉编译两种架构，产物发到本仓库一个专门的
Release（同 NER 模型 `torrent-ner-v1` 的做法），构建时下载 + 校验；「关于」页附 FFmpeg 许可全文、源码地址与编译脚本位置。
**风险**：ass-media 0.5.x 是对着 Media3 1.8 编的，Media3 版本要与它、与自编扩展三方对齐，升级 Media3 时一起验。

### 4.4 电视上才有的事

- **帧率匹配**：24p 片源让电视切 24Hz。Android 11+ 用 Media3 的帧率策略（`Surface.setFrameRate`），遵从系统「匹配内容帧率」开关；
  更老的系统按需切 `preferredDisplayModeId`。
- **HDR / 杜比视界**：按显示能力输出；杜比视界 Profile 7 双层原盘依赖少数芯片，无解码器时退到 HDR10 基础层。
- **音频透传**：读 HDMI 支持的格式，直通优先（全景声 EAC3-JOC / TrueHD-Atmos 原样给功放），不行再解码。
- **MediaSession**：接入系统（遥控器媒体键、Google 助理「暂停 / 快进」、系统「正在播放」）。
- **控制层**照 Android TV 系统播放器的手感：确认键 播放 / 暂停；左右 后退 / 前进 10 秒，按住连续拖动（带缩略图预览）；
  下键 信息面板（字幕、音轨、画质、版本、章节）；返回键 先收面板、再退出（进度照常上报）；片头 / 片尾出现「跳过片头」「下一集」并自动拿焦点。

## 5. 账号与登录

- 令牌：`AndroidKeyStore` 生成 AES-GCM 密钥加密后存 DataStore；账号列表（服务器地址、用户名、头像、设备 ID）同库。
- `installation_id` = `androidtv-<uuid>`，首次启动生成、随账号库保存。
- 401 回登录（登录 / 引导接口除外）；退出登录先调 `DELETE /auth/devices/current`，失败入队、下次联网补发。
- 权限按 `GET /auth/me` 的 `capabilities` 算（一期只影响「标记已看 / 收藏」之外的入口，基本用不到）。

## 6. 服务端与网页要改的（新增 `androidtv` 设备类型）

| 位置 | 改动 |
|---|---|
| `services/login_devices.py` | `KINDS` 加 `androidtv`（`Android TV App`，interactive，family login）；进 `APP_KINDS`、`PAIRING_KINDS` |
| `schemas/auth.py` | `DeviceClientInfo.kind` 的 Literal 加 `androidtv`，`client_type` 描述同步 |
| `services/playback/watch.py` | User-Agent 正则与 `_APP_CLIENTS` 认 `MovieClaw-AndroidTV/`（否则活动页记成「MovieClaw Web」） |
| `api/routes/playback.py` | `NATIVE_APP_CLIENTS` 加 `androidtv` |
| `apps/web/lib/devices-display.ts` 等 | 类型名「Android TV」、电视图标、批准页「将获得」文案同 `tvos` |
| iOS「设置 → 设备」 | 类型名与「将获得」文案同上 |

**兼容**：老服务端收到 `kind: androidtv` 会 422。TV 端登录前已有最低服务器版本检查，把最低版本定为带上这批改动的服务器版本，
并在界面上说清「请先升级服务器到 x.y」，而不是报登录失败。

## 7. 分期与验收

| 阶段 | 内容 | 验收 |
|---|---|---|
| **A0 骨架** | 工程、CI 编译与单测；账号密码登录（调试参数可直达）；能力探测；最简播放页直连原文件 + HLS 兜底 + 进度上报；服务端 `androidtv` 改动 | 模拟器上对隔离测试服务器（/tmp 新库 + 生成的测试片）登录并播完：H.264 MP4、HEVC + AC3 5.1 + 双字幕 MKV、MPEG-2 TS、VP9 WebM；活动页显示「Android TV」 |
| **A1 能看** | 局域网发现、扫码登录、谁在看、导航抽屉、首页、海报墙、详情、搜索、完整播放控制层（拖动预览、信息面板、跳过片头、下一集）、关于 | 只用方向键 / 确认 / 返回，走完「开机 → 选人 → 选片 → 播放 → 下一集 → 返回」；每页焦点能走到所有元素；遥控器按键驱动的端到端用例全过 |
| **A2 好看好听** | 自编 LGPL FFmpeg 音频扩展、libass、帧率匹配、HDR / 杜比视界 / 透传在索尼电视上验 | 索尼真机：HDR10 / 杜比视界给原文件不降级；24p 切 24Hz；接功放全景声 / TrueHD 不降混；ASS 特效字幕正确 |
| **A3 之后** | Google TV「继续观看」（系统首页的 Watch Next）、大图预告、可选 libmpv 备用引擎、发版接入 | 另定 |

端到端验证方式：模拟器 `Android_TV_API_34` + 遥控器按键（`adb shell input keyevent DPAD_*`，或 UI Automator 用例）+ 截图；
后端用 /tmp 下全新数据库的隔离测试服务器（不碰本机 data 库）。真机项（HDR、透传、帧率）在索尼电视上验。

## 8. 风险与待验证

- **厂商 ROM 的解码器怪癖**：部分盒子硬解器自报能力与实际不符（报支持 4K HEVC 却花屏）。能力探测要有「实测失败即拉黑该解码器 + 降档」的回路。
- **32 位系统内存**：armeabi-v7a 盒子内存常只有 2GB，首页十几行海报要控制图片解码尺寸与并发。
- **Media3 / ass-media / 自编 FFmpeg 扩展的版本对齐**（§4.3）。
- **Compose for TV 在老系统（Android 6～8）上的性能**：在模拟器的低版本镜像上至少跑一遍首页滚动。

## 9. 已定（2026-10-08 用户确认）

1. **目录与包名**：`apps/android-tv/`、`io.movieclaw.androidtv`。
2. **设备类型**：新增 `androidtv`（§6）。
3. **导航**：照 Apple TV 的左侧可收起抽屉（§2），只有账号 / 搜索 / 首页三项。
4. **接口层**：仿 Apple 端 `gen_api.py` 的思路，在进程内读 FastAPI 路由与 Pydantic 模型，生成 Kotlin 模型 + 接口，
   只生成 TV 用到的那部分（白名单）；生成脚本放 `apps/android-tv/scripts/`，CI 校验生成物与后端一致。

## 10. 实现记录

### 10.1 A0 骨架（2026-10-08，分支 `feat/androidtv-app`）

| 落点 | 内容 |
|---|---|
| `apps/android-tv/core/model` | 生成的接口模型（`generated/Models.kt`，88 个）+ `McJson` 宽容配置 |
| `apps/android-tv/core/network` | OkHttp 传输、信封拆包、错误、User-Agent、地址解析、图片宽度阶梯；生成的 `McApi`（36 个接口）；协议契约单测（MockWebServer） |
| `apps/android-tv/core/session` | 账号库（KeyStore 加密令牌，坏 KeyStore 退回私有目录明文）、服务器探测与最低版本、账号密码登录 |
| `apps/android-tv/core/playback` | 能力探测（Exo 的解码器清单 + HDMI 透传 + 显示 HDR）、`PlaybackController`（开会话、直连 / HLS、本机选音轨、进度 10 秒 / 心跳 15 秒、失败带 `failed_tiers` 降档） |
| `apps/android-tv/app` | 登录页、A0 首页（接下来继续 + 各库最近条目）、播放页（确认 播放暂停、左右 ∓10 秒、返回 退出）；调试直达参数 `mc_server / mc_user / mc_pass / mc_play` |
| `apps/android-tv/scripts/gen_api.py` | 接口生成器（白名单），`--check` 进 CI |
| `apps/android-tv/tests/fixture/fixture.py` | 隔离测试服务器 + 生成测试片 |
| `.github/workflows/android-tv.yml` | 生成物校验、单测、lint、debug / release 包；`android-tv-ok` 汇总 |

工程取舍：Navigation3 要求 minSdk 24，与 §1 的 23 冲突，导航栈自己管（一个栈 + 返回键 + `SaveableStateHolder`）。

**服务端顺带修的两处**（都是 Exo 首次接入暴露的）：
1. 直连判定认客户端申报的容器、新增 `local_tracks`（§4.2）。
2. VOD 模式（`-copyts`）转码音频时，编码器预填充让 fMP4 第一片音轨的 `tfdt` 为负（AAC −1024、E-AC-3 −256）。
   Safari / hls.js 把它当有符号数宽容读，ExoPlayer 按规范读无符号数直接报「Top bit not zero」，凡是要服务端转码音频的片子
   都起不了播。现把转码音频整体后移一个预填充（`asetpts`），视频时间戳不动（`ffmpeg_args._audio_args`）。

**验收（模拟器 Android TV 14，对隔离测试服务器）**：遥控器按键 / 调试参数驱动，全部真实起播并截图核对：
- H.264 MP4、VP9 WebM、续播用的 6 分钟 H.264：档 0 原文件直连；
- HEVC + AC3 5.1 + 双字幕 MKV、MPEG-2 + AC3 TS：模拟器没有 AC3 解码器也不能透传，服务端判档 2（音频转码），
  服务端 HLS 播放正常（修 `tfdt` 前在 Exo 上必挂，降档链路一路降到「需要软件转码」的提示，也验证了降档回路）；
- 暂停信息层、快进、返回退出上报 stop；续播点 70.3 秒落库，再进入从 70.3 秒接着播；
- 活动页记录为「MovieClaw Android TV · Android TV · Android 14」。

**未验证**：本机切内封音轨（`local_tracks` 直连时选非默认轨）在模拟器上没有触发条件（AC3 不能解），留到真机；
release 混淆包只验证了能编出来，没装机跑。NAS（0.32.0）还不认 `androidtv`，部署本分支前连不上。

### 10.2 A1 能看 + 与 Apple TV 对齐走查（2026-10-08）

两台模拟器并排走查：Apple TV 模拟器（tvOS 27，本地 XCUITest 遥控代理）与 Android TV 模拟器（API 34，`adb input keyevent`），
连同一台隔离测试服务器，同一串按键各按一遍、逐步截图拼成对照图核对。覆盖：冷启动首页、大图预告与卡片行让位、
各行上下移动、详情（首屏 / 季与分集 / 演职员 / 影人页）、海报墙与排序菜单、搜索、谁在看 / 关于 / 开源许可、
欢迎页 → 选服务器 → 扫码登录 → 账号密码登录、播放（控制层、暂停、∓10 秒、信息面板、切音轨、跳过片头、下一集倒计时连播、
HEVC + AC3 MKV）。

走查改掉的交互差异：

| 现象 | 根因与改法 |
|---|---|
| 详情页按一次返回不退 | 焦点组在 Compose 里先吃掉返回键（焦点退出）：根节点把返回键直接交给返回分发器 |
| 退回上一页焦点丢失 / 落到第一颗 | 二级页压栈时把下面的页拆了；Compose 的 `focusRestorer` 只记直接子级，隔着滚动容器记不住。改成整个导航栈常驻（只摆栈顶，下面的页不参与方向键找焦点），可聚焦控件登记到每页的 `LayerFocusMemory`，退回时还给离开时那颗 |
| 关面板 / 回首页后大图预告不恢复，或两页抢同一个播放器 | 预告只有一个全局可见开关。照 `TVStagePreview` 按页认领画面层（被盖住的页算消失），只有最后认领的那层挂画面；页面先要片段再认领 |
| 海报行上下切进来落在第二张 | Compose 按中心点挑最近的。照 `TVShowcaseShelf`：从上下切进来只落在上次停的那张（没停过第一张，停过「查看全部」就落它） |
| 排序菜单 | 照 tvOS 27 量的尺寸（450 宽、一项 66 高），打开时焦点在第一项，选完焦点回排序按钮，排序按库记在本机 |
| 搜索页只有一个输入框 | 换成 tvOS 系统搜索页那套：一排屏幕键盘（字母 / 数字 / 符号三档、空格、删除长按清空）、联想词条（第一个搜当前输入，聚焦即预览）、分隔线、结果；「换输入法」键或遥控器播放键唤起系统输入法（汉字、语音），接实体键盘可直接打字。功能键与字键焦点区同高，上下落点与 tvOS 一致 |
| 谁在看位置、从「关于」返回焦点 | 按 tvOS 安全区居中；头像、按钮登记焦点记忆 |
| 默认按钮、输入框 | tvOS 默认按钮固定 68 高、body 29 号字；输入框胶囊形，平时比卡片暗、聚焦浅灰；玻璃卡更淡 |
| 配对页多一个「更换服务器」 | 去掉，同 Apple 用返回键回选服务器 |
| 信息面板偏上偏左 | 加 tvOS 系统安全区（上 60、左右 80） |

**两端仍不同、按平台惯例保留的**：
- 登录页的地址、账号、密码输入：tvOS 弹全屏系统键盘，Android 弹系统输入法（都是按确认进入输入、平台原生）；
- 搜索键盘没有拼音候选行（tvOS 的中文拼音输入法自带）：拼音首字母本来就能搜中文片名，打汉字走系统输入法；
- 字体：Noto CJK 比 PingFang 宽、行框高，长简介可能多折一行、各行有十来点的上下差（大处已按 SF 行高补齐）；
- 玻璃材质：电视上不做背后实时模糊，用半透明近似；
- 局域网发现：Android 模拟器在 NAT 后面收不到宿主机的 mDNS（真机局域网可用）。

**走查里发现、未在本分支修的服务端问题**：服务端直接跑在 macOS 上（`hw=videotoolbox` 本地执行）时，
不能硬解的片源（如 MPEG-2）仍按硬解装命令，ffmpeg 滤镜阶段报 `-78 Function not implemented`，档 3 转码起不来。
远程 Mac 转码器那条路径按 `hw_decoders` 改走软解没有这个问题；Docker / NAS 不走这条。模拟器上 MPEG-2 软解掉帧 84%，
被掉帧看门狗降到档 3 才撞上（真机有硬解不会降）。

**验证**：单测（network / session / playback / app）与 lint 全过；上面每一组走查在两台模拟器上逐步截图对照通过。
**未验证**：转码同意对话框（夹具服务器开着软件转码，触发不了）；索尼真机。

### 10.3 NAS 真实片源回归（2026-10-08，dev overlay `0.33.1-dev.20261008.132218`）

> 2026-10-08 补记：这一轮模拟器开的是 `-gpu swiftshader_indirect`（画面全靠宿主机 CPU 软件渲染，qemu 占 900% CPU），
> 播放只有约 0.7 倍速。下表里「1080p 软解掉帧升到档 3」「MPEG-2 软解掉帧 84%」一类结论有一部分是它造成的；之后的实测
> 改用 `-gpu host`（见 §10.5）。

两台模拟器都连用户 NAS（yee），按「容器 × 视频编码 × HDR × 音频 × 字幕 × 原盘」从 1.6 万个文件里挑 28 部代表片源，
深链起播、等 25～45 秒截图，对照 NAS 会话日志里的档位与失败原因。**模拟器没有硬解、显示不支持 HDR，也没有 AC3 / E-AC-3 / DTS
解码器**，所以 Android 侧大量走服务端流——这一轮验证的是降档链路与服务端配合，原文件直放能力要在索尼真机上验。

| 片源 | Android TV（模拟器） | Apple TV（模拟器） |
|---|---|---|
| H.264 MP4 AAC / H.264 MKV FLAC + ASS / VP9 4K MKV | 档 0 直放 | 直放 |
| H.264 + E-AC-3 / DTS / PCM 24bit（含 PGS） | 档 2（服务端只转音频）；1080p 软解掉帧的升到档 3 | 直放 |
| HEVC 10bit 4K60、HEVC 1080p50 + MP2 | 模拟器解码失败 → 降档到档 3 / 4 | 直放 |
| HDR10 / HLG / 杜比视界（MKV、MP4、TS，含 TrueHD + PGS） | 档 3：远程 Mac 转码器色调映射成 SDR，画面、中文字幕、33 条字幕 / 10 条音轨的面板、快进都正常 | 直放 |
| 蓝光原盘目录（H.264 / VC-1 / MPEG-2 / UHD HDR10） | 档 2～3 | 龙猫（H.264 原盘）卡在「正在缓冲 0 KB/s」，其余直放 |
| VC-1 MKV、AVI MPEG-4、TS 1080i + DVB 字幕、TS MP2、MP4 VobSub | 档 3 | 直放 |
| 蓝光 ISO、DVD ISO | 修复前**放不了**：服务端读不了 ISO 盘内结构、无法换封装或转码（DVD ISO 还要先白等 60 秒关键帧采样才报错）；修复后见 §10.4 | 蓝光 ISO 45 秒仍在缓冲；DVD ISO 直放 |

走查里修掉的客户端问题：开会话请求读超时被报成「连不上服务器、请检查地址」——改为「服务器响应太慢」，开会话单独放宽到 150 秒（§4）。

服务端问题（均已在本分支修，见 §10.4）：
1. ISO 片源对不能直读 ISO 的客户端整体不可用；DVD ISO 先做 60 秒关键帧采样再拒绝，提示文案还写着 BDMV。
2. 远程转码节点名额被占满时，HDR / 杜比视界片源报「未检测到可用的硬件加速设备」，实际是忙而不是没有。
3. 客户端被强杀（没发 DELETE）时转码会话要等 180 秒心跳超时才回收，期间新的播放会被「转码会话已满」挡住。

### 10.4 ISO 服务端播放修复（2026-10-08，dev overlay `0.33.1-dev.20261008.154632`）

- **为什么放不了**：服务端从来不读镜像的盘内结构，ISO 只原字节交给自己能读镜像的播放器（App 引擎、Infuse）；
  Android TV 要服务端换封装 / 转码，决策直接拒绝。
- **为什么慢**：拒绝之前先对整个镜像做关键帧采样（NFS 上 60 秒），客户端 60 秒读超时，报成「连不上服务器」。
- **修法**（disc-playback.md §7）：UDF 读出正片在镜像上的字节区间，装成与原盘目录同一种播放源；ffmpeg 经
  `subfile`（多截再套 `concat`）协议读，远程 Worker 按区间取字节；原盘不做整文件关键帧采样；台账里 ffprobe
  对镜像估错的片长按盘内结构校准（启动自愈，NAS 上改正 62 / 78 个）。
- **NAS 实测**（Android 模拟器，起播时服务端会话就绪 50～470 毫秒）：

| 片源 | 镜像里正片的形态 | 结果 |
|---|---|---|
| 鬼子来了（蓝光 ISO，H.264 + DTS） | 一整截 | 档 2，从 5000 秒起播正常 |
| 千与千寻（蓝光 ISO） | 交错存放，1683 截 | 档 3（远程 Mac），总长 2:04:32，从 1 小时起播画面正确 |
| 林肯（蓝光 ISO） | 双层盘换层处断成 2 截 | 档 3，从 5000 秒起播落在 1:23:53，总长与盘内一致 |
| 金枝玉叶（DVD ISO） | 正片节目链 16 个单元，时间戳连续 | 档 3，从 4000 秒起播正常 |
| 公司的力量 S01E01（DVD ISO，一盘两集） | 两个 VOB 各自从 0 起时间戳 | 修前从续播点起播「转一片就到末尾」→ 按 VOB 分段后从 50 分钟起播落在第二集 |

  NAS 上 78 个 ISO 只剩 1 个读不出（不是 UDF 镜像）。另修客户端起播日志 `first_frame_ms` 报成开机以来的毫秒数。
  转码器忙的提示与强杀后旧会话释放由单测覆盖，NAS 日志里也看到了同设备换片时旧会话当场让出名额。

### 10.5 播放器故障注入与体验实测（2026-10-08，模拟器 + 用户 NAS）

借鉴 Apple 端的故障注入（`apps/apple/scripts/faultlab.py`、player-engine.md §3.7）与网页实验台（web-player.md §14.5），
给 Android TV 搭了一套：`scripts/perf/androidtv_faultlab/`。复用网页实验台的代理（限速、拒连、挂起、回错误码，可只对取流；
新增抓开会话请求、按正则选范围），模拟器里的调试包把服务器地址填成代理；判定读调试包每秒打的 logcat 行（`PlaybackProbe`：
阶段、文件时间播放头、缓冲、提示、错误页、换画质卡片）和服务端存下的播放记录（与真实使用同一口径）。
调试包的实验台入口：`mc_lab`（记录打实验室标签）、`mc_seek_ms`（跳到某个文件时间）、`mc_audio` / `mc_subtitle`（换轨）。

**环境坑**：模拟器要 `-gpu host`。`swiftshader_indirect` 下宿主机满载、播放 0.7 倍速，所有计时都失真（§10.3 补记）。

**实测发现并修掉的问题**：

| 现象 | 根因与改法 |
|---|---|
| 断网 / 服务端 503 时 App 直接闪退（看着片也会） | 首页每 60 秒刷新，`HomeStore.load` 的 try 包在 `coroutineScope` 里面：async 子任务失败会取消作用域、在返回处再抛一次，冒到 `LaunchedEffect` 崩溃。try 挪到作用域外（`HomeStoreTest` 锁住） |
| 看片时首页仍每分钟重取各行与背景图 | 定时刷新只在首页真被看着时跑（播放器盖着、压着二级页时停） |
| 线路只有码率一半（5 Mbps 放 9 Mbps），90 秒卡 19 次，从不提示换画质 | 服务端流里 Exo 只认得音轨码率（640 kbps），拿它当整路流的码率，线路「够用」。认不出视频码率时改用片源总码率（`QualitySuggestion.streamBitrate`）；修后第 19 秒弹卡 |
| 杜比视界换 PGS 字幕（要服务端烧录）直接落错误页「转码器正忙」 | 服务端：这位成员自己的旧会话占着唯一的色调映射名额，决策先判了拒绝，而「先让出同文件旧会话再决策」只在成功路径上做。拒绝路径也先让出来（`test_reopening_a_tone_mapped_title_frees_its_own_worker_slot_first`） |
| 档 2（视频原样、只转音轨）上报成整片转码，统计里全成「可避免的规格损失」 | 通路改用网页口径：`direct` / `server_remux` / `server_transcode` / `server_transcode_required`（`PlaybackRoute`） |
| 起播后 1.5 秒内的正常预滚被算成卡顿 | 卡顿采样的第一个点只记基准，不清起步宽限 |
| 「打开『⋯ → 播放诊断』」提示指向一个 Android 上没有的面板 | 改为「把出错时间告诉管理员，服务器上留有诊断记录」 |

**最终一轮**（片源：直放《十三邀》MP4、服务端流《边缘世界》9 Mbps MKV、《风味人间》VP9 4K 14 Mbps；
全部从 600 秒起播；22 场 20 过）：

| 场景 | 结果 |
|---|---|
| 断线 20 秒、挂起 40 / 70 秒、服务端 503 一分半（直放 / 服务端流） | 原地恢复、不降档 |
| 一直拒连 | 约 1 分钟后落「连接中断」，不降档 |
| 直放片源 404 | 放完缓冲后（第 67 秒）报「服务器上找不到这个文件」，不降档 |
| 服务端重启（停 20 秒 + 旧会话 404） | 原地重开，不误跳下一集 |
| 暂停 225 秒（超过服务端 180 秒回收）再继续 | 原地重开接着放 |
| 线路 7 / 5 Mbps | 不降档；第 19 秒弹换画质卡 |
| 断流 90 秒 | 播放头停在缓冲末尾、判卡顿、15 秒无字节后重连，不空跑 |
| 跳转（+10 / +600 / −10 / 回 300 / 连按两下） | 直放 MP4、服务端换封装 MKV、蓝光 ISO：全部 ≤ 1.3 秒，缓冲内多在 0.1～0.3 秒 |
| 跳转：DVD ISO（远程 Mac 转码） | +600 用了 9.2 秒——当时远程转码器断开、落到 NAS 软件转码（上一轮 1.1 秒）；记为环境问题 |
| 跳转：杜比视界（远程 Mac 色调映射） | 缓冲外 0.8～2.5 秒：服务端重开转码的成本 |
| 换轨（远程转码的杜比视界、黑客帝国原盘） | 音轨 2.1～3.1 秒、烧录 PGS 5.5～6.5 秒、关字幕 1～1.8 秒：都是服务端重开转码；直放时原地换 |

**真机采样（给种子用户）**：每次播放离开时上报一条完整记录（playback-qoe.md §3.8），服务端按 `client=androidtv` 分组。
排查时：`mclaw playback stats qoe --days 7 --group-by client`（样本不足 30 条直接列每一次，含编号、结局、首帧、最长跳转、
中断数），再 `mclaw playback attempt get <编号>` 看完整明细——设备快照（机型、芯片、显示模式与 HDR 类型、HDMI 能透传的编码、
解码器清单）、规格快照（实际解码器、硬 / 软解、解出来的格式、HDR 是否保住、音频透传还是解码、输出设备、当前显示模式）、
每次跳转 / 换轨 / 卡顿 / 重连、时间线，出过问题的附播放器日志尾巴，闪退的下次补报并带崩溃栈。
帧率匹配、HDR 输出、透传这些模拟器验不了的，从 `delivery.output.display_mode`、`video.output_format`、`audio.delivery` 直接看。

### 10.6 A2：选型目标补齐（2026-10-08）

对照 §4 的选型目标逐条核对后补做的（libmpv 备用引擎与 AV1 专项照计划不做：冷门格式服务端能转、片库没有 AV1）：

| 项 | 做法 | 验证 |
|---|---|---|
| 杜比视界按 profile | 服务端：台账新增 `dv_profile` / `dv_bl_compatible`（迁移 + 启动后补探存量，NAS 526 个）；客户端申报 `dolby_vision_profiles`（杜比视界解码器支持且屏幕支持杜比视界）与 `dolby_vision_base_layer_profiles`（P4 / P8 → HEVC、P9 → AVC、P10 → AV1，要硬解）。能解的直通、能放基础层的直通、其余（主要是 P5，NAS 抽样占 68%）照旧色调映射 | 服务端判定单测 6 条、探测与补探单测；模拟器屏幕不支持杜比视界，仍走转码（回归通过）；**真机待验，NAS 待部署**（另有会话在用 NAS，部署要重启容器） |
| 自动帧率匹配 | 同分辨率、刷新率为片源整数倍（精确优先、倍数小优先、误差 ≤ 0.15%），遵从 Android 12+ 的「匹配内容帧率」设置；离开播放器交还系统 | 选模式单测；模拟器只有 60Hz 一档验不了，真机看采样里的 `display_mode` 与引擎日志「帧率匹配」行 |
| 能力只算硬解 | 只有软解码器的编码最多申报 1080p | 单测；模拟器上 4K HEVC 改走服务端（软解 4K 必卡） |
| 解码器拉黑 | 改走服务端的解码失败记下出错解码器（30 天 / 升级清空），选解码器与能力申报都绕开；设备快照列出 | 单测；模拟器实测：拉黑 goldfish H.264 硬解后播放记录显示改用 `c2.android.avc.decoder` |
| FFmpeg 音频软解 | `core/ffmpeg`：Media3 1.11.1 的 decoder_ffmpeg 胶水层 + `native/ffmpeg/build.sh` 编的 FFmpeg 6.0.1（LGPL-2.1 共享库，只开音频解码器）；扩展排在系统解码器之后（透传优先）；CI 先编它再出 release 包；「关于」页列出许可、源码与脚本 | 模拟器：E-AC-3、DTS 从档 2 变档 0，播放记录 `decoder=ffmpegLavc60.3.100-eac3 / -dca` |
| ASS 特效字幕 | ass-media 0.5.1（libass）叠加层渲染（OVERLAY_OPEN_GL，不进视频管线、不影响 HDR），渲染像素封顶 1080p | 《老友记》双语 ASS 的字号 / 颜色 / 描边正确，切 SRT、关字幕正常；ass-media 对着 Media3 1.8 编，升 Media3 时要复验 |
| 老系统 | Android 6.0 / 8.0 arm64 镜像（电视镜像只有 x86，Apple 芯片跑不了，用手机镜像验系统 API） | 发现并修掉内存溢出（堆上限 48 MB，Exo 默认缓冲约 130 MB）：申请大堆 + 缓冲按堆的 1/4（16～128 MB）；修后首页、详情、ASS、FFmpeg、杜比视界服务端流、35 Mbps 直放都正常 |

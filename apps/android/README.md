# MovieClaw for Android

MovieClaw 自托管媒体服务器的 Android 原生客户端(Kotlin + Jetpack Compose)。

界面与交互以 **apps/web 的移动端网页**为准(逐屏实测对齐),播放链路参照 apps/apple 的 iOS 客户端。

## 正式版本与下载

Android 版本由 `version.properties` 独立管理，不跟随服务器或 iPhone 的版本号。
服务器每次发版都会附带正式签名的 `MovieClaw-Android-arm64.apk`；Android 代码没变化时沿用旧包。
[最新版 APK](https://github.com/movieclaw/MovieClaw/releases/latest/download/MovieClaw-Android-arm64.apk)
在首个包含 Android 的正式 Release 发布后生效。当前支持 Android 8.0+、arm64-v8a 手机/平板。

正式打包使用 `bash apps/android/scripts/package-release.sh`（在仓库根目录执行），需要固定签名密钥，
并强制检查完整播放器依赖。版本规则、签名配置和发版作业见
[Android 发版说明](../../docs/design/android-release.md)。

## 本地构建

```
cd apps/android
echo "sdk.dir=<你的 Android SDK 路径>" > local.properties   # 或设 ANDROID_HOME
./gradlew :app:assembleDebug
```

- 需要 JDK 17、Android SDK(compileSdk 36 / minSdk 26)、NDK 28.2(构建 ISO 直读那部分 JNI)。
- **预编译原生库会在首次构建时自动下载**(约 38MB,来自 Releases 的 `android-native-libs`):
  构建脚本先校验 sha256 再解压到 `app/src/main/jniLibs/arm64-v8a/`,只下一次。
  地址与校验和在 `gradle.properties` 的 `nativeLibsUrl` / `nativeLibsSha256`,换版本改这两行;
  开发构建离线或下载失败**不会中断构建**,只是产出一个仅 Exo 内核的包；正式打包会拒绝这种降级。
  想显式跳过:`./gradlew :app:assembleDebug -PskipNativeLibsDownload=true`。
### 预编译依赖(FFmpeg / mpv / libass)

`app/src/main/jniLibs/arm64-v8a/` 下的 10 个 `.so` 是第三方二进制(入库前约 116MB、
strip 进 APK 后约 33MB),**不入库**,作为 [Release 附件](https://github.com/anlan-home/movieclaw-android-libs/releases/tag/android-native-libs) 提供:

| 文件 | 作用 |
| --- | --- |
| `libmp2.so` | mpv 内核(libmpv 接口),应用运行时 `dlopen` 它 |
| `libavcodec` `libavformat` `libavfilter` `libavutil` `libswscale` `libswresample` `libavdevice` | FFmpeg 共享库,`libmp2.so` 的 `NEEDED` 依赖 |
| `libc++_shared.so` | C++ 运行库(mpv / FFmpeg 需要;本项目的 JNI 库不依赖它) |
| `libass.so` | 字幕渲染;仅供已废弃的 `cpp/libass_bridge.cpp`,可不带 |

**少任何一个 `libmp2.so` 的 NEEDED 都会让 dlopen 失败**——动态链接器解析依赖时不看
上游是否真的用到它,所以不能按需裁剪。

缺这些库时**照样能编出可安装、可运行的 APK**(CMake 不链接它们,`libmp2.so` 是运行时
dlopen;缺库时 `MpvNative.available` 为 false,应用干净地只用 Exo 内核),区别只在
播放能力:ISO / BDMV 原盘直读、VC-1/MPEG-2/TrueHD/PGS 软解、HDR 与 ASS 特效字幕
的 MPV 路径不可用。构建脚本会在首次构建时自动拉这个附件,拉不到就退回 Exo 内核包。

二进制再分发注意许可:mpv GPL-2.0+、FFmpeg LGPL-2.1+ 或 GPL-2.0+(视构建开关)、
libass ISC、libc++ Apache-2.0 with LLVM exception;附件里的 `NOTICE.md` 有逐项来源。

附件地址写在 `gradle.properties` 的 `nativeLibsUrl`(换地址时 `nativeLibsSha256` 要同步换)。
想从别处取(镜像 / fork / 本地文件),按这个优先级覆盖,不必改仓库里的文件:

1. 命令行:`./gradlew :app:assembleRelease -PnativeLibsUrl=<url> -PnativeLibsSha256=<sha256>`
2. `local.properties`(机器本地、不入库)加 `nativeLibsUrl=` / `nativeLibsSha256=`
3. 仓库 `gradle.properties` 里的默认值

## 代码结构

```
app/src/main/java/io/movieclaw/android/
  core/designsystem/   主题令牌、McTopBar / McCapsuleTabBar、卡片与格式化器
  core/network/        GeneralChannel / LiveChannel / PlaybackChannel 三通道 + 信封解包
  core/playback/       双内核(Exo / MPV)、ISO 直读桥、字幕解析、轨道与进度上报
  core/model/          服务端契约的数据模型(全局 SnakeCase 映射)
  feature/<板块>/      登录 / 发现 / 媒体库 / 订阅 / 活动 / 搜索 / 设置 / Agent / 播放器 …
  routing/AppNav.kt    全部路由
app/src/main/cpp/      mpv_bridge(libmpv dlopen)、iso_native(UDF over HTTP Range)、libass_bridge
```

## 当前进度:M1b(双内核播放)完成 —— Exo + MPV 全链路可用

已完成:

- Gradle 工程(Kotlin 2.2 + Compose BOM + Hilt/KSP,版本集中在 `gradle/libs.versions.toml`)
- 三通道网络层(`GeneralChannel` / `LiveChannel` / `PlaybackChannel`,对齐 iOS 三 URLSession 设计)
- `/api/v1` 统一信封解包、`ApiException`、`friendlyMessage` 中文错误映射、UA 标识(`MovieClaw-Android/0.1.0`)
- 登录全流程:探测 `/health` → bootstrap 检查(未初始化自动进入「创建管理员」)→ `POST /auth/device/login`
- 凭证存储:Android Keystore AES-256-GCM 加密 + DataStore(`mc_vault`),多服务器多账号快照(`mc_servers`)
- 冷启动快开:缓存 session 快照直出 READY,后台 `GET /auth/me` revalidate,401 回落登录页
- 局域网自动发现:Jellyfin 兼容 UDP 7359 + /24 单播扫描 + `/api/v1/health` 验证
- silver glass 主题 tokens 与基础组件(PosterCard / LandscapeCard / GlassCard / Loadable)
- 登录页(星空背景 + 自动发现)、五 Tab 主壳、发现页(继续观看/资料库真实数据)、媒体库网格、我的页
- **播放链路(双内核)**:`POST /playback/sessions` 协商 → ExoPlayer 直连/HLS 或 MPV 全量直连 →
  start + 10s progress 上报(互斥串行)→ 15s 会话心跳(404 原位重开)→ 退出 stop + 关会话;
  capability 按设备 MediaCodec 实测上报;consent(软件转码)走 `PUT /playback/policy` 后原请求重发
- **MPV 万能内核(M1b)**:libmp2.so(libmpv 构建,已在真机验证过)+ JNI 桥
  (`cpp/mpv_bridge.cpp`,dlopen 方案)+ CMake 原生构建。它是**共享 FFmpeg 的构建**:
  `readelf -d libmp2.so` 的 NEEDED 里列着 libavcodec / libavformat / libavfilter /
  libavutil / libswscale / libswresample / libavdevice / libc++_shared——这几个必须
  和它一起放进 `jniLibs/arm64-v8a/`,少一个 dlopen 就失败(动态链接器解析 NEEDED 时不
  看是否真的用到);
  VC-1/MPEG-2/TrueHD/PGS 本地全解,ASS 特效字幕内核直渲;Surface 生命周期契约
  (wid=全局引用 / android-surface-size / vo=null→detach)逐条照抄已验证的契约;
  内核选项配方(缓存落盘、stream-lavf-o 重连组、HDR tone-map、CVE 黑名单)全部内置
- **引擎策略**:默认 Exo(省电);直连解码失败自动降级 MPV(仅直连场景,HLS 不切);
  播放中手动切换只迁移 position/playing/speed;右上角 EXO/MPV 徽标可点
- **浏览链路**:库详情海报墙 → 条目详情(简介/分集列表/文件规格)→ 点播;Navigation Compose 路由
- `scripts/gen_kotlin_api.py`:OpenAPI → Kotlin 数据模型生成器(脚手架版)

- **轨道管线(M1c)**:音轨/字幕菜单(服务端 track refs 驱动,双引擎分别应用:
  Exo TrackSelectionOverride / MPV aid+sid);默认轨道从会话 watch 快照预填;
  用户选择立即上报 progress(track ref),服务端只记用户亲手选的轨;外挂字幕
  (SRT/ASS/VTT)在 Exo 侧经 SubtitleConfiguration 合流挂载
- **画中画(M1c)**:播放器工具栏手动进入(system bars 级);Manifest 已声明 supportsPictureInPicture
- **海报墙分页(M1c)**:60 条/页 offset 分页,滚动到底自动追加

- **后台播放(M1d)**:`PlaybackService : MediaSessionService` + `MediaSession` 承载锁屏/通知控制;
  播放会话提升为应用级单例 `PlaybackSessionHolder`,页面销毁不再中断播放;
  引擎切换用 `MediaSession.setPlayer` 热替换:Exo 直挂 ExoPlayer,MPV 挂
  `MpvPlayerProxy`(SimpleBasePlayer 官方用法,把非 Media3 引擎接入 MediaSession);
  划掉任务卡片时按 Media3 默认契约(播放中保活/未播放则停止);自动画中画(Home 键进入)
- **服务器地址修正(M1d)**:探活跟随重定向(http→https)并**采用最终地址**作为基址,
  支持反向代理强制跳转与子路径部署(`https://host/sub/` 也能落对 `/api/v1` 基址)

- **搜索与通知(M2a)**:SSE 客户端基础设施(`EventStream`:okhttp-sse + Last-Event-ID 续传 +
  指数退避重连 + 终止事件收尾);搜索页三模式——**资源(站点流式)**:`/search/torrents/stream`
  按站点边收边渲染(站点失败隔离、耗时/命中数、免费种子徽标),支持分类筛选;
  **标题**(`POST /search/titles`)、**库内**(`GET /search/library-items` 分组);
  搜索历史(点击重搜/清空)+ 一键下载提交(`POST /downloaders/submit`,auto_route 自动入库);
  通知中心(30s 轮询 + 乐观忽略 + 全部忽略)

- **订阅与活动(M2b)**:**订阅页**——自动化就绪度徽标(`/subscriptions/automation-readiness`)、
  近期入库/待播横滑卡(`/subscriptions/today-arrivals`)、追更列表(进度条 + 入库/待搜/下载中计数 +
  自动追更开关 + 取消订阅);**订阅流程**——搜索页「标题」模式点结果 → `POST /subscriptions/title-preview`
  预览(已订阅/库内已有/歧义提示)→ 选季(显示已播/库内集数)→ 创建;
  **订阅详情**——进度明细、订阅范围、追更开关、取消订阅;
  **活动中心**——后台任务用 `GET /jobs` 快照 + **SSE `/jobs/stream`** 实时增量(120ms 防抖,与 iOS 一致),
  任务卡片按状态提供取消/重试/忽略;下载任务 10s 轮询(进度/速度/ETA/站点);
  播放监控 8s 轮询(`/playback/activity`,可在 App 内结束任意会话)

- **发现页与标题详情(M2c)**:**发现页板块**由服务端编排驱动(`GET /ui/discovery/{movie|tv}`):
  电影/剧集切换、hero 形态大卡、横滑行(海报+年份+评分)、「全部」入口、
  各板块数据并行拉取(`/discover/collections/{ref}/titles`);
  **标题详情页**(`/discover/titles/{title_ref}`)——沉浸背景、海报、评分/时长、
  简介、类型、演职员圆形头像行、相关推荐(可继续下钻)、数据来源;
  **已入库识别**:`library_links` 非空时按钮变为「播放」(电影直接起播)/「查看剧集」
  (进媒体库条目页选集),否则为「订阅」;**合集浏览页**——网格 + 滚动分页加载

- **AI Agent 对话(M3)**:会话列表(`GET /sessions`)/ 新建会话(首条消息与建会话同一请求)/
  对话页——轨迹加载(`GET /sessions/{id}`,message/compaction/handoff 三型联合解析)+
  **SSE 流式渲染**(`/sessions/{id}/events` 的 11 种事件:`thinking_delta` 思维链折叠、
  `text_delta` 正文增量拼接、`tool_call_start/delta/result` 工具卡片(含输出与失败态)、
  `context_compacted` 系统条、`agent_done/error/cancelled` 收尾并重载轨迹);
  运行中可停止 / 结束后可重试 / 可压缩上下文;
  图片附件:系统选图器 → multipart 上传(`POST /sessions/attachments`)→ 随消息提交

## 视觉与交互对齐 iOS(2026-09-30)

对照 `apps/apple` 源码做了三批对齐(P0 视觉基座 / P1 播放器与反馈):

- **P0 视觉基座**:主题色改为 iOS 真值(accent `#CDD6E6` 冷银、新增 `accent2 #9FB0C9`、
  success/warning/info 全部更正)、卡片换成 iOS `cardStyle`(`#1E212B@74%` + 白色 8% 发丝描边)、
  iOS 字号阶梯(largeTitle 34 / title3 20 / headline 17 / subheadline 15 / footnote 13 / caption 12、11)、
  `McFormat` 格式化器(二进制字节、clock、时长、dayjs 阈值阶梯的 fromNow、dateTime、设备相对时间)、
  海报评分徽标 + 已入库/已订阅斜角缎带 + 黑色阴影 + 元信息行常驻(卡片高度不跳)、闪烁骨架屏、
  横滑行黄金数字(卡宽 126 / 间距 12)
- **P1 播放器**:手势层(单击立即生效 + 双击事后推断、双击左 1/3 快退 / 右 1/3 快进 10s 且恢复控制层状态、
  长按 0.5s 2× 变速并在缓冲跟不上时自动退出、左半屏亮度 / 右半屏音量且满行程 60% 屏高、
  上下 32px 边缘守卫、竖向调节仅在 12%~76% 高度带)、控制层 4s 隐藏与暂停/拖动/调节时常显、
  片尾 T−40s 连播卡(常驻不倒计时)、**画质菜单**(四档上限语义,引擎切换收进菜单)、
  **画质记忆**(片名 × 网络环境、300 条 LRU、起播回填并提示「已沿用上次的选择」)、
  **降质建议卡**(5 分钟窗口 ≥3 次卡顿或累计 45s + 实测带宽 < 所需 ×0.9、一片只提一次、
  20 秒无操作消失、绝不自动切换;实测带宽由 Exo 数据源 TransferListener 真实计量)
- **P1 反馈**:`FeedbackBus` + 顶部玻璃 Toast(最多 4 条、错误 6s / 其余 4s、点任意处关闭),
  替换全部 Material Snackbar;VM 提示升级为带语气的 `McNotice`(成功绿 / 失败红)

P2 已完成:图片灯箱(捏合 1–5× / 双击 2.5× / 渐进加载 / 缩略图条)、详情页剧照与海报墙、
媒体库筛选面板(类型/年代/地区/观看 + 找片:评分·片长·原始语言 + 查库:分辨率·动态范围·库存状态,
**勾选后 180ms 去抖按草稿重算计数**,取值原样回传服务端)、A–Z 索引条(拖动选档 + 气泡「N 部/无作品」+ 轻触感,
跳转按服务端 item-index 的 offset 重设窗口)、排序菜单(标题/时间/评分)

P2 已完成(续):**设置区** —— 索引页(按账号/播放与内容/服务器分组,管理员专属项自动隐藏)、
个人信息(昵称/头像上传/改密 + 「同时下线配对设备」)、设备管理(在线状态、最近使用相对时间、
改名、注销、管理员可切「显示所有成员设备」)、播放设置(软件转码/进度预览/转码缓存三个开关,
乐观更新 + 失败回滚 + 硬件能力实测展示)、网页托管分区(总览/订阅/站点/下载器/导入观看 → 说明 + 浏览器打开)

P2 已完成(续):**访客分享** —— 深链(`movieclaw://share/<slug>?origin=` 与 `https://<服务器>/s/<slug>`)、
密码门、条目/分集/合集三种分享形态、**访客播放**(端点抽象 `PlaybackEndpoint`:成员域与访客域共用
整套播放/上报逻辑)、访客态与登录态并行(未登录也能看);深链优先于会话状态处理

P2 已完成(续):**Agent Markdown 渲染** —— 自写轻量解析器(标题按级别缩放、有序/无序列表带缩进与序号栏、
围栏代码块带复制按钮并横向滚动、表格首行浅底、引用左侧 3dp 竖条、分隔线、行内粗体/斜体/行内码/删除线/链接),
按 iOS AgentMarkdown 的比例规格实现;思考块与用户气泡同样走 Markdown

- **M1 收尾**:QoE 上报(`POST /playback/metrics`)——每次尝试记录首帧耗时/seek 数/重缓冲次数与时长/
  观看时长,报告先落盘队列再尽力发送,`active.json` 心跳让崩溃与被杀的播放下次启动补一份 `abnormal_exit`;
  trickplay 拖动缩略图——会话建立时按 streamUrl 里的签名 token 拉雪碧图信息,
  拖动时按位置算格号并裁切渲染(160dp 预览),未就绪时只显示时间

- **M3 收尾(第一批)**:多账号切换 —— 按服务器分组、当前账号标记不可点、失效账号提示重新输密码、
  单账号从本机移除、「出口全部账号」带确认、添加账号走路由化登录页(登录成功自动返回);
  家庭成员管理 —— 成员列表(状态/最近登录/设备数/媒体库范围)、**启用停用**、
  三项权限开关(订阅追更/资源搜索/一键下载,乐观更新+失败回滚)、**重置密码(明文只显示一次)**、
  登出该成员全部设备、删除成员(带确认)、新建成员(登录名/初始密码/昵称)

- **M3 收尾(第二批)**:更新与维护(版本/覆盖层/已知问题版本/未激活原因、检查更新含兼容性与变更日志、
  一键更新 + 进度轮询到结束、存储用量与磁盘占用、**按目录清理缓存并回报释放空间**)、
  网络(代理三态/代理地址/图床与数据源基址、保存、**连通性测试含延迟**)、
  日志(按天列表含体积、内容查看、**ERROR/WARN 自动着色**)

P2 剩余:发现页沉浸 Hero(Ken Burns / 环境色采样)、家庭成员管理、更新与维护、网络、日志、
订阅日程、Reels。

M3 剩余待办:访客分享(深链 + 密码门 + 访客播放)、播放器手势(双击快进快退/上下滑音量亮度)
与自动连播、trickplay 进度缩略图、QoE 上报、多账号切换 UI、设置页各分区、人物页与筛选器。

## 构建

- Android Studio(最新稳定版)+ JDK 17+;compileSdk 36 / minSdk 26
- 打开本目录(`android/`)直接 Sync 运行;`./gradlew :app:assembleDebug` 命令行构建
- 局域网代理写在 `gradle.properties`(无代理请删除 systemProp 六行)

## 目录结构

```
app/src/main/java/io/movieclaw/android/
├── MovieClawApp.kt / MainActivity.kt
├── routing/          # 顶层状态机 BOOTING → NEEDS_LOGIN / READY
├── core/
│   ├── model/        # M0 手写模型(snake_case 全局映射,服务端加字段不炸)
│   ├── network/      # 三通道 OkHttp、信封、ApiFactory(按 origin 缓存 Retrofit)
│   ├── api/          # McApi(Retrofit 端点,M0 手写核心端点)
│   ├── session/      # TokenVault(Keystore)、SessionRepository(登录/多账号/冷启动)
│   ├── discovery/    # UDP 7359 局域网发现
│   └── designsystem/ # 主题 tokens + 组件库 + 带鉴权头的 Coil 加载器
└── feature/
    ├── onboarding/   # 登录页
    ├── root/         # 五 Tab 主壳
    ├── discover/ library/ more/   # M0 页面
    └── subscriptions/ activity/   # M2 接入(占位)
```

## 里程碑

- **M0**(本阶段):地基 + 登录 + 浏览最小闭环
- **M1**:媒体库条目/分集 + 播放器全链路(Exo + MPV 双内核)
- **M2**:发现板块 + 搜索(站点 SSE)+ 订阅 + 活动(jobs SSE)+ 通知
- **M3**:Reels + Agent + 访客分享 + 设置 18 节 + 多账号
- **M4**:性能打磨、QoE 完善、发布

## 服务端联调

App 与 `movieclaw/movieclaw` Docker 容器直连(默认 `http://<NAS_IP>:3000`);
真机与服务器需在同一局域网。过渡期也可用任意 Jellyfin 兼容客户端直连 MovieClaw 验证播放链路。

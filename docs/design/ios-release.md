# iOS App 打包与上架

> 2026-09-28 开发者账号开通后整理。首发路线：TestFlight 内部测试 → TestFlight 对外公开链接 → App Store。
> 首版只上 iPhone；只有一个发行版本，所有用户功能相同。资源站点 / 下载器 / 自动入库 / 订阅规则这类服务器配置在网页端管理（与 Android 版一致）。
> **要亲手做的事按顺序列在 [ios-release-checklist.md](ios-release-checklist.md)（含新机器搭环境）。**
> 相关：App 设计 [ios-app.md](ios-app.md)，Mac 转码器的签名公证见 `macos/MovieClawTranscoder/README.md`。

## 1. 只有一个发行版本

同一个构建既进内部 / 对外 TestFlight，也用于提审和上架；开发调试版与发布版功能相同（只差 `#if DEBUG` 的调试开关）。

App 里不提供「资源与下载」这组服务器配置（订阅规则、资源站点、下载器、自动入库，见
`SettingsSection.availableInApp`）和设置「概览」（站点 / 下载器链路体检）：它们是部署时一次性的
配置，表单大、要拖拽排序和多步联调，与 Android 版一样只在网页端管理。设置首页不列出；其他页面里
去这几项的跳转与深链落到「请在网页端管理」页，给出直达网页对应分区的按钮。资源搜索、订阅、
下载任务、刷流等日常功能 App 里都有。

所有用户拿到的是同一个构建、同样的功能：没有远程开关，不区分审核员与普通用户。**不要**用远程开关
让某些功能只在过审后出现——违反审核条款 2.3.1，处罚可到终止开发者账号。提审时如实介绍全部功能，
并给审核员一个能用全部功能的账号（§4）。

## 2. 一次性准备（需要账号持有人在网页上操作）

1. **确认团队 ID**：developer.apple.com → Membership 里的 Team ID，写进本机
   `apps/apple/XcodeConfig/Signing.local.xcconfig` 的 `DEVELOPMENT_TEAM`（不入库）。
   付费团队和之前的个人免费团队 ID 不同，别混用。
2. **Xcode 登录账号**（Xcode → 设置 → 账户）：真机调试要用。打包导出靠下一条的 API 密钥——
   Xcode 27 的 xcodebuild 读不到 Xcode 里登录的账号，不给密钥时导出报 `No Accounts`。
3. **App Store Connect API 密钥**：App Store Connect → 用户和访问 → 集成 → App Store Connect API，
   新建一个**「管理」**角色的团队密钥（「App 管理」用不了云端托管的发布证书，导出报
   `Cloud signing permission error`），下载 `.p8`（只能下载一次）。
   放到 `~/.appstoreconnect/private_keys/AuthKey_<密钥 ID>.p8`，记下密钥 ID 与 Issuer ID。
   同一把密钥也用于 Mac 转码器的公证。**不要提交进仓库、不要贴进聊天或日志。**
4. **建 App 记录**：App Store Connect → App → 新建 App
   - 平台 iOS，名称 MovieClaw（被占用就换，例如「MovieClaw 影音」），主要语言简体中文；
   - 套装 ID 选 `io.movieclaw.app`（没有就先在 developer.apple.com → Identifiers 注册，或让
     Xcode 自动签名首次导出时自动注册）；SKU 随意（如 `movieclaw-ios`）。
5. **App 信息**：
   - 隐私政策网址：`https://github.com/movieclaw/movieclaw/blob/main/docs/privacy-policy.md`；
   - 技术支持网址：`https://github.com/movieclaw/movieclaw/issues`；
   - 类别：娱乐（或摄影与录像）；价格：免费；
   - App 隐私问卷：**不收集任何数据**（数据都在用户自己的服务器上，见隐私政策）；
   - 年龄分级：内容来自用户自己的服务器，按问卷如实填写（「不受限制的网络访问」选是）。
6. **TestFlight 测试组**：内部测试组只能加团队成员（最多 100 人，免审）；朋友等外部测试员加进对外测试组
   （邮箱或公开链接，最多 1 万人），组里第一个构建要过一次 Beta 审核（见 §4）。iPhone 上装 TestFlight App。

## 3. 打包与上传

```bash
cd apps/apple
export MC_ASC_KEY_ID=… MC_ASC_ISSUER_ID=…   # 建议放本机 ~/.appstoreconnect/ 下的 env 文件里 source，不入库
scripts/release.sh --upload                 # 上传：同一个构建可用于内部 / 对外 TestFlight 与提审
scripts/release.sh --tv --upload            # Apple TV 版：同一条 App 记录，构建单独上传
```

- **版本号与服务器各自独立**（2026-09-29 用户决定：App 和服务器不是一回事）：
  - 营销版本号只有一处——`project.yml` 的 `MARKETING_VERSION`（首发 0.1.0），TestFlight、App Store、
    侧载 IPA 都读它；与服务器的 `pyproject.toml` / 发版 tag 无关，也不受「版本号三处一致」约束。
  - iPhone、Apple TV、Mac 三端共用这一个版本号（2026-10-05 定：同一份代码、同一个 Bundle ID，版本号对齐
    才说得清「0.5.0」是哪套代码；构建号各平台各自递增）。Mac 版随服务器 Release 发的 zip 同样读它，
    首个随发版的 Mac 包是 0.5.0。某个平台要单独发紧急修复时只给它提审补丁版本，下一个常规版本再对齐。
  - 什么时候改：准备**提审**一个新版本时手动递增（App Store 要求新版本号大于已上架的）；
    同一版本号下反复传 TestFlight 不用改，靠构建号区分。
  - 构建号默认取 UTC 时间 `yyyyMMddHHmm`，天然递增，不用管。
  - 随服务器 Release 附带的侧载 IPA 与 Mac 版 zip 是最近一次改动 App 时编的那个包，版本号就是当时的
    `MARKETING_VERSION`，所以服务器 v0.28.0 里的 IPA 可能是 App 0.1.0，这是正常的。
- 产物与日志在 `apps/apple/build-release/`（已被 git 忽略），归档约 5 分钟，DerivedData 约 0.7 GB，
  磁盘紧时打包完可删。
- 不带 `--upload` 只在本机导出 `.ipa`，用于验证签名；首次导出时自动签名会在账号下创建
  「Apple Distribution」证书与 App Store 描述文件，属正常流程。
- 上传后 5～30 分钟处理完才出现在 TestFlight；处理期间 Apple 会发邮件报告问题，
  **首次上传务必看邮件**（见 §5）。

### 侧载用的未签名 IPA

发版时 release.yml 的 `ios-ipa` 作业在 macOS runner 上跑 `apps/apple/scripts/build-unsigned-ipa.sh`，
把 `MovieClaw-iOS-unsigned.ipa` 附到 GitHub Release（可选附件，失败不拦转正）。自上一版以来 iPhone 版
用到的代码（`apps/apple` 除 Apple TV 专属目录与测试）没改动时不重编，由 `carry-assets` 作业直接沿用
上一个 Release 里的 IPA（判断规则见 `scripts/release-asset-plan.sh`）。Apple TV 版不出侧载包，只走 TestFlight。给不走 App Store /
TestFlight 的用户：用 AltStore / SideStore / Sideloadly 以自己的 Apple ID 重签安装——免费 Apple ID
签的包 7 天过期（AltStore / SideStore 可后台自动续签），付费开发者账号 1 年。

- 与商店版**同一份代码、同一个发行版本**（§1），只是不签名；不需要任何签名密钥，fork 仓库也能产出。
- 打包时去掉通知扩展（`MovieClawNotificationService`）和推送、App Group 的 entitlements，免费
  Apple ID 也能签（只占 1 个 App ID）。代价是侧载版**收不到推送**：免费 Apple ID 本来就没有推送能力，
  官方推送中继也只推商店版的 Bundle ID。App 发现自己没带通知扩展时不请求通知权限、不登记推送。
- 文件名固定，`releases/latest/download/MovieClaw-iOS-unsigned.ipa` 长期指向最新版。
- 附在服务器 Release 上而不单开 iOS Release：应用内更新按 GitHub 的 latest Release 判断服务器新版本，
  单独的 iOS Release 会被当成最新服务器版本，打乱更新检查。App 自己的版本号见 §3。
- 本机也能打：`apps/apple/scripts/build-unsigned-ipa.sh`，产物在 `apps/apple/build-ipa/`（已被 git 忽略）。
- **不要**用企业证书对外分发（只允许公司内部使用，违规会被吊销）；Ad Hoc 每年每类设备限 100 台，
  只适合极少数人。

## 4. 提交审核（对外测试与上架）

对外 TestFlight 首个构建要过一次 Beta 审核，上架要过正式审核，两者都要：

- **演示服务器与账号**：App 离开服务器无法使用，审核员必须能登录**并把每个功能真的用一遍**。
  用演示站 `https://demo.movieclaw.io`（`feat/demo` 分支，部署见该分支的 `demo/README.md`）：
  媒体库只有开放授权的影片，另有一个只收开放授权影片的演示资源站和一个模拟下载器，搜索、下载、
  订阅、刷流、自动入库都能端到端跑通，不产生任何真实的 P2P 流量。
  审核员用部署环境里的**审核账号**（超管，不是登录页公布的公开只读账号），用户名密码填在
  「App 审核信息 → 登录信息」，不写进备注。提审前用审核账号在 iPhone 上按 `demo/README.md`
  「App Store 审核」的清单走一遍；审核期间停掉演示站的每日还原，AI 助手接好真实模型。
- **审核备注模板**（审核员看英文；界面是简体中文，按钮名后面括注英文）：

  > MovieClaw is the iPhone client for MovieClaw, a self-hosted media server that users install on
  > their own hardware (a NAS, a home computer or a private server). Source code:
  > https://github.com/movieclaw/MovieClaw. It is comparable to Plex / Jellyfin / Infuse clients,
  > combined with the library-automation features found in Sonarr / Radarr companion apps.
  >
  > **Content and responsibility.** MovieClaw does not provide, host, index, link to or recommend any
  > movies, TV shows or torrent files, and it ships with no content sources of any kind. The app only
  > talks to the MovieClaw server that the user deploys on their own device. What goes into the
  > library, and which sources (if any) are connected to the server, is configured by the user on
  > their own server, and the user is responsible for having the rights to that content. Search,
  > download and subscription actions in the app are remote-control commands sent to the user's own
  > server: no media or torrent files are transferred to or from the iPhone, the app streams video
  > from the user's server only, and it contains no BitTorrent or other peer-to-peer code.
  >
  > **About the previous rejection (Guideline 5.6).** We believe it came from a misunderstanding caused
  > by the account we supplied last time. It was the shared, read-only account of our public demo
  > website, so when the reviewer tried to search sources, download or subscribe, the demo server
  > refused with messages such as "演示站不会真的订阅和下载" ("the demo site does not actually
  > subscribe or download"). Those refusals came from the public demo server's read-only mode, not
  > from the app. The app has no hidden, dormant or remotely enabled features and does not detect
  > reviewers: every user gets the same build and the same features. This time we provide a dedicated
  > review account with full administrator access on a demo server where every feature works end to
  > end.
  >
  > **How to sign in.** On first launch tap "连接服务器" (Connect to server), enter
  > https://demo.movieclaw.io, then sign in with the review account above.
  >
  > **About the demo server.** Its library contains only Creative Commons–licensed open movies from
  > the Blender Foundation and public-domain images. To let you try search, download and subscription,
  > it has a built-in demo "resource site" that lists only Creative Commons–licensed Blender films
  > (three of them, Elephants Dream, Charge and Wing It!, are not in the library yet), and a demo
  > download client that simulates transfers by copying those files on the server. No BitTorrent or
  > other peer-to-peer traffic happens on the demo server; the seeding/upload figures shown there are
  > simulated.
  >
  > **Features you can try**
  > 1. Browse and play: tabs "发现" (Discover), "媒体库" (Library); tap any film to play it.
  > 2. Search and download: tap the search button, type "Elephants", switch to "站点资源" (Site
  >    results), tap the result and choose "下载" (Download), then "下载到「电影」" (Download to
  >    "Movies"). Progress appears in the "活动" (Activity) tab; one or two minutes later the film is
  >    imported into "媒体库 → 电影" (Library → Movies) automatically.
  > 3. Subscribe: search "Charge" (or find it in Discover), open it, tap "订阅追踪" (Subscribe), then
  >    "确认订阅" (Confirm). The server finds a matching release, downloads it and adds it to the
  >    library within a few minutes; the subscription then shows as completed in the "订阅"
  >    (Subscriptions) tab.
  > 4. Seeding: "活动" (Activity) → "刷流做种" (Seeding) shows the server's seeding tasks (simulated on
  >    the demo server).
  > 5. AI assistant: "我的" (Me) → "最近会话" (Recent sessions) → "新会话" (New session). It answers
  >    questions about the user's own library and can act on it. It uses the language model that the
  >    server owner configured on their own server; the app never talks to an AI provider directly.
  >    Before the first message is sent, the app explains that messages, images and the library data
  >    the assistant looks up are sent by the user's server to the AI provider configured by the server
  >    owner (naming that provider), and asks for consent. A model is configured for the review
  >    account on the demo server.
  > 6. Administration: "我的 → 设置" (Me → Settings) manages members, devices, notifications, playback
  >    and other server settings. One-time server setup (adding resource sites, download clients and
  >    import rules) is done in the server's web console, on iOS and Android alike, because it needs
  >    large forms and drag-to-reorder lists. This is a product design decision, not a review
  >    restriction: open https://demo.movieclaw.io in Safari and sign in with the same account to see
  >    it. On the demo server these few settings are locked so the demo keeps working.
  > 7. MovieClaw Cloud (optional, for push notifications): "我的 → 设置 → MovieClaw Cloud". Connecting
  >    creates a MovieClaw account on our website (Sign in with Apple, Google or email). The same page
  >    links to "管理或删除 MovieClaw 账号" (Manage or delete MovieClaw account), where the account can
  >    be deleted at any time.
  >
  > **Technical notes.** Local networking / arbitrary loads: most users run the server on their home
  > LAN over plain HTTP (e.g. http://192.168.1.10:3000), so the app must reach LAN addresses without
  > TLS. Background audio is used to continue playback and for Picture in Picture.

  写备注的几条经验：
  - 首屏是「连接服务器」而不是账号密码框，**不写明先填服务器地址，审核员会卡住**。
  - 用「source code」而不是「open source」：本项目许可证带非商业条件，严格说是源码公开，
    中文描述同理写「源码完全公开」。
  - 备注里写到的每一步，提审前都用审核账号在演示站上实际走一遍；界面文字改了要同步改备注。
  - 「About the previous rejection」一段只在回应 5.6 拒审的这次提交里用，之后的提交删掉。

- **回复审核（Resolution Center）**：这次被以 5.6 拒审后重新提交时，在拒审消息下回复一段，
  内容就是上面「Content and responsibility」与「About the previous rejection」两段，并说明已在
  「登录信息」里换成了完整权限的审核账号。
- **截图**：6.9 英寸 iPhone（1320×2868 或 1290×2796）至少 3 张，用演示服务器的开放授权内容截；
  搜索、下载、订阅的画面也用演示资源站里的开放授权影片截。
- **出口合规**：Info.plist 已声明 `ITSAppUsesNonExemptEncryption = NO`，上传不再追问。

## 5. 已知风险与首次上传要核对的

- **隐私清单**：App（`MovieClaw/PrivacyInfo.xcprivacy`）与引擎框架（`AetherCore/PrivacyInfo.xcprivacy`）
  已声明用到的「需声明原因的 API」（偏好设置、系统运行时长、磁盘空间、文件时间戳）。
  FFmpeg 的 `AetherLib*` 二进制框架不带清单；若上传后收到 ITMS-91053 邮件点名缺少某类声明，
  按邮件补到对应清单里。新增代码用到这几类 API 时同步更新清单。
- **开源许可**：「我的 → 关于 MovieClaw」列出随包分发的组件、许可与源码地址，全文随包
  （`apps/apple/Shared/Resources/Licenses/`，iPhone 与 Apple TV 共用）。升级 AetherEngine / FFmpegBuild / Nuke 等依赖时同步核对。
  AetherEngine 是 LGPL-3.0 且带 App Store 例外；FFmpeg 为 LGPL-2.1（未启用 GPL 组件），
  以动态框架随包，满足可替换要求。
- **播放质量记录**：App 会把每次播放的起播耗时、跳转、卡顿、失败原因（失败时附最近的播放器日志，
  引擎自带脱敏）上报给**用户自己的服务器**，供管理员排查（设计见 [playback-qoe.md](playback-qoe.md)）。
  开发者不接收任何数据，隐私问卷仍填「不收集数据」；隐私政策已写明这一点。旧版服务器没有这个接口时
  回 404，App 直接丢弃记录，不重试、不积压。
- **调试开关只在调试版**：`-mc…` 启动参数（真机实验台、故障注入、强制通路）都在 `#if DEBUG` 里，
  发布构建不含；提审前不必额外清理。
- **TMDB 署名**：关于页已注明「本产品使用 TMDB API，但未经 TMDB 认可或认证」。
- **5.2.3（不得便利非法文件共享）**：App 有资源搜索、下载与订阅（遥控用户自己的服务器），这是这类
  App 最常被追问的条款。应对：备注里讲清内容来源与责任归属（§4），演示站只放开放授权影片、下载与
  做种都是模拟的。若仍被拒，在 Resolution Center 按审核意见逐条说明，必要时申请电话沟通。
- **最低系统 iOS 26**：只有 iOS 26 及以上的 iPhone 能在商店里看到它。
- **CI 的 Xcode 比本机旧**：GitHub macos-26 runner 目前最高 Xcode 26.x，本机开发常用更新的版本。
  新 Xcode 能推断通过的写法在旧版上会编译失败甚至让编译器崩溃（v0.28.0 发版因此缺过 IPA）。
  规矩：以 PR 上的 `ios` 检查（`.github/workflows/ios.yml`，普通 PR 编 Debug，发版 PR 编 Release）为准；不写 `Binding(get:set:)`，
  用 `Binding(mcGet:set:)`（原因见 `Core/ClosureBinding.swift`）；给生成模型补协议一致性写
  `nonisolated extension`；长的三元 / 字符串拼接拆成显式类型的局部量。

## 6. Mac 转码器

与 iOS 共用同一个开发者账号，但证书不同：需要在 developer.apple.com → Certificates 新建
**Developer ID Application** 证书（只有账号持有人能建），导出成 `.p12` 后按
`.github/workflows/release.yml` worker-macos 作业的注释配置仓库密钥；公证复用 §2 的 API 密钥。
配好后每次发版的 `MovieClawTranscoder-macos-arm64.zip` 自动签名、公证、钉票据，用户双击即可打开。

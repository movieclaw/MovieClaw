# 发布范围证据

基准提交：`a4559c65d50702497d7d90a022d10c79e15e9ee1`。读取于 2026-10-25；本文件记录版本修改之前的主线产品差异。

GitHub Release 记录已联网读取；商店和 TestFlight 的实际分发版本未独立核实，不能把 GitHub tag 当成已上架证明。

## 区间内合入的 PR

| PR | 合入 SHA | 标题 |
|---|---|---|
| [#1027](https://github.com/movieclaw/MovieClaw/pull/1027) | `a4559c65d` | feat(i18n): Web 与苹果三端国际化（简体中文 / 英语，跟随系统） |
| [#1026](https://github.com/movieclaw/MovieClaw/pull/1026) | `056bcfeff` | chore(dependabot): 忽略 next 大版本升级 |
| [#1024](https://github.com/movieclaw/MovieClaw/pull/1024) | `f1179cca7` | chore(deps): 用 pnpm 10 重做 javascript-security 依赖升级（替代 #1010） |
| [#1023](https://github.com/movieclaw/MovieClaw/pull/1023) | `9e55d5c9e` | feat(plugins): 能力表「定时任务」「会发通知」行的查看直达具体那一行 |
| [#1021](https://github.com/movieclaw/MovieClaw/pull/1021) | `d4bc852b4` | feat(playback): 硬件转码给能解的客户端出 HEVC（#1008 第二步） |
| [#1020](https://github.com/movieclaw/MovieClaw/pull/1020) | `173e1c4af` | perf(androidtv): 照 Apple TV 优化详情页、海报行与「接下来继续」的滑动 |
| [#1019](https://github.com/movieclaw/MovieClaw/pull/1019) | `b04094efd` | fix(plugins): 插件能力表每行都带「查看」——通知行说明收订在「账号 → 通知」 |
| [#1018](https://github.com/movieclaw/MovieClaw/pull/1018) | `c22d62c23` | feat(androidtv): 深链 movieclaw://home——电视桌面插件的主页键直达首页根部 |
| [#1017](https://github.com/movieclaw/MovieClaw/pull/1017) | `c91912b4d` | feat(offline): NAS 显卡离线导出出 HEVC + QSV/NVENC 强制 IDR（#1008 第一步） |
| [#1016](https://github.com/movieclaw/MovieClaw/pull/1016) | `e523b1734` | feat(android): 内外网自动切换、片段预切与离线下载对齐 iOS |
| [#1015](https://github.com/movieclaw/MovieClaw/pull/1015) | `95f50c047` | fix(mac): Sparkle 权限名的 Bundle ID 从编好的 App 读；没装进应用程序时设置里说明原因 |
| [#1014](https://github.com/movieclaw/MovieClaw/pull/1014) | `c58ea3266` | feat(windows): MovieClaw 转码器（Windows）——把 NAS 的硬件转码交给 NVIDIA 显卡 |
| [#1013](https://github.com/movieclaw/MovieClaw/pull/1013) | `92cb54a39` | feat(subscription): 订阅上限——一季上千集时先订阅前 N 集，之后一键继续 |
| [#1012](https://github.com/movieclaw/MovieClaw/pull/1012) | `fd63d0729` | style(web): Netflix 媒体库 hero 底部渐变换八段缓动，文案块上移 |
| [#1011](https://github.com/movieclaw/MovieClaw/pull/1011) | `2ba7c6cf7` | feat(mac): Sparkle 自动更新与更新界面（GitHub 直接分发版） |
| [#1009](https://github.com/movieclaw/MovieClaw/pull/1009) | `98c7089b6` | feat(mac): 安装盘（DMG）与「必须装进应用程序」的安装引导 |
| [#1007](https://github.com/movieclaw/MovieClaw/pull/1007) | `35d8c047a` | fix(ingest): 内容无法识别的文件归待处理，不再当环境故障每小时重试 |
| [#1005](https://github.com/movieclaw/MovieClaw/pull/1005) | `e8ec6081d` | fix(macos): 播放时置顶下全屏失效、⋯ 菜单弹出即收起；双击面板空白也全屏 |
| [#1004](https://github.com/movieclaw/MovieClaw/pull/1004) | `8d239a803` | feat(subscription): 规则组可以排除杜比视界 Profile 5（「DV P5」芯片） |
| [#1003](https://github.com/movieclaw/MovieClaw/pull/1003) | `455fada90` | fix(subscription): 中文季集命名可选择性下载，确定性失败不留孤儿任务、不无限重试 |
| [#1002](https://github.com/movieclaw/MovieClaw/pull/1002) | `b114b3b3f` | fix(downloads): 任务中心去向与真实投递同口径选库，未定格库的订阅不再误报不会入库 |
| [#1001](https://github.com/movieclaw/MovieClaw/pull/1001) | `6ab814fc7` | feat(android): 平板适配与 iOS 端功能对齐（离线下载、扫码登录、设置页、小幕） |
| [#1000](https://github.com/movieclaw/MovieClaw/pull/1000) | `18bd86c69` | feat(auth): support Windows devices in existing native login and pairing |
| [#995](https://github.com/movieclaw/MovieClaw/pull/995) | `1b73cb1de` | feat(playback): 插件宿主操作 playback.sync.state，回写续播、取消已看、收藏 |
| [#993](https://github.com/movieclaw/MovieClaw/pull/993) | `d46a24bcb` | fix(playback): VAAPI 对全范围（pc）源起播即崩；杜比视界 P5 落到本机显卡时在诊断里说明偏色原因 |
| [#991](https://github.com/movieclaw/MovieClaw/pull/991) | `af934b55a` | 插件市场详情：下载量、反馈入口，以及更干净的首屏 |
| [#990](https://github.com/movieclaw/MovieClaw/pull/990) | `407962701` | fix(web/theme): iPhone 系统转横屏不再被当成电脑——主题按设备类取 |
| [#989](https://github.com/movieclaw/MovieClaw/pull/989) | `903dba4ed` | fix(player): 详情页点播放只在用户亲手选过版本时才锁定文件 |
| [#988](https://github.com/movieclaw/MovieClaw/pull/988) | `ef105d1e4` | fix(player): 进度条阴影两端横向淡出，消除亮画面下的垂直硬切线 |
| [#984](https://github.com/movieclaw/MovieClaw/pull/984) | `4f91880b6` | chore(deps): 用 pnpm 10 重做 javascript-security 依赖升级（替代 #956） |
| [#983](https://github.com/movieclaw/MovieClaw/pull/983) | `41a44f6bb` | feat(sites): 站点代请求 site.proxy.request——插件借宿主已认证会话访问站点 |
| [#982](https://github.com/movieclaw/MovieClaw/pull/982) | `ced7badf0` | fix(playback): 分片取流被掐断后提前回收没人看的转码会话，并给 Windows 补上 killpg 兜底 |
| [#981](https://github.com/movieclaw/MovieClaw/pull/981) | `f6e849603` | test(playback): 超时分档用例改用体积替身，不再 truncate 20/200 GB 的文件 |
| [#975](https://github.com/movieclaw/MovieClaw/pull/975) | `c6b729e00` | fix(androidtv): 开机时网络晚到，首页等网络连上就自己重试 |
| [#973](https://github.com/movieclaw/MovieClaw/pull/973) | `2058487a8` | feat(playback): add permission-scoped watch history exchange APIs |
| [#972](https://github.com/movieclaw/MovieClaw/pull/972) | `66ffe3877` | feat(player): add video display modes to iOS and Web |

## 服务器

基线 `v0.42.0` → `a4559c65d`。路径：`.`。

```text
a4559c65d Integrate main's Windows transcoder with localized remote-worker text
3fbfe4f5c Integrate main's row-level deep links with localized plugin and notification text
1c338b4ad fix(i18n): CI fixes for lint, generated Kotlin models and older-host plugin installs
abe53c67f fix(i18n): requests without Accept-Language keep Chinese
65b73507c Integrate origin/main: localize newly merged Web, Apple and server text
df157886c fix(i18n): native DROP COLUMN in today's downgrades, legacy GitHub scope values; record the English walkthrough and final regression
5380d8ded fix(i18n): genre tiles and fixed job subjects render in the reader's language (found in the English iOS walkthrough)
ce1854a1a test(i18n): web genre parity reads Apple's String Catalog; quote accessibility covers English quotes
237cceb23 feat(i18n): web welcome quotes follow the interface language from the shared Apple quote data
5351be098 feat(i18n): finish the server ratchet: localize remaining validation, device, TMDB setup and verification texts; mark developer-facing strings
758899ab2 feat(i18n): localize request validation texts (site paths, LLM, subscriptions, addresses, agent input), key site availability and spec errors; mark plugin-facing errors
9c23a2f16 feat(i18n): key subtitle extraction failure reasons, transcoder revocation and webhook test samples; exempt built-in plugin titles; mark plugin-facing texts
a5f994520 feat(i18n): localize downloader input and discovery reference errors; key GitHub update scopes; mark job/sync developer diagnostics
921d75b18 feat(i18n): localize IM image notices and default attachment names; key agent run error fallbacks; mark model-facing agent texts
b94cdafe0 feat(i18n): key smart-submission file selection errors; mark ratio boost ledger notes and submit logs as non-UI
9dd12f0b3 feat(i18n): localize the offline password reset command by terminal language, falling back to the administrator's UI language
758da6303 feat(i18n): localize IM binding notes, pairing receipts in the binder's language, channel errors and dead-letter replay errors
c34cd8124 feat(i18n): localize settings validation messages; key the egress service catalog; treat setting-domain titles as code labels
74866dd80 feat(i18n): localize source removal preview, skip reasons and job results
a2dca09d5 feat(i18n): localize offline export errors, activity lines and manifest labels; keep failure references in export state
9334f9c48 feat(i18n): localize push alerts, outcomes, plugin rule labels and status episode labels; mark internal push texts
8be8d4b0b feat(i18n): localize Reels facets and clip precut job texts; mark diagnostics and track-title tokens
a1c6de79c feat(i18n): localize metadata refresh phases, image tallies, job progress and release schedule activity
da28a6da1 feat(i18n): localize plugin declarations, switches, safe mode and callback lookups; guard builtin metadata
f6d467ed7 feat(i18n): localize plugin market errors and compatibility reasons
38d04bb7e feat(i18n): localize plugin package validation, approval, dependency and rollback messages
a0ecf644f feat(i18n): localize cloud storage errors, uploads and replica failures; guard storage directory texts
81fbf129f feat(i18n): localize remaining route texts, worker handshake (WebSocket locale) and recycle labels
a61adaf60 feat(i18n): localize subtitle generation pause, labels and actor; keep prompts and diagnostics as source text
5c1fc5dfd feat(i18n): localize playback diagnostics, hardware probe, remote worker and strm probe texts
232b8f04f feat(i18n): localize spec audit, matching rejection notes and identity explanations; mark forecast logs
a0851917d feat(i18n): localize subscription dispatch, upgrade, cleanup and smart submission texts; add job subject references
55362ac7e feat(i18n): localize download attempt notes, replacement activity and task center rescue texts
17c102d4b fix(i18n): keep watch import pilot notes parameter-compatible across locales
c995a8561 feat(i18n): localize watch import conclusions, progress and job texts
8c4f1699d feat(i18n): localize remaining library service messages
3e0da7ae0 feat(i18n): localize library scan, re-identify and cloud folder messages
d42de9351 feat(i18n): derive library rollback texts from catalog keys (duplicates, origins, parsers)
44576ede9 chore(i18n): treat bare strings, logs and regex patterns as non-interface text
718bdf92b feat(i18n): localize intro/credits detection job messages
c1de2e033 test(i18n): wrap long lines in library job i18n tests
ff23b36a8 feat(i18n): localize library transfer, batch transfer and chapter job messages
b5f09f8cc chore(i18n): exclude OpenAPI docs and keyed fallbacks from the server ratchet
aa76fb2f4 feat(i18n): finish Apple localization (shell, extensions, welcome quotes)
a2b036f81 feat(i18n): localize Apple discover, AI assistant and Mac/TV library
0beb424d7 feat(i18n): localize Apple search and offline downloads; scan nested Swift literals
f245c8911 feat(i18n): localize Apple subscriptions
034656f20 feat(i18n): localize Apple settings
d51ff8086 feat(i18n): localize Apple library, item detail and library management
6e99fc14c feat(i18n): localize Apple activity, task center and watch statistics
b44e260eb fix(i18n): use reader-language list separators in missing summaries and source warnings
273eddaa0 feat(i18n): localize AI handoff, plugin fallback, schema placeholders and upload errors
4b87bc941 feat(i18n): localize route titles and accessible profile labels
cf52126b3 feat(i18n): localize cross-library walls and recent summaries
5a233b62a feat(i18n): localize Agent media cards and refresh reader data
49d8575e4 feat(i18n): localize library reports with stable rule identities
7fed332b7 feat(i18n): localize manual source annotation without changing tiers
dff4be03f feat(i18n): localize search preferences and preserve named scopes
987c96cbd feat(i18n): localize playback settings and verify worker configuration
ee6df7b1e feat(i18n): localize MCP management and verify authenticated clients
4b90a2154 feat(i18n): localize home customization without persisting display names
c32da2ecf feat(i18n): localize duplicate decisions while preserving version identities
526ea27b5 feat(i18n): localize recycle controls and verify file recovery
fc8b4a31b feat(i18n): render recycle snapshots without changing grouping facts
8788ad40c feat(i18n): localize IM channel management and owned binding flows
285826cdf feat(i18n): carry declared channel metadata across plugin runtimes
b2ff2cfea feat(i18n): localize notification preferences and retain stable group identities
06475d755 feat(i18n): localize push relay management and preserve neutral diagnostics
7304e4085 feat(i18n): localize cloud pairing and render connection failures per reader
3da8712c3 feat(i18n): localize owned plugin metadata with source provenance checks
7917bfea5 feat(i18n): render plugin capabilities after stable deduplication
6d4dd6b1c feat(i18n): localize plugin details and preserve declared author metadata
d02808255 feat(i18n): localize plugin package approval and installation management
9e5b65843 feat(i18n): localize plugin marketplace browsing and permission summaries
54d62997f feat(i18n): localize plugin overview and web consent management
fc19b1a9c feat(i18n): localize plugin status and isolate feature catalogs by language
9b1f34662 feat(i18n): localize automatic import configuration and folder selection
68a5790a4 feat(i18n): localize cloud drive setup and restore theme navigation
adcf35ecc feat(i18n): localize site setup and retain verification provenance
0bec88cde feat(i18n): localize downloader setup and preserve error references
b99f4bdb2 feat(i18n): preserve automatic session title and skill instruction provenance
c84c50195 feat(i18n): localize agent session interactions and tool summaries
938b36294 feat(i18n): preserve model stream errors across readers and notifications
bd62fafac feat(i18n): translate model providers and persist localized connection errors
b36dbf7e8 feat(i18n): translate AI preferences and verify search configuration
4868b1161 feat(i18n): translate update controls and render progress per reader
5801dda7f fix(i18n): isolate Mac account navigation and verify native playback
ba64472ba feat(i18n): translate Webhook controls and verify real signed deliveries
233455cdf feat(i18n): translate Mac menus and verify native language settings
7bb0a025d feat(i18n): translate native schedules and verify draft discard and save
e06c92cd5 feat(i18n): localize scheduled tasks and preserve runtime scheduling
57576fa42 feat(i18n): translate log controls and preserve raw daily files
5a940f6e4 feat(i18n): translate native storage cleanup and validate reader languages
659a27d2a feat(i18n): translate storage snapshots and verify real cleanup
711ae9a7a feat(i18n): translate network settings and verify port restarts
bb372f7d7 feat(i18n): translate member access and credential workflows
fbeeb29fc feat(i18n): translate device management and pairing grants
82f85dc39 feat(i18n): translate account switching and startup recovery
a91f74cf8 feat(i18n): translate watch statistics and responsive charts
56181b298 feat(i18n): localize live viewing and playback histories
84f434f21 fix(i18n): classify playback executors independently of labels
6d9669560 feat(i18n): translate task timelines and boost cleanup flows
5dc1a38e4 feat(i18n): localize shared job cards and action receipts
d57cc5c71 feat(i18n): translate pipeline health checks and rule previews
b741d54ec feat(i18n): localize subscription home calendars and walls
62039fb9b feat(i18n): render smart selection explanations with rollback-safe state
a18a91663 feat(i18n): localize subscription inspector and search histories
14976af65 feat(i18n): render subscription lifecycle histories for each reader
a8cb1d821 feat(i18n): sync native message references with legacy decoding support
2b46f80de feat(i18n): localize subscription adjustments and season cleanup
2a5db11b1 feat(i18n): localize subscription forms and season selection
6281027dd feat(i18n): localize quality upgrade confirmation and reports
d8d62939e feat(i18n): localize cancellation previews and verify file recycling
b752b9b5d feat(i18n): localize smart settings and reader-specific subscription preferences
00fda7f28 feat(i18n): localize rule sets and preserve seeded name provenance
cca827951 feat(i18n): localize download destinations and routing previews
d8cb0916b feat(i18n): localize search results and reader-specific diagnostics
e1a8b820b feat(i18n): localize search palette and preserve custom history labels
e46889714 feat(i18n): retain semantic search scopes across history and cached runs
01a103e2c feat(i18n): localize subtitle generation and persisted job diagnostics
50266667f feat(i18n): localize subtitle preview and timing calibration
b6b578b61 feat(i18n): localize sharing visitor pages and artwork selection
e4d18e19c feat(i18n): persist identification reasons and candidate evidence
57cb8d2ea feat(i18n): localize identification and filename organization
b942995b8 feat(i18n): localize item details tracks and file operations
dee0859ba feat(i18n): localize collections favorites and galleries
5bf153861 feat(i18n): localize library browsing and filters
b6faf8c3d feat(i18n): localize library forms and metadata configuration
bdc681c3d feat(i18n): localize library management and operation confirmations
bc83412ef feat(i18n): translate content browsing, discovery and library home
8d7aeed77 feat(i18n): localize operation responses and playback activity
9e7bee7a5 feat(i18n): translate Apple playback and engine diagnostics
cae593713 docs(i18n): record verification and prepare English release copy
ac60204aa feat(i18n): translate web playback controls, tracks and diagnostics
8098cdd73 feat(i18n): localize subscription history and playback decision messages
146913851 feat(i18n): localize Apple onboarding, navigation and shared controls
415e57efc feat(i18n): translate web navigation and subscription views
a2d2ae0a4 feat(i18n): localize API errors, stored notices and plugin metadata
5ea469162 feat(i18n): add locale formatting, Apple catalogs and quality gates
7123ffb76 feat(i18n): add locale foundation and account language flow
c58ea3266 feat(windows): MovieClaw 转码器（Windows）——把 NAS 的硬件转码交给 NVIDIA 显卡 (#1014)
9e55d5c9e test(plugins): 通知行的去处断言跟上 ?event= 行级定位键
47c8791c3 test(plugins): 契约测试的长断言折行——过 ruff 的 100 列门禁
fc28ac518 fix(plugins): 定时任务行的定位键改用任务 key——第三方贡献 id 带「插件id:」前缀
56d2e2523 feat(web): ?task=/?event= 行级深链——目标页滚到那一行并短暂高亮
df22779e4 feat(plugins): 能力表「定时任务」「会发通知」行的查看直达具体那一行
f1179cca7 chore(deps): 用 pnpm 10 重做 javascript-security 依赖升级（替代 #1010）
92cb54a39 feat(subscription): 订阅窗口按季状态分流——在播长剧订最新 N 集并照常追新
83ea329d7 feat(subscription): 订阅上限——一季上千集时先订阅前 N 集，之后一键继续
b04094efd fix(plugins): 能力表通知行未获批不再自相矛盾；拆超长断言过 ruff（评审 #1019）
51095440e fix(plugins): 插件能力表每行都带「查看」——通知行说明收订在「账号 → 通知」（附浏览器验收）
d4bc852b4 feat(playback): 硬件转码给能解的客户端出 HEVC（#1008 第二步）
c91912b4d fix(playback): QSV / NVENC 强制关键帧显式出 IDR，分片切回 4 秒栅格
e0c9559e7 fix(offline): HEVC 导出中途卡一下不再整份改 H.264 重转
f43c4115a feat(offline): NAS 显卡（VAAPI/QSV/NVENC）离线导出出 HEVC
fd63d0729 style(web): Netflix 媒体库 hero 底部渐变换八段缓动，文案块上移
2ba7c6cf7 feat(mac): Sparkle 自动更新与更新界面（GitHub 直接分发版）
98c7089b6 feat(mac): 安装盘（DMG）与「必须装进应用程序」的安装引导
8d239a803 refactor(subscription): 按评审收窄「不要杜比视界 Profile 5」——去掉智能设置开关，只留规则组「DV P5」芯片
c8fd296b9 feat(apple,android,harmonyos,desktop): 跟上「不要杜比视界 Profile 5」——智能开关与规则组芯片
146502aa2 feat(web): 设置页「不要杜比视界 Profile 5」开关与规则组「DV P5」芯片，附浏览器验收
9cb1948ab feat(subscription): 杜比视界 Profile 5 可以不要——判定、规则组「DV P5」与智能设置开关
35d8c047a fix(ingest): 内容无法识别的文件归待处理，不再当环境故障每小时重试 (#1006)
18bd86c69 fix(auth): show Windows pairing as computer app login on the web
7a203e0bd fix(auth): preserve old-server decoding in generated native models
3ec41bb24 feat(auth): support Windows app devices and advertise native login kinds
455fada90 fix(subscription): 中文季集命名可选择性下载，确定性失败不留孤儿任务、不无限重试
b114b3b3f fix(downloads): 任务中心去向与真实投递同口径选库，未定格库的订阅不再误报不会入库
1b73cb1de feat(playback): add playback.sync.state host op for two-way sync write-back
d46a24bcb feat(playback): 杜比视界 P5 落到读不了 RPU 的本机显卡时，诊断的判定理由说明偏色原因与出路
d1473c51a fix(playback): VAAPI 对全范围（pc）源起播即崩——硬件缩放转成 limited，帧标签写 range=tv
e3557c81d refactor(player): simplify scaling controls and align ASS with video
410acc586 fix(player): reset stale display selections and stabilize CI clock test
77781178d test(player): format browser regression and resolve fixture without shadowing
d9208218d feat(player): add reversible video display modes on iOS and web
af934b55a fix(cli): 把插件市场截图接口登记为不生成命令
79eaadb8d feat(plugins): 插件市场详情显示下载量与反馈入口
2058487a8 fix(playback): retain imported watches across identity changes
03429db09 feat(playback): add permission-scoped watch history exchange APIs
903dba4ed fix(player): 锁定的文件只对进入播放页的那一集生效，并还原混进来的无关颜色替换
a4d04368c fix(player): 详情页点播放只在用户亲手选过版本时才锁定文件
407962701 fix(web/theme): iPhone 系统转横屏不再被当成电脑——主题按设备类取，而不只看页面宽度
ef105d1e4 fix(player): 进度条阴影两端横向淡出，消除亮画面下的垂直硬切线
41a44f6bb fix(sites): 站点代请求不跟随跳转、标为危险操作，并让 CLI 守卫过关
c2e288b32 feat(sites): 站点代请求 site.proxy.request——插件借宿主已认证会话访问站点，凭据不出宿主
ced7badf0 fix(playback): 分片断连按 session_id 登记到会话，断开后又有动静就不提前回收
c7a285482 fix(playback): 页签直接关闭时提前回收转码会话，并给 Windows 补上 killpg 兜底
4f91880b6 chore(deps): 用 pnpm 10 重做 javascript-security 依赖升级（替代 #956）
f6e849603 test(playback): 超时分档用例改用体积替身，不再 truncate 20/200 GB 的文件
```

文件差异汇总： 1344 files changed, 154426 insertions(+), 17514 deletions(-)。


## iPhone / iPad

基线 `ios-v0.10.0` → `a4559c65d`。路径：`apps/apple`。

```text
65b73507c Integrate origin/main: localize newly merged Web, Apple and server text
aa76fb2f4 feat(i18n): finish Apple localization (shell, extensions, welcome quotes)
a2b036f81 feat(i18n): localize Apple discover, AI assistant and Mac/TV library
0beb424d7 feat(i18n): localize Apple search and offline downloads; scan nested Swift literals
f245c8911 feat(i18n): localize Apple subscriptions
034656f20 feat(i18n): localize Apple settings
d51ff8086 feat(i18n): localize Apple library, item detail and library management
6e99fc14c feat(i18n): localize Apple activity, task center and watch statistics
c32da2ecf feat(i18n): localize duplicate decisions while preserving version identities
bd62fafac feat(i18n): translate model providers and persist localized connection errors
5801dda7f fix(i18n): isolate Mac account navigation and verify native playback
233455cdf feat(i18n): translate Mac menus and verify native language settings
7bb0a025d feat(i18n): translate native schedules and verify draft discard and save
5a940f6e4 feat(i18n): translate native storage cleanup and validate reader languages
711ae9a7a feat(i18n): translate network settings and verify port restarts
84f434f21 fix(i18n): classify playback executors independently of labels
a8cb1d821 feat(i18n): sync native message references with legacy decoding support
b6faf8c3d feat(i18n): localize library forms and metadata configuration
9e7bee7a5 feat(i18n): translate Apple playback and engine diagnostics
cae593713 docs(i18n): record verification and prepare English release copy
146913851 feat(i18n): localize Apple onboarding, navigation and shared controls
5ea469162 feat(i18n): add locale formatting, Apple catalogs and quality gates
7123ffb76 feat(i18n): add locale foundation and account language flow
d4bc852b4 feat(playback): 硬件转码给能解的客户端出 HEVC（#1008 第二步）
95f50c047 fix(mac): Sparkle 权限名的 Bundle ID 从编好的 App 读；没装进应用程序时设置里说明原因
2ba7c6cf7 feat(mac): Sparkle 自动更新与更新界面（GitHub 直接分发版）
98c7089b6 feat(mac): 安装盘（DMG）与「必须装进应用程序」的安装引导
8d239a803 refactor(subscription): 按评审收窄「不要杜比视界 Profile 5」——去掉智能设置开关，只留规则组「DV P5」芯片
c8fd296b9 feat(apple,android,harmonyos,desktop): 跟上「不要杜比视界 Profile 5」——智能开关与规则组芯片
18bd86c69 fix(auth): show Windows pairing as computer app login on the web
7a203e0bd fix(auth): preserve old-server decoding in generated native models
66ffe3877 fix(ios): use current geometry for subtitles after paused rotation
e3557c81d refactor(player): simplify scaling controls and align ASS with video
d9208218d feat(player): add reversible video display modes on iOS and web
```

文件差异汇总： 255 files changed, 159116 insertions(+), 5704 deletions(-)。


## Apple TV

基线 `tvos-v0.10.0` → `a4559c65d`。路径：`apps/apple`。

```text
65b73507c Integrate origin/main: localize newly merged Web, Apple and server text
aa76fb2f4 feat(i18n): finish Apple localization (shell, extensions, welcome quotes)
a2b036f81 feat(i18n): localize Apple discover, AI assistant and Mac/TV library
0beb424d7 feat(i18n): localize Apple search and offline downloads; scan nested Swift literals
f245c8911 feat(i18n): localize Apple subscriptions
034656f20 feat(i18n): localize Apple settings
d51ff8086 feat(i18n): localize Apple library, item detail and library management
6e99fc14c feat(i18n): localize Apple activity, task center and watch statistics
c32da2ecf feat(i18n): localize duplicate decisions while preserving version identities
bd62fafac feat(i18n): translate model providers and persist localized connection errors
5801dda7f fix(i18n): isolate Mac account navigation and verify native playback
233455cdf feat(i18n): translate Mac menus and verify native language settings
7bb0a025d feat(i18n): translate native schedules and verify draft discard and save
5a940f6e4 feat(i18n): translate native storage cleanup and validate reader languages
711ae9a7a feat(i18n): translate network settings and verify port restarts
84f434f21 fix(i18n): classify playback executors independently of labels
a8cb1d821 feat(i18n): sync native message references with legacy decoding support
b6faf8c3d feat(i18n): localize library forms and metadata configuration
bc83412ef feat(i18n): translate content browsing, discovery and library home
9e7bee7a5 feat(i18n): translate Apple playback and engine diagnostics
cae593713 docs(i18n): record verification and prepare English release copy
146913851 feat(i18n): localize Apple onboarding, navigation and shared controls
5ea469162 feat(i18n): add locale formatting, Apple catalogs and quality gates
7123ffb76 feat(i18n): add locale foundation and account language flow
d4bc852b4 feat(playback): 硬件转码给能解的客户端出 HEVC（#1008 第二步）
95f50c047 fix(mac): Sparkle 权限名的 Bundle ID 从编好的 App 读；没装进应用程序时设置里说明原因
2ba7c6cf7 feat(mac): Sparkle 自动更新与更新界面（GitHub 直接分发版）
98c7089b6 feat(mac): 安装盘（DMG）与「必须装进应用程序」的安装引导
8d239a803 refactor(subscription): 按评审收窄「不要杜比视界 Profile 5」——去掉智能设置开关，只留规则组「DV P5」芯片
c8fd296b9 feat(apple,android,harmonyos,desktop): 跟上「不要杜比视界 Profile 5」——智能开关与规则组芯片
18bd86c69 fix(auth): show Windows pairing as computer app login on the web
7a203e0bd fix(auth): preserve old-server decoding in generated native models
66ffe3877 fix(ios): use current geometry for subtitles after paused rotation
e3557c81d refactor(player): simplify scaling controls and align ASS with video
d9208218d feat(player): add reversible video display modes on iOS and web
```

文件差异汇总： 102 files changed, 154175 insertions(+), 1100 deletions(-)。


## Mac 版

基线 `macos-v0.10.0` → `a4559c65d`。路径：`apps/apple`。

```text
65b73507c Integrate origin/main: localize newly merged Web, Apple and server text
aa76fb2f4 feat(i18n): finish Apple localization (shell, extensions, welcome quotes)
a2b036f81 feat(i18n): localize Apple discover, AI assistant and Mac/TV library
0beb424d7 feat(i18n): localize Apple search and offline downloads; scan nested Swift literals
f245c8911 feat(i18n): localize Apple subscriptions
034656f20 feat(i18n): localize Apple settings
d51ff8086 feat(i18n): localize Apple library, item detail and library management
6e99fc14c feat(i18n): localize Apple activity, task center and watch statistics
c32da2ecf feat(i18n): localize duplicate decisions while preserving version identities
bd62fafac feat(i18n): translate model providers and persist localized connection errors
5801dda7f fix(i18n): isolate Mac account navigation and verify native playback
233455cdf feat(i18n): translate Mac menus and verify native language settings
7bb0a025d feat(i18n): translate native schedules and verify draft discard and save
5a940f6e4 feat(i18n): translate native storage cleanup and validate reader languages
711ae9a7a feat(i18n): translate network settings and verify port restarts
84f434f21 fix(i18n): classify playback executors independently of labels
a8cb1d821 feat(i18n): sync native message references with legacy decoding support
b6faf8c3d feat(i18n): localize library forms and metadata configuration
9e7bee7a5 feat(i18n): translate Apple playback and engine diagnostics
cae593713 docs(i18n): record verification and prepare English release copy
146913851 feat(i18n): localize Apple onboarding, navigation and shared controls
5ea469162 feat(i18n): add locale formatting, Apple catalogs and quality gates
7123ffb76 feat(i18n): add locale foundation and account language flow
d4bc852b4 feat(playback): 硬件转码给能解的客户端出 HEVC（#1008 第二步）
95f50c047 fix(mac): Sparkle 权限名的 Bundle ID 从编好的 App 读；没装进应用程序时设置里说明原因
2ba7c6cf7 feat(mac): Sparkle 自动更新与更新界面（GitHub 直接分发版）
98c7089b6 feat(mac): 安装盘（DMG）与「必须装进应用程序」的安装引导
8d239a803 refactor(subscription): 按评审收窄「不要杜比视界 Profile 5」——去掉智能设置开关，只留规则组「DV P5」芯片
c8fd296b9 feat(apple,android,harmonyos,desktop): 跟上「不要杜比视界 Profile 5」——智能开关与规则组芯片
e8ec6081d feat(macos): 双击控制面板空白处与片名也能全屏
737e3e2b0 fix(macos): 播放时置顶下全屏失效、⋯ 菜单弹出即被收起
18bd86c69 fix(auth): show Windows pairing as computer app login on the web
7a203e0bd fix(auth): preserve old-server decoding in generated native models
66ffe3877 fix(ios): use current geometry for subtitles after paused rotation
e3557c81d refactor(player): simplify scaling controls and align ASS with video
d9208218d feat(player): add reversible video display modes on iOS and web
```

文件差异汇总： 104 files changed, 154789 insertions(+), 1225 deletions(-)。


## Mac 转码器

基线 `transcoder-v0.33.1` → `a4559c65d`。路径：`macos/MovieClawTranscoder`。

```text
无路径提交差异。
```

文件差异汇总：无差异。


## Android

基线 `android-v0.7.0` → `a4559c65d`。路径：`apps/android`, `apps/android-core`。

```text
1c338b4ad fix(i18n): CI fixes for lint, generated Kotlin models and older-host plugin installs
7123ffb76 feat(i18n): add locale foundation and account language flow
e523b1734 fix(android): 批量下载断网时继续取清单，不跳过后续集
e0279e3fe fix(android): 故障转移保留子路径反代前缀
fbd0a36b1 fix(android): 断网时保留下载进度并在 Wi-Fi 恢复后续传
d849ce2e5 feat(android): 离线下载对齐 iOS（仅 Wi-Fi、按账号隔离、档位记忆）
d3113c0de fix(android): 菜单收起动画与表单面板滚动跳动
6facdb140 fix(android): 媒体库封面地址跟随当前服务器入口
2b72b21c0 feat(android): 片段优先播放预切片段并跟随当前内外网入口
980e8ceab feat(android): 内外网地址自动切换与请求级故障转移
d4bc852b4 feat(playback): 硬件转码给能解的客户端出 HEVC（#1008 第二步）
8d239a803 refactor(subscription): 按评审收窄「不要杜比视界 Profile 5」——去掉智能设置开关，只留规则组「DV P5」芯片
c8fd296b9 feat(apple,android,harmonyos,desktop): 跟上「不要杜比视界 Profile 5」——智能开关与规则组芯片
6ab814fc7 fix(android): 修 CI lint 错误（Camera 的 ExperimentalGetImage opt-in、CAMERA 权限补 uses-feature）
ec621c305 fix(android): 按评审修自动选连鉴权、竞速超时与下载失败/取消（PR #1001）
e189a8dcc feat(android): 平板适配与 iOS 端功能对齐（离线下载、扫码登录、设置页、小幕）
18bd86c69 fix(auth): show Windows pairing as computer app login on the web
7a203e0bd fix(auth): preserve old-server decoding in generated native models
```

文件差异汇总： 127 files changed, 19470 insertions(+), 901 deletions(-)。


## Android TV

基线 `androidtv-v0.6.0` → `a4559c65d`。路径：`apps/android-tv`, `apps/android-core`。

```text
1c338b4ad fix(i18n): CI fixes for lint, generated Kotlin models and older-host plugin installs
7123ffb76 feat(i18n): add locale foundation and account language flow
c22d62c23 fix(androidtv): 主页键深链交还页面焦点——播放器/侧栏移除后没人接（评审 #1018）
5cbc0bf46 feat(androidtv): 海报屏保 S1——待机轮播「继续观看」剧照（androidtv-mc-screensaver.md S1）
3e7cae965 feat(androidtv): 深链 movieclaw://home——桌面壳的主页键直达首页根部
d4bc852b4 feat(playback): 硬件转码给能解的客户端出 HEVC（#1008 第二步）
173e1c4af perf(androidtv): 照 Apple TV 优化详情页、海报行与「接下来继续」的滑动
18bd86c69 fix(auth): show Windows pairing as computer app login on the web
7a203e0bd fix(auth): preserve old-server decoding in generated native models
c6b729e00 fix(androidtv): 网络回调触发的首页重试不再被半路取消
e59f6254f fix(androidtv): 开机时网络晚到，首页等网络连上就自己重试
```

文件差异汇总： 22 files changed, 871 insertions(+), 172 deletions(-)。


## Windows

基线 `windows-v0.1.1` → `a4559c65d`。路径：`apps/desktop`。

```text
c8fd296b9 feat(apple,android,harmonyos,desktop): 跟上「不要杜比视界 Profile 5」——智能开关与规则组芯片
```

文件差异汇总： 1 file changed, 1 insertion(+), 1 deletion(-)。


## Web

基线 `v0.42.0` → `a4559c65d`。路径：`apps/web`, `plugins/netflix`, `pnpm-lock.yaml`, `package.json`。

```text
a4559c65d Integrate main's Windows transcoder with localized remote-worker text
3fbfe4f5c Integrate main's row-level deep links with localized plugin and notification text
1c338b4ad fix(i18n): CI fixes for lint, generated Kotlin models and older-host plugin installs
abe53c67f fix(i18n): requests without Accept-Language keep Chinese
65b73507c Integrate origin/main: localize newly merged Web, Apple and server text
ce1854a1a test(i18n): web genre parity reads Apple's String Catalog; quote accessibility covers English quotes
237cceb23 feat(i18n): web welcome quotes follow the interface language from the shared Apple quote data
b44e260eb fix(i18n): use reader-language list separators in missing summaries and source warnings
273eddaa0 feat(i18n): localize AI handoff, plugin fallback, schema placeholders and upload errors
4b87bc941 feat(i18n): localize route titles and accessible profile labels
cf52126b3 feat(i18n): localize cross-library walls and recent summaries
5a233b62a feat(i18n): localize Agent media cards and refresh reader data
49d8575e4 feat(i18n): localize library reports with stable rule identities
7fed332b7 feat(i18n): localize manual source annotation without changing tiers
dff4be03f feat(i18n): localize search preferences and preserve named scopes
987c96cbd feat(i18n): localize playback settings and verify worker configuration
ee6df7b1e feat(i18n): localize MCP management and verify authenticated clients
4b90a2154 feat(i18n): localize home customization without persisting display names
c32da2ecf feat(i18n): localize duplicate decisions while preserving version identities
526ea27b5 feat(i18n): localize recycle controls and verify file recovery
fc8b4a31b feat(i18n): render recycle snapshots without changing grouping facts
8788ad40c feat(i18n): localize IM channel management and owned binding flows
b2ff2cfea feat(i18n): localize notification preferences and retain stable group identities
06475d755 feat(i18n): localize push relay management and preserve neutral diagnostics
7304e4085 feat(i18n): localize cloud pairing and render connection failures per reader
3da8712c3 feat(i18n): localize owned plugin metadata with source provenance checks
6d4dd6b1c feat(i18n): localize plugin details and preserve declared author metadata
d02808255 feat(i18n): localize plugin package approval and installation management
9e5b65843 feat(i18n): localize plugin marketplace browsing and permission summaries
54d62997f feat(i18n): localize plugin overview and web consent management
fc19b1a9c feat(i18n): localize plugin status and isolate feature catalogs by language
9b1f34662 feat(i18n): localize automatic import configuration and folder selection
68a5790a4 feat(i18n): localize cloud drive setup and restore theme navigation
adcf35ecc feat(i18n): localize site setup and retain verification provenance
0bec88cde feat(i18n): localize downloader setup and preserve error references
b99f4bdb2 feat(i18n): preserve automatic session title and skill instruction provenance
c84c50195 feat(i18n): localize agent session interactions and tool summaries
bd62fafac feat(i18n): translate model providers and persist localized connection errors
b36dbf7e8 feat(i18n): translate AI preferences and verify search configuration
4868b1161 feat(i18n): translate update controls and render progress per reader
ba64472ba feat(i18n): translate Webhook controls and verify real signed deliveries
e06c92cd5 feat(i18n): localize scheduled tasks and preserve runtime scheduling
57576fa42 feat(i18n): translate log controls and preserve raw daily files
659a27d2a feat(i18n): translate storage snapshots and verify real cleanup
711ae9a7a feat(i18n): translate network settings and verify port restarts
bb372f7d7 feat(i18n): translate member access and credential workflows
fbeeb29fc feat(i18n): translate device management and pairing grants
82f85dc39 feat(i18n): translate account switching and startup recovery
a91f74cf8 feat(i18n): translate watch statistics and responsive charts
56181b298 feat(i18n): localize live viewing and playback histories
84f434f21 fix(i18n): classify playback executors independently of labels
6d9669560 feat(i18n): translate task timelines and boost cleanup flows
5dc1a38e4 feat(i18n): localize shared job cards and action receipts
d57cc5c71 feat(i18n): translate pipeline health checks and rule previews
b741d54ec feat(i18n): localize subscription home calendars and walls
a18a91663 feat(i18n): localize subscription inspector and search histories
14976af65 feat(i18n): render subscription lifecycle histories for each reader
2b46f80de feat(i18n): localize subscription adjustments and season cleanup
2a5db11b1 feat(i18n): localize subscription forms and season selection
6281027dd feat(i18n): localize quality upgrade confirmation and reports
d8d62939e feat(i18n): localize cancellation previews and verify file recycling
b752b9b5d feat(i18n): localize smart settings and reader-specific subscription preferences
00fda7f28 feat(i18n): localize rule sets and preserve seeded name provenance
cca827951 feat(i18n): localize download destinations and routing previews
d8cb0916b feat(i18n): localize search results and reader-specific diagnostics
e1a8b820b feat(i18n): localize search palette and preserve custom history labels
e46889714 feat(i18n): retain semantic search scopes across history and cached runs
01a103e2c feat(i18n): localize subtitle generation and persisted job diagnostics
50266667f feat(i18n): localize subtitle preview and timing calibration
b6b578b61 feat(i18n): localize sharing visitor pages and artwork selection
57cb8d2ea feat(i18n): localize identification and filename organization
b942995b8 feat(i18n): localize item details tracks and file operations
dee0859ba feat(i18n): localize collections favorites and galleries
5bf153861 feat(i18n): localize library browsing and filters
b6faf8c3d feat(i18n): localize library forms and metadata configuration
bdc681c3d feat(i18n): localize library management and operation confirmations
bc83412ef feat(i18n): translate content browsing, discovery and library home
9e7bee7a5 feat(i18n): translate Apple playback and engine diagnostics
ac60204aa feat(i18n): translate web playback controls, tracks and diagnostics
415e57efc feat(i18n): translate web navigation and subscription views
5ea469162 feat(i18n): add locale formatting, Apple catalogs and quality gates
7123ffb76 feat(i18n): add locale foundation and account language flow
c58ea3266 feat(windows): MovieClaw 转码器（Windows）——把 NAS 的硬件转码交给 NVIDIA 显卡 (#1014)
56d2e2523 feat(web): ?task=/?event= 行级深链——目标页滚到那一行并短暂高亮
f1179cca7 chore(deps): 用 pnpm 10 重做 javascript-security 依赖升级（替代 #1010）
92cb54a39 feat(subscription): 订阅窗口按季状态分流——在播长剧订最新 N 集并照常追新
83ea329d7 feat(subscription): 订阅上限——一季上千集时先订阅前 N 集，之后一键继续
51095440e fix(plugins): 插件能力表每行都带「查看」——通知行说明收订在「账号 → 通知」（附浏览器验收）
d4bc852b4 feat(playback): 硬件转码给能解的客户端出 HEVC（#1008 第二步）
fd63d0729 style(web): Netflix 媒体库 hero 底部渐变换八段缓动，文案块上移
8d239a803 refactor(subscription): 按评审收窄「不要杜比视界 Profile 5」——去掉智能设置开关，只留规则组「DV P5」芯片
146502aa2 feat(web): 设置页「不要杜比视界 Profile 5」开关与规则组「DV P5」芯片，附浏览器验收
18bd86c69 fix(auth): show Windows pairing as computer app login on the web
e3557c81d refactor(player): simplify scaling controls and align ASS with video
410acc586 fix(player): reset stale display selections and stabilize CI clock test
d9208218d feat(player): add reversible video display modes on iOS and web
79eaadb8d feat(plugins): 插件市场详情显示下载量与反馈入口
903dba4ed fix(player): 锁定的文件只对进入播放页的那一集生效，并还原混进来的无关颜色替换
a4d04368c fix(player): 详情页点播放只在用户亲手选过版本时才锁定文件
407962701 fix(web/theme): iPhone 系统转横屏不再被当成电脑——主题按设备类取，而不只看页面宽度
ef105d1e4 fix(player): 进度条阴影两端横向淡出，消除亮画面下的垂直硬切线
4f91880b6 chore(deps): 用 pnpm 10 重做 javascript-security 依赖升级（替代 #956）
```

文件差异汇总： 463 files changed, 54837 insertions(+), 11100 deletions(-)。


## CLI

基线 `v0.42.0` → `a4559c65d`。路径：`cli`, `src/movieclaw_api`, `scripts/export-spec.sh`。

```text
a4559c65d Integrate main's Windows transcoder with localized remote-worker text
3fbfe4f5c Integrate main's row-level deep links with localized plugin and notification text
abe53c67f fix(i18n): requests without Accept-Language keep Chinese
65b73507c Integrate origin/main: localize newly merged Web, Apple and server text
df157886c fix(i18n): native DROP COLUMN in today's downgrades, legacy GitHub scope values; record the English walkthrough and final regression
5380d8ded fix(i18n): genre tiles and fixed job subjects render in the reader's language (found in the English iOS walkthrough)
5351be098 feat(i18n): finish the server ratchet: localize remaining validation, device, TMDB setup and verification texts; mark developer-facing strings
758899ab2 feat(i18n): localize request validation texts (site paths, LLM, subscriptions, addresses, agent input), key site availability and spec errors; mark plugin-facing errors
9c23a2f16 feat(i18n): key subtitle extraction failure reasons, transcoder revocation and webhook test samples; exempt built-in plugin titles; mark plugin-facing texts
a5f994520 feat(i18n): localize downloader input and discovery reference errors; key GitHub update scopes; mark job/sync developer diagnostics
921d75b18 feat(i18n): localize IM image notices and default attachment names; key agent run error fallbacks; mark model-facing agent texts
b94cdafe0 feat(i18n): key smart-submission file selection errors; mark ratio boost ledger notes and submit logs as non-UI
9dd12f0b3 feat(i18n): localize the offline password reset command by terminal language, falling back to the administrator's UI language
758da6303 feat(i18n): localize IM binding notes, pairing receipts in the binder's language, channel errors and dead-letter replay errors
c34cd8124 feat(i18n): localize settings validation messages; key the egress service catalog; treat setting-domain titles as code labels
74866dd80 feat(i18n): localize source removal preview, skip reasons and job results
a2dca09d5 feat(i18n): localize offline export errors, activity lines and manifest labels; keep failure references in export state
9334f9c48 feat(i18n): localize push alerts, outcomes, plugin rule labels and status episode labels; mark internal push texts
8be8d4b0b feat(i18n): localize Reels facets and clip precut job texts; mark diagnostics and track-title tokens
a1c6de79c feat(i18n): localize metadata refresh phases, image tallies, job progress and release schedule activity
da28a6da1 feat(i18n): localize plugin declarations, switches, safe mode and callback lookups; guard builtin metadata
f6d467ed7 feat(i18n): localize plugin market errors and compatibility reasons
38d04bb7e feat(i18n): localize plugin package validation, approval, dependency and rollback messages
a0ecf644f feat(i18n): localize cloud storage errors, uploads and replica failures; guard storage directory texts
81fbf129f feat(i18n): localize remaining route texts, worker handshake (WebSocket locale) and recycle labels
a61adaf60 feat(i18n): localize subtitle generation pause, labels and actor; keep prompts and diagnostics as source text
5c1fc5dfd feat(i18n): localize playback diagnostics, hardware probe, remote worker and strm probe texts
232b8f04f feat(i18n): localize spec audit, matching rejection notes and identity explanations; mark forecast logs
a0851917d feat(i18n): localize subscription dispatch, upgrade, cleanup and smart submission texts; add job subject references
55362ac7e feat(i18n): localize download attempt notes, replacement activity and task center rescue texts
17c102d4b fix(i18n): keep watch import pilot notes parameter-compatible across locales
c995a8561 feat(i18n): localize watch import conclusions, progress and job texts
8c4f1699d feat(i18n): localize remaining library service messages
3e0da7ae0 feat(i18n): localize library scan, re-identify and cloud folder messages
d42de9351 feat(i18n): derive library rollback texts from catalog keys (duplicates, origins, parsers)
718bdf92b feat(i18n): localize intro/credits detection job messages
ff23b36a8 feat(i18n): localize library transfer, batch transfer and chapter job messages
ee6df7b1e feat(i18n): localize MCP management and verify authenticated clients
c32da2ecf feat(i18n): localize duplicate decisions while preserving version identities
fc8b4a31b feat(i18n): render recycle snapshots without changing grouping facts
8788ad40c feat(i18n): localize IM channel management and owned binding flows
285826cdf feat(i18n): carry declared channel metadata across plugin runtimes
b2ff2cfea feat(i18n): localize notification preferences and retain stable group identities
06475d755 feat(i18n): localize push relay management and preserve neutral diagnostics
7304e4085 feat(i18n): localize cloud pairing and render connection failures per reader
3da8712c3 feat(i18n): localize owned plugin metadata with source provenance checks
7917bfea5 feat(i18n): render plugin capabilities after stable deduplication
6d4dd6b1c feat(i18n): localize plugin details and preserve declared author metadata
fc19b1a9c feat(i18n): localize plugin status and isolate feature catalogs by language
9b1f34662 feat(i18n): localize automatic import configuration and folder selection
68a5790a4 feat(i18n): localize cloud drive setup and restore theme navigation
adcf35ecc feat(i18n): localize site setup and retain verification provenance
0bec88cde feat(i18n): localize downloader setup and preserve error references
b99f4bdb2 feat(i18n): preserve automatic session title and skill instruction provenance
938b36294 feat(i18n): preserve model stream errors across readers and notifications
bd62fafac feat(i18n): translate model providers and persist localized connection errors
b36dbf7e8 feat(i18n): translate AI preferences and verify search configuration
4868b1161 feat(i18n): translate update controls and render progress per reader
ba64472ba feat(i18n): translate Webhook controls and verify real signed deliveries
e06c92cd5 feat(i18n): localize scheduled tasks and preserve runtime scheduling
659a27d2a feat(i18n): translate storage snapshots and verify real cleanup
711ae9a7a feat(i18n): translate network settings and verify port restarts
fbeeb29fc feat(i18n): translate device management and pairing grants
a91f74cf8 feat(i18n): translate watch statistics and responsive charts
56181b298 feat(i18n): localize live viewing and playback histories
84f434f21 fix(i18n): classify playback executors independently of labels
5dc1a38e4 feat(i18n): localize shared job cards and action receipts
d57cc5c71 feat(i18n): translate pipeline health checks and rule previews
62039fb9b feat(i18n): render smart selection explanations with rollback-safe state
a18a91663 feat(i18n): localize subscription inspector and search histories
14976af65 feat(i18n): render subscription lifecycle histories for each reader
6281027dd feat(i18n): localize quality upgrade confirmation and reports
b752b9b5d feat(i18n): localize smart settings and reader-specific subscription preferences
00fda7f28 feat(i18n): localize rule sets and preserve seeded name provenance
cca827951 feat(i18n): localize download destinations and routing previews
d8cb0916b feat(i18n): localize search results and reader-specific diagnostics
e1a8b820b feat(i18n): localize search palette and preserve custom history labels
e46889714 feat(i18n): retain semantic search scopes across history and cached runs
01a103e2c feat(i18n): localize subtitle generation and persisted job diagnostics
50266667f feat(i18n): localize subtitle preview and timing calibration
e4d18e19c feat(i18n): persist identification reasons and candidate evidence
57cb8d2ea feat(i18n): localize identification and filename organization
b942995b8 feat(i18n): localize item details tracks and file operations
dee0859ba feat(i18n): localize collections favorites and galleries
5bf153861 feat(i18n): localize library browsing and filters
b6faf8c3d feat(i18n): localize library forms and metadata configuration
bc83412ef feat(i18n): translate content browsing, discovery and library home
8d7aeed77 feat(i18n): localize operation responses and playback activity
8098cdd73 feat(i18n): localize subscription history and playback decision messages
a2d2ae0a4 feat(i18n): localize API errors, stored notices and plugin metadata
5ea469162 feat(i18n): add locale formatting, Apple catalogs and quality gates
7123ffb76 feat(i18n): add locale foundation and account language flow
c58ea3266 feat(windows): MovieClaw 转码器（Windows）——把 NAS 的硬件转码交给 NVIDIA 显卡 (#1014)
fc28ac518 fix(plugins): 定时任务行的定位键改用任务 key——第三方贡献 id 带「插件id:」前缀
df22779e4 feat(plugins): 能力表「定时任务」「会发通知」行的查看直达具体那一行
92cb54a39 feat(subscription): 订阅窗口按季状态分流——在播长剧订最新 N 集并照常追新
83ea329d7 feat(subscription): 订阅上限——一季上千集时先订阅前 N 集，之后一键继续
b04094efd fix(plugins): 能力表通知行未获批不再自相矛盾；拆超长断言过 ruff（评审 #1019）
51095440e fix(plugins): 插件能力表每行都带「查看」——通知行说明收订在「账号 → 通知」（附浏览器验收）
d4bc852b4 feat(playback): 硬件转码给能解的客户端出 HEVC（#1008 第二步）
c91912b4d fix(playback): QSV / NVENC 强制关键帧显式出 IDR，分片切回 4 秒栅格
e0c9559e7 fix(offline): HEVC 导出中途卡一下不再整份改 H.264 重转
f43c4115a feat(offline): NAS 显卡（VAAPI/QSV/NVENC）离线导出出 HEVC
8d239a803 refactor(subscription): 按评审收窄「不要杜比视界 Profile 5」——去掉智能设置开关，只留规则组「DV P5」芯片
9cb1948ab feat(subscription): 杜比视界 Profile 5 可以不要——判定、规则组「DV P5」与智能设置开关
35d8c047a fix(ingest): 内容无法识别的文件归待处理，不再当环境故障每小时重试 (#1006)
18bd86c69 fix(auth): show Windows pairing as computer app login on the web
7a203e0bd fix(auth): preserve old-server decoding in generated native models
3ec41bb24 feat(auth): support Windows app devices and advertise native login kinds
455fada90 fix(subscription): 中文季集命名可选择性下载，确定性失败不留孤儿任务、不无限重试
b114b3b3f fix(downloads): 任务中心去向与真实投递同口径选库，未定格库的订阅不再误报不会入库
1b73cb1de feat(playback): add playback.sync.state host op for two-way sync write-back
d46a24bcb feat(playback): 杜比视界 P5 落到读不了 RPU 的本机显卡时，诊断的判定理由说明偏色原因与出路
d1473c51a fix(playback): VAAPI 对全范围（pc）源起播即崩——硬件缩放转成 limited，帧标签写 range=tv
af934b55a fix(cli): 把插件市场截图接口登记为不生成命令
79eaadb8d feat(plugins): 插件市场详情显示下载量与反馈入口
2058487a8 fix(playback): retain imported watches across identity changes
03429db09 feat(playback): add permission-scoped watch history exchange APIs
41a44f6bb fix(sites): 站点代请求不跟随跳转、标为危险操作，并让 CLI 守卫过关
c2e288b32 feat(sites): 站点代请求 site.proxy.request——插件借宿主已认证会话访问站点，凭据不出宿主
ced7badf0 fix(playback): 分片断连按 session_id 登记到会话，断开后又有动静就不提前回收
c7a285482 fix(playback): 页签直接关闭时提前回收转码会话，并给 Windows 补上 killpg 兜底
```

文件差异汇总： 384 files changed, 34441 insertions(+), 5686 deletions(-)。


## Windows 转码器（首次发布）

基线 `v0.42.0` → `a4559c65d`。路径：`windows/MovieClawTranscoder`。

```text
c58ea3266 feat(windows): MovieClaw 转码器（Windows）——把 NAS 的硬件转码交给 NVIDIA 显卡 (#1014)
```

文件差异汇总： 28 files changed, 4914 insertions(+)。


## 浏览器扩展

基线 `v0.42.0` → `a4559c65d`。路径：`apps/extension`。

```text
无路径提交差异。
```

文件差异汇总：无差异。


## Netflix 主题

基线 `v0.42.0` → `a4559c65d`。路径：`plugins/netflix`, `src/movieclaw_sdk/theme.py`。

```text
68a5790a4 feat(i18n): localize cloud drive setup and restore theme navigation
ac60204aa feat(i18n): translate web playback controls, tracks and diagnostics
415e57efc feat(i18n): translate web navigation and subscription views
a2d2ae0a4 feat(i18n): localize API errors, stored notices and plugin metadata
f1179cca7 chore(deps): 用 pnpm 10 重做 javascript-security 依赖升级（替代 #1010）
fd63d0729 style(web): Netflix 媒体库 hero 底部渐变换八段缓动，文案块上移
4f91880b6 chore(deps): 用 pnpm 10 重做 javascript-security 依赖升级（替代 #956）
```

文件差异汇总： 12 files changed, 151 insertions(+), 99 deletions(-)。


## HarmonyOS（无正式发布；仅以上次服务器 tag 作开发参考）

基线 `v0.42.0` → `a4559c65d`。路径：`apps/harmonyos`。

```text
c8fd296b9 feat(apple,android,harmonyos,desktop): 跟上「不要杜比视界 Profile 5」——智能开关与规则组芯片
```

文件差异汇总： 2 files changed, 23 insertions(+)。


## NER 模型

基线 `torrent-ner-v3` → `a4559c65d`。路径：`ml`。

```text
无路径提交差异。
```

文件差异汇总：无差异。

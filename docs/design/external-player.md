# 外部播放器：把原文件交给 PotPlayer / IINA / Infuse / VLC 播放——设计（第一期）

> 状态：**后端已实现；网页 UI 第一期预览已实现（2026-11-20），scheme 参数待实机核对**；第二期待维护者拍板。代码基线 `ca1118d0f`。
> 关联：[web-player.md](web-player.md) §4.7（取流签名 token，本文直接复用）、
> [media-share.md](media-share.md)（分享访客，本文明确不给）、
> [library-access.md](library-access.md)（库可见范围与内容分级）、
> [activity.md](activity.md)（活动页，第二期的落点）、
> [jellyfin-compat.md](jellyfin-compat.md)（能同步进度的那条路）。

## 0. 一句话定义

**登录的成员在详情页 / 分集卡片上点「用外部播放器打开」，服务端签一条只授权这一个原文件、
12 小时有效的绝对地址，网页把它交给本机的 PotPlayer / IINA / Infuse / VLC / MX Player / MPV，
或复制下来自己粘贴。不转码、不建播放会话、不同步进度。**

## 1. 背景与目标

- 网页播放器受浏览器解码能力所限：HEVC、杜比视界、TrueHD / DTS 音轨、PGS 字幕、
  大码率原盘镜像，要么转码（吃 NAS 算力）、要么放不了。本机装了 PotPlayer、IINA、
  MPV 的用户更愿意直接用它们放原文件——画质、音轨、字幕全在本机处理。
- 社区里的做法是油猴脚本 embyLaunchPotplayer（[bpking1/embyExternalUrl](https://github.com/bpking1/embyExternalUrl)，
  MIT）：在 Emby / Jellyfin 详情页加按钮，拼出 `potplayer://…`、`iina://…` 这类地址拉起
  本机播放器。**本文只参考它的思路**（按钮位置、各播放器的 URL scheme），不搬代码。
  它的问题在凭据：地址里拼的是**长期 api_key**（等同账号密码，不过期、不限文件），
  地址会留在剪贴板、播放器的历史记录、甚至被同步到云端——泄漏一次就是整个库对外敞开。
  本文改用**短期、单文件**的签名 token（§3）。
- 已经有一条「外部播放器」的正路：Jellyfin 兼容层（jellyfin-compat.md）。Infuse、VidHub、
  SenPlayer、Fileball 这类播放器把 movieclaw 当 Jellyfin 服务器添加，浏览、播放、进度
  同步都由播放器自己做。本文**不取代**它，补的是另一类场景：PotPlayer / IINA / MPV / VLC
  这些不认 Jellyfin 协议的「纯播放器」，以及「临时在别的机器上看一集」不想添加服务器的人。

目标：

1. 一个登录态接口签出外部播放器能直接打开的绝对地址（含可用的文本字幕地址）；
2. 授权面与网页播放完全一致，不多给一分：同样的可见性判据、同样的 token 体系；
3. 不在活动页、播放记录、观看状态里留下假的网页播放；
4. 网页 UI（第一期后续 PR）用这个接口拉起六种常见播放器，并在协议未注册时有兜底。

## 2. 接口

`POST /api/v1/playback/external-link`（登录区，`require_login`；`operation_id=playback.external-link`，
`x-cli-hidden`）。

请求（`PlaybackExternalLinkRequest`）：

| 字段 | 说明 |
|---|---|
| `media_item_id` | 条目 |
| `season_number` / `episode_number` | 播放单元，缺省 `(0, 0)` 即电影——与 `/progress`、`/resume` 同一表达 |
| `file_id` | 可选：指定版本。必须是这个播放单元的在位文件，否则 404 |

不收 `device_id`：设备标识写进 token 的唯一作用是把取流登记成网页的实时会话（活动页），
而外部播放器恰恰不该被登记成网页播放（§2.4）。

响应（`PlaybackExternalLinkView`，ApiResponse 信封）：

| 字段 | 说明 |
|---|---|
| `file_id` | 实际选中的文件 |
| `stream_url` | 绝对地址 `…/api/v1/playback/files/{id}/stream/{文件名}?token=…` |
| `subtitles[]` | `{track, label, language, format, url}`：只列文本轨，默认轨排第一 |
| `title` | 「片名 (2024)」或「剧名 S01E02」，读者语言的片名 |
| `file_name` | 清洗过的文件名（与地址末段一致） |
| `container` | 台账容器 |
| `start_ms` | 续播点 |
| `duration_ms` | 片长（与观看状态的分母同口径，`unit_runtime_ms`） |
| `expires_at` | token 到期时刻（UTC） |

### 2.1 选文件

- 给了 `file_id`：只在这个单元的在位、可见文件里找，找不到 404（另一部片、另一集、
  看不到的库，一律与「不存在」相同）。
- 没给：与**全解码客户端开会话**的结果一致——外部播放器什么都能解，所有版本都落在档 0，
  `plan._best` 的同档决胜规则就是取分辨率最高的那份。原盘目录给不了外部播放器
  （§2.2），同一单元还有别的版本时不挑它。
- 续播点与开会话同一规则：有续播点就接着播（看完时续播点已清零，所以「看完 → 0」自然成立）。

### 2.2 拒绝情形

| 情形 | 应答 | 理由 |
|---|---|---|
| 原盘目录（BDMV / VIDEO_TS） | 409 `errors.playback.externalDiscFolder` | 目录不是一个文件，没有一条地址能代表它；网页与 App 各有目录直推 / 换封装的路 |
| strm 写坏了（读不出可用地址） | 404 `errors.playback.strmUnavailable` | 与直出端点同一道检查；地址给出去也只会 404 |
| 不可见（库范围、内容分级） | 404 | 与开会话同一组判据，不区分「没有」与「看不到」 |
| 分享访客 | 403 `errors.playback.externalLinkMembersOnly` | §2.3 |

**ISO 放行**：光盘镜像是**一个文件**，直出端点原样出原字节（disc-direct-play.md §2.3），
PotPlayer、VLC、MPV、Infuse 都能自己读镜像里的盘内结构。能放的就不拦。
正常的 strm（网盘直链、指向挂载目录的本地文件）与只在网盘上的文件也放行：直出端点
本来就会 302 到直链或由家里转发。

### 2.3 权限

- 登录的超管与成员都能要；可见性与开会话（`_decide`）同一组判据：`assert_item_visible`
  （分享范围 + 内容分级）+ `visible_library_ids` 过滤在位文件。
- **分享访客不给**。分享主体本就进不了 `require_login`（只由分享路由的依赖产出），处理函数
  里再显式拒一次 403，防止以后有人把它挂到分享路由下：访客的 token 受分享有效期与「取消
  分享」约束，地址一旦交给外部播放器、留进它的历史，就脱离了分享页的管控，超管在
  活动页也看不到它。

### 2.4 不建播放会话

接口只签 token，不碰播放链路的任何状态：不起转码会话、不记 QoE「已开始」、不写
`playback_state` / `playback_log`、不登记活动页实时会话。token 不带浏览器设备标识，
直出端点的 `_register_play_stream` 因此不计量这一路（与升级前签出的旧 token 同一分支）。
外部播放器不回报进度，记了只会在活动页挂一条永远「正在播放」的假会话、在播放记录里
留一条零进度的假记录。

### 2.5 绝对地址

外部播放器不在浏览器的源里，相对地址对它毫无意义，所以全部给绝对地址。源取**这次请求
浏览器实际用的地址**：`X-Forwarded-Host` / `X-Forwarded-Proto`（容器内 nginx 总会带上，
多级代理取最外层），没有再取 `Host` 与本层协议——与 Jellyfin 兼容层对外地址的回落同一取法，
再经 `server_addresses.normalize_url` 规范化；拼不出合法地址时退回 `request.base_url`。

为什么不用「外部访问地址」设置或访问地址簿：用户此刻在浏览器里用的地址，才是**同一台
设备**上的播放器一定连得上的那个——在家用内网 IP 打开网页，拿到的就是内网地址；在外面
用域名打开，拿到的就是域名。设置里的外部地址在家里可能绕公网甚至不通（NAT 回环）。
复制链接发给别的设备时，用户自己知道那台设备连哪个地址。

### 2.6 文件名段

`GET /playback/files/{file_id}/stream/{filename}` 是 `/stream` 的别名，**同一个处理函数**——
处理函数根本不收 `filename`，取哪个文件只看 `file_id` 与 token。IINA、Infuse、VLC 拿地址末段
当片名显示，没有它就是一串「stream」。生成时取真实文件名的 basename，去掉路径分隔符、
控制字符与 `..`，URL 编码；strm 换成它指向的容器后缀；取不出就用 `video.<容器>`。

直出端点本来只认 GET（FastAPI 不给 GET 路由自动加 HEAD），别名保持一致；若实测某个播放器
先发 HEAD 探测，再给两条一起加。字幕地址沿用 `/subtitles?track=…&format=…&token=…`，没有加
文件名段（播放器加载外挂字幕时不显示它的名字）。

### 2.7 字幕

清单来自开会话同一个函数（`plan_subtitles`，默认轨策略 `track_context`）：

- 文本轨（外挂 srt、内封 SubRip / mov_text / WebVTT）→ `format=srt`：外挂 srt 原样、内封文本轨
  抽出来本来就是 srt，哪个播放器都认；
- ASS / SSA 特效轨 → 原格式（转格式会丢样式）；
- PGS / VobSub 等位图轨 → 不列：外部播放器从原文件自己读内封轨，外挂 .sup 的支持参差不齐。

## 3. 安全

- **token 只授权单文件**：复用 `issue_stream_token`，范围 = 成员 id + 文件 id，同一部片的
  另一个版本也取不了。字幕地址用同一个 token（同一个文件）。
- **12 小时**，与网页播放同一个 `STREAM_TOKEN_TTL_S`。不能太短：外部播放器每次拖动、缓冲
  续拉都是新的 Range 请求，三小时的片子中间不会回来换地址；也不能长到「泄漏出去还能用一年」。
- **轮换登录密钥即失效**：取流 token 用登录会话的签名密钥 + 独立 salt 签名，「全端下线」
  一并作废所有在途地址。
- **外部标记**：token 负载多一个 `"x": 1`（`StreamGrant.external`）。授权范围不变，只让以后的
  取流统计分得清这一路（第二期按它登记「外部播放器」会话）。旧 token 没有这个键，按 `False`。
- **地址会留痕**：剪贴板、播放器的「最近播放」、甚至播放器的云同步里都会留下这条地址。
  12 小时内拿到它的人能看这一个文件。UI 在「复制链接」旁提示「链接 12 小时内有效，
  请勿分享给他人」；需要长期给别人看，用分享功能（可设密码、可随时取消）。
- **绝不用长期凭据**：地址里不放 Jellyfin 设备令牌、登录 Cookie、PAT 或任何长期密钥。
  这正是相对油猴脚本的核心改进。
- **文件名段只做显示**，不参与寻址（§2.6）；`..`、`%2F` 之类要么 404（路由不匹配）、要么
  仍是这个文件的字节——守护测试逐个覆盖。
- 日志只记 `file_id` 与主体名，不记 token（诊断上报另有 `_DIAGNOSTIC_SECRET_RE` 脱敏）。

## 4. 第一期网页 UI（后续 PR）

### 4.1 入口

- 详情页播放键旁加下拉箭头：「用 ××× 打开」（本机默认播放器）+ 其余播放器 + 「复制链接」；
- 分集卡片的 ⋯ 菜单加同样一组。
- 点击时现调 `POST /playback/external-link`（token 不预取，不在页面上长期挂着）。

### 4.2 第一期播放器与 URL scheme

下表的 `URL` 指 `stream_url`，`SUB` 指首条字幕的 `url`，`enc()` 是 `encodeURIComponent`。
各 scheme 参数以各播放器文档为准，**合入 UI 前逐一实机核对**（尤其起播位置与字幕参数）。

| 播放器 | 平台 | 拉起方式 | 字幕 / 续播 / 标题 |
|---|---|---|---|
| PotPlayer | Windows | `potplayer://` 协议；参数多时走剪贴板方式：把 `URL /sub=SUB /seek=秒 /title="标题"` 写进剪贴板，再拉起 PotPlayer 让它从剪贴板打开 | `/sub` `/seek` `/title` |
| IINA | macOS | `iina://weblink?url=enc(URL)` | 字幕需在播放器里手动加载（或下一期研究 IINA 的命令行参数） |
| Infuse | iOS / iPadOS / tvOS / macOS | `infuse://x-callback-url/play?url=enc(URL)&sub=enc(SUB)` | `sub`；不同步进度（同步请走 Jellyfin 兼容层） |
| VLC | 桌面 | `vlc://URL`，需用户另装 vlc-protocol 一类协议处理器（VLC 桌面版自身不注册） | — |
| VLC | Android | `intent:URL#Intent;package=org.videolan.vlc;type=video/*;S.title=标题;end` | — |
| VLC | iOS | `vlc-x-callback://x-callback-url/stream?url=enc(URL)&sub=enc(SUB)` | `sub` |
| MX Player | Android | `intent:URL#Intent;package=com.mxtech.videoplayer.ad;type=video/*;S.title=标题;i.position=毫秒;end`（专业版 `com.mxtech.videoplayer.pro`） | `i.position` 续播 |
| MPV | 桌面 | `mpv-handler://play/{base64url(URL)}/?subfile={base64url(SUB)}`，需用户安装 [akiirui/mpv-handler](https://github.com/akiirui/mpv-handler) | `subfile` |
| MPV | Android | `intent:URL#Intent;package=is.xyz.mpv;type=video/*;end`（mpv-android） | — |
| 复制链接 | 全平台 | 复制 `stream_url` | — |

- **按本机系统过滤**：只列当前平台装得上的（按 UA / `navigator.userAgentData` 判 Windows / macOS
  / iOS / Android），复制链接永远在。
- **本机默认播放器存 localStorage**：下拉里选过一次，播放键旁直接显示「用 IINA 打开」。
  跟设备走、不跟账号走——同一个账号在 Mac 上用 IINA、在 Windows 上用 PotPlayer。
- **协议未注册时浏览器没有任何反应**（不报错、拿不到失败回调），所以拉起后统一弹提示：
  「没有打开？可能没装 ×××，或浏览器拦截了；也可以复制链接手动打开」+ 复制按钮。
- 提示「**外部播放器不同步进度，看完请点「标记已看」**」（第二期之前）。
- Infuse / VidHub / SenPlayer / Fileball 的入口旁引导「添加为 Jellyfin 服务器，可同步进度」，
  链到设置里的 Jellyfin 兼容说明。

### 4.3 实现备注（2026-11-20 网页 UI 预览）

本轮网页 UI 预览已按上表落地（原表格保留），与 §4.1–§4.2 原设计有以下明确偏差与约定：

1. **平台识别仅用 UA + `maxTouchPoints`**：只解析 `navigator.userAgent` 并结合 `navigator.maxTouchPoints`（`Macintosh` 且 `maxTouchPoints > 1` 按 iOS/iPadOS 处理），不依赖 `navigator.userAgentData`。后者仅 Chromium 支持，且浏览器测试/模拟改 UA 时不会同步变化。
2. **Android Intent 采用 Chrome 标准式**：生成 `intent://<host><path><query>#Intent;scheme=<http|https>;type=video/*;package=<pkg>;S.title=…;end`（仅 MX Player 在 `start_ms > 0` 时追加 `;i.position=<ms>`），不使用上表的宽松写法 `intent:URL#Intent…`，避免不同浏览器对 `Intent.parseUri` 兼容不一致。
3. **PotPlayer 本期仅用直链，不做剪贴板模式**：仅使用 `potplayer://<stream_url>`，不传 `/sub`、`/seek`、`/title`，也不在拉起前自动写入剪贴板——剪贴板模式会静默覆盖用户剪贴板、异步请求后剪贴板写入常被浏览器拦截、且多参数格式尚未实机核对。字幕统一通过结果面板的「复制字幕链接」手动加载作为 fallback。
4. **字幕与续播参数保守收敛、协议待实机核对**：仅保留上表列出的参数（Infuse `sub`、VLC iOS `sub`、mpv-handler `subfile`、MX Player `i.position`），其余播放器均标注为不自动加载字幕 / 可能从头播放，并在结果面板提供字幕链接复制的手动 fallback。所有播放器的 URL scheme 及参数均**待实机逐一核对**后再作为正式行为锁定。
5. **手势激活与拉起兜底**：点击后异步调用 `POST /playback/external-link`（不预取 token）；仅在用户激活仍有效（`navigator.userActivation.isActive`，缺失时按 1 秒窗口估计）时通过临时隐藏 `<a href>` 触发拉起。若激活已过期则不自动拉起，改为弹出结果面板并提供真实 `<a href>` 按钮供用户重新触发手势。无论是否自动拉起，均弹出结果面板兜底（含「再试一次」、只读视频链接、字幕链接复制及 HTTP 内网 / 剪贴板受限时的手动全选复制 fallback）。
6. **Jellyfin 兼容层引导**：设置页当前没有独立的「Jellyfin 兼容说明」分区，本期仅在 Infuse 结果面板内展示一行纯文字提示，不挂跳转链接，待设置分区补齐后再补链。
7. **「全部分集」宫格（`EpisodeCell`）未加独立菜单**：分集 ⋯ 外部播放器菜单仅挂在横滚分集卡片（`EpisodeCard`）上；长季的「全部分集」数字宫格（`EpisodeCell`）保持紧凑选集，不加独立菜单，可选集后使用上方主入口（或回到横滚分集卡的 ⋯ 菜单）。

## 5. 第二期：按取流字节估算进度（待维护者拍板）

外部播放器不回报进度，但服务端看得到它取了哪些字节。思路：

- 带外部标记的 token 取流时，在活动页登记一条「外部播放器」会话（成员、条目、文件、UA）；
- 连接空闲 / 关闭后，用 **最后读取的字节偏移 ÷ 文件大小 × 片长** 估算播放位置，写续播点；
  超过阈值（如 90%）记已看。

不准的地方（必须先想清楚）：

1. **拖动**：Range 跳读，偏移代表的是「跳到哪」而不是「看到哪」；
2. **预读 / 缓冲**：播放器读得比播得快几十秒到几分钟；MKV 的 Cues、MP4 尾部的 moov 在文件末尾，
   起播时一次尾部读取就会让偏移瞬间到 100%；
3. **暂停**：连接可能挂着不动，也可能被播放器关掉重连；
4. **多路并发 Range**：一个播放器同时开主读取、尾部预读、字幕预读几路；
5. **码率不均**：字节比例 ≠ 时间比例，动作戏与对话戏码率差几倍；
6. **302 到网盘直链**：服务器根本看不到字节；
7. **多人同一链接**：链接被复制到两台设备，字节流混在一起。

缓解：

- 取「持续顺序读取」的最大连续偏移，而不是最后一次请求的偏移；
- 忽略文件尾部的小块读取（索引、moov）；
- 按时间与读取速率平滑：读得远快于码率的那段视为预读；
- **只写续播点、不轻易写已看**——或写已看前在网页上请用户确认；
- 302 直链的情形不估算。

这一期要不要做、做到哪一步（只登记活动页 / 写续播点 / 写已看），需要维护者拍板。

## 6. 不做

- 给 MPV / IINA 写回报进度的辅助脚本（Lua / 插件）——维护面太大，且 Jellyfin 兼容层已经是
  能同步进度的那条路；
- 分享访客入口（§2.3）；
- 插件形态（这是播放链路的基础能力，不放进可卸载的插件）。

## 7. 测试与验收

`tests/api/test_playback_external_link.py`，端到端按用户真实流程走：网页登录 → 要链接 →
把返回的绝对地址原样交给「外部播放器」（测试客户端，**不带登录 Cookie**）取字节、拉字幕。

- 电影主路径：200、绝对地址带文件名段、token 验签通过且只授权这一个文件、约 12 小时、
  外部标记为真、不带设备标识；整取与 Range 取回原文件字节；HEAD 与老地址一致；
- 文件名段：任意名字、中文、`..%2F..%2Fetc%2Fpasswd`、`..`、`%2e%2e` 要么 404 要么仍是这个文件；
- token：取不了另一个文件（含同一部片的另一个版本）、改一个字节失效、过期失效；
  旧 token（无外部标记）照常验签；
- 源地址跟随 `X-Forwarded-Host` / `-Proto`，畸形时退回本层地址；
- 剧集单元、默认取最高分辨率、显式 `file_id`、别的集 / 别的条目的文件 404；
- 续播点来自观看状态；
- 外挂 srt 列出且地址可取（SRT 格式）；PGS 不列；
- 原盘目录 409 且文案正确；同一单元有普通文件时默认不挑原盘目录；ISO 放行且可取；
- strm 写坏 404、正常 strm 的地址 302 到直链；
- 未登录 401；成员看不到的库 404；超过内容分级 404；分享主体 403；
- 调接口并取流之后：没有播放会话、没有观看状态 / 播放记录 / QoE 记录、活动页没有会话与取流。

守护测试同步登记：`test_auth.py` 公开白名单加别名路由（只凭 token）、`test_member_auth.py`
成员白名单加接口与别名路由。

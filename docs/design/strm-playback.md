# 网盘（strm）条目的播放：与本地文件同等体验——设计

> 状态：已实现（2026-10-11）。源起：issue #601（「增加播放器播放 strm 302 能力」）。
> 同日补：strm 内容兼容（服务器本地路径、编码容错、内网 302 服务替播放器跟跳转，§1.1、§7.1），
> 源起用户反馈 CloudDrive2 挂载路径的 strm 被拒。
> 关联：[web-player.md](web-player.md)（本文撤销其 §0.2 硬边界 2）、
> [jellyfin-transcode.md](jellyfin-transcode.md)（撤销 §0 第 3 条的 strm 部分）、
> [strm-workflow.md](strm-workflow.md)（strm 怎么进媒体库）。

## 0. 问题

此前 strm 条目只允许直连：取流 302 到网盘直链，播放器自己解。App（自研引擎全解码）、
Infuse / VidHub 没问题；网页播放器遇到浏览器解不了的编码（MKV 容器、DTS / TrueHD /
AC3 音轨、老编码）就落到「网盘条目不支持转码播放」的错误页。

原理由是「转码要先把云端内容拉到服务器，消耗大量网盘流量」。这一条不成立：浏览器直连
同样从网盘读这些字节，两种方式都只读实际播放的部分，网盘侧的消耗基本一样。服务端中转
真正多出来的是服务器的带宽（网盘 → 服务器、服务器 → 播放器）与转码算力——和播放本地
文件是同一回事。2026-10-11 决定撤销这条硬边界：网盘条目的播放体验与本地文件一致，
直推、换封装、转码都支持，不再为流量设限。

## 1. 总体

strm 只是「源在网盘」，播放链路的每一环都按本地文件做，只在**读源**这一层分叉：

| 环节 | 本地文件 | strm |
|---|---|---|
| 规格（编码、时长、音轨、字幕） | 扫描时 ffprobe 落库 | 扫描不碰网盘；**第一次播放时**按需探测直链并落库（§2） |
| 决策 | 判定引擎 | 同一套判定；只有探测不到规格时乐观直连（§3） |
| 档 0 直出 | FileResponse + Range | 302 到网盘直链；内网 / 回环 / 容器服务名的直链由服务端按 Range 转发（§7.1） |
| 档 1～4 会话 | ffmpeg `-i 路径` | ffmpeg `-i 直链` + 协议白名单 + 断线续读（§4） |
| 关键帧索引（VOD 列表） | 读 Cues / moov | 同样的读法，按 HTTP Range（§5） |
| 远程 Worker 取源 | NAS 按 Range 出字节 | 取源接口 302 到直链，Worker 直接从网盘取（§4） |
| 内封字幕 / 字体 / 缩略图 | ffmpeg 读文件 | ffmpeg 读直链（§6） |
| Jellyfin 限码率转码 | 协商 + master.m3u8 | 同样协商（先按需探测） |

strm 有两层含义，代码里分开：

- **「云端条目」策略**看 `is_strm(file_path)`（按扩展名，不读文件）：扫描不探规格、不做整片
  通读的后台活（刷片预切、整片抽字幕、ffprobe 通读关键帧）。指向挂载目录的本地路径也守这条——
  挂载背后多半是网盘，通读就是把整片拉一遍；
- **「字节在哪」**看 `streaming.parse_strm` 的结果（§1.1）：`StrmLink`（远端地址 + 请求头）或
  `Path`（本地视频文件）。直出、ffmpeg 输入（`media_input` / `strm_source_input`）、按索引稀疏读
  （`open_strm_range`：远端 `RemoteRangeFile`、本地 `LocalRangeFile`，接口相同）都只在这里分叉。

读源的入口是 `streaming.media_input(file_path)`：本地文件返回路径本身；strm **每次**
现读文件（直链多带时效签名，seek 重启也重读）——本地路径给真实文件，直链附上 `strm_input_args`：

- `-protocol_whitelist http,https,httpproxy,tcp,tls,crypto,rtsp,rtp,udp`：直链来自库里的
  文本文件，远端若回一份清单，ffmpeg 默认会照着打开里面写的地址——不放行 `file`，就读不到
  服务器本地文件。`httpproxy` 必须在：环境里设了 `http_proxy` 时 ffmpeg 经它连 http 地址
  （本机端到端实测，漏了它所有直链都读不了）；
- http(s) 加 `-reconnect` 系列与 `-rw_timeout`：网盘 CDN 中途断开是常态。

缓存指纹、失败记忆、实时进度等仍按 strm 文件本身（路径 + mtime）记——strm 内容变了
（换了直链）指纹自然变。

### 1.1 strm 里能写什么（`streaming.parse_strm`）

2026-10 调研了 Emby / Jellyfin / Kodi / Infuse 怎么读 strm、国内各家生成工具（alist / OpenList、
CloudDrive2、AutoFilm、MoviePilot 的 P115StrmHelper / P123StrmHelper / CloudStrm、qmediasync、
p115nano302、SmartStrm、Symedia、CMS）实际写进去什么，按并集兼容：

- 取第一个非空、非 `#` 开头的行（`#EXTM3U` / `#EXTINF` / `#KODIPROP` 都跳过）；UTF-8 容忍 BOM
  与 CRLF，读不成 UTF-8 的按 GB18030（Windows 中文工具）；
- `http/https/rtsp/rtp://`：远端地址，**原样保留不重新编码**——各家写法五花八门（原样中文与空格、
  逐段编码、整段编码的 `%2F`、签名里的 `=:`、`+` 当空格、`http://host:8000?pickcode=` 没有路径、
  `user:pass@host`），都要原样交给对端。请求头的两种 Kodi 写法见 §9；
- 不带 `scheme://` 的是**服务器本地路径**（CloudDrive2 / rclone 挂载；Emby、Kodi 支持，Symedia、
  CMS 本地模式、CloudStrm 本地模式、qmediasync 本地驱动、P115StrmHelper 接管挂载都这么写）：绝对
  路径、`file://`（主机只能空或 localhost）、相对 strm 所在目录的路径（Kodi 写法）；原样找不到时按
  URL 解码后再找一次（有的工具把路径编码了写）。解析到真实位置（展开软链）后必须是**存在的普通
  文件、扩展名是视频**（媒体库视频扩展名 + iso），否则拒绝；
- 其余一律拒绝并给出原因（日志、开会话 / 取流的错误信息、探测失败原因都是这句话）：`smb://` /
  `nfs://`（请先挂载到服务器）、`rtmp://`、Windows 路径（`D:\`、`\\NAS\`）、`redirect115&…`
  这类只有某个 302 反代认识的伪地址、挂载掉线找不到文件。

本地路径的安全边界：strm 能写任意路径就成了任意文件读取。Jellyfin 10.11.7 因一条「上传字幕路径
穿越写出 strm → 指向数据库读出 → 提权」的漏洞链（GHSA-j2hf-x4q5-47j3，9.9 分）整个禁掉了本地路径；
我们不禁，但只认视频文件——数据库、密钥、系统文件都过不了（软链改名成 .mkv 也一样，判的是解析后
的真实文件）。不限定在媒体库目录里：挂载目录本来就在库外。

不做路径映射：容器里看到的挂载路径必须与 strm 里写的一致（docker 按同一路径映射挂载目录），
对不上时错误信息直接说「容器里的路径与 strm 里写的不一致」。

## 2. 按需探测（`services/playback/strm_probe.py`）

- 时机：决策前（`plan.decide_for_files`，网页与 App 共用）与 Jellyfin `PlaybackInfo`。
  扫描不探：一个库几千个 strm，逐个请求直链会触发网盘的风控。提前探交给官方插件「网盘规格预探」
  （[plugin-strm-prefetch.md](plugin-strm-prefetch.md)）：后台限速逐个补探，开始播放、收藏、打开
  详情时让相关条目插队——详情页因此也会探这一个条目（2026-10-11 撤销了「详情页不探」）；
- 内容：`probe_media(直链)`，只读文件头与索引（实测 MKV / MP4 各 0.1 秒、一两 MB）；
  容器先看直链路径的扩展名，看不出按 ffprobe 的 `format_name` 映射（`strm_container`）；
- 落库：与扫描、补探同一批规格列，`container` 从 `strm` 改成真实容器。在独立短会话里提交，
  再以「已提交」状态写回调用方的对象，调用方会话不留脏字段；同一文件并发探测合成一次；
- 失败：不改规格，决策退回乐观直连（§3）；一分钟内不重探，免得同一次播放的降档重试每次都
  白等一轮超时。失败另记进 `strm_probe_state`，后台预探按 1 小时 → 6 小时 → 1 天 → 3 天退避，
  首播不受退避限制；
- 改写：扫描（手动扫描、监控点名）发现 .strm 变了就重读直链，主机或路径变了清空规格待重探，
  只换签名参数规格照旧（plugin-strm-prefetch.md §4）。

## 3. 决策

`decide.py` 不再有 strm 硬分支。`_unprobed_strm`（strm 且 `video_codec` 为空）是唯一的
特殊情形：无从判断，档 0 乐观直连；档 0 失败后拒绝，提示检查直链或改用第三方播放器——
服务端连规格都读不出，换封装 / 转码也无从谈起。探测到规格的 strm 与本地文件完全同档：
画质上限、PGS 烧录、降档回路一视同仁。

## 4. 转码会话与远程 Worker

- 本机：`session._local_command` 识别 strm 源，换成直链与输入选项；直链不合法报
  `SessionStartError`（开会话时 503 带原因，seek 重启时按「拿不到分片」处理）；
- 远程 Worker：取源地址仍是 NAS 的 `/transcode-worker/sessions/{id}/source`，strm 时
  302 到直链。Worker 的取源代理（URLSession）与 ffmpeg 都跟随跳转，跳转后 Range 照带
  （本机用 Swift 脚本对仿网盘服务验证过：跟随 302 后仍是 206）。Worker 端零改动、
  旧版 Worker 兼容，字节不经 NAS。

## 5. 关键帧索引（`keyframes.py` / `remote_range.py`）

VOD 列表（web-player.md §12）的直通档要全片关键帧表。`RemoteRangeFile` 是只读、可 seek
的 HTTP 文件，每次读发一个 Range 请求（至少取 64 KB，留最近一块），不认 Range 的服务器
直接报错，绝不顺着把整片读下来：

- Matroska：读头部与 Cues，三四个请求、一两百 KB；
- MP4 / MOV：读 moov，并按 Range 抽检 16 个关键帧样本（本地是 128 个），4 路并发——
  家用的直链服务（alist 一类）监听队列可能很浅，8 路并发在仿网盘服务上实测会被重置连接；
- 其余容器（TS 等）没有索引可读：返回 None，换封装档退回会话相对模式；不做后台通读；
- 读不出的结论按 (strm 路径, mtime, 大小) 记十分钟，开会话、估关键帧间隔不再重复请求。

关键帧间隔（决定能否直通）也只读索引，**不做码流采样**——三段各 30 秒的码流从网盘现拉，
4K 片是几百 MB、起播前白等十几秒。读不出索引就按未知处理：不直通，改转码。

## 6. 字幕、字体、缩略图

- 内封字幕：MKV 按字幕索引只读字幕块（[subtitle-cues.md](subtitle-cues.md)，一集几 MB、几秒）；
  没有索引的整轨抽取与片段窗口抽取读直链，占位文件看不出体积，通读上限直接给封顶值；
- 字体附件：顺带修了 `-f null` 输出会把整片解码一遍的问题（加 `-t 0`，附件在打开输入时
  就写出了）——本地文件省一次通读，网盘条目不再为字体把整片拉下来；
- 进度条缩略图：网盘条目**不通读**（Jellyfin 对 strm 直接跳过）。按 MKV 索引只取每 10 秒之前
  最近的一个视频关键帧（`subtitle_cues.build_keyframe_mkv`），拼成只含视频轨的小 MKV 再出雪碧图；
  先取第一帧量出关键帧体积，其余按它的 1.5 倍探测。实测老友记一集 467 MB 只读 12 MB。
  不是 MKV、没有索引就没有预览；本地文件照旧按 4 倍实时通读。

## 7. 网页播放器

- 直出断线后探片源用 `redirect: "manual"`：取流 302 到网盘时看到的是跳转，算「取得到」，
  不跟过去探网盘（跨域的网盘地址不给 CORS，跟过去只会报错，以前会一路退避到「连接中断」）；
- 直出的是网盘直链且同档重开用完：**降档**，由服务端读直链换封装 / 转码。浏览器连不上
  网盘（直链是内网地址、https 页面里的 http 直链）不等于服务器连不上。

### 7.1 内网直链：先替播放器跟跳转，出不去才转发（`streaming.strm_redirect_target`）

内网地址多半不是片子本身，而是一个 302 服务（MoviePilot 的 P115StrmHelper、p115nano302、
qmediasync、alist 115 存储的 `/d/`）：它只负责换出网盘 CDN 直链。整条流都转发会把片子全压在
服务器上行上（NAS 常见上行只有几 MB/s）。所以直出时先由服务端**带着播放器自己的 User-Agent**
（115 一类直链与 UA 绑定）替它跟跳转（带 `Range: bytes=0-0`，只取响应头，最多 5 跳）：跳到播放器
连得上的地址就把播放器 302 过去，片子不经服务器——go-emby2openlist、MediaWarp 一类 302 反代同一
思路；一路都是内网、或者内网服务自己出字节（alist 本地存储的 `/p/`、CD2 的 `/static`）、或者连不上，
才按下面转发。strm 写了请求头、地址里带账号密码的不跟跳转，直接转发（播放器不会带这些头，浏览器
拒绝带凭据的媒体地址）。

服务端自己读源（探测、换封装 / 转码、读索引）不受影响：ffmpeg 与 `RemoteRangeFile` 都自己跟跳转，
用的是自己的 UA，同一次读取里前后一致。

#### 转发（`streaming.strm_needs_relay` / `RemoteRelayResponse`）

MoviePilot、alist 一类工具常把 strm 写成 `http://127.0.0.1:5244/d/...`、`http://alist:5244/d/...`
或 `http://192.168.x.x/...`：只在服务器所在的网络里连得上，302 给外网的浏览器、电视、Mac 转码器
就是连不上。这类地址（回环、私网、链路本地、100.64/10、单标签与 `.local` / `.lan` 等主机名）
不再 302，由服务端按播放器的 Range 原样转发（不起 ffmpeg，借鉴 Jellyfin 的
`GetStaticRemoteStreamResult`）；公网地址照旧 302，服务器零流量。

- 只看地址本身，不看请求方：容器桥接网络里看到的客户端地址常常都是网关，靠它分内外网不可靠；
  局域网里的播放器多走一跳服务器，代价只是局域网带宽；
- 覆盖全部取流入口：网页直出、Jellyfin 的 `/Videos/{id}/stream` 与下载、远程 Worker 取源；
  Jellyfin 的 PlaybackInfo 把这类版本按本地文件呈现（Protocol=File），播放器就会走服务端取流；
- 与磁盘直出同一套断连检测、停止信号与活动页计量；上游一律 GET（预签名直链常常只签了 GET），
  HEAD 只回头；上游不走代理；
- 播放器换成服务端拿字节，客户端一行不改——App、Android TV 的「连不上网盘」也一并解决；
- strm 里写了请求头的直链同样转发（见 §9 请求头）。

## 8. 验证

单测：`tests/playback/test_strm_playback.py`（仿网盘 HTTP 服务：302 + 只认 Range；真
ffmpeg / ffprobe 的用例标 integration）、`test_decide.py` 的 strm 段、
`tests/api/test_playback_stream.py`（302、换封装会话读直链、Worker 取源跳转）、
`tests/jellyfin/test_transcode.py`（限码率转码读直链）、活动页、失败策略表。

端到端（2026-10-11，本机仿网盘服务 + 真 Chrome + 隔离后端，四部 TMDB 识别的条目）：

| 场景 | 结果 |
|---|---|
| MP4 H.264/AAC | 档 0，浏览器经 302 直接从网盘取流；首播探测 0.1 秒；拖动正常 |
| MKV H.264 + AC3 5.1 + 内封中文字幕 | 档 2（视频直通、AC3→AAC），VOD 列表（Cues 经 Range 读出），内封字幕从直链抽出并显示，拖动 3 秒内恢复 |
| MKV 1080p，播放器画质上限 480p | 档 3 VideoToolbox 转码，854×480，拖动正常 |
| MKV MPEG-2（浏览器解不了） | 本机 Homebrew ffmpeg 的 VideoToolbox 硬解不了 MPEG-2，硬件档失败——同一文件放本地库**同样失败**，与 strm 无关；软件转码命令直接读直链从 60 秒起转产出正常 |
| 直链是内网地址（浏览器连不上、服务器连得上） | 档 0 失败 → 自动降到档 1 由服务端中转，VOD 列表（moov 经 Range 读出），续播点接着放，拖动正常 |
| Jellyfin（Infuse 形态）限 2 Mbps | PlaybackInfo 给 TranscodingUrl，档 3 转 480p，首段与中段分片正常 |

兼容矩阵（`tests/api/test_strm_compat.py`）：起一个仿网盘生态的 HTTP 服务——alist `/d/`（115 存储
302 到 CDN、本地存储 302 到自己的 `/p/`）、CD2 `/static`（整段编码路径）、P115StrmHelper / P123StrmHelper /
p115nano302 / qmediasync 的 302、SmartStrm 的 Basic 认证（带质询头）、与 UA 绑定且会过期的网盘
CDN——按 §1.1 每种写法走真实取流 / 探测接口：内网 302 服务都把播放器送到 CDN 且服务端问路时带的是
播放器的 UA、播放器拿着 CDN 地址用自己的 UA 能取到字节（换个 UA 403）；自己出字节的服务转发；公网
地址原样 302 不重编码；各种编码 / 格式；本地路径六种写法按本地文件直出、换封装时 ffmpeg 直接读挂载
文件；十几种该拒绝的内容逐条给出原因、读不到密钥与数据库；过期直链的探测失败原因是「HTTP 403，请
重新生成 strm」；真 ffprobe 按每种写法读出规格；本地路径 strm 的关键帧 / 字幕块按索引读与本地文件
一致。Jellyfin 侧（`tests/jellyfin/test_http_flow.py`）：本地路径的 PlaybackInfo / 取流 / HEAD /
下载，内网 302 服务的取流 302。

真实进程端到端（2026-10-11，隔离后端 + 仿网盘生态 + 真扫描「其他」库）：14 种写法（9 种工具形态的
地址 + 本地绝对路径 / `file://` / 相对路径 / BOM+CRLF / GB18030）在「全解码播放器直出」（ffprobe
带 Infuse 的 UA 当播放器）与「浏览器换封装」（ffmpeg 拉 HLS）两条链路全部播放成功、首播探出规格，
扫描期间对网盘零请求；4 种该拒绝的给出原因。同一脚本对照改动前的代码：本地路径类 5 种全部失败、
拒绝原因一律是「网盘直链无效」，302 服务从没见过播放器的 UA（整片经服务器转发）。

## 9. 已知边界

- App（iOS / Mac / Apple TV）声明全解码，网盘条目照旧直连；Android TV 与网页一样按
  真实规格换封装 / 转码。内网直链由服务端转发（§7.1），各端都连得上；公网直链对某个播放端
  不可达时，只有网页会降档走服务端，App 与 Android TV 的失败策略未改；
- 请求头：strm 里按 Kodi 写法给的头（`#EXTVLCOPT:http-user-agent=…` / `http-referrer=…`
  行、地址后的 `|User-Agent=…&Referer=…`）会带给服务端的每一种读取（ffprobe / ffmpeg 的
  `-user_agent` / `-headers`、按 Range 读索引与字幕、转发），这样的直链一律由服务端转发
  （302 出去的播放器不会带这些头）。头名只收字母数字与连字符、值里不许有换行，防注入；
- 没有字幕索引的 MKV（片库约 2%）与 MP4 内封字幕，第一次选字幕仍要通读全片；
- 本地路径的 strm 直出时字节经服务器（挂载 → 服务器 → 播放器），与 Emby 不加 302 反代时一样。
  要让播放器直接连网盘，得把挂载路径翻译成直链（CD2 的 gRPC `GetMountPoints` + `GetDownloadUrlPath`
  能自动做到，302 反代靠手配前缀映射），留待有需要时再做；
- 服务端替播放器跟跳转不缓存结果：播放器每条 Range 连接都会问一次 302 服务（局域网内一次往返；
  302 服务自己多半有缓存）。

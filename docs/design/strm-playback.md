# 网盘（strm）条目的播放：与本地文件同等体验——设计

> 状态：已实现（2026-10-11）。源起：issue #601（「增加播放器播放 strm 302 能力」）。
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
| 档 0 直出 | FileResponse + Range | 302 到网盘直链（不变） |
| 档 1～4 会话 | ffmpeg `-i 路径` | ffmpeg `-i 直链` + 协议白名单 + 断线续读（§4） |
| 关键帧索引（VOD 列表） | 读 Cues / moov | 同样的读法，按 HTTP Range（§5） |
| 远程 Worker 取源 | NAS 按 Range 出字节 | 取源接口 302 到直链，Worker 直接从网盘取（§4） |
| 内封字幕 / 字体 / 缩略图 | ffmpeg 读文件 | ffmpeg 读直链（§6） |
| Jellyfin 限码率转码 | 协商 + master.m3u8 | 同样协商（先按需探测） |

读源的唯一入口是 `streaming.media_input(file_path)`：本地文件返回路径本身；strm **每次**
现读文件里的直链（直链多带时效签名，seek 重启也重读），附上 `strm_input_args`：

- `-protocol_whitelist http,https,httpproxy,tcp,tls,crypto,rtsp,rtp,udp`：直链来自库里的
  文本文件，远端若回一份清单，ffmpeg 默认会照着打开里面写的地址——不放行 `file`，就读不到
  服务器本地文件。`httpproxy` 必须在：环境里设了 `http_proxy` 时 ffmpeg 经它连 http 地址
  （本机端到端实测，漏了它所有直链都读不了）；
- http(s) 加 `-reconnect` 系列与 `-rw_timeout`：网盘 CDN 中途断开是常态。

缓存指纹、失败记忆、实时进度等仍按 strm 文件本身（路径 + mtime）记——strm 内容变了
（换了直链）指纹自然变。

## 2. 按需探测（`services/playback/strm_probe.py`）

- 时机：决策前（`plan.decide_for_files`，网页与 App 共用）与 Jellyfin `PlaybackInfo`。
  扫描与详情页不探：一个库几千个 strm，逐个请求直链会触发网盘的风控；
- 内容：`probe_media(直链)`，只读文件头与索引（实测 MKV / MP4 各 0.1 秒、一两 MB）；
  容器先看直链路径的扩展名，看不出按 ffprobe 的 `format_name` 映射（`strm_container`）；
- 落库：与扫描、补探同一批规格列，`container` 从 `strm` 改成真实容器。在独立短会话里提交，
  再以「已提交」状态写回调用方的对象，调用方会话不留脏字段；同一文件并发探测合成一次；
- 失败：不落库，决策退回乐观直连（§3）；一分钟内不重探，免得同一次播放的降档重试每次都
  白等一轮超时。strm 文件被改写时扫描会重新入账、规格清空，下次播放重探。

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
- 进度条缩略图：网盘条目**不生成**（与 Jellyfin 一致）。现有生成要按 4 倍实时把整片通读一遍，
  对网盘就是把整片拉下来；改成按关键帧索引稀疏取帧之后再打开。

## 7. 网页播放器

- 直出断线后探片源用 `redirect: "manual"`：取流 302 到网盘时看到的是跳转，算「取得到」，
  不跟过去探网盘（跨域的网盘地址不给 CORS，跟过去只会报错，以前会一路退避到「连接中断」）；
- 直出的是网盘直链且同档重开用完：**降档**，由服务端读直链换封装 / 转码。浏览器连不上
  网盘（直链是内网地址、https 页面里的 http 直链）不等于服务器连不上。

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

## 9. 已知边界

- App（iOS / Mac / Apple TV）声明全解码，网盘条目照旧直连；Android TV 与网页一样按
  真实规格换封装 / 转码。「直链对播放端不可达就降档走服务端」只在网页播放器做了，
  App 与 Android TV 的失败策略本次未改；
- 不支持按网盘要求定制请求头（如 115 要求的 User-Agent）：服务端 ffmpeg 用 `Lavf` UA，
  浏览器 / App 用各自的 UA，与以前一样；
- 没有字幕索引的 MKV（片库约 2%）与 MP4 内封字幕，第一次选字幕仍要通读全片。

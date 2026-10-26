# 蓝光按剪辑直推：服务端解析结构，安卓引擎只解复用

> 状态：已实现，模拟器（手机 API 36、电视 API 34）连本机测试服务器端到端验证通过（2026-10-15）；**未经安卓真机验证**。
> 起因：统一引擎（[android-app.md](android-app.md) §4）不认光盘，原盘与 ISO 都要 NAS 起 ffmpeg 换封装：
> 只留第一路视频、TrueHD 退成 AC-3 核心、PGS 字幕不进流，拖动要等服务端重新切片。
>
> 关联：[disc-direct-play.md](disc-direct-play.md)（iOS 自研引擎在本机解析光盘）、[disc-playback.md](disc-playback.md)
> （服务端选主片、ISO 区间、concat 换封装）。

## 1. 为什么不照搬 iOS

iOS 的引擎自己读 UDF / MPLS / CLPI / IFO、自己选主片。安卓再照做就是第三份选片逻辑（服务端 Python、引擎 Swift、安卓 Kotlin）：
服务端的进度、缩略图、跳片头、台账时长都按服务端选的主片算，客户端选得不一样就全错位。服务端本来就会选主片、算剪辑在
镜像里的字节区间、读 CLPI 的入口点表（远程转码 Worker 已经按「剪辑清单 + 每段一个取流地址」取源），所以：

**服务端给剪辑清单，安卓引擎只做 m2ts 解复用与拼接。**

## 2. 决策

- 新能力位 `bluray_clips`：只有统一引擎的**正片播放器**申报（`PlaybackController.sessionBody`）；刷片的片段播放器不认清单，
  不申报，所以不放进 `CapabilityProbe`。
- 蓝光原盘目录与蓝光镜像（`disc_format == "bluray"`，DVD 不算）在编码能直通时给档 0、`disc = "clips"`、带主播放列表名；
  解不了的编码（VC-1、播放器没有的音频编码）照常换封装 / 转码。编码判定与普通文件同一套。
- `pcm_bluray` 进音频能力（由引擎的 LPCM 读取器转成普通 PCM）。

## 3. 接口

- `GET /playback/files/{id}/bluray?token=`：主播放列表名；每段剪辑的取流地址、IN / OUT（45 kHz）、CLPI 入口点表
  （`entry_pts` 45 kHz、`entry_spn` 源包号）；音轨 / 字幕的 `embedded:N` 编号、PID、编码、语言、声道。
- `GET /playback/files/{id}/bluray/{index}?token=`：第 index 段剪辑的原字节（按 Range）。镜像里的剪辑由 `FileWindowResponse`
  把镜像上的几截拼成一个文件；照常记设备流与活动页。
- 两个接口都在公开取流区，只凭签名 token（与原文件直出、目录直推同一套），成员与分享访客共用。

**ISO 的规格**：ffprobe 读整个蓝光镜像多半什么流都认不出（NAS 上 46 个蓝光镜像视频编码为空，决策判断不了能不能直推）。
探测改读主片第一段剪辑在镜像里的字节（`subfile`），带上 PID 与 CLPI 语言；存量行在手动扫描时补探一次
（`container == "iso" and video_codec IS NULL`）。

## 4. 引擎（`apps/android-core/playback/.../disc/`）

1. **`M2tsDataSource`**：蓝光剪辑是 192 字节一包（4 字节到达时间戳 + 188 字节 TS），Exo 的 TS 解析器只认 188。按包去头、
   偏移换算；长度报「未知」，TS 解析器就不去文件尾估时长、不按时间二分定位。
2. **`BluRayClipExtractor`**：Exo 的 `TsExtractor`，外加
   - 时间戳不平移（`TimestampAdjuster.MODE_NO_OFFSET`）：样本时间就是剪辑里的 PTS，与 IN / OUT、入口点表同一口径；
   - 定位查服务端的入口点表（`IndexSeekMap`），一次按字节到位（续播起播也是）；
   - 轨 id 改写成服务端编号、补上语言（蓝光 PMT 里没有语言）；杜比视界增强层（0x1015）与画中画视频不出轨（只放 HDR10 基础层，
     与服务端换封装相同）。
3. **读取器**（Exo 不认的蓝光流，按 PES 处理——蓝光的这几种 PES 都按帧对齐）：
   - TrueHD（0x83）：同一个 PID 里 AC-3 核心与 TrueHD 交替；拆成两条轨（与服务端清单一一对应），TrueHD 每 16 个访问单元
     一个样本、主同步处起新样本，交 FFmpeg 解（无损）；
   - DTS-HD（0x85 / 0x86）：核心帧 + 扩展子流拼成一个样本，FFmpeg 的 dca 解码器解出无损；
   - LPCM（0x80）：去掉补齐的空声道、大端转小端；
   - PGS（0x90）：一组显示攒齐到 END 段成一个样本，Exo 的 PgsParser 解。
   - 注意：Exo 读 PMT 时见到「AC-3」注册描述符会把 0x83 / 0x84 改报成 0x81，TrueHD 的 PID 只能按服务端清单认。
4. **`BluRaySource`**：每段剪辑按 IN / OUT 裁好（`ClippingMediaSource`），首尾相接（`ConcatenatingMediaSource2`）。
   播放器位置就是播放列表时间，与服务端进度同一口径。
5. 清单取不到、或引擎放不了：按兜底阶梯改走服务端流（标掉档 0，服务端照旧换封装）。

## 5. 验证

- 服务端：决策（目录 / 镜像 / DVD / VC-1 / 未申报）、清单与剪辑取流（目录、镜像区间、越界、伪造 token）、ISO 探测改读剪辑、
  补探只捞 ISO 一次。
- 引擎单测（Robolectric）：去头的偏移换算；ffmpeg 封的蓝光样子的剪辑（H.264 + TrueHD + AC-3 + LPCM）过一遍解复用——
  编号、语言、绝对时间戳、入口点定位；四种读取器的边界（跨 PES 的单元、定位后半截的显示组、补齐声道）。
- NAS 真实盘片段（不入库）：TrueHD 96 kHz + AC-3 核心 + LPCM + 3 路 PGS、DTS-HD MA、4K HEVC 杜比视界 + TrueHD 全景声 +
  E-AC-3 + 13 路 PGS——全部轨读出、编号语言对上、增强层丢弃。
- 模拟器端到端（本机夹具服务器）：tsMuxer 生成的两段剪辑原盘与 ISO（H.264 + AC-3 + DTS + LPCM + PGS）、NAS 真实盘片段
  （稀疏文件，只放开头与 24 分钟处的真实字节）。起播、跨剪辑无卡顿、跨剪辑拖动、三种音轨切换各走对应解码器、PGS 字幕
  （合成盘与真实盘都显示、时间对）、真实盘按入口点续播到 14 分钟处；电视包同样通过。
- 未验证：安卓真机（硬解码器、透传给功放的 TrueHD / DTS-HD）、NAS 上的整盘长时间播放、交错存放（上千截）的镜像经 HTTP 的读取吞吐。

## 6. 不做

- VC-1（Exo 没有 VC-1 解析器，大多数设备也没有解码器）、DVD（VOB 里的 DTS / LPCM、VobSub 字幕 Exo 都不认），继续走服务端。
- 杜比视界双层（Profile 7）合成：只放 HDR10 基础层。
- PGS 跨显示组引用对象（epoch continue）：与 MKV 里的 PGS 同样的限制。

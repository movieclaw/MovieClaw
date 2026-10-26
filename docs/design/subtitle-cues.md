# 内封字幕按索引精确读取——设计

> 状态：已实现（2026-10-11）。关联：[strm-playback.md](strm-playback.md)（网盘条目的播放）、
> [web-player.md](web-player.md) §6.2（字幕旁挂）、`services/media_extract.py`（抽取的单飞、
> 缓存、失败记忆）。

## 0. 问题

内封字幕和音视频按时间交错存放在容器里，ffmpeg 抽一条字幕轨只能把整个文件从头读到尾。
本地 NAS 上一部 30 GB 的原盘要读五分钟；网盘（strm）条目更糟，等于为了字幕把整片从网盘
下载一遍。Jellyfin（`SubtitleEncoder.ExtractAllExtractableSubtitles`）、Emby（「播放时提取
字幕」）都是这么做的：前者一次读完抽出全部轨并缓存，后者在设置里提示「可能很慢、导致卡顿」。
两家都没有用容器索引。

## 1. 依据：mkvmerge 给每一条字幕都写了索引

Matroska 规范建议每个字幕帧都有一个 CuePoint（带 CueDuration）。mkvmerge 5.9.0（2012）
起默认这么写，并带 `CueRelativePosition`：Cluster 位置加块内偏移，直接定位到字幕块。

NAS 片库实测（2026-10-11）：

- 抽样 200 个带内封字幕的 MKV：195 个（98%）每条字幕轨都有索引，194 个带块内偏移；
  封装器 mkvmerge 192 个，其余是 XthorMerge、ffmpeg（Lavf）。没有索引的是 2010 年前后的
  老 mkvmerge 与个别 VobSub 轨。
- 抽查 4 个文件（4K、PGS、ASS、多字幕轨）：索引条数与全量数出的字幕包数逐轨一致。

## 2. 做法（`playback/subtitle_cues.py`）

1. 走一遍 Matroska 布局（复用 `container_index._matroska_layout`），读原 EBML 头、Info、
   Tracks、Cues（几百 KB）；
2. 每条字幕一个块：`Cluster 位置 + Cluster 元素头长 + 块内偏移`。元素头长取决于 Cluster
   长度字段的字节数：读第一个 Cluster 的头学到它，其余照用，某块按它解析不对再单独读那个
   Cluster 的头重算。按位置排序、相邻的合并成一次读、并发取回；每块先读 4 KB（PGS / VobSub
   读 64 KB，一块几 KB 到几十 KB，按 4 KB 探几乎每块都要补读），超出再补读；
3. 拼一个只含字幕轨的小 MKV：原 EBML 头、原 Info、只含字幕轨的 Tracks（TrackEntry 原样
   拷贝，CodecPrivate、压缩设置都在里面），每个块单独一个 Cluster，Cluster 时间戳取 CueTime、
   块内相对时间戳清零；
4. 交给 ffmpeg 转 SRT / ASS / SUP，命令与整片抽取同一套，只多两项：`-copyts` 与
   `-output_ts_offset -原片起点`。小 MKV 的起点是第一条字幕，不这么做转出的字幕会整体提前
   （PGS 实测偏了 93 秒）。

两处实测才发现的细节：

- **块按原文件位置排序，不按时间**：同一时刻常有好几个 PGS 显示集（一个清屏、一个显示），
  按时间排会打乱先后，结果对不上；
- **Cluster 时间戳不一定是第一个子元素**：ffmpeg 封装的 Cluster 先写 CRC-32。

字幕轨顺序与原文件一致，`-map 0:s:N` 的序号不变。任何一步对不上——没有 Cues、某条字幕轨
没有索引点、缺块内偏移、读出的块不是这条轨的——就返回 None，退回整片通读：宁可慢，不能错。

## 3. 接入（`services/media_extract.py`）

- 抽取批次先走按索引读取，成功即结束；失败（不记失败）再排队过全局闸门整片通读；
- 不过全局闸门：它只读几 MB，不和整片通读抢存储；
- **不随请求取消**：在独立任务里跑完、落进缓存。它很轻，网盘上却是几百个请求，播放器换轨、
  关页面就作废的话下次还得重来（Jellyfin 的字幕抽取同样不随请求取消）；
- 本地文件用 `pread` 16 路并发；网盘用 `RemoteRangeFile` 的连接池（keep-alive）16 路并发；
- 不是 MKV（MP4 的 mov_text 等）直接整片抽，不记日志。

## 4. 实测

NAS 本地片库，与整片 ffmpeg 抽取的产物逐字节比对，全部一致：

| 文件 | 体积 | 字幕 | 按索引 | 整片通读 |
|---|---|---|---|---|
| 千寻小姐（Remux） | 31.4 GB | 4 条 PGS | 12.8 秒 | 321 秒 |
| 绝命毒师 S04E08 | 22.6 GB | 4 条 PGS（mkvmerge 9.4） | 13.5 秒 | 233 秒 |
| 安多 S01E09（4K） | 6.7 GB | 28 条 SRT、2 万个块 | 4.2 秒 | 77.8 秒 |
| 绿色星球 S01E03（Remux） | 11.8 GB | PGS + SRT | 3.1 秒 | 109.7 秒 |
| 塔尔萨之王 S01E03（4K） | 2.6 GB | ASS + PGS + SRT | 3.5 秒 | 23.5 秒 |
| 鬼怪 S01E02（ffmpeg 封装） | 2.6 GB | 6 条 SRT | 2.9 秒 | 23.8 秒 |
| 老友记 S07E10 | 0.5 GB | 3 ASS + 2 SRT | 1.1 秒 | 5.3 秒 |

网盘（仿网盘服务，每个请求人为加 80 毫秒延迟）：老友记一集 479 MB、5 条字幕轨、1622 个块，
读了 3.7 MB、600 来个请求；8 路并发 17 秒、16 路 8.5 秒。浏览器端到端：网盘剧集开播后字幕
请求 8.9 秒返回，5 条轨一次落缓存，换轨 6 毫秒。

## 5. 边界

- 只覆盖 MKV。MP4 的 mov_text 很少见，仍整片读；
- 没有字幕索引（约 2%）仍整片读；
- 网页播放器的三种字幕渲染都是整份加载，网盘长片要等全部块取完（几秒到几十秒）才出第一条。
  若要「先出播放位置附近的字幕」，需要三种渲染器都支持增量，暂不做。

# 不要杜比视界 Profile 5

状态：**已实现**（2026-10-23；2026-10-24 按评审收窄为只有规则组一个入口）。判定在
`movieclaw_matcher/formats.py`，入口见 §3。

## 0. 问题与结论

杜比视界 Profile 5（P5）没有 HDR10 兼容层：基础层是 IPT-PQ-c2，读不了 RPU 的转码链路
（本机核显、网页端）会把画面转得偏绿偏紫，只能交给能处理杜比视界的转码器。P8 / P7 自带
HDR10 基础层，不支持杜比视界的屏幕放基础层就行，没有这个问题。

现状的缺口：规则组的 HDR 黑名单能拦 `DV`，但是整类——P8 / P7 一起被拦。

**结论：把 P5 单列成规则组 HDR 黑名单里的一个值。**

| 入口 | 位置 | 默认 |
|---|---|---|
| 规则组 | HDR 一行多一个「DV P5」芯片，只能排除（点一下排除、再点取消） | 不选 = 不限 |

默认不选：Apple TV、iPhone 等能原样播放 P5 的设备上，它反而是最好的版本，不能替用户拦。
规则组本来就是给懂行用户的高级能力，加一个只能排除的芯片不增加任何必经的选项。

**智能选择不加开关**（评审意见）：智能订阅的用户不该为了做决定先弄懂 Profile 5 与转码，智能订阅
保持干净、「把复杂留给产品」。后续方向是由产品自动判断——看有没有能处理杜比视界的转码器、常用
播放设备能不能直放 P5，自动降低 P5 的优先级（不是硬拦），用户无需设置；`is_dv_p5` 与
`attrs.site_labels` 就是为那一步留的底子，本 PR 不做。

## 1. 站点能给什么（2026-10-23 实测）

站点从不在标题里写 profile：NAS 上 M-Team 索引 26,532 条标题 / 副标题里 0 条（唯一像的是制作组名 `DVP8`）。
能用的是两条侧面证据：

1. **命名约定**：WEB 源（WEB-DL / WEBRip）只标 DV、没标任何 HDR10 兼容格式 → 单层 DV。光盘源
   （Remux / 蓝光）的 DV 是 P7 / P8；Hulu 是社区公认的例外（Radarr 的 TRaSH 规则同样排除）。
2. **站点标记**：M-Team 的 `labelsNew` 把 `DoVi` 与 `hdr10` / `hdr10+` / `hdr` / `hlg` 分开标，P5 只有
   `DoVi`。列表与搜索接口都带，不需要额外请求；MovieClaw 此前完全忽略它。

用 M-Team 详情接口（`/api/torrent/detail`，返回上传者贴的完整 MediaInfo）与入库文件的 ffprobe 核对，
共 20 次详情请求（站点建议约 100 次/小时）：

- 5 个有 ffprobe 真值的种子（P5×2、P8×2、P7×1）：MediaInfo 的 `dvhe.05 / 07 / 08` 5/5 吻合；
- 12 个「WEB 源 + 只标 DV」的种子（Netflix、Apple TV+、Disney+、爱奇艺、Amazon、国内平台，按制作组分散抽样）
  **全是 P5**；另 3 个 DV + HDR 的是 P8 / P8 / P7；
- 标题推断与 `labelsNew` 两条证据各自对这 15 个样本都 15/15 吻合。

所以不做 MediaInfo 确认：省掉每个疑似种子一次详情请求，也不需要新增数据库列和迁移。
（MediaInfo 里 P5 写作 `dvhe.05.06` / `dvhe.05.07`，老版本 MediaInfo 没有「Profile 5」字样；
将来给没有站点标记的 NexusPHP 系做确认时按 `dvhe\.0?5\.\d\d` 认。）

## 2. 判定

`is_dv_p5(attrs)`：同时满足才算——

- 标了杜比视界：标题里有 `DV`，或站点标记里有 `DoVi`；
- 没有 HDR10 兼容层的任何标记：标题里没有 HDR / HDR10 / HDR10+ / HLG / HDR Vivid，站点标记里没有
  hdr / hdr10 / hdr10+ / hlg / HDRVi；
- 片源是 WEB-DL 或 WEBRip，且不是 Remux；
- 平台不是 Hulu。

任何一条证据显示有兼容层就不拦——错的方向是少拦，不是错拦。片源不明、没有杜比视界标记都当作「不是」
（三态铁律：未知不当已知用）。站点标记存在 `attrs.site_labels`，由 `enrich(…, site_labels=)` 原样透传、
随观测落库；存量重算（`enrich_backfill`）会从旧 attrs 带回去，不会被抹掉。这一项不是提取逻辑，
没有 bump `ENRICH_VERSION`，部署后不会触发整库重算。

## 3. 入口

**规则组**：`hdr_block` 认 `DV P5`（也认 `DV-P5` / `DV_P5`）；写进白名单 `hdr_levels` 会被当未知值丢掉
并留一条日志。命中时拒绝原因是 `hdr_blocked` +「规则排除 …，该资源是只标了 DV、没有 HDR10 兼容层的杜比视界
（Profile 5），转码会偏色」，记在订阅详情的「排查记录」里。与「只要 DV」叠加 = 只要带 HDR10 兼容层的杜比视界。
芯片在 Web / iOS / Android / 鸿蒙 / 桌面的规则组编辑器里（Android 的编辑器是 `RuleSetsScreen.kt`）。

## 4. 兼容

- 规则组 spec 里多一个 `hdr_block` 取值：读取对未知值宽容，回退到旧版本时旧版直接忽略 `DV P5`
  （旧三态读到的是「不限」），没有迁移。
- `attrs.site_labels` 是新增的可选键，旧版本读 attrs 时忽略；`TorrentListItem.labels` 标了 `exclude`，
  搜索结果的条目输出字段不变（只多 `attrs.site_labels`）。
- 站点标记不是提取逻辑，没有 bump `ENRICH_VERSION`，部署后不会触发整库重算；存量重算
  （`enrich_backfill`）会从旧 attrs 把站点标记带回去，不会抹掉。

## 5. 没做的

- **智能选择里的开关 / 自动降优先级**：见 §0，由产品后续自动判断。
- **入库后 ffprobe 兜底**：标题与站点标记都漏掉的 P5 下完才知道，现在只在媒体库里看得到 `dv_profile`，
  不会自动换版本（换版本涉及下载器清理与做种保护，单独设计）。
- **MediaInfo 确认**：见 §1，M-Team 不需要；没有站点标记的 NexusPHP 系将来再说。
- **NexusPHP 系的站点标记**：主线版有「国语 / 中字 / HDR」等标签但默认没有杜比视界，各分支各异，未核实。
- **国语配音**：同一轮调研的结论是音轨认不准（简介「国语配音」会错、站点「中配」标记含粤语且会漏、
  MediaInfo 常没写语言、ffprobe 是 `und`），不在本次范围。

## 6. 验收

| 场景 | 位置 |
|---|---|
| 判定：15 个真实样本 × 三种证据（只看标题 / 标题 + 站点标记 / 只看站点标记）+ 边界表 | `tests/matcher/test_formats.py` |
| 规则组：拦 P5、放 P8、与 DV 白名单叠加、写法归一、旧版回退、站点标记纠正与补缺 | `tests/matcher/test_rules.py` |
| M-Team 列表解析 `labelsNew` | `tests/tracker/unit/test_mteam_labels.py` |
| 存量重算带回站点标记；搜索结果带 `attrs.site_labels` | `tests/enrich/test_backfill.py`、`tests/api/test_search.py` |
| 真实匹配链路：规则组跳过 P5 下 P8、对照组、只有 P5 时等待、站点标记纠正与补缺、同步管线落库 | `tests/api/test_avoid_dv_p5.py` |
| 浏览器：规则组芯片点选与回显、被跳过的原因出现在「排查记录」 | `tests/e2e/test_avoid_dv_p5_browser.py` |

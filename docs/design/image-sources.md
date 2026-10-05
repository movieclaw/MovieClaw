# 图片来源：接入 Fanart.tv

> 状态：已实现（2026-10-04）。交互样稿见 `docs/design/mockups/fanart-image-source-demo.html`。

## 1. 为什么接 Fanart.tv

成熟的刮削软件（Jellyfin、Emby、Kodi、tinyMediaManager、MoviePilot）在 TMDB 之外几乎都接了
Fanart.tv：社区维护的高清图库，**中文片名 Logo、季海报、无文字背景**往往比 TMDB 全。我们
此前只用 TMDB，片名 Logo 在 TMDB 没有对应语言时直接留空（详情页退回文字标题）。

一期只接海报、背景、片名 Logo、季海报四类——这四类三端客户端都有展示位。Fanart 独有的
clearart、碟面、横幅、角色图没有消费方，不做。

## 2. 产品口径（2026-10-04 拍板）

| 问题 | 结论 |
|---|---|
| 多来源时听谁的 | **语言优先，写死**：先按各类图的语言优先级逐档找，同一档两个来源都有图时才按来源顺序挑 |
| 来源顺序 | **按图片类型分开排**：默认海报、背景 TMDB 在前（TMDB 背景常有 4K），片名 Logo、季海报 Fanart 在前（中文更多） |
| 海报 | Fanart 也参与；海报「TMDB 默认」模式下 TMDB 只拿出它指定的那一张，和 Fanart 的海报按语言比（Fanart 没有更靠前语言的图时结果不变） |
| 默认开关 | **关** |
| API Key | **不内置**：用户在第一次用 Fanart 的地方（设置开关、库设置、换图弹层）就地填一次，验证通过才保存，全站共用；不单开配置页 |
| 片名 Logo 语言 | 开放成「片名 Logo」卡（以前写死在代码里），默认值即历史行为 |
| 存量条目 | 开启后在卡片里提醒用户自己去「刷新元数据」，不刷新就保持原样 |
| 季海报语言 | 跟随海报卡的语言优先级，不单开卡 |
| 换图弹层 | 填过 Key 就展示 Fanart 候选，**不看自动选图开关**（手动换图本身就是明确想用） |
| Key 失效 | 刮削跳过 Fanart、不影响 TMDB，日志写中文说明；设置卡显示「Key 已失效」，点开即重新填写 |
| 网络 | 「网络与代理」里单独一项「Fanart.tv」（出口标签 `fanart`），同时管接口与图床（图片代理按域名把 assets.fanart.tv 分给它），默认走代理；可达性由部署者决定 |
| iOS 设置页 | 二期跟进 |

## 3. 实现

**凭据**：`metadata.fanart` 配置域（`FanartSetting`），`api_key` 加密落库，另有 `key_invalid`。
单独成域而不是并进 `MetadataScrapeSetting`：后者整份下发前端、可按库覆盖，凭据放进去
要么泄漏要么到处打码。接口只回 `configured / key_invalid / key_hint`（末四位）：

- `GET /scrape/fanart`、`PUT /scrape/fanart`（先向 Fanart 真发一次请求，通过才保存；
  CLI：`mclaw scrape fanart show / set-key`）。

**偏好**：`MetadataScrapeSetting` 新增 `fanart_enabled`、四个 `*_source_order`、
`logo_language_priority`，都属条目态、可按库覆盖。来源顺序必须恰好是全部来源的一个排列
（「不用某个来源」走开关，不靠删顺序）。

**客户端**：`movieclaw_media/fanart.py`。电影按 TMDB 编号查，剧集按 TVDB 编号查（从 TMDB 详情
的 `external_ids` 取，用户无需配置）。响应归一化成与 TMDB images 同形的字典，`file_path`
是 Fanart 图床的**绝对地址**——与 TMDB 相对路径共用 `poster_path` 等列，出图处统一经
`tmdb_images.remote_image_url` 区分。2026-10-04 用真实 Key 核对过的响应要点：

- 每张图 `{id, url, lang, likes}`，`likes` 是字符串，季图多 `season`（数字串或 `"all"`，后者不收）；
- 无文字有 `""` / `"00"` / `"xx"` 三种写法；中文只有 `zh`；
- 没有宽高字段，按类型补标称规格：海报 1000×1426、背景 1920×1080、4K 背景 3840×2160、
  HD Logo 800×310、SD Logo 400×155（实测核对）；
- 图床地址是扁平的 `assets.fanart.tv/fanart/<名字>-<哈希>.<扩展名>`，`/preview/` 是缩略图；
- 查无此条目回 `200 {}`；Key 无效回 `401 {"error":"invalid API key"}`。

**选图**：`library.py` 的 `_pick_by_tiers` 加了来源维度——语言档 → 宽度门槛 → 来源顺序 →
来源内热度（TMDB 加权票数、Fanart 点赞；两种分数不跨来源比较）。没传 Fanart 时排序键退化为
历史行为，结果逐张一致；季详情只在启用 Fanart 时才顺带拉 `images`（同一请求）。

**稳健性**：Fanart 请求失败不阻断档案，`MediaProfile.fanart_failed` 置位，落库时**保留条目现用的
Fanart 图**——不让一次偶发失败把图换回 TMDB、下次成功又换回来（来回重下、媒体目录抖动）。
刮削遇 401 时回调 `mark_key_invalid`，此后不再请求 Fanart，直到用户重新填写有效 Key；
回调绑定发出请求的那把 Key，换 Key 瞬间旧 Key 晚到的 401 不会误伤新 Key。

- **独立出口**：接口与图床都走 `fanart` 出口标签（图片代理按域名分流，本地 DNS 校验也按该标签的
  代理开关判断），代理开关与熔断都与「图片回源」分开——Fanart 连不通不会连带 TMDB/豆瓣图片下载
  一起快速失败；设置页验证 Key 绕过熔断（必须真发请求）；「网络与代理」的连通性测试带上已保存的
  Key（请求头），一次测线路与 Key；
- **不拖慢刮削**：补充来源超时 8 秒、不重试，持续不通由熔断兜底（连续 3 次失败后 60 秒内快速失败）；
  季详情失败时并发中的 Fanart 请求随之取消；
- **Logo 清晰度不压过语言**：HD Logo 全收，SD 只补 HD 里没有的语言（只有 SD 版的中文 Logo 不会被丢）；
- **换 Key**：旧客户端延迟 5 分钟再关闭，批量任务手里的旧引用不会撞上「client has been closed」；
  万一撞上也按普通取图失败处理；
- **换图弹层**：TMDB 候选与 Fanart 候选并发拉取；Fanart 一侧（含剧集现查 TVDB 编号）任何异常只把
  状态置为 `error`，TMDB 候选照常展示。

**选图接口**：`ArtworkSelectPayload.file_path` 只收 TMDB 相对路径或 `https://assets.fanart.tv/`
地址——选定后服务端会去拉这张图，不能让任意 URL 经这里变成服务端代发的请求。

## 4. 测试

- `tests/media/test_fanart.py`：归一化与客户端（真实响应形态、401/404/`{}`/网络错误）；
- `tests/media/test_image_sources.py`：语言先于来源、同档按来源、「TMDB 默认」语义、宽度门槛、
  季海报、失败回落、不启用时请求与结果不变；
- `tests/api/test_fanart_source.py`：全链路（扫描入库 → 资产落盘 → 媒体目录 clearlogo.png）、
  开关切换后刷新生效、偶发失败保留现图、Key 被撤销后标记失效、Key 加密落库、按库覆盖、
  换图候选与选定、接口读写；
- `tests/media/test_fanart_review_fixes.py`：代码审查发现问题的回归（上面「稳健性」各条）；
- `tests/media/test_fanart_live.py`：真实接口（`-m integration`，需 `FANART_API_KEY`）。

# 扩展点目录：能做什么、做不到什么

插件能用的全部开放契约（与 `scripts/contracts.py` 的输出、`$SRC/movieclaw_sdk/surface.json` 一致，
tests 守着：契约有增删时本文必须同步）。都是实验级；清单 `[requires]` 写 `"<名字>" = "^<主版本>.0"`（版本看
`contracts.py <名字>`）。

写代码前用 `python <本技能>/scripts/contracts.py <名字>` 看载荷 / 结果的真实类型；写法见 `recipes.md` 对应小节。

## 1. 系统事件：某件事发生后做点什么

全部从 `movieclaw_sdk.events` 导入（`from movieclaw_sdk.events import SUBSCRIPTION_FULFILLED, SubscriptionFulfilled`）。
通知、Webhook、插件订的是同一批事件、同一份载荷（`docs/design/domain-events.md`）。**投递方式由你选**：

- **实时订阅** `ctx.on(EVENT, fn)`：发完即忘（插件不在、积压满了就丢），适合「现在值得做点什么」的提示，该做的事要能从
  库里的事实补回来（例如按待探列表补探）；
- **可靠订阅** `ctx.on(EVENT, fn, id="稳定id", durable=True)`：至少投递一次、重启不丢，要做副作用（删种、搬运、记账）就用它。
  须 `inject=(DURABLE_EVENTS,)`，按 `ctx.delivery.event_id` 去重。标「高频」的只能实时订阅。

载荷里的条目是 `MediaRef`（`media.id` 是条目 id），季集是 `UnitRef`（电影没有单元：列表为空、单个为 `None`），客户端是
`ClientRef`。成员 id 0 是超管。

| 契约 | 什么时候发生 | 典型用途 | 备注 |
|---|---|---|---|
| `subscription.created` / `deleted` | 订阅新建 / 删除 | 给订阅挂规则、清理插件数据 | 示例 `keyword_rules.py`（删除时清理） |
| `subscription.status_changed` | 追踪中 / 已收齐 / 暂停 | 状态同步 | |
| `subscription.download_started` | 订阅的种子真实提交下载器 | 下载开始提醒 | 带种子、季集、谁手动选的种 |
| `subscription.fulfilled` | 订阅的季集经媒体库对账确认入库 | 收齐提醒、外部片单打勾 | `units` 全部入库的，`requested_units` 其中仍在订阅范围内的 |
| `subscription.upgraded` | 订阅的一集换成了更好的版本 | 洗版记录 | |
| `subscription.identity_skipped` | 订阅跳过了身份不明的同名资源（每个订阅一次） | 知会 | |
| `subscription.download_stuck` | 订阅已选中的种子一直下不下来，换源也没搜到（每次卡住一次） | 提醒换源、手动处理 | 带种子名、多少小时后再试 |
| `subscription.more_episodes` | 订阅收齐后发现可能还有更多集（站点或豆瓣给的集数更多） | 提醒确认集数 | `source` 是 `site` / `douban` |
| `download.completed` | 订阅投递的种子在下载器里下载完成（入库前） | 下载完通知、校验、搬运 | |
| `download.imported` | 手动下载的内容全部入库 | 通知点下载的人 | |
| `library.ingest.completed` | 下载条目整理入库完成（载荷 `imported_names` 是整理前的原始文件名：按命名模板改名后 TC、CAM 这类发布标记通常就没了，按发布名判断的看它） | 入库后通知、同步到别处、记账 | |
| `library.files.added` | 媒体库新入账了文件（扫描一轮发一次，下载入库每个条目一次） | 新文件来了就处理（预探、生成东西） | 示例 `$SRC/movieclaw_plugins/strm_prefetch/` |
| `library.items.arrived` | 媒体库有新片（不管谁下载、怎么入库；攒几分钟一批） | 新片提醒、同步片单 | |
| `library.item.deleted` | 一部作品在某个库里的文件全部删除 | 删片联动：删订阅、删种子 | 示例 `delete_cascade.py`；种子按 `files[].id` 调 `dl.file-sources.list` 查 |
| `library.file.deleted` | 部分文件被删（删了几集） | 同上，部分删除 | 同上 |
| `library.item.moved` | 条目转移到了另一个库（分错库补救、库内归并），文件随之搬走 | 同步路径、通知下游刷新 | |
| `library.file.trashed` / `restored` / `purged` | 文件进回收站 / 恢复 / 彻底清除 | 回收站联动 | |
| `library.item.favorited` / `unfavorited` | 收藏 / 取消收藏（`level`：整部、一季、一集） | 收藏即准备好整部 | 敏感 |
| `library.item.viewed` | 打开条目详情（网页详情页、播放器取条目） | 用户可能要看了，先准备 | 敏感、高频 |
| `playback.started` / `stopped` / `completed` | 开始播放 / 停止（`completed` 表示停时刚好看完）/ 看完 | 预取下一集、播放联动、记录 | 敏感 |
| `playback.progress` | 播放进度（每集最多 30 秒一条） | 同步进度 | 敏感、高频 |
| `playback.marked_played` / `marked_unplayed` | 标记已看 / 取消（整季标记是一个事件、带每一集） | 同步观看记录 | 敏感 |
| `account.device.signed_in` | 一台设备登录了账号（`new_device` 表示第一次在这台登录） | 安全审计 | 敏感 |
| `agent.run.finished` | AI 会话的一轮跑完（`status`：`done` 回答完 / `error` 出错；用户停止的不算） | 回复完成提醒、记录用量 | 敏感；`source` 是 `app` / `plugin` / `channel`，`answer` 是回答开头的纯文本 |
| `system.alert.raised` / `resolved` | 待处理事项出现（或复发）/ 自动消退 | 把告警转到别处 | |
| `system.update.available` | 有新版本（每个版本一次） | | |
| `system.tip.suggested` | 有使用建议（每条一次） | | |

**「新文件入库后做事」选哪个**：只关心下载后整理入库的、而且必须每次都处理 → 可靠订阅 `library.ingest.completed`
（带原始文件名）；手动扫描、实时监控进库的也要覆盖 → `library.files.added`（只有文件 id，标题、路径用宿主操作查）；
只想知道「来了新片」 → `library.items.arrived`。可以都订、用插件数据按文件 id 去重。

## 2. 决策钩子：改变系统的判断

**只做判断、不许有副作用**（不写数据、不调会改东西的宿主操作、不往外发通知）：决策可能被别的插件或规则推翻，
副作用会留下错的痕迹。只读查询可以（比如向网盘问直链），但要快：单个监听器 2 秒超时、整条链 5 秒，超时按没回答处理。

| 契约 | 模式 | 能做什么 | 导入 | 示例 |
|---|---|---|---|---|
| `subscription.search.keywords` | 洋葱 | 在系统推导的搜索词上追加或替换（最终截到 6 个以内） | `from movieclaw_api.hooks import SEARCH_KEYWORDS` | `keyword_rules.py` |
| `subscription.candidates.filter` | 洋葱 | 按自己的规则淘汰候选种子（只能淘汰不能加），原因写进订阅动态 | `… import CANDIDATES_FILTER` | `keyword_rules.py` |
| `subscription.candidates.rank` | 洋葱 | 重排候选（必须是原集合的重排） | `… import CANDIDATES_RANK` | — |
| `dl.downloader.select` | 第一个说了算 | 没指定下载器时按站点 / 体积 / 类型选一个已接入的下载器（各场景能拿到的字段见 `recipes.md` 第 2 节） | `… import DOWNLOADER_SELECT` | — |
| `dl.torrent.before-delete` | 第一个说了算 | 否决删种（如 H&R 没达标），否决后删除返回 409 | `… import TORRENT_BEFORE_DELETE` | — |
| `playback.strm.direct-link` | 第一个说了算 | strm 指向服务器挂载目录里的文件（CloudDrive2 / rclone）时，给播放器换一个网盘直链，播放器被 302 过去、视频流量不经服务器。载荷有文件路径与播放器 UA（115 直链与 UA 绑定）；可以给内网 302 服务地址（alist `/d/…`），系统会带播放器的 UA 替它跟跳转；`ttl_s` 是可复用多久。不认领返回 `None`，没认领 / 出错 / 播放器连不上一律照旧由服务器出字节。只管播放器去哪取，服务器自己读（探测、转码、字幕）照旧读挂载 | `… import STRM_DIRECT_LINK, DirectLink` | 插件仓库 movieclaw-plugins 的 `plugins/openlist-direct-link/` |

## 3. 注册表：给系统加一种新实现

`ctx.contribute(KEY, "<贡献 id>", 贡献项)`（注册表**不写进 `inject`**，只写进清单 `[requires]`）；第三方贡献 id 自动带插件 id 前缀（不会和内置撞名），
要**替换**内置的某一项时用 `override=True` 并用原 id（卸载后内置自动恢复）。

| 契约 | 能做什么 | 导入 | 示例 |
|---|---|---|---|
| `im-channels` | 接一个新的消息平台（收发、绑定），账号 / 白名单 / AI 对话 / 推送由主程序负责 | `from movieclaw_sdk.channels import IM_CHANNELS` | `examples/ntfy-channel/`、`$SRC/movieclaw_plugins/` |
| `downloader-adapters` | 接一款新的下载软件（Deluge、Aria2……）：继承 `BaseDownloader` 实现提交 / 查询 / 删除等方法，登记 `DownloaderAdapter`（`connection=` 给连接参数模型，字段只能取 url / username / password，决定添加下载器表单各栏的叫法与要不要，写法见 `movieclaw_sdk/downloaders.py` 文件头）；配置、路径映射、订阅投递、做种同步由主程序负责，独立进程也能跑 | `from movieclaw_sdk.downloaders import DOWNLOADER_ADAPTERS, BaseDownloader, DownloaderAdapter` | `$SRC/movieclaw_plugins/qbittorrent/`、`$SRC/movieclaw_plugins/transmission/` |
| `site-classes` | 新的站点框架（`BaseSite` 子类），站点 YAML 的 `custom_class` 引用它 | `from movieclaw_api.plugins.keys import SITE_CLASSES` | `$SRC/movieclaw_tracker/sites/custom/` |
| `site-data-packs` | 一批站点 YAML 打成插件分发（同 site_id 覆盖内置） | `… import SITE_DATA_PACKS` | `examples/site_pack/` |
| `scheduled-tasks` | 周期任务（出现在「定时任务」里，用户可调周期）；可 override 整段替换内置任务（如订阅缺口搜索 `search_wanted`） | `from movieclaw_scheduler import SCHEDULED_TASKS` | — |
| `job-handlers` | 持久化后台任务（断点续传、进度、重试 / 阻塞）；类型写成 `<插件 id>:<名字>`，`title=` 是任务中心里显示的名字；插件停用 / 卸载时它的任务被取消 | `from movieclaw_sdk.jobs import JOB_HANDLERS, RegisteredJobHandler` | `cloud_strm.py` |
| `ingest-steps` | 入库流水线里插一个步骤（暂存完成后，如上传网盘） | `from movieclaw_api.pipeline import INGEST_STEPS` | `cloud_strm.py` |
| `library.delete-participants` | 删除影片 / 文件的弹窗里加一个勾选项（默认不勾）：只读预览说清后果，用户勾了才建后续任务（`job_type` 带插件 id 前缀，如 `f"{ctx.entry_id}:cleanup"`，同时登记同名任务处理器）。适合「删片时顺带删网盘备份 / 外部记录」；要删下载任务和源文件用内置选项，不用自己写 | `from movieclaw_api.services.library.delete_participants import LIBRARY_DELETE_PARTICIPANTS, DeleteParticipant, Preview, PreviewLine` | `$SRC/movieclaw_api/services/remove_source.py` |

## 4. 服务：插件可用的能力

`@plugin(inject=(KEY, …))` 声明，`ctx.use(KEY)` 取。

| 契约 | 作用 | 导入 | 示例 |
|---|---|---|---|
| `host-ops` | 以插件身份调用系统操作（与 mclaw 同一份目录，`subscriptions.create` ↔ `mclaw subscriptions create`），只能调批准过的 | `from movieclaw_sdk.ops import HOST_OPS` | `watchlist_feed.py`、`delete_cascade.py` |
| `plugin-data` | 插件自己的键值状态；可挂在实体上（`entity_scope("subscription", id)`）；`secret=True` 加密 | `from movieclaw_api.plugins.keys import PLUGIN_DATA` | `keyword_rules.py` |
| `plugin-files` | 读写用户批准的目录；插件私有目录总能用；路由里交出文件 | `… import PLUGIN_FILES` | `cloud_strm.py` |
| `plugin-routes` | 开接口：`/api/v1/plugins/<id>/…`，管理员 / 成员 / 签名公开三区，可签发不过期链接。**接口会自动成为 mclaw 命令**，AI 助手也能调 | `… import PLUGIN_ROUTES` | `cloud_strm.py`、`templates/starter/` |
| `plugin-health` | 常驻任务报告降级 / 恢复，降级进系统通知与诊断 | `… import PLUGIN_HEALTH` | — |
| `plugin-jobs` | 建自己的后台任务（只能建自己登记的任务类型）：`ctx.use(PLUGIN_JOBS).scoped(ctx).create("<id>:sync", input=…, priority=…, dedupe_key=…)`，同去重键还在进行的直接返回它；优先级高的先领 | `from movieclaw_sdk.jobs import PLUGIN_JOBS` | `recipes.md` 第 7、16 节、`$SRC/movieclaw_plugins/strm_prefetch/` |
| `plugin-callbacks` | 回调端点：外部平台（企业微信、GitHub、Slack、Telegram……）能直接调进来的地址，请求原样交给插件，**插件自己验签**；清单 `callbacks` 声明端点名 | `from movieclaw_sdk.callbacks import PLUGIN_CALLBACKS` | `recipes.md` 第 14 节 |
| `agent` | 驱动 AI 助手跑一轮对话：`ask` 同步等结果，`start` 后 `events()` 逐事件流式（可续传）；只看得到自己建的会话。权限串 `agent:none` / `agent:mclaw` / `agent:full`（工具档位，插件包最高 `mclaw`），用户批准才生效 | `from movieclaw_sdk.agent import AGENT` | `recipes.md` 第 15 节、`examples/go-a2a-bridge/` |
| `kernel/durable-events` | 可靠订阅事件的投递（`durable=True` 订阅时 inject 它） | `from movieclaw_kernel import DURABLE_EVENTS` | `delete_cascade.py` |
| `plugin-events` | 发插件自己的事件：`plugin_event("<插件 id>.xxx", 载荷模型, title=…)` 定义，`await ctx.use(PLUGIN_EVENTS).register(ctx, EVENT)` 登记，`publisher.publish(EVENT, 载荷)` 发。别的插件、Webhook 能订；清单 `[[notifications]]` 声明了通知、经用户批准的，宿主按规则推到手机和 IM | `from movieclaw_sdk.events import PLUGIN_EVENTS, plugin_event` | `recipes.md` 第 17 节 |

另有 `movieclaw_sdk.net.http_transport("<服务名>")`：连外网按用户的代理设置走（清单写 `network = true`）。

## 5. 还没开放的：遇到要直说，并给替代办法

| 用户想要 | 现状 | 替代办法 |
|---|---|---|
| 给网页 / App 加界面（按钮、页面、首页卡片、播放器按钮） | 插件不能带前端代码；唯一的界面是配置模型自动生成的「设置」表单（`recipes.md` 第 13 节） | 先找现成功能：首页自定义行（`mclaw ui prefs show`，每个库有「最近添加」）、订阅页「刚刚入库」、消息推送、播放器的片头片尾 / 广告识别（剧集库 `--detect-media-segments`）。插件能补的：开接口让 AI 助手随问随答、推送到 IM 通道、结果写进订阅动态或系统通知；配置见 `recipes.md` 第 13 节 |
| 新的元数据来源（替代 TMDB / 豆瓣） | 不能 | — |
| 新的 Webhook 推送格式 | 不能新增格式 | 监听可靠事件，自己向外部服务发请求（`network = true`） |
| 新的站点认证方式 | 认证方式是固定的 | 先读 `$SRC/movieclaw_tracker/sites/custom/` 现有站点类，看能否在站点类里处理；不能就直说 |
| 替换播放、转码、媒体库扫描、刮削主流程 | 不能整体替换（产品核心）；播放只开放了「网盘挂载文件给播放器换直链」（`playback.strm.direct-link`），转码没有插手点 | 入库前后可以用入库流水线步骤、可靠事件插手；播放相关的需求先看现有设置 |
| 改 AI 助手本身 | AI 助手是核心，不可替换 | 想给它加能力（查天气、查某个外部服务）：开插件接口，它会成为 mclaw 命令，AI 助手直接能调——这是能做的，见 `recipes.md` 第 5、10 节 |
| 让内置功能可开可关 | 不是插件能做的事 | 告诉用户去对应功能的设置页 |

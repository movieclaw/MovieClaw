# 扩展点目录：能做什么、做不到什么

插件能用的全部开放契约（与 `scripts/contracts.py` 的输出、`$SRC/movieclaw_sdk/surface.json` 一致，
tests 守着：契约有增删时本文必须同步）。每个都是「实验级 1.0」：清单 `[requires]` 写 `"<名字>" = "^1.0"`。

写代码前用 `python <本技能>/scripts/contracts.py <名字>` 看载荷 / 结果的真实类型；写法见 `recipes.md` 对应小节。

## 1. 可靠事件：某件事发生后做点什么

至少投递一次、重启不丢（`inject=(DURABLE_EVENTS,)`，`ctx.on(EVENT, fn, id="稳定id")`，按 `ctx.delivery.event_id` 去重）。

| 契约 | 什么时候发生 | 典型用途 | 导入 | 示例 |
|---|---|---|---|---|
| `download.completed` | 订阅投递的种子下载完成 | 下载完通知、校验、搬运 | `from movieclaw_api.domain_events import DOWNLOAD_COMPLETED` | — |
| `library.ingest.imported` | 下载条目整理入库完成 | 入库后通知、同步到别处、记账 | `… import LIBRARY_INGEST_IMPORTED` | — |
| `library.item.deleted` | 一部作品在某个库里的文件全部删除 | 删片联动：删订阅、删种子 | `… import LIBRARY_ITEM_DELETED` | `delete_cascade.py` |
| `library.file.deleted` | 部分文件被删（删了几集） | 同上，部分删除 | `… import LIBRARY_FILE_DELETED` | `delete_cascade.py` |
| `library.file.trashed` / `restored` / `purged` | 文件进回收站 / 恢复 / 彻底清除 | 回收站联动 | `… import LIBRARY_FILE_TRASHED` 等 | — |
| `subscription.created` / `deleted` | 订阅新建 / 删除 | 给订阅挂规则、清理插件数据 | `… import SUBSCRIPTION_CREATED` 等 | `keyword_rules.py`（删除时清理） |
| `subscription.download-started` | 订阅的种子真实提交下载器 | 下载开始提醒 | `… import SUBSCRIPTION_DOWNLOAD_STARTED` | — |
| `subscription.fulfilled` | 订阅的季集已确认入库 | 收齐提醒、外部片单打勾 | `… import SUBSCRIPTION_FULFILLED` | — |
| `subscription.status-changed` | 追踪中 / 已收齐 / 暂停 | 状态同步 | `… import SUBSCRIPTION_STATUS_CHANGED` | — |

## 2. 决策钩子：改变系统的判断

**只做判断、不许有副作用**（不发请求、不写数据、不调宿主操作）；要快（在搜索 / 投递的热路径上）。

| 契约 | 模式 | 能做什么 | 导入 | 示例 |
|---|---|---|---|---|
| `subscription.search.keywords` | 洋葱 | 在系统推导的搜索词上追加或替换（最终截到 6 个以内） | `from movieclaw_api.hooks import SEARCH_KEYWORDS` | `keyword_rules.py` |
| `subscription.candidates.filter` | 洋葱 | 按自己的规则淘汰候选种子（只能淘汰不能加），原因写进订阅动态 | `… import CANDIDATES_FILTER` | `keyword_rules.py` |
| `subscription.candidates.rank` | 洋葱 | 重排候选（必须是原集合的重排） | `… import CANDIDATES_RANK` | — |
| `dl.downloader.select` | 第一个说了算 | 没指定下载器时按站点 / 体积 / 类型选一个已接入的下载器 | `… import DOWNLOADER_SELECT` | — |
| `dl.torrent.before-delete` | 第一个说了算 | 否决删种（如 H&R 没达标），否决后删除返回 409 | `… import TORRENT_BEFORE_DELETE` | — |

## 3. 注册表：给系统加一种新实现

`ctx.contribute(KEY, "<贡献 id>", 贡献项)`；第三方贡献 id 自动带插件 id 前缀（不会和内置撞名），
要**替换**内置的某一项时用 `override=True` 并用原 id（卸载后内置自动恢复）。

| 契约 | 能做什么 | 导入 | 示例 |
|---|---|---|---|
| `im-channels` | 接一个新的消息平台（收发、绑定），账号 / 白名单 / AI 对话 / 推送由主程序负责 | `from movieclaw_sdk.channels import IM_CHANNELS` | `examples/ntfy-channel/`、`$SRC/movieclaw_plugins/` |
| `site-classes` | 新的站点框架（`BaseSite` 子类），站点 YAML 的 `custom_class` 引用它 | `from movieclaw_api.plugins.keys import SITE_CLASSES` | `$SRC/movieclaw_tracker/sites/custom/` |
| `site-data-packs` | 一批站点 YAML 打成插件分发（同 site_id 覆盖内置） | `… import SITE_DATA_PACKS` | `examples/site_pack/` |
| `scheduled-tasks` | 周期任务（出现在「定时任务」里，用户可调周期）；可 override 整段替换内置任务（如订阅缺口搜索 `search_wanted`） | `from movieclaw_scheduler import SCHEDULED_TASKS` | — |
| `job-handlers` | 持久化后台任务（断点续传、进度、重试 / 阻塞） | `from movieclaw_api.services.jobs import JOB_HANDLERS` | `cloud_strm.py` |
| `ingest-steps` | 入库流水线里插一个步骤（暂存完成后，如上传网盘） | `from movieclaw_api.pipeline import INGEST_STEPS` | `cloud_strm.py` |

## 4. 服务：插件可用的能力

`@plugin(inject=(KEY, …))` 声明，`ctx.use(KEY)` 取。

| 契约 | 作用 | 导入 | 示例 |
|---|---|---|---|
| `host-ops` | 以插件身份调用系统操作（与 mclaw 同一份目录，`subscriptions.create` ↔ `mclaw subscriptions create`），只能调批准过的 | `from movieclaw_api.plugins.keys import HOST_OPS` | `watchlist_feed.py`、`delete_cascade.py` |
| `plugin-data` | 插件自己的键值状态；可挂在实体上（`entity_scope("subscription", id)`）；`secret=True` 加密 | `… import PLUGIN_DATA` | `keyword_rules.py` |
| `plugin-files` | 读写用户批准的目录；插件私有目录总能用；路由里交出文件 | `… import PLUGIN_FILES` | `cloud_strm.py` |
| `plugin-routes` | 开接口：`/api/v1/plugins/<id>/…`，管理员 / 成员 / 签名公开三区，可签发不过期链接。**接口会自动成为 mclaw 命令**，AI 助手也能调 | `… import PLUGIN_ROUTES` | `cloud_strm.py`、`templates/starter/` |
| `plugin-health` | 常驻任务报告降级 / 恢复，降级进系统通知与诊断 | `… import PLUGIN_HEALTH` | — |
| `kernel/durable-events` | 可靠事件的投递（监听可靠事件时 inject 它） | `from movieclaw_kernel import DURABLE_EVENTS` | `delete_cascade.py` |

另有 `movieclaw_sdk.net.http_transport("<服务名>")`：连外网按用户的代理设置走（清单写 `network = true`）。

## 5. 还没开放的：遇到要直说，并给替代办法

| 用户想要 | 现状 | 替代办法 |
|---|---|---|
| 给网页 / App 加界面（按钮、页面、设置表单、首页卡片） | 插件不能加界面；插件包也没有用户可改的配置页 | 开插件路由（自动成为 mclaw 命令，AI 助手能调）；结果写进订阅动态（候选淘汰原因）或系统通知（健康上报）；参数先写常量，或提供管理员接口写进插件数据 |
| 新的下载器类型（Aria2、Deluge、网盘离线） | 下载器类型是固定的，插件不能新增 | 用「选下载器」钩子在已接入的下载器之间分流；或做一个独立的后台任务调外部服务（但订阅投递不会走它，要跟用户讲清） |
| 新的元数据来源（替代 TMDB / 豆瓣） | 不能 | — |
| 新的 Webhook 推送格式 | 不能新增格式 | 监听可靠事件，自己向外部服务发请求（`network = true`） |
| 新的站点认证方式 | 认证方式是固定的 | 先读 `$SRC/movieclaw_tracker/sites/custom/` 现有站点类，看能否在站点类里处理；不能就直说 |
| 替换播放、转码、媒体库扫描、刮削主流程 | 不能整体替换（产品核心） | 能用钩子或流水线步骤在具体环节插手的，按那条路做 |
| 改 AI 助手本身、给它加工具 | AI 助手是核心，不可替换、不能直接加工具 | 开插件路由：它会成为 mclaw 命令，AI 助手可以调用 |
| 让内置功能可开可关 | 不是插件能做的事 | 告诉用户去对应功能的设置页 |

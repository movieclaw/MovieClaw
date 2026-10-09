# 写法速查

每节给最小可用的写法。载荷字段以 `scripts/contracts.py <名字>` 打印的类型为准；
完整、经过测试的写法见 `references/examples/`（对应文件在每节末尾标出）。

## 0. 需求 → 扩展形态

| 用户想要 | 形态 | 契约 |
|---|---|---|
| 某事发生后自动做点什么（入库后、删片后、下载完成后、订阅变化后） | 可靠事件监听 + 宿主操作 | `library.*`、`download.completed`、`subscription.*` 事件；`host-ops` |
| 改订阅的搜索词 / 淘汰或重排候选种子 | 决策钩子（waterfall） | `subscription.search.keywords`、`subscription.candidates.filter`、`subscription.candidates.rank` |
| 按规则选下载器 / 阻止删除某些种子 | 决策钩子（bail） | `dl.downloader.select`、`dl.torrent.before-delete` |
| 定期做事（轮询外部片单、定时清理） | 后台循环 `ctx.task` 或定时任务 | `scheduled-tasks` |
| 入库前后插一个耗时步骤（上传网盘、转码） | 持久化任务处理器 + 流水线步骤 | `job-handlers`、`ingest-steps` |
| 给外部系统或用户开接口（Webhook 接收、状态查询、签名下载链接） | 插件路由 | `plugin-routes` |
| 新的 IM 平台 | 通道驱动 | `im-channels` |
| 新站点 / 一批站点配置 | 站点类 / 站点数据包 | `site-classes`、`site-data-packs` |
| 记住状态、给订阅等实体挂额外字段 | 插件数据 | `plugin-data` |
| 读写某个目录的文件 | 插件文件 | `plugin-files` |
| 常驻任务出问题时提醒用户 | 健康上报 | `plugin-health` |

**规则：钩子里只做判断，不产生副作用；副作用放进可靠事件监听或宿主操作。**

## 1. 可靠事件监听

```python
from movieclaw_api.domain_events import LIBRARY_INGEST_IMPORTED, IngestImported
from movieclaw_kernel import DURABLE_EVENTS

@plugin("me.after-import", title="入库后通知", inject=(DURABLE_EVENTS, PLUGIN_DATA))
async def apply(ctx: Context) -> None:
    store = ctx.use(PLUGIN_DATA).scoped(ctx)

    async def on_imported(event: IngestImported) -> None:
        event_id = ctx.delivery.event_id if ctx.delivery else None   # 本次投递的事件 id
        seen = await store.get("seen", default=[])
        if event_id in seen:                          # 至少投递一次：按事件 id 去重
            return
        ctx.logger.info("《%s》入库了 %d 个文件", event.media.title, len(event.files))
        if event_id:
            await store.set("seen", [event_id, *seen][:500])   # 只留最近的，别每个事件一个键越攒越多

    ctx.on(LIBRARY_INGEST_IMPORTED, on_imported, id="after-import")   # 稳定 id：改了会丢进度
```

清单：`[requires] "library.ingest.imported" = "^1.0"`。
- 监听器抛错 = 这次投递失败，按退避重试；多次失败进**死信**（`mclaw app plugins dead-letters …` 可重放 / 忽略）。
- 插件自己的操作引起的事件：`ctx.delivery.origin.is_plugin(ctx.entry_id)` 为真，按需跳过以防循环。

示例：`references/examples/delete_cascade.py`（删片联动）。

## 2. 决策钩子

洋葱式（waterfall）：先拿下游结果，再在它的基础上改。

```python
from movieclaw_api import hooks

async def more_keywords(payload: hooks.Keywords, next_) -> tuple:
    keywords = await next_()
    return ("某字幕组", *keywords)

async def filter_candidates(batch: hooks.CandidateBatch, next_) -> hooks.FilterResult:
    result = await next_()
    mine = tuple(
        hooks.Rejection(key=c.key, reason_code="keyword", reason_text="标题含『抢先版』")
        for c in batch.candidates if "抢先版" in c.title
    )
    return hooks.FilterResult(rejected=result.rejected + mine)

ctx.on(hooks.SEARCH_KEYWORDS, more_keywords)
ctx.on(hooks.CANDIDATES_FILTER, filter_candidates)
```

第一个说了算（bail）：返回结果 = 接管，返回 `None` = 不管。

```python
def pick(query: hooks.DownloaderQuery) -> hooks.DownloaderChoice | None:
    if query.media_kind == "tv":
        return hooks.DownloaderChoice(downloader_id=2, reason="剧集走 2 号下载器")
    return None

ctx.on(hooks.DOWNLOADER_SELECT, pick)
# 否决删种：ctx.on(hooks.TORRENT_BEFORE_DELETE, fn)，fn 返回 hooks.Veto(reason="…") 即否决
```

钩子在热路径上：要快，不发网络请求；需要的数据提前在后台准备好存在内存或插件数据里。
监听器抛错 / 超时 / 返回类型不对时按「不存在」处理，连续失败会被熔断。

示例：`references/examples/keyword_rules.py`。

## 3. 调用宿主操作

```python
from movieclaw_api.plugins.keys import HOST_OPS
from movieclaw_api.services.host_ops import OpsError

@plugin("me.x", title="…", inject=(HOST_OPS,), permissions=("search.titles", "subscriptions.create"))
async def apply(ctx: Context) -> None:
    ops = await ctx.use(HOST_OPS).client(ctx)       # 以插件身份调用，只能用批准过的操作
    try:
        found = await ops.call("search.titles", {"query": "沙丘", "provider": "tmdb", "save_history": False})
    except OpsError as exc:                         # exc.status / exc.code / exc.message / exc.details
        ctx.logger.warning("搜索失败：%s", exc.message)
```

清单 `permissions.operations` 同步写上。返回值是该操作响应的 `data` 部分（字典）。
支持演练的危险操作（如 `dl.torrent.delete` 的 `dry_run`）开发时先传 `"dry_run": True`。

示例：`references/examples/watchlist_feed.py`。

## 4. 插件数据

```python
from movieclaw_api.plugins.keys import PLUGIN_DATA
from movieclaw_api.services.plugin_data import entity_scope

store = ctx.use(PLUGIN_DATA).scoped(ctx)
await store.set("cursor", "abc")                         # 全局
await store.get("cursor", default="")
await store.set("token", "xxx", secret=True)             # 加密存储
scope = entity_scope("subscription", 35)                 # 挂在 35 号订阅上
await store.set("rules", {"exclude": ["TC"]}, scope=scope)
await store.items(scope=scope)                           # 某作用域下全部键值
await store.scopes("rules", entity="subscription")       # 哪些订阅有这个键
await store.delete("rules", scope=scope)
```

值须能 JSON 序列化。实体删除时自己清理（监听对应的删除事件）。

## 5. 插件路由

```python
from fastapi import APIRouter
from movieclaw_api.plugins.keys import PLUGIN_ROUTES

routes = ctx.use(PLUGIN_ROUTES)
router = APIRouter()

@router.get("/status", operation_id=f"plugins.{ctx.entry_id}.status", summary="运行状态")
async def status() -> dict:
    return {"ok": True}

routes.mount(ctx, router)                     # 默认 admin 区 → /api/v1/plugins/<条目 id>/status
# routes.mount(ctx, router, zone="member")   # 登录成员可访问
# routes.mount(ctx, router, zone="public")   # 不登录，但必须带本插件签发的签名，否则 404
# url = await routes.sign(ctx, "/play/7", absolute=True)   # 签发公开区链接
```

- `operation_id` 必须以 `plugins.<条目 id>.` 开头；鉴权由宿主注入，插件绕不开。
- 端点参数 / 返回值的类型要在**模块顶层**导入（进程外运行时宿主要能解析）；入口模块尽量不要写
  `from __future__ import annotations`。
- 插件路由进入操作目录，因此也是 mclaw 命令：安装后随便执行一条 mclaw 业务命令触发目录刷新（提示「服务器接口目录已更新」），
  之后 `operation_id` 按点拆成命令调用，如 `plugins.me.hello.status` → `mclaw plugins me hello status`。

示例：`references/examples/cloud_strm.py`（公开区 + 签名链接）。

## 6. 后台循环与定时任务

简单轮询用后台循环：

```python
import asyncio

async def poll() -> None:
    while True:
        try:
            await sync_once()
        except asyncio.CancelledError:
            raise
        except Exception:
            ctx.logger.warning("同步失败，下一轮再试", exc_info=True)
        await asyncio.sleep(30 * 60)

ctx.task(poll(), name="poll")                 # 卸载时自动取消
```

要让用户在「设置 → 定时任务」里看到、可调整周期的，贡献定时任务：

```python
from movieclaw_scheduler import SCHEDULED_TASKS, TaskDefinition, TriggerType

async def cleanup() -> None:                  # 无参数
    ...

ctx.contribute(SCHEDULED_TASKS, "cleanup", TaskDefinition(
    key=f"{ctx.entry_id}.cleanup", title="清理过期记录", handler=cleanup,
    default_trigger_type=TriggerType.INTERVAL, default_interval_seconds=3600,
))
```

## 7. 持久化任务与入库流水线

耗时、要断点续传 / 进度 / 重试的工作做成持久化任务；挂到入库流水线的槽位上，每批暂存完成的文件建一个任务。

```python
from movieclaw_api.pipeline import INGEST_STEPS, IngestStep
from movieclaw_api.services.jobs import JOB_HANDLERS, JobBlocked, JobContext, JobRetry, RegisteredJobHandler

async def upload(context: JobContext, data: dict) -> dict:
    # 临时失败 raise JobRetry("…", delay_seconds=60)；需要用户处理 raise JobBlocked("…")
    await context.update_progress(mode="determinate", phase="upload", message="…", current=1, total=3)
    return {"done": True}

ctx.contribute(JOB_HANDLERS, "upload", RegisteredJobHandler(upload, frozenset({1})))
ctx.contribute(INGEST_STEPS, "upload", IngestStep(job_type=f"{ctx.entry_id}:upload", title="上传网盘"))
```

示例：`references/examples/cloud_strm.py`。

## 8. 读写文件

```python
from movieclaw_api.plugins.keys import PLUGIN_FILES

files = ctx.use(PLUGIN_FILES).scoped(ctx)
mine = files.path("plugin", "cache.json")     # 插件私有目录，总是可读写
f = await files.open(mine, "wb")              # 也有 exists / stat / listdir / makedirs / rename / remove
with f:
    await asyncio.to_thread(f.write, b"...")
# 路由里交出文件（支持 Range）：return files.response(path)
```

私有目录以外的路径都要在清单 `permissions.paths` 申请；没批准的路径抛 `PermissionError`。

## 9. 健康上报

```python
from movieclaw_api.plugins.keys import PLUGIN_HEALTH

health = ctx.use(PLUGIN_HEALTH).reporter(ctx)
await health.degraded("feed", "片单地址连不上，已重试 3 次", action_href="/settings/plugins")
await health.ok("feed")                       # 恢复后清除
```

降级会进系统通知和诊断页；只在用户需要知道、能处理时上报。

## 10. 连外网

```python
import httpx
from movieclaw_sdk import net

async with httpx.AsyncClient(transport=net.http_transport("me-feed"), timeout=20) as client:
    resp = await client.get(url)
```

服务名用插件自己的名字；会按用户「设置 → 网络与代理」的规则走代理。清单写 `network = true`。

## 11. IM 通道

只依赖 `movieclaw_sdk.channels`：继承 `ChannelDriver`（或 `AdapterDriver`），实现绑定（`Binding.form` 表单 / `Binding.flow`
交互流程）、`run`（收消息）、`send`（发消息），然后 `ctx.contribute(IM_CHANNELS, "<通道 id>", driver)`。
账号存储、白名单、AI 对话、推送、设置页都由主程序负责，插件只返回 `BindResult`。

样板：`references/examples/ntfy-channel/`（最小第三方通道）、`$SRC/movieclaw_plugins/feishu/`（最短的内置通道）、
`$SRC/movieclaw_plugins/weixin/`（扫码交互流程）。契约说明在 `$SRC/movieclaw_sdk/channels.py` 文件头。

## 12. 站点

- 一批站点 YAML：`ctx.contribute(SITE_DATA_PACKS, "sites", <目录 Path>)`，YAML 写法同
  `$SRC/movieclaw_tracker/sites/configs/_template.yaml`。示例 `references/examples/site_pack/`。
- 新的站点框架：继承站点基类，`ctx.contribute(SITE_CLASSES, "<类 id>", 类)`，YAML 的 `custom_class` 引用这个 id。
  参考 `$SRC/movieclaw_tracker/sites/custom/` 下现有的站点类。

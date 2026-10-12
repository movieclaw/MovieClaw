# 写法速查

每节给最小可用的写法。载荷字段以 `scripts/contracts.py <名字>` 打印的类型为准；
完整、经过测试的写法见 `references/examples/`（对应文件在每节末尾标出）。

## 0. 先选形态

需求对应哪种扩展点、哪些还没开放：见 `extension-points.md`。一个插件里组合多个扩展点、何时拆分：见 `composition.md`。

**规则：钩子里只做判断，不产生副作用；副作用放进可靠事件监听或宿主操作。**

## 1. 可靠订阅事件

```python
from movieclaw_kernel import DURABLE_EVENTS
from movieclaw_sdk.events import LIBRARY_INGEST_COMPLETED, IngestCompleted

@plugin("after-import", title="入库后通知", inject=(DURABLE_EVENTS, PLUGIN_DATA))
async def apply(ctx: Context) -> None:
    store = ctx.use(PLUGIN_DATA).scoped(ctx)

    async def on_imported(event: IngestCompleted) -> None:
        event_id = ctx.delivery.event_id if ctx.delivery else None   # 本次投递的事件 id
        seen = await store.get("seen", default=[])
        if event_id in seen:                          # 至少投递一次：按事件 id 去重
            return
        ctx.logger.info("《%s》入库了 %d 个文件", event.media.title, len(event.files))
        if event_id:
            await store.set("seen", [event_id, *seen][:500])   # 只留最近的，别每个事件一个键越攒越多

    # 可靠订阅：稳定 id（改了会丢进度）+ durable=True
    ctx.on(LIBRARY_INGEST_COMPLETED, on_imported, id="after-import", durable=True)
```

清单：`[requires] "library.ingest.completed" = "^1.0"`。
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
TV_DOWNLOADER = 2   # 先用 `mclaw dl list` 确认这个下载器真的存在，id 以那里为准

def pick(query: hooks.DownloaderQuery) -> hooks.DownloaderChoice | None:
    if query.media_kind == "tv":
        return hooks.DownloaderChoice(downloader_id=TV_DOWNLOADER, reason="剧集走 2 号下载器")
    return None

ctx.on(hooks.DOWNLOADER_SELECT, pick)
# 否决删种：ctx.on(hooks.TORRENT_BEFORE_DELETE, fn)，fn 返回 hooks.Veto(reason="…") 即否决
```

选下载器钩子**只在调用方没有指定下载器时**才会被问；各场景拿到的字段不同，按画质 / 体积分流前先看这张表：

| 场景（`tags`） | `title` | `size_bytes` | `site_id` |
|---|---|---|---|
| 订阅自动投递（`movieclaw-sub`）、换源（再加 `movieclaw-replacement`） | 种子发布名 | 有 | 有 |
| 手动下载（`movieclaw-manual`） | 提交时带的标题，不一定是发布名 | 无 | 有 |
| 投递预览 | 片名 | 无 | 可能无 |

钩子在热路径上：要快，不发网络请求；需要的数据提前在后台准备好存在内存或插件数据里。
监听器抛错 / 超时 / 返回类型不对时按「不存在」处理，连续失败会被熔断。

示例：`references/examples/keyword_rules.py`。

## 3. 调用宿主操作

```python
from movieclaw_sdk.ops import HOST_OPS, OpsError

@plugin("my-plugin", title="…", inject=(HOST_OPS,), permissions=("search.titles", "subscriptions.create"))
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
- 报错用 `raise HTTPException(status_code=404, detail="找不到城市：xx")`：`detail` 的原文就是用户 / AI 助手在 mclaw 里看到的错误信息，写成人话。
- 选区：AI 助手经 mclaw 调用时用的是 Agent 身份（管理员级），admin 区就能调；要让普通成员在网页 / App 里直接调用才放 member 区。
- 端点参数（查询参数、请求体模型）会进接口目录，变成 mclaw 命令的选项，AI 助手据此传参。
- 插件路由进入操作目录，因此也是 mclaw 命令：安装后随便执行一条 mclaw 业务命令触发目录刷新（提示「服务器接口目录已更新」），
  之后 `operation_id` 按点拆成命令调用，如 `plugins.hello-world.status` → `mclaw plugins hello-world status`。

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
# 每天固定时间用 cron（按服务器的调度时区，默认 Asia/Shanghai）：
#   default_trigger_type=TriggerType.CRON, default_cron="0 8 * * *"
```

## 7. 持久化任务与入库流水线

耗时、要断点续传 / 进度 / 重试 / 能在任务中心看到和取消的工作做成持久化任务：插件登记**处理器**，
需要时用 `PLUGIN_JOBS` **自己建任务**；排队、按优先级领取、重启后接着跑、在任务中心展示都由主程序负责。

```python
from movieclaw_sdk.jobs import (
    JOB_HANDLERS, PLUGIN_JOBS, JobBlocked, JobContext, JobRetry, RegisteredJobHandler, ResourceRef,
)

SYNC = "my-sync:sync"   # 任务类型一律写全「<插件 id>:<名字>」：建任务、登记处理器用同一个字符串

async def sync(context: JobContext, data: dict) -> dict:
    total = len(data["items"])
    done = (await context.current_progress()).get("current") or 0   # 断点：重启后从这里接着做
    for index in range(done, total):
        await context.raise_if_cancelled()          # 每一步之间检查取消（插件停用 / 卸载会取消它的任务）
        ...                                         # 临时失败 raise JobRetry("…", delay_seconds=60)；要用户处理 raise JobBlocked("…")
        if index + 1 == total or context.progress_due():
            await context.update_progress(mode="determinate", phase="sync", message=f"已同步 {index + 1} 个",
                                          current=index + 1, total=total)
    return {"synced": total}

@plugin("my-sync", title="同步", inject=(PLUGIN_JOBS,))
async def apply(ctx: Context) -> None:
    # title 是任务中心里显示的名字（不写就显示原始类型）
    ctx.contribute(JOB_HANDLERS, SYNC, RegisteredJobHandler(sync, frozenset({1}), title="同步收藏"))
    jobs = ctx.use(PLUGIN_JOBS).scoped(ctx)
    ref = await jobs.create(
        SYNC,
        input={"items": [...]},                     # 不能放密钥（被拒）；放配置引用
        subject="沙丘2",                            # 可选：任务中心的标题（做的是谁，如片名）；不写就显示 title
        priority=-10,                               # 后台慢慢做用负数；要插队的用 0（高的先被领取）
        dedupe_key="all",                           # 同一去重键还在进行时直接返回它（ref.created 为 False）
        resources=[ResourceRef("media_item", 42, "context")],   # 任务中心按它归到条目下；"target" 会独占加锁
    )
```

- 只能建**自己登记的**任务类型；去重键只在本插件内有效。
- 清单 `[requires]` 写 `"job-handlers" = "^1.1"`（用了 `title`）；`PLUGIN_JOBS` 是服务，写进 `inject` 即可。
- 任务里别 `asyncio.sleep` 很久不检查取消：要歇就分段歇、每段之间 `await context.cancel_requested()`。
- 停用 / 卸载插件时它的活动任务会被取消；去重拿回来的若是 `status == "cancelling"` 的旧任务，等它结束再建
  （否则它一结束就没有下一轮了）。

挂到入库流水线的槽位上，每批暂存完成的文件由系统建一个任务：

```python
from movieclaw_api.pipeline import INGEST_STEPS, IngestStep

ctx.contribute(JOB_HANDLERS, "my-cloud:upload", RegisteredJobHandler(upload, frozenset({1}), title="上传网盘"))
ctx.contribute(INGEST_STEPS, "upload", IngestStep(job_type="my-cloud:upload", title="上传网盘"))
```

入库流水线步骤的前提（缺一个就不会触发，给用户方案时先用 mclaw 查齐）：

- 下载要经「监听导入」规则入库，且规则的目标是**自定义目录（暂存）**——步骤只处理暂存完成的文件（`mclaw watch list`、`watch create --help`）；
- 文件归哪个媒体库由系统按收藏范围决定，`library_id` 可能为空（`mclaw library list`）；
- 要写出可从外面访问的链接（如 strm 里的播放地址），先设好外部访问地址（`mclaw app show` / `app set --help`）。

示例：`references/examples/cloud_strm.py`（入库流水线）；`$SRC/movieclaw_plugins/strm_prefetch/`（自己建任务、插队）。

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

服务名写**条目 id**（如 `"douban-wish"`）：独立进程里宿主只为这个名字给出代理设置，
写成别的名字会悄悄直连、不走用户「设置 → 网络与代理」的规则。清单写 `network = true`。
装之前可以在 bash 里用 curl 请求外部公开接口，核对返回格式再写解析代码（不要带用户的凭据）。
外部服务出错时捕获 `httpx.HTTPError`，记日志后在接口里 `raise HTTPException(502, detail="天气服务暂时不可用")`，
不要把堆栈抛给用户；后台循环里则记日志、下一轮再试。

## 11. IM 通道

只依赖 `movieclaw_sdk.channels`：继承 `ChannelDriver`（或 `AdapterDriver`），实现绑定（`Binding.form` 表单 / `Binding.flow`
交互流程）、`run`（收消息）、`send`（发消息），然后 `ctx.contribute(IM_CHANNELS, "<通道 id>", driver)`。
账号存储、白名单、AI 对话、推送、设置页都由主程序负责，插件只返回 `BindResult`。

样板：`references/examples/ntfy-channel/`（最小第三方通道）、`$SRC/movieclaw_plugins/feishu/`（最短的内置通道）、
`$SRC/movieclaw_plugins/weixin/`（扫码交互流程）。契约说明在 `$SRC/movieclaw_sdk/channels.py` 文件头。

**选接入方式**：MovieClaw 多半跑在家里的 NAS 上，没有公网地址，平台推不进来。按这个顺序选：

1. 服务器主动连出去收消息：长轮询（如 Telegram `getUpdates`）、长连接（如 Discord Gateway；企业微信「智能机器人」
   的长连接模式，绑定只要 botId + secret）。能对话、能推送，不需要公网地址——**首选**；
2. 只推送：群机器人 Webhook（飞书、企业微信群机器人、钉钉群机器人），粘贴地址即可，但不能对话；
3. 需要公网回调地址的方式（企业微信自建应用、公众号、Slack Events）放最后：用回调端点（第 14 节）收消息，
   选它要先确认用户配了外部访问地址（`mclaw app show`）、并且平台能从公网访问到它。
   通道驱动声明 `Capabilities(webhook=True)`、实现 `webhook(account, request)`，清单写 `callbacks = ["webhook"]`：
   中枢在用户绑定时自动发回调地址（绑定结果里给出），解绑即作废。完整示例：`references/examples/wecom-channel/`。

给用户方案时把「能不能对话」「要不要公网地址」「绑定要填什么」讲清楚；平台有几种接入方式而用户没指定时，
列出对比请用户选，选定后再写。

**只推送的通道**（群机器人、Bark 这类没有「绑定人」的）必须覆盖 `push_target(account)`，返回推送目标；
默认实现只推给绑定人，不覆盖就会静默发不出去。参考 `$SRC/movieclaw_plugins/feishu/`。

**通知类需求优先做通道插件**：主程序的推送开关（`mclaw channels im push config get`）已经决定推哪些事件
（入库、开始下载、收齐……），通道插件只管「发到哪」，用户在设置里统一开关。开关对所有通道一起生效：
用户只想收其中一种时，提醒他其他开着的也会推过来，要不要关由他定。随带通道（如飞书）的清单没写 `network = true`、
直接用 httpx——它们是受信代码，第三方通道照着写时要补上联网声明、改走 `net.http_transport`。要推的事情不在开关里时，
不要自己监听事件、自己发请求：定义插件事件、在清单写 `[[notifications]]`（第 17 节），宿主按每个人的开关推到手机和 IM。

各平台的协议细节（地址、鉴权、心跳、消息格式）技能里没有：先用 curl 查平台公开文档核对，或请用户提供文档；
不要凭记忆写协议。

## 12. 站点

- 一批站点 YAML：`ctx.contribute(SITE_DATA_PACKS, "sites", <目录 Path>)`，YAML 写法同
  `$SRC/movieclaw_tracker/sites/configs/_template.yaml`。示例 `references/examples/site_pack/`。
- 新的站点框架：继承站点基类，`ctx.contribute(SITE_CLASSES, "<类 id>", 类)`，YAML 的 `custom_class` 引用这个 id。
  参考 `$SRC/movieclaw_tracker/sites/custom/` 下现有的站点类。

## 13. 用户要填的配置与凭据

用户要填的值（账号 ID、地址、Key），写成配置模型交给 `@plugin(config=...)`：插件详情页会自动出现
「设置」表单，用户保存后插件按新值重启，`ctx.config` 拿到的就是模型实例。插件包、本地插件、独立进程都一样。

```python
from pydantic import BaseModel, Field, SecretStr

class Settings(BaseModel):
    douban_id: str = Field("", title="豆瓣用户 ID", description="个人主页地址里的那串数字")
    api_key: SecretStr | None = Field(None, title="API Key")   # 敏感：加密存、界面不回显

@plugin("acme-feed", title="片单同步", config=Settings)
async def apply(ctx) -> None:
    key = ctx.config.api_key.get_secret_value() if ctx.config.api_key else None
```

- 每个字段写 `title`（表单上的名字）和 `description`（一句说明）；不写 `title` 会显示字段名。
- 界面只认这些类型：布尔、字符串（可用 `Enum` 给候选值）、整数、数字、字符串列表，以及它们的可选形式；
  多行文本加 `json_schema_extra={"multiline": True}`，敏感字段用 `SecretStr`。
  嵌套对象、字典等界面编辑不了：插件照常运行，设置页说明原因，只能改 `data/plugins.yaml`（本地插件）。
- 约束（`ge`、`le`、`min_length`、`pattern`）写在 `Field` 里：保存前用你的模型校验，错误按字段标题用中文提示。
- 值只在启动时读一次，改了会重启插件，不用自己监听变化。
- 没填完（比如还没给 Key）时插件要照常加载、只记一条日志说明去哪填，别抛异常。
- **周期性的工作不要在配置里放「间隔」**：贡献定时任务（第 6 节），用户在「设置 → 定时任务」里统一调周期、
  暂停、立即运行，和系统自己的定时任务在一处。

按实体存的数据（每条订阅一份规则）不是配置，用插件数据（第 4 节，作用域 `subscription:<id>`）。

## 14. 回调端点：接收外部平台推过来的请求

外部平台按插件交出去的地址调进来：`<外部访问地址>/api/v1/hooks/<条目 id>/<端点名>/<密钥>[/<子路径>]`。
宿主只管地址（密钥不对一律 404）、方法、请求体上限、频率、剥掉 MovieClaw 的登录 Cookie；
**不验签、不解析请求体**，请求原样给插件，插件的答复原样回平台。

```python
from movieclaw_sdk.callbacks import PLUGIN_CALLBACKS, CallbackRequest, CallbackResponse

@plugin("github-notify", title="GitHub 推送", inject=(PLUGIN_CALLBACKS, PLUGIN_DATA, PLUGIN_ROUTES))
async def apply(ctx):
    callbacks = ctx.use(PLUGIN_CALLBACKS)
    store = ctx.use(PLUGIN_DATA).scoped(ctx)

    async def on_push(req: CallbackRequest) -> CallbackResponse:
        secret = await store.get("webhook_secret")
        if not secret or not github_ok(req, secret):
            return CallbackResponse(status=401)              # 记为一次验证失败
        ctx.logger.info("收到 GitHub 推送：%s", req.header("x-github-event"))
        return CallbackResponse(status=204)

    callbacks.endpoint(ctx, "push", on_push, methods=("POST",))   # 只能在 apply 里登记
    # 发地址：一般放在管理员接口里，装好后由你调用、把地址交给用户填到平台后台
    #   issued = await callbacks.issue(ctx, "push")      # issued.url；absolute 为 False 说明没配外部访问地址
```

清单：`[permissions] callbacks = ["push"]`（不声明，登记时直接报错；批准安装时会单独列给用户看）。

- `CallbackRequest`：`method`、`subpath`、`query`（多值）、`headers`、`body`（原始字节）、`scope`（这把密钥的归属）、
  `key_id`；取值用 `req.header("x")`（不分大小写）、`req.param("x")`、`req.text()`、`req.json()`。
- `CallbackResponse(status, body, headers)`，或 `CallbackResponse.text("…")` / `.json({...})`。
- 处理函数默认 10 秒超时（超时宿主回 504）；耗时工作交给后台任务（第 7 节）后立即返回。
- 一个端点可以发多把密钥：`issue(ctx, "push", scope="entity:repo:42")`，处理函数按 `req.scope` 区分；
  `revoke(ctx, key_id)` 作废，`keys(ctx)` 列出（打码）。用户也能在 `mclaw app plugins callbacks list / rotate / revoke` 管理。
- 插件卸载时地址全部作废；插件停着时调进来回 503，地址保留。

各平台验签（只用标准库和主程序自带的 `cryptography`）：

```python
import base64, hashlib, hmac, struct, time

def github_ok(req, secret: str) -> bool:                 # X-Hub-Signature-256
    want = "sha256=" + hmac.new(secret.encode(), req.body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(want, req.header("x-hub-signature-256") or "")

def telegram_ok(req, secret: str) -> bool:               # setWebhook 时填的 secret_token
    return hmac.compare_digest(secret, req.header("x-telegram-bot-api-secret-token") or "")

def slack_ok(req, signing_secret: str) -> bool:          # 另：type=url_verification 时回 {"challenge": …}
    ts = req.header("x-slack-request-timestamp") or "0"
    if abs(time.time() - int(ts)) > 300:
        return False
    base = b"v0:" + ts.encode() + b":" + req.body
    want = "v0=" + hmac.new(signing_secret.encode(), base, hashlib.sha256).hexdigest()
    return hmac.compare_digest(want, req.header("x-slack-signature") or "")

def wecom_ok(req, token: str, encrypted: str) -> bool:   # 企业微信：msg_signature
    parts = sorted([token, req.param("timestamp") or "", req.param("nonce") or "", encrypted])
    return hashlib.sha1("".join(parts).encode()).hexdigest() == req.param("msg_signature")

def wecom_decrypt(encrypted: str, aes_key: str) -> bytes:   # EncodingAESKey；AES-256-CBC，iv = key[:16]
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    key = base64.b64decode(aes_key + "=")
    raw = Cipher(algorithms.AES(key), modes.CBC(key[:16])).decryptor().update(base64.b64decode(encrypted))
    raw = raw[: -raw[-1]]                                 # 去 PKCS#7 填充（企业微信按 32 字节块）
    size = struct.unpack(">I", raw[16:20])[0]             # 16 字节随机串 + 4 字节长度 + 消息 + receiveid
    return raw[20 : 20 + size]
```

企业微信配置回调地址时会先发一次 GET（带 `echostr`）：验签后解密 `echostr`，原文作为响应体返回；
之后的消息是 POST 一段 XML，`Encrypt` 字段按同样方式验签、解密。

## 15. 驱动 AI 助手（协议适配、自动化）

插件可以让 AI 助手跑一轮对话，同步等结果或逐事件流式消费。典型用法是协议适配：插件开一个接口，
把对端的请求转成一轮对话，再把回复（含流式）转回对端格式。

**先定对端怎么进来**（最关键的取舍；用户已经说清「只聊天」或「要它操作」的直接按对应行做，没说的给方案时讲清、让用户选）：

| 对端要做什么 | 接口挂在 | 对端拿什么调 | 说明 |
|---|---|---|---|
| **只聊天**（闲聊、凭模型自己的知识推荐，不查也不动系统） | 公开区 `zone="public"` | 插件签发的**签名链接** | 最小权限：公开区里的调用一律不带工具（**查不了片库、订阅、下载**），链接泄露也动不了系统；用一条管理员区接口把链接交给用户（`mclaw plugins <id> link`） |
| 要让 AI 助手**查或替它操作**（问片库、建订阅、查下载） | 管理员区 `zone="admin"` | 用户在网页建的**个人令牌** | 令牌等于管理员权限，只给完全信任的系统；工具档位按授权 `agent:mclaw` |

```python
import json

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from movieclaw_api.plugins.keys import PLUGIN_DATA, PLUGIN_ROUTES
from movieclaw_sdk import plugin
from movieclaw_sdk.agent import (
    AGENT, AgentBusy, AgentNotGranted, AgentSessionNotFound, AgentUnavailable,
)

PLUGIN_ID = "acme-chat"


class Ask(BaseModel):          # 请求体模型放模块顶层（第 5 节）
    text: str
    session_id: str | None = None


@plugin(PLUGIN_ID, title="外部聊天接口", inject=(AGENT, PLUGIN_ROUTES, PLUGIN_DATA),
        permissions=("agent:none",))   # 只聊天
async def apply(ctx):
    agent = ctx.use(AGENT).scoped(ctx)
    routes = ctx.use(PLUGIN_ROUTES)
    store = ctx.use(PLUGIN_DATA).scoped(ctx)
    public, admin = APIRouter(), APIRouter()

    async def check_version(request: Request) -> None:
        # 链接里带一个插件自己存的版本号：换版本号，旧链接全部作废（签名本身不能单独吊销）
        if request.query_params.get("v") != str(await store.get("link_version", default=1)):
            raise HTTPException(404)

    async def begin(body: Ask):
        """开始一轮；把异常翻成 HTTP 状态（流式接口必须在开始推流**之前**处理完）。"""
        try:
            return await agent.start(body.text, session_id=body.session_id, tools="none",
                                     instructions="你在回答外部系统，回复要简洁。")
        except AgentBusy as exc:                 # 这个会话正在跑 / 本插件已有 2 轮：不排队
            raise HTTPException(409, str(exc))
        except AgentSessionNotFound:             # 对端带了不存在（或不是本插件建）的 session_id
            raise HTTPException(404, "会话不存在")
        except (AgentUnavailable, AgentNotGranted) as exc:   # 没配模型供应商 / 没授权
            raise HTTPException(503, str(exc))

    @public.post("/ask", operation_id=f"plugins.{PLUGIN_ID}.ask")
    async def ask(body: Ask, request: Request):
        await check_version(request)
        reply = await (await begin(body)).result(120)        # 同步：等这一轮跑完（超时取消）
        return {"session_id": reply.session_id, "status": reply.status, "text": reply.text}

    @public.post("/stream", operation_id=f"plugins.{PLUGIN_ID}.stream")
    async def stream(body: Ask, request: Request):
        await check_version(request)
        turn = await begin(body)

        async def frames():
            async for event in turn.events():          # text / tool / done / error / cancelled
                if event.type == "text":               # 只转增量文字和终态，不把内部字段原样给对端
                    yield f"event: text\ndata: {json.dumps({'delta': event.delta}, ensure_ascii=False)}\n\n"
                elif event.reply is not None:
                    data = {"session_id": event.reply.session_id, "text": event.reply.text}
                    yield f"event: {event.type}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"

        return StreamingResponse(frames(), media_type="text/event-stream",
                                 headers={"Cache-Control": "no-cache, no-transform"})

    @admin.get("/link", operation_id=f"plugins.{PLUGIN_ID}.link")
    async def link():
        """签名绑定路径：每个公开接口各签一条。"""
        v = {"v": str(await store.get("link_version", default=1))}
        try:
            return {path: await routes.sign(ctx, f"/{path}", params=v, absolute=True)
                    for path in ("ask", "stream")}
        except ValueError:                             # 没配外部访问地址：给相对地址，提醒用户拼上
            return {path: await routes.sign(ctx, f"/{path}", params=v) for path in ("ask", "stream")}

    @admin.post("/rotate-link", operation_id=f"plugins.{PLUGIN_ID}.rotate-link")
    async def rotate():
        await store.set("link_version", int(await store.get("link_version", default=1)) + 1)
        return await link()

    routes.mount(ctx, public, zone="public")
    routes.mount(ctx, admin, zone="admin")
```

- **授权**：清单 `permissions.operations` 写 `agent:none`（纯对话）或 `agent:mclaw`（可调服务操作），与
  `@plugin(permissions=...)` 一致；插件包不能申请 `agent:full`。用户批准时它被标为危险项。代表成员运行（`act_as`）的插件不能用。
- **先查模型**：服务器没接入模型供应商时每次都报 `AgentUnavailable`；给方案前用 `mclaw llm providers list` 查。
  没接不影响写代码和本地检查，在征求安装同意的那一轮提醒用户先去「设置 → 模型接入」配好。
- **外部访问地址**：`mclaw app show` 看 `external_url`；为空时签出来的是相对链接，告诉用户对端要自己在前面补上
  MovieClaw 的地址（如 `http://NAS的IP:3000`），或者去「设置 → 应用」填好外部访问地址。
- **签名绑定路径**：每个公开接口要单独签一条链接，拿 `/ask` 的链接去调 `/stream` 会 404。
- **自测**：转换逻辑（拼帧、解析对端请求）写成纯函数在 bash 里自测；接口本身装好后用 `mclaw plugins <id> link`
  取链接、`curl` 实调验证（没配模型时应得到 503 和「请先接入模型」的提示）。
- **会话**：插件建的会话只归它自己，`agent.sessions()` 列出、`session_id=` 续写、`agent.delete()` 删除；
  外部协议的会话标识（如 A2A 的 contextId）和 `session_id` 的对应关系存进插件数据。
- **流式**：`turn.events(after=上次的 seq)` 续传；迭代器关了不会取消运行（对端断线后可以 `agent.attach(session_id)`
  重新订阅），要取消显式 `await turn.cancel()`。工具的参数和输出不给插件。
- **护栏**：同时最多 2 轮，满了报 `AgentBusy`（不排队）；挂在成员区、公开区路由或回调端点里的调用一律不带工具；
  由 AI 助手引起的调用（例如 AI 助手调了你的接口）不能再发起 AI 助手，报 `AgentNotGranted`。
- 回调端点（第 14 节）要在 10 秒内答复，不适合等一轮对话；外部平台推消息进来要 AI 回复的，回调里先应答、
  再用 `ctx.task` 跑对话并经平台的发送接口回复。

## 16. 实时事件：用户正要用的先准备好

任何系统事件都能实时订阅（`ctx.on(EVENT, fn)`，不加 `durable`）：发完即忘，插件不在、积压满了就丢。适合
「现在值得提前做点什么」——预取下一集、先准备好要看的条目。**漏了不能出错**：该做的事要能从数据库里的事实
补回来（定时或启动时按待办补做），事件只负责让相关的先做。

```python
from movieclaw_sdk.events import LIBRARY_FILES_ADDED, PLAYBACK_STARTED, FilesAdded, Playback

@plugin("my-prefetch", title="预取", inject=(PLUGIN_JOBS,))
async def apply(ctx: Context) -> None:
    jobs = ctx.use(PLUGIN_JOBS).scoped(ctx)

    async def on_play(event: Playback) -> None:
        if event.unit is None:   # 电影没有「下一集」
            return
        # 插队：只排一个高优先级的小任务，监听器里不做耗时的事
        await jobs.create("my-prefetch:item", priority=0,
                          input={"media_item_id": event.media.id, "after_episode": event.unit.episode},
                          dedupe_key=f"item:{event.media.id}:{event.unit.season}")

    async def on_added(event: FilesAdded) -> None:
        await jobs.create("my-prefetch:backfill", priority=-10, dedupe_key="backfill")   # 慢慢补

    ctx.on(PLAYBACK_STARTED, on_play, id="play")      # 实时订阅：不用 inject DURABLE_EVENTS
    ctx.on(LIBRARY_FILES_ADDED, on_added, id="added")
```

- 清单 `[requires]` 写用到的事件，如 `"playback.started" = "^2.0"`（版本看 `contracts.py`）。
- 和可靠订阅的分别：可靠订阅（第 1 节）随业务提交写库、至少投递一次，适合「发生了就必须处理」的事（删片联动）；
  实时订阅不落库、不重投，适合提示。播放、收藏、浏览、账号类是敏感事件（谁在什么时候看了什么）。
- 载荷是快照、字段少（条目 / 季集 / 文件 id、成员）：要标题等更多信息用宿主操作查。

完整示例：`$SRC/movieclaw_plugins/strm_prefetch/`（网盘规格预探：后台补探 + 播放 / 收藏 / 打开详情时插队，
探测本身调宿主操作 `library.strm.*`）。

## 17. 发自己的事件、给人发通知

插件定义自己的事件，和系统事件进同一个目录：别的插件能订、Webhook 能勾。清单里再写通知规则，用户批准安装后，
发出的事件由宿主按规则推到手机和 IM（发给谁、按每个人的通知开关过滤、看不到的片不推，都由宿主做）。

```python
from pydantic import BaseModel, ConfigDict

from movieclaw_sdk import plugin
from movieclaw_sdk.events import PLUGIN_EVENTS, plugin_event


class QuotaExceeded(BaseModel):
    model_config = ConfigDict(frozen=True)
    site: str
    remaining_gb: float


QUOTA_EXCEEDED = plugin_event("quota-watch.exceeded", QuotaExceeded, title="站点配额超限")


@plugin("quota-watch", title="配额提醒", inject=(PLUGIN_EVENTS,))
async def apply(ctx) -> None:
    events = await ctx.use(PLUGIN_EVENTS).register(ctx, QUOTA_EXCEEDED)   # 插件停用时自动撤下

    async def check() -> None:
        ...
        await events.publish(QUOTA_EXCEEDED, QuotaExceeded(site="mteam", remaining_gb=2.5))

    ctx.task(check(), name="check")
```

清单（`manifest.md`）：

```toml
[[events]]
name = "quota-watch.exceeded"
title = "站点配额超限"

[[notifications]]
event = "quota-watch.exceeded"
title = "{site} 配额只剩 {remaining_gb} GB"
audience = "admins"
```

- 事件名以插件 id 开头、在 `[[events]]` 里声明；载荷是冻结的 pydantic 模型（进程外插件按它的 JSON Schema 校验）。
- 一个事件最多一条通知。收件人 `audience` 只有三种写法，`<字段>` 换成**你事件载荷里的字段名**（嵌套用 `a.b`），
  宿主发事件时去这个字段取值、据此定收件人：

  | 写法 | 那个字段的值 | 推给谁 |
  |---|---|---|
  | `admins` | （不取字段） | 管理员 |
  | `member:member_id` | 成员 id（整数）：宿主给过你的——调用你成员区接口的人、系统事件载荷里的成员 | 这个成员 |
  | `media:item` | 一部片：Python 插件用 `MediaRef`（`from movieclaw_sdk.events import MediaRef`），进程外插件传 `{"id", "kind", "title"}`，`id` 是媒体库条目 id | 订阅或关注了这部片的人 |

  字段名你自己起，和载荷对得上即可；取不到值（字段名写错、类型不对）就谁也不推，不报错——写完用一次真实发送核对。
  宿主不提供「列出所有成员」。载荷里有片的，看不到这部片的人一律不推，`open = "media"` 点开去这部片的条目页。

  ```python
  class BetterVersion(BaseModel):
      model_config = ConfigDict(frozen=True)
      item: MediaRef        # 清单写 audience = "media:item"
      label: str            # 模板里用 {label}、{item.title}
  ```
- 用户在「账号 → 通知」的「插件 · <插件名>」分组里逐条开关；插件卸载时这些开关一并删掉。


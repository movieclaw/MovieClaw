# 写法速查

每节给最小可用的写法。载荷字段以 `scripts/contracts.py <名字>` 打印的类型为准；
完整、经过测试的写法见 `references/examples/`（对应文件在每节末尾标出）。

## 0. 先选形态

需求对应哪种扩展点、哪些还没开放：见 `extension-points.md`。一个插件里组合多个扩展点、何时拆分：见 `composition.md`。

**规则：钩子里只做判断，不产生副作用；副作用放进可靠事件监听或宿主操作。**

## 1. 可靠事件监听

```python
from movieclaw_api.domain_events import LIBRARY_INGEST_IMPORTED, IngestImported
from movieclaw_kernel import DURABLE_EVENTS

@plugin("after-import", title="入库后通知", inject=(DURABLE_EVENTS, PLUGIN_DATA))
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
from movieclaw_api.plugins.keys import HOST_OPS
from movieclaw_api.services.host_ops import OpsError

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

入库流水线步骤的前提（缺一个就不会触发，给用户方案时先用 mclaw 查齐）：

- 下载要经「监听导入」规则入库，且规则的目标是**自定义目录（暂存）**——步骤只处理暂存完成的文件（`mclaw watch list`、`watch create --help`）；
- 文件归哪个媒体库由系统按收藏范围决定，`library_id` 可能为空（`mclaw library list`）；
- 要写出可从外面访问的链接（如 strm 里的播放地址），先设好外部访问地址（`mclaw app show` / `app set --help`）。

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
直接用 httpx——它们是受信代码，第三方通道照着写时要补上联网声明、改走 `net.http_transport`。只有要推的事件不在开关里时，
才监听可靠事件自己发请求。

各平台的协议细节（地址、鉴权、心跳、消息格式）技能里没有：先用 curl 查平台公开文档核对，或请用户提供文档；
不要凭记忆写协议。

## 12. 站点

- 一批站点 YAML：`ctx.contribute(SITE_DATA_PACKS, "sites", <目录 Path>)`，YAML 写法同
  `$SRC/movieclaw_tracker/sites/configs/_template.yaml`。示例 `references/examples/site_pack/`。
- 新的站点框架：继承站点基类，`ctx.contribute(SITE_CLASSES, "<类 id>", 类)`，YAML 的 `custom_class` 引用这个 id。
  参考 `$SRC/movieclaw_tracker/sites/custom/` 下现有的站点类。

## 13. 用户要填的配置与凭据

用户要填的值（账号 ID、地址、间隔、Key），写成配置模型交给 `@plugin(config=...)`：插件详情页会自动出现
「设置」表单，用户保存后插件按新值重启，`ctx.config` 拿到的就是模型实例。插件包、本地插件、独立进程都一样。

```python
from pydantic import BaseModel, Field, SecretStr

class Settings(BaseModel):
    douban_id: str = Field("", title="豆瓣用户 ID", description="个人主页地址里的那串数字")
    interval: int = Field(3600, ge=300, title="拉取间隔（秒）")
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


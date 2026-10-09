# 插件体系原理

## 1. 一切都是插件

MovieClaw 主程序自己就由约 60 个插件拼成（数据库、调度、订阅、下载、媒体库、IM 通道中枢……），
它们和你写的插件跑在同一个**插件内核**（`$SRC/movieclaw_kernel/`）上。插件之间不直接 import 对方的对象，
只通过**契约**协作：

| 契约 | 插件怎么用 | 例子 |
|---|---|---|
| 服务 `ServiceKey` | `@plugin(inject=(KEY,))` 声明，`ctx.use(KEY)` 取 | `HOST_OPS`、`PLUGIN_DATA`、`PLUGIN_ROUTES` |
| 注册表 `RegistryKey` | `ctx.contribute(KEY, "<贡献 id>", 贡献项)` 往里加一项 | `IM_CHANNELS`、`SCHEDULED_TASKS`、`INGEST_STEPS` |
| 事件 `Event` | `ctx.on(EVENT, handler, id=...)` 监听 | `LIBRARY_INGEST_IMPORTED`、`SUBSCRIPTION_CREATED` |
| 决策钩子（也是 `Event`，模式为 waterfall / bail） | `ctx.on(HOOK, handler)`，返回值影响主程序的决策 | `SEARCH_KEYWORDS`、`CANDIDATES_FILTER`、`DOWNLOADER_SELECT` |

每个契约有**稳定性**：`internal`（只给内置插件）、`experimental`、`stable`。第三方插件只能用 experimental 以上的，
完整清单就是 `scripts/contracts.py` 的输出（与 `$SRC/movieclaw_sdk/surface.json` 快照一致）。用了内部契约，
`ctx.use` / `ctx.on` 会直接抛 `PermissionError`。

## 2. 插件与条目

```python
from movieclaw_sdk import Context, plugin

@plugin("me.hello", title="你好", inject=(PLUGIN_DATA,), permissions=("library.list",))
async def apply(ctx: Context) -> None:
    ...
```

- `@plugin` 声明一个插件：名字（= 条目 id）、标题、要注入的服务、要调用的宿主操作。`apply` 必须是 `async def`。
- 一次挂载叫一个**条目**。诊断、日志、插件数据、路由前缀都以条目 id 隔离。
- 条目 id 规则：小写、带命名空间、`^[a-z0-9][a-z0-9-]*(\.[a-z0-9][a-z0-9_-]*)+$`，如 `me.hello`、`acme.group-blocklist`。
  不能和内置插件、本地插件撞名；和随带插件包（如 `channel.weixin`）同 id 表示**替换**它。

## 3. 生命周期

```
上传 → 校验（清单、兼容、权限）→ 待批准 → 用户批准 → 解包到 data/plugins/packages/<id>/<版本>/
     → 启动独立进程、导入入口模块、找到同名 @plugin → 执行 apply（登记）→ active
卸载 / 升级 / 回滚：撤销该条目登记过的一切（逆序）→ 进程退出 →（升级时）挂上新版本
```

- `apply` 只做登记：`ctx.on`、`ctx.contribute`、`routes.mount`、`ctx.task`、`ctx.effect`。
  这些都被内核记账，卸载时按登记的逆序自动撤销——所以插件可以**热插拔**，不用重启主程序。
- `apply` 有 30 秒上限，超时或抛错 = 启动失败。首次安装失败会撤销安装；升级失败自动回到上一版。
- 自己打开的资源（客户端连接、文件句柄）用 `ctx.effect(释放函数, label=...)` 登记；后台循环用
  `ctx.task(coro, name=...)`，卸载时会被取消并等待结束。
- 插件反复崩溃（连续拖垮）会被**安全模式**隔离：下次启动不加载第三方插件，直到用户退出安全模式。

## 4. 运行位置

| `runtime` | 在哪跑 | 权限 | 何时用 |
|---|---|---|---|
| `process`（默认） | 独立子进程，非特权用户 | 拿不到主密钥、数据库地址；文件只能经 `PLUGIN_FILES` 访问批准过的目录 | 一律用这个 |
| `inline` | 主程序进程里 | 与主程序相同 | 只有用户明确要求、且插件确实需要（极低延迟）时；安装须单独批准 |

进程外运行时，宿主为插件生成代理：`ctx.use(...)` 的服务、`ctx.on` 的监听器、`ctx.contribute` 的贡献项、
挂的路由都经标准输入输出上的协议转发（`$SRC/movieclaw_sdk/runner.py`）。所以：

- 载荷、返回值要能 JSON 序列化（契约里的类型都满足）；
- 贡献项若是对象（如通道驱动），它的方法会被远程调用，方法必须是 `async`；
- 插件进程的运行副本在 `/tmp/movieclaw-plugins/`，它看到的主程序源码是一份只读快照。

同一份代码当「本地插件」（`data/plugins.yaml` 开启，改了要重启）或「插件包」（运行中安装）都能跑。
你写的一律做成**插件包**。

## 5. 权限模型

插件「做事」不直接改数据库，而是调用**宿主操作**：与 `mclaw` 命令行、MCP、Agent 同一份 OpenAPI 操作目录。

- 清单 `permissions.operations` 申请，用户批准时逐项确认；`领域.*` 只覆盖该领域的**非危险**操作，
  危险操作（删除、清理这类，`mclaw` 帮助里带 ⚠）必须逐个列出。
- 插件以自己的身份调用：`ops = await ctx.use(HOST_OPS).client(ctx)`，`await ops.call("<操作 id>", {参数})`。
  没批准的操作调用时报权限错误。失败抛 `OpsError(status, code, message, details)`
  （`from movieclaw_api.services.host_ops import OpsError`）。
- 文件：清单 `permissions.paths` 申请目录（绝对路径，或 `staging` / `library` / `library:<id>` 这类别名），
  经 `PLUGIN_FILES` 读写；插件自己的目录 `files.path("plugin", ...)` 总是可读写。
- 网络：`permissions.network = true` 只是声明给用户看；连外网要走用户的代理设置（`movieclaw_sdk.net.http_transport`）。

## 6. 数据与状态

- 插件数据 `PLUGIN_DATA`：键值存储，按条目隔离；`scope` 可挂到实体上（`entity_scope("subscription", 35)`）；
  `secret=True` 加密存储。卸载默认保留数据，重装后还在。
- 插件包目前**没有用户可改的配置**（`ctx.config` 只有配置模型的默认值）。需要用户可调的参数时：
  先用常量；或挂一个管理员路由让用户写进插件数据；或请用户告诉你值后改代码发新版本。

## 7. 主程序源码在哪

| 位置 | 内容 |
|---|---|
| `$SRC/movieclaw_kernel/` | 内核：`plugin`、`Context`、事件总线、契约与版本、测试工具 `KernelHarness` |
| `$SRC/movieclaw_sdk/` | 给插件用的 SDK：`plugin` / `Context` 再导出、IM 通道契约、网络出口、进程外运行器、契约表面 |
| `$SRC/movieclaw_plugins/` | 随应用携带的插件包（四个 IM 通道），与第三方插件包同格式，最好的完整样板 |
| `$SRC/movieclaw_api/plugins/` | 主程序的内置插件与插件管理（清单校验 `packages.py`、随带包 `bundled.py`、服务键 `keys.py`） |
| `$SRC/movieclaw_api/domain_events.py`、`hooks.py`、`pipeline.py` | 领域事件、决策钩子、入库流水线槽位 |
| `$SRC/movieclaw_api/services/plugin_*.py`、`host_ops.py` | 插件用到的各服务的实现（看方法签名） |
| 本技能 `references/examples/` | 设计验收用的示例插件（删片联动、片单订阅、关键字规则、网盘上传、ntfy 通道） |

已安装的插件包在数据目录 `plugins/packages/<id>/<版本>/`，当前版本记在 `plugins/packages/state.json`。

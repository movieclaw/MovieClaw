# 插件体系 · 第一阶段：插件内核与自举

> 状态：**设计稿 v2，待评审**（2026-10-08）。v1 只覆盖了「把启动编排改成插件树」；v2 围绕
> 稳定性、可扩展性、插件开发体验重新审视，补上了以后返工代价大、必须在第一阶段定死的契约：
> 插件与挂载条目分离、一对多注册表、契约版本与稳定性分级、可跨进程约束、事件的超时/校验/熔断
> 语义、测试工具与严格模式。
>
> 源起：要做一套插件体系满足个性化需求、又不影响主程序。调研了 Emby / Jellyfin / Plex
> 和 DeepSeek Harness（dsh）后定下方向：**内核思想学 dsh——没有特权内核，官方功能也是插件；
> 信任边界学 Plex——第三方代码默认进程外运行**。整体分四个阶段，本文细化第一阶段，同时给出
> 总体蓝图（§3），说明第一阶段的每个决定是为后面哪一步铺路。
>
> 依据：main 分支 `6851d322` 的代码调研（`movieclaw_api/lifespan.py`、
> `movieclaw_scheduler/{registry,service}.py`、`movieclaw_api/services/jobs.py`、
> `services/push/hub.py`、`movieclaw_channel/adapter.py`、`movieclaw_downloader/factory.py`、
> `movieclaw_tracker/registry.py`、`tests/conftest.py`）；dsh 仓库 `docs/architecture.md`、
> `docs/cordis-primer.md`、`docs/cordis-tutorial/02~06`、`docs/defensive-patterns.md`、
> `packages/boot/plugin-manager/README.md`、`packages/client/ui-slots/README.md`、`SAFETY.md`。
>
> v2.1（同日）：用真实扩展场景（删片联动删种、网盘上传后入库、关键字订阅、外部信号触发订阅、站点与订阅链路）
> 推演后，按 `docs/design/plugin-extension-model.md` §6 修订：事件区分「实时 / 可靠」投递、监听器带稳定 id、
> 内核贯穿发起方与因果链、决策钩子无副作用；第二阶段拆为二 A / 二 B。
>
> 关联文档：`docs/design/plugin-extension-model.md`（总体扩展模型与场景推演，本文是其第一阶段）、
> `docs/design/architecture-refactor-plan.md`（分层收口，本文不推翻其结论）、
> `docs/design/webhook.md`（领域事件信封，第二阶段并入事件总线）、
> `docs/design/cache-management.md`（数据目录登记，插件数据目录第三阶段接入）、
> `docs/design/member-permissions-v2.md`（插件贡献的操作第三阶段接入权限）。

## 0. 定位与硬决策

一句话：**第一阶段不加载任何第三方代码，而是写一个小内核，把 MovieClaw 自己的后端改造成
「一棵由内置插件组成的树」；同时把将来第三方插件要依赖的契约规则——版本、稳定性、可跨进程、
事件语义——一次定死，并让内置插件先按这些规则跑通。**

硬决策：

1. **内核自研、零依赖。** 放在新叶子包 `movieclaw_kernel`，只依赖标准库，将来原样作为插件 SDK
   的核心发布。pluggy 等现成库缺服务注册、依赖等待、可撤销副作用和生命周期，见 §17。
2. **行为零变化为原则，唯一例外是启动容错**（§9）：非关键子系统启动失败，从「整站起不来」改为
   「这一项标记失败、其余照常、待处理事项里提醒」。
3. **不改存量调用点。** `get_database()`、`get_scheduler()` 这类模块级单例保留，插件负责初始化
   和关闭它们；`ctx` 与单例并存，存量调用点在第二阶段按 seam 逐个迁移。
4. **不做代码热重载。** 进程内只支持「卸载 / 重新挂载」（靠可撤销注册）。真正的「改代码即生效」
   由第三阶段的进程外插件以「重启插件进程」实现，天然可靠。
5. **启动串行。** 按依赖拓扑序逐个启动，同层按清单顺序。
6. **第三方代码默认进程外。** 第一阶段不实现，但内核的稳定契约从第一天起就必须满足可跨进程约束（§5.3）。

## 1. 为什么第一阶段做这些

dsh 能「打开内核」，靠的不是接口开得多，而是**官方功能和第三方插件用同一套机制**。
Jellyfin 的插件接口只是内核的一个子集，插件永远够不到核心；它的接口又直接暴露内部类，
导致 10.11 换数据库层时大部分插件都要重发，10.11.9 一个小版本改了 `IUserManager`，旧插件
运行时直接 `MissingMethodException`。

所以第一阶段要同时解决两件事：

- **自举**：先让内置子系统全部成为插件，API 不够用会立刻暴露，「插件能做什么」由内置插件
  实际做了什么来定义。
- **契约**：把「什么是公开契约、怎么演进、怎么跨进程」定成规则，否则第二阶段一开放就会把
  内部接口变成事实上的公开 API，重走 Jellyfin 的老路。

现状本身也有痛点：

| 现状 | 问题 |
|---|---|
| `lifespan.py` 415 行，手工排列约 37 个启动步骤 | 新增子系统要读懂整段顺序；关闭顺序全靠注释维护 |
| 定时任务靠 lifespan 里一长串 `import ... # noqa: F401` 触发 `@register_task` | 注册是 import 副作用，不可撤销，说不清归谁 |
| 后台任务处理器同上；其中章节、批量转移、重复文件三类处理器不在列表里，靠路由模块碰巧 import 才注册上 | 正是 lifespan 注释警告过的隐患 |
| 下载器（`_ADAPTERS` 字典）、站点（`register_site`）、IM 通道（`ImChannelId` 字面量）、任务、处理器各有一套注册表 | 五套写法，没有统一的冲突、撤销、覆盖规则 |
| 任一 `init_xxx` 抛错整站起不来 | 边缘子系统拖垮播放、媒体库 |
| 启动慢只能看日志时间戳猜（issue #162） | 没有逐子系统耗时 |

## 2. 设计原则

**稳定性——插件出问题，主程序不受影响：**

- S1 所有注册都可撤销；卸载必须走到「完全停稳」，不能只是发出停止信号（dsh 防御性模式原文）。
- S2 插件的回调都在隔离里执行：抛错、超时、返回值不合契约，都按「这个插件不存在」处理，核心流程继续。
- S3 反复出错的插件自动熔断，冷却后再试；不会每次请求都去撞同一个坏插件。
- S4 主程序升级后，不兼容的插件在**加载前**就被识别出来（标记「不兼容」），而不是运行到一半崩溃。
- S5 关键路径（数据库、配置、加密）之外，任何插件失败都不阻断启动。

**可扩展性——能扩展的范围足够深，而且演进不伤插件：**

- E1 官方功能也是插件，没有特权内核；能扩展的范围 = 内置插件实际用到的范围。
- E2 两种扩展形态：**服务**（一个提供方，可替换）和**注册表**（多个贡献方，可覆盖）。
- E3 每个公开契约（服务键、注册表键、事件）都带版本号和稳定性分级，独立演进。
- E4 稳定契约必须可跨进程：参数和返回值可序列化、只用异步方法，不传数据库会话和回调函数。
- E5 能用数据表达的扩展不要求写代码（站点定义、规则集、推送模板），数据包插件零风险。

**易开发——写插件、测插件、排查插件都要省心：**

- D1 最小插件只需要一个带装饰器的函数，不需要继承、不需要样板。
- D2 依赖和能力都显式声明，类型检查器能发现大部分接线错误。
- D3 内核出一套测试工具（`KernelHarness`），内置插件和第三方插件用同一套；退出时自动检查泄漏。
- D4 一切「为什么没生效」都能查到原因：缺哪个依赖、哪个契约版本不符、被谁覆盖、熔断到什么时候。
- D5 契约目录从代码生成，文档不会和实现脱节。

## 3. 总体蓝图（四个阶段如何衔接）

### 3.1 插件分层

| 层级 | 例子 | 运行位置 | 能做什么 | 引入阶段 |
|---|---|---|---|---|
| 内置插件 | 本仓库的全部子系统 | 主进程 | 全部，包括内部契约 | 第一阶段 |
| 数据包插件 | 站点定义、规则集、推送模板、识别规则 | 主进程（只是数据，按 schema 校验） | 往「可声明」的注册表里填数据 | 第二阶段 |
| 代码插件 | 第三方开发的插件 | **独立进程** | 只能用声明过、用户批准过的稳定 / 实验契约 | 第三阶段 |
| 受信代码插件 | 用户自己写、明确批准进程内运行 | 主进程 | 同上，换取更低延迟 | 二 A（本地受信插件）/ 第三阶段 |

数据包这一层值得强调：现在的 `data/site-configs/*.yaml` 用户目录，本质上就是一个数据包插件。
很多个性化需求（加一个站点、改一套规则、换推送文案）根本不需要写代码，做成数据包既安全又好分享。

### 3.2 四个阶段

| 阶段 | 内容 |
|---|---|
| 一：内核与自举（本文） | 内核；全部内置子系统改为插件；任务与处理器走注册表；诊断；契约规则定稿 |
| 二 A：能力底座 | 插件主体与按操作授权，宿主操作复用 OpenAPI 操作目录（`ctx.ops`）；可靠事件（事务内写入、提交后投递、死信）；第一批领域事件（删除、回收站、下载完成、入库完成、订阅生命周期）；文件到种子的关联落库；下载意图归属；本地受信插件 |
| 二 B：开放点 | 订阅链路决策钩子；提供方注册表（站点、框架、认证、下载器、通知渠道、Webhook 格式）；管线槽位；插件路由与签名链接；实体扩展字段；健康上报；数据包；运行中启停；插件配置表单；契约目录与表面快照 |
| 三：第三方插件 | 插件包格式与清单；安装、兼容检查、失败回滚；进程外运行器与代理；凭据与存储；路径授权；安全模式；开发者工具链 |
| 四：客户端扩展 | Web 端 slot；原生端声明式界面 |

每个阶段的验收插件与依据见 `plugin-extension-model.md` §5。

## 4. 内核设计（`src/movieclaw_kernel`）

### 4.1 插件与条目

- **插件**：一段代码及其元数据（依赖、提供、配置 schema、契约要求）。
- **条目**：插件的一次挂载，带自己的 id 和配置。

```python
@plugin("channel.telegram", title="Telegram 通道", inject=(AGENT_RUNS,))
async def telegram(ctx: Context) -> None: ...

BUILTIN_MANIFEST = [
    Entry("channel.telegram", telegram),                    # 单实例：条目 id = 插件名
    # 将来：Entry("channel.telegram#family", telegram, config={...})  同一插件多实例
]
```

第一阶段所有内置插件都是单实例，但诊断、补丁、日志、指标从一开始就**以条目 id 为准**，
将来支持多实例时不需要返工。这一点照搬 Cordis：配置树里的每一行是条目，不是插件。

### 4.2 两种契约：服务键与注册表键

**服务键**：一个提供方。适合「整个系统只有一个」的东西（数据库、调度器）。

```python
DB = ServiceKey[Database]("db", version="1.0", stability=Stability.INTERNAL)
```

**注册表键**：多个贡献方，每条贡献有自己的 id。适合下载器类型、站点框架、推送渠道、
定时任务、后台任务处理器。

```python
SCHEDULED_TASKS = RegistryKey[TaskDefinition]("scheduled-tasks", version="1.0", stability=Stability.INTERNAL)

ctx.contribute(SCHEDULED_TASKS, "torrent_sync", definition)     # 可撤销
reg = ctx.registry(SCHEDULED_TASKS)
reg.get("torrent_sync"); reg.items()
ctx.watch(SCHEDULED_TASKS, on_change)                           # 增删通知，也是可撤销注册
```

注册表由内核按键名惰性创建，不需要「提供方插件」。规则：

| 情况 | 处理 |
|---|---|
| 两个贡献 id 相同 | 后到者失败（报错写明与谁冲突），除非它显式 `override=True` |
| `override=True` | 形成覆盖栈：新贡献生效、旧贡献被「遮住」；覆盖者卸载后旧贡献自动恢复 |
| 遍历顺序 | 按 `(priority, 层级, 注册顺序)` 确定，结果可复现 |
| 第三方贡献的 id | 自动加插件 id 前缀（`acme.blocklist:xxx`），避免撞名；内置贡献保留现有 id（数据库里存着任务 key，不能改） |

覆盖栈是「替换内置行为」的标准方式：用户的插件覆盖内置的某个下载器适配器，停用插件就自动
回到内置版本，不需要手动恢复任何东西。

服务键刻意**不支持**覆盖栈：替换单例服务必须在补丁里显式禁用内置提供方、启用新提供方，
避免「不知道谁在提供数据库」这种隐式状态。

两种键都携带契约元数据：

| 字段 | 含义 |
|---|---|
| `version` | `主.次`：次版本只做向后兼容的增加，主版本可以破坏 |
| `stability` | `INTERNAL`（仅内置可用）/ `EXPERIMENTAL`（第三方可用，可能变）/ `STABLE`（承诺兼容） |
| `doc` | 一句话说明，进契约目录 |
| `schema` | 注册表键可选：声明贡献项的 pydantic 模型；有 schema 的注册表可以接收数据包（§3.1） |

### 4.3 插件声明

```python
@plugin(
    "library.watch",            # 插件名：<领域>.<名字>
    title="媒体库实时监控",
    inject=(DB,),               # 硬依赖：都就绪才启动
)
async def library_watch(ctx: Context) -> None:
    from movieclaw_api.services.library.watch import close_library_watcher, init_library_watcher

    await init_library_watcher()
    ctx.effect(close_library_watcher)
```

`@plugin` 的参数：

| 参数 | 含义 | 默认 |
|---|---|---|
| `name` | 插件名 | 必填 |
| `title` | 中文名 | 必填 |
| `inject` | 硬依赖的服务键 | `()` |
| `provides` | 本插件会提供的服务键（静态声明，用于排序和提前发现缺口；启动结束时校验） | `()` |
| `requires` | 契约版本要求，如 `{"downloaders": "^1.1"}`；内置插件不写（永远与主程序同版本） | `{}` |
| `critical` | 启动失败是否中止整个应用 | `False` |
| `disableable` | 是否允许在补丁里禁用（逐个审过才打开，§10.3） | `False` |
| `apply_timeout` | 启动超时秒数；关键插件不设超时 | `30` |
| `reloadable` | 是否通过了「卸载 → 再挂载」测试（§12.4），第二阶段只对它开放运行中启停 | `False` |

### 4.4 上下文 API

| 方法 | 作用 | 可撤销 |
|---|---|---|
| `ctx.use(KEY)` | 取已注入的服务；未在 `inject` 声明就报错 | — |
| `ctx.get(KEY)` | 取可选服务，没有返回 `None` | — |
| `ctx.provide(KEY, value)` | 提供服务 | 是：撤下前先释放所有依赖方 |
| `ctx.contribute(RKEY, id, item, *, priority=0, override=False)` | 往注册表贡献一项 | 是 |
| `ctx.registry(RKEY)` | 读注册表 | — |
| `ctx.watch(RKEY, callback)` | 订阅注册表增删 | 是 |
| `ctx.on(EVENT, handler, *, id=None, priority=0)` | 订阅事件；`id` 是监听器在条目内的稳定标识，可靠事件必填（§4.7） | 是 |
| `ctx.origin` | 当前发起方与因果链（§4.7），只读 | — |
| `ctx.events` | 分发事件（§4.7） | — |
| `ctx.effect(disposer)` | 登记释放函数（同步/异步均可） | 是 |
| `ctx.task(coro, *, name)` | 起后台协程；任务名自动带条目 id | 是：取消并**等它结束** |
| `ctx.plugin(child)` | 挂载子插件，用于「可选依赖」 | 是 |
| `ctx.settings` | 应用 `Settings`（只读） | — |
| `ctx.logger` | 以条目 id 命名的 logger | — |

**子插件是可选依赖的标准写法**：父插件本身不依赖某服务，只有其中一部分需要。例如应用更新插件：
清理旧提醒总要做，但「启动后首查」只有调度器开着时才有意义：

```python
@plugin("app-update", title="应用更新", inject=(DB,))
async def app_update(ctx: Context) -> None:
    await clear_legacy_update_notices()
    ...
    ctx.plugin(app_update_startup_check)        # 调度器禁用时这部分停在等待状态

@plugin("app-update.startup-check", title="启动后检查更新", inject=(SCHEDULER,))
async def app_update_startup_check(ctx: Context) -> None:
    start_startup_check()
    ctx.effect(close_startup_check)
```

定时任务**不需要**这种写法：任务只是往注册表里贡献，调度器在不在都不影响贡献（§6）。

### 4.5 生命周期状态

```
DISABLED      INCOMPATIBLE
PENDING → LOADING → ACTIVE → UNLOADING → DISPOSED
              ↘ FAILED
```

| 状态 | 含义 | 诊断附带信息 |
|---|---|---|
| `DISABLED` | 补丁或开关禁用 | 由谁禁用（补丁 / 环境变量） |
| `INCOMPATIBLE` | `requires` 与主程序契约版本不符，**不会加载** | 哪个契约、要求的版本、实际版本 |
| `PENDING` | 依赖的服务还没有 | 缺哪个键；是「没人提供」还是「提供方失败 / 禁用 / 不兼容」 |
| `LOADING` | `apply` 运行中 | 已运行多久 |
| `ACTIVE` | 正常 | 启动耗时、运行指标（§4.8） |
| `FAILED` | `apply` 抛错或超时；已登记的副作用已全部回滚 | 错误与堆栈 |
| `UNLOADING` / `DISPOSED` | 释放中 / 已释放 | 释放耗时；超时未停稳的标记 |

依赖持续跟踪：提供方被释放时，依赖方先被释放并回到 `PENDING`；提供方恢复后依赖方自动重新挂载。

### 4.6 启动、关闭与结构变更

**结构变更串行化。** 启动、关闭、启用、禁用、因依赖变化引起的级联，全部经过内核的一个串行队列，
任何时刻只有一个结构变更在进行。插件在 `apply` 里发起的结构变更（例如挂子插件）排到当前变更之后执行，
避免重入。

**启动** `await kernel.start(manifest, patches)`：

1. 合并清单与补丁层得到条目列表。
2. 静态校验：条目 id 重复、同一服务键多个提供方、依赖成环 → 报错（属于代码缺陷）。
3. 契约检查：`requires` 不满足 → `INCOMPATIBLE`。
4. 静态标记：依赖的键没有任何可用条目提供 → `PENDING` 并写明原因。
5. 按拓扑序串行执行 `apply`，同层按清单顺序（**清单顺序沿用现 lifespan 的顺序**）：
   - 记录每个条目的启动耗时，超过 2 秒打 warning；
   - 非关键插件超过 `apply_timeout` → 取消、回滚、`FAILED`（防 issue #162 这类启动卡死）；
   - 失败：回滚该条目已登记的副作用；关键插件失败 → 逆序释放全部已启动条目后抛出，应用启动失败；
     非关键插件失败 → `FAILED`，依赖方留在 `PENDING`，继续往下；
   - `apply` 结束时校验 `provides` 声明的键都已提供，否则按失败处理。
6. 发出 `kernel/ready`。

**关闭** `await kernel.stop()`：

- 按**激活顺序的逆序**逐个释放。激活顺序是拓扑序，所以依赖方一定先于提供方释放。
- 条目内的释放函数按登记逆序**串行**执行；`ctx.task` 起的协程被取消并等待结束。
- 单个条目释放超过 10 秒：打 warning、在诊断里标记「未停稳」、继续下一个，避免一个卡死的子系统
  拖住后面的清理（特别是最后的数据库落统计）。时限可配。

**排序规则一句话：声明顺序 = 激活顺序（在依赖允许的范围内）= 释放的逆序。** 现 lifespan 注释里
那些「谁先停」的约束，全部用「真实依赖写进 `inject`」加「清单顺序」表达，并逐条用测试断言（§12.2），
不另设「仅排序」的概念。

### 4.7 事件总线

事件是带分发模式、版本和稳定性的常量。**模式是契约的一部分**，用错分发方法直接抛 `TypeError`：

```python
PLUGIN_STATE = Event[PluginStateChanged, None](
    "kernel/plugin-state", Mode.EMIT, version="1.0", stability=Stability.INTERNAL,
)
```

| 模式 | 调用 | 语义 | 第二阶段典型用途 |
|---|---|---|---|
| `EMIT` | `ctx.events.emit(E, payload)` | 只通知，发出方不等待 | 领域事件（入库、播放、订阅） |
| `WATERFALL` | `await ctx.events.waterfall(E, payload, terminal=默认实现)` | 洋葱式中间件：`handler(payload, next)`，可改输入、包装结果、或不调 `next` 直接短路 | 搜索结果排序过滤、投递路径翻译、推送文案 |
| `BAIL` | `await ctx.events.bail(E, payload)` | 依次询问，第一个返回非 `None` 的说了算 | 「这个资源要不要下」「用哪个版本播」 |

`serial` / `parallel` 两种模式用到时再加。

**`EMIT` 事件区分两种投递方式**（事件定义的 `delivery` 字段）：

| 投递方式 | 语义 | 适用 | 第一阶段 |
|---|---|---|---|
| `LIVE`（默认） | 内存队列，至多一次，重启即丢 | 统计、展示、低价值通知 | 实现 |
| `DURABLE` | 业务事务内写入事件表，提交后投递，至少一次，失败重试，超限进死信；消费方按事件 id 幂等 | 有后果的自动化（删片后删种、入库后上传） | 只定接口 |

- `DURABLE` 事件的监听器必须带稳定 `id`：消费进度以「条目 id + 监听器 id」为键，跨重启续投。
- `DURABLE` 的存储与投递由服务 `DURABLE_EVENTS` 提供（第二阶段 A 由应用层插件实现）。第一阶段没有提供方，
  订阅了可靠事件的插件按普通依赖规则停在 `PENDING` 并写明原因——**内核接口第二阶段不必再改**。
- 依据见 `plugin-extension-model.md` §4。

**发起方与因果链。** 内核用 `contextvar` 记录「当前操作由谁发起（用户 / 成员 / 插件 / 系统）、因哪个事件引起」，
自动传过 `ctx.task`、事件分发，第二阶段起再传过宿主操作；每个事件载荷都带上它。两个用途：

- 插件可以识别并忽略自己引起的事件（`event.cause.is_plugin(ctx.entry_id)`）；
- 因果链长度超过 8 时内核拒绝继续分发并报错，防止插件之间经可靠事件互相触发成环
  （同一调用栈内的递归由下文的「递归嵌套超过 8 层」规则覆盖）。

**决策钩子不许有副作用。** `WATERFALL` / `BAIL` 的监听器只能计算、只能读，不能写库、不能调下载器、不能发通知。
一次决策可能被后续环节否决，钩子里的副作用就会变成孤儿；核心事务里也不能混进插件代码。副作用一律放到提交后的
可靠事件或宿主操作里。第一阶段写进插件开发约定；第二阶段开放业务钩子时，在测试工具里提供检查（钩子执行期间
写库或调用宿主操作即报错）。

**载荷必须不可变。** 事件定义时检查载荷类型必须是冻结的 dataclass 或冻结的 pydantic 模型，否则直接报错。
waterfall 监听器要改输入，就构造一个新对象传给 `next`，而不是原地修改——这样一个插件不可能改坏
核心持有的状态，也保证将来能把载荷原样序列化给进程外插件。

**EMIT 不能反压业务。** 照搬推送中枢已经验证过的做法：

- 每个监听器一个有界队列（默认 1000），发出方只做 `put_nowait`，开销 O(监听器数)；
- 每个监听器的队列由一个归属于该插件的后台协程串行消费，所以同一监听器内事件保序；
- 队列满了丢弃新事件、计数、每分钟最多记一条日志；
- 插件卸载时它的消费协程随之取消；
- 从非事件循环线程发事件（如 watchdog 观察者线程）用 `emit_threadsafe`。

**WATERFALL / BAIL 的隔离规则：**

| 情况 | 处理 |
|---|---|
| 监听器在调用 `next` 之前抛错或超时 | 视为它不存在，用它收到的输入继续往下 |
| 在调用 `next` 之后抛错或超时 | 直接返回下游结果 |
| 返回值类型不符合事件声明（运行时校验） | 同抛错处理 |
| BAIL 监听器抛错或超时 | 视为返回 `None`，继续问下一个 |
| 同一事件递归嵌套超过 8 层 | 拒绝分发并报错（防插件互相触发成环） |

**超时**：每个事件声明 `timeout`（单个监听器）和 `budget`（整条链），由事件定义者按调用场景定，
例如搜索排序 0.5 秒。超时监听器的协程会被取消。

**熔断**：同一监听器连续 5 次失败或超时，自动暂停它，冷却时间从 1 分钟起翻倍、最长 30 分钟，
冷却后放行一次试探，成功即恢复。暂停期间分发直接跳过它，诊断里可见。

**粒度规则**：决策类事件一律按批传递（一次传整页搜索结果，而不是每条结果一个事件）。
进程外插件每次调用都有跨进程开销，按条触发会把搜索拖慢一个数量级。

第一阶段只有内核自己的事件（`kernel/plugin-state`、`kernel/ready`），**不把任何业务流程改成走事件**。
以上语义第一阶段全部实现并用单元测试锁住，第二阶段开放业务钩子时直接用。

### 4.8 可观测性

全部在内存里、零落盘，满足「统计计量不碰盘、按需运行」的要求：

- **归属**：内核用 `contextvar` 记录「当前正在执行哪个条目的代码」（`apply`、事件监听器、`ctx.task`），
  日志过滤器把它加进每条日志记录。深处领域代码打的日志，也能看出是替哪个插件干活。
- **任务命名**：`ctx.task` 起的协程名一律是 `plugin:<条目 id>:<名字>`，py-spy、asyncio 调试、
  泄漏检查都能直接认出归属。
- **指标**：每个条目一份内存计数——启动 / 释放耗时、监听器数、处理事件数、失败数、超时数、
  丢弃数、处理耗时（最大值和滑动平均）、熔断状态、存活的后台任务数。开销是每次回调一对
  `perf_counter`。

### 4.9 测试工具与严格模式

内核自带 `movieclaw_kernel.testing`，内置插件的测试和将来第三方插件的测试用同一套：

```python
async def test_library_watch_cleans_up(tmp_path):
    async with KernelHarness(strict=True) as h:
        h.provide(DB, fake_database(tmp_path))     # 用假的服务替换依赖
        entry = await h.mount(library_watch)
        assert entry.state is State.ACTIVE
        await h.unmount(entry)
    # 退出时严格模式自动检查：该条目的任务、监听器、贡献、子插件是否全部撤回
```

严格模式检查项：卸载后仍存活的 `plugin:<id>:*` 协程、未撤回的监听器和贡献、未释放的子插件。
测试里默认开启，生产关闭。`KernelHarness` 还提供直接分发事件、读取指标、模拟提供方消失
（验证依赖方的级联）等能力。

### 4.10 规模估计

| 模块 | 内容 | 行数（估） |
|---|---|---|
| `contracts.py` | `ServiceKey`、`RegistryKey`、`Stability`、版本比较 | 80 |
| `plugin.py` | `@plugin`、`Entry`、元数据校验 | 80 |
| `context.py` | `Context` 及其注册 API | 160 |
| `registry.py` | 注册表、覆盖栈、增删通知 | 110 |
| `kernel.py` | 清单合并、契约检查、拓扑排序、状态机、启动、关闭、级联、串行队列 | 300 |
| `events.py` | 三种模式、载荷检查、队列、超时、返回值校验、熔断、递归保护 | 220 |
| `observe.py` | 归属 contextvar、日志过滤器、内存指标 | 70 |
| `testing.py` | `KernelHarness`、严格模式 | 120 |
| 合计 | | **约 1140** |

比 v1 估的 530 行多一倍，多出来的部分对应 §2 的稳定性和易开发原则。每一项都在 §17 说明了为什么
现在做而不是以后做。

## 5. 契约规则

### 5.1 稳定性分级

| 级别 | 谁能用 | 能怎么改 |
|---|---|---|
| `INTERNAL` | 仅内置插件 | 随时改，不另行通知 |
| `EXPERIMENTAL` | 第三方可用，安装时提示 | 次版本内可以破坏，须在更新日志写明 |
| `STABLE` | 第三方可用 | 次版本只增不破；破坏性修改必须升主版本，旧主版本至少保留一个大版本周期（双版本并存，由内置适配插件转接） |

第一阶段所有契约都是 `INTERNAL`。第二阶段每开放一个，就是一次明确的「升为 `EXPERIMENTAL`」决定。

### 5.2 版本检查

- 插件在 `requires` 里写 `{"<契约名>": "^主.次"}`，含义是「主版本相同、次版本不低于」。
- 检查发生在**加载之前**：不满足就是 `INCOMPATIBLE`，不执行插件的任何代码。主程序升级后，不兼容的
  插件变成「不兼容」状态并在待处理事项里提示，而不是崩溃。
- `requires` 里写了 `INTERNAL` 契约 → 第三方插件直接拒绝加载。

### 5.3 可跨进程约束（适用于 `EXPERIMENTAL` 和 `STABLE`）

- 服务和注册表项的方法一律 `async`。
- 参数、返回值、事件载荷只能是基本类型、冻结 dataclass、冻结的 pydantic 模型及其列表 / 字典组合。
- 不允许传数据库会话、ORM 对象、文件句柄、回调函数、生成器。
- 需要回调的场景改成事件；需要流式数据的场景改成分页。

这条规则在第一阶段写进文档；第二阶段第一个契约升为 `EXPERIMENTAL` 时，配套一个按类型注解自动检查
的测试。满足了它，第三阶段的进程外代理就能对任何契约通用生成，不需要逐个手写。

### 5.4 契约目录与表面快照（第二阶段）

- 从代码生成契约目录（每个服务键、注册表键、事件的版本、稳定性、说明、提供方、贡献方、监听方），
  CI 检查目录与代码一致。
- 对 `STABLE` 契约的签名做快照，CI 比对：签名有破坏性变化但主版本没升 → 构建失败。

## 6. 定时任务与后台任务：改为注册表贡献

现在 `@register_task` 和 `register_job_handler` 在 import 时直接写进全局字典。第一阶段拆成两步：

1. **声明**（纯标记，无副作用）：装饰器只把定义挂在函数上。
   ```python
   @scheduled_task("torrent_sync", title="同步种子", trigger_type=TriggerType.INTERVAL, interval_seconds=900)
   async def sync_torrents() -> None: ...
   ```
2. **贡献**（插件里做，可撤销）：
   ```python
   contribute_tasks(ctx, torrent_sync)          # 把模块里带标记的函数逐个 contribute 到 SCHEDULED_TASKS
   contribute_job_handlers(ctx, library_scan)   # 同理，贡献到 JOB_HANDLERS
   ```

两个引擎改成**注册表的消费者**：

| 引擎 | 改动 |
|---|---|
| 调度器 | 启动时读注册表现有项，并 `watch` 后续增删：新增 → 补数据库行（沿用 `create_if_absent`）、按库中定义加 APScheduler job（复用 `reschedule()` 逻辑）；撤下 → 摘掉 job、**保留数据库行**（保留用户改过的周期）。「库里有定义但没有处理器」的逐条告警，改为 `kernel/ready` 后汇总一次 |
| 后台任务执行器 | 领取时只领注册表里**当前有处理器的类型**（`_claim_one` 加 `job_type IN (...)`）。处理器所属插件没启用时，任务留在队列里等，而不是被领走后报「请更新版本」 |

好处：

- 领域插件只管贡献，**不需要依赖调度器或执行器**。调度器禁用时（`SCHEDULER_ENABLED=false`），任务
  安静地待在注册表里；领域插件的其他部分照常工作。
- 卸载领域插件，它的任务和处理器自动撤下。
- 这正是第三方插件贡献定时任务的方式，内置插件先替它走通。

**实施时的调整（PR 3）**：装饰器保留原名 `@register_task` / `@register_job_handler`，不做全量替换。
它们既登记进模块级「声明目录」，也在函数上打标记；插件用 `contribute_tasks(ctx, 模块)` /
`contribute_job_handlers(ctx, 模块)` 把**本模块定义的**声明贡献进内核注册表。由此有两种模式：

| 模式 | 何时 | 生效的任务表 / 处理器表 |
|---|---|---|
| 内核接管 | 应用运行时，`core.registries` 插件绑定内核注册表 | 只有插件贡献的项；插件卸载即撤下 |
| 声明目录 | 没有内核（命令行工具、单独驱动调度器 / 执行器的测试） | 模块 import 时登记的全部声明，与改造前一致 |

这样几十个单独驱动执行器的测试不用改，生产环境得到新行为。

执行器在内核接管时的领取规则：**认识、但当前没有处理器**的类型（所属插件没启用）跳过，任务留在
队列里等；**没有任何代码认识**的类型照旧领取，在执行时以「当前版本无法执行这类任务」阻塞，
保留降级版本后的提示。「认识」= 本进程里声明过或被贡献过。局限：启动时就被禁用、从未贡献过的
插件，其任务类型会被当成不认识而阻塞；第一阶段允许禁用的插件都不拥有处理器，不受影响；第二阶段
开放运行中启停与第三方插件时，须把「贡献过哪些类型」持久化。

调度器关闭时，领域插件照常贡献任务，定时任务接口能看到全部任务定义（改造前只看得到被路由碰巧
import 的 7 个）；调度器自己的内置任务随它一起不在。

顺带修正一个隐患：章节识别（`library/chapters.py`）、批量转移（`library/batch_transfer.py`）、重复文件扫描
（`library/duplicate_scan.py`）的处理器并不在 lifespan 的 import 列表里，现在是靠路由模块碰巧 import 了它们
才注册上——正是 lifespan 注释里警告的「不能依赖某条路由碰巧加载过模块」。改造后它们由 `library.core` 显式注册。

## 7. 内置插件清单

位置：`movieclaw_api/plugins/`，按领域一个模块；服务键和注册表键集中在 `movieclaw_api/plugins/keys.py`；
`manifest.py` 按顺序列出全部条目。下表即清单顺序（**沿用现 lifespan 的顺序**），「关键」✔ 的失败会中止启动。

| # | 条目 id | 提供 | 依赖 | 关键 | 来自现 lifespan 的哪一步 |
|---|---|---|---|---|---|
| 1 | `core.database` | `DB` | — | ✔ | 建库、迁移、刷统计、重配日志；释放：刷统计 + 关库 |
| 2 | `core.secrets` | `SECRETS` | — | ✔ | `init_secret_box` |
| 3 | `core.settings` | `SETTING_STORE` | DB, SECRETS | ✔ | `init_setting_store` |
| 4 | `core.egress` | `EGRESS` | SETTING_STORE | ✔ | `load_network_egress` |
| 5 | `core.scrape-runtime` | — | SETTING_STORE | ✔ | `load_scrape_runtime` |
| 6 | `playback.remote-config` | — | SETTING_STORE | | `load_remote_transcode_config` |
| 7 | `core.http-clients` | — | EGRESS | | 释放：`close_media_service` + `close_image_proxy`（单例懒建，只管关闭） |
| 8 | `tracker.sites` | `SITES` | — | ✔ | `load_all_sites` |
| 9 | `tracker.site-access` | `SITE_ACCESS` | SITES, EGRESS, DB | ✔ | `init_site_access`；释放：`aclose` |
| 10 | `selfheal.credentials` | — | DB, SECRETS | | 重置卡在验证中的状态 + 存量明文凭据加密 |
| 11 | `library.builtin-collections` | — | DB | | 补齐「我的收藏」 |
| 12 | `agent.runs` | `AGENT_RUNS` | DB | | Agent 运行注册表 |
| 13 | `agent.session-index` | — | DB | | 会话索引校准 |
| 14 | `agent.attachments` | — | — | | 清理过期附件 |
| 15 | `enrich.backfill` | — | DB | | 扩充属性重算（`ctx.task`） |
| 16 | `app-update` | — | DB | | 清旧提醒、清陈旧 overlay、记基线版本；贡献每日检查任务；子插件（依赖 SCHEDULER）：启动首查 |
| 17 | `scheduler` | `SCHEDULER` | DB | | 调度器，消费 `SCHEDULED_TASKS`，并贡献自己的内置任务；`SCHEDULER_ENABLED=false` 时禁用 |
| 18 | `downloads` | — | SITE_ACCESS | | 贡献下载进度、种子同步、种子匹配、媒体刷新任务 |
| 19 | `boost` | — | SITE_ACCESS | | 贡献刷流任务；子插件（依赖 SCHEDULER）：带宽哨兵 |
| 20 | `subscription` | — | SITE_ACCESS | | 贡献智能调度、缺口搜索、洗版任务；取消订阅清理处理器 |
| 21 | `library.core` | — | DB | | 贡献扫描、导入、NFO 回填、回收站、系列回填任务；扫描、导入、整理、转移、批量转移、章节、片头、重复文件处理器 |
| 22 | `library.watch` | — | DB | | 媒体库实时监控 |
| 23 | `library.ingest-watch` | — | DB | | 下载监听导入 |
| 24 | `channel.weixin` | — | AGENT_RUNS | | 微信通道 |
| 25 | `channel.im` | — | AGENT_RUNS | | Telegram / Discord / 飞书（后改为 `channels.hub` 中枢 + 每个通道一个插件，见 plugin-channels.md） |
| 26 | `cloud` | `CLOUD` | EGRESS | | MovieClaw Cloud 续签循环 |
| 27 | `push.hub` | `PUSH_HUB` | DB | | 释放：`hub.stop()` |
| 28 | `push.channels-refresh` | — | CLOUD | | 推送通道能力快照刷新 |
| 29 | `push.arrivals` | — | PUSH_HUB, DB | | 「媒体库有新片」 |
| 30 | `jellyfin.discovery` | — | — | | UDP 7359 局域网发现 |
| 31 | `jobs` | `JOBS` | DB | | 后台任务执行器，消费 `JOB_HANDLERS` |
| 32 | `media.scrape` | — | DB | | 元数据刷新处理器 |
| 33 | `subtitle.gen` | — | DB | | 字幕生成处理器；PGS 能力预热（`ctx.task`） |
| 34 | `library.search-index` | — | JOBS | | 搜索索引（含其处理器） |
| 35 | `library.skip-segments` | — | JOBS | | 片头识别启动补算（`ctx.task`） |
| 36 | `storage.guard` | — | — | | 未登记数据目录告警 |
| 37 | `playback.remote-workers` | `REMOTE_WORKERS` | — | | 释放：`shutdown()` |
| 38 | `playback.transcode` | — | REMOTE_WORKERS | | 清孤儿分片、起心跳巡检、硬件自检预热；释放：`shutdown()`（killpg） |

`playback.transcode` 放在清单最后，关闭时**第一个**被释放，对应现注释「转码会话最先停，否则留下
满负荷烧 GPU 的孤儿 ffmpeg」。

### 7.1 关闭顺序约束的落实

| 约束（摘自现注释） | 保证方式 |
|---|---|
| 转码会话最先停（killpg 整组） | 清单最后一项 → 逆序第一个释放 |
| 远程 Worker 在转码会话之后关 | `playback.transcode` 依赖 `REMOTE_WORKERS` |
| 媒体库监听在事件循环关闭前退出 | 所有释放都在 lifespan 退出前完成 |
| 先停微信 / IM 通道，再停 Agent 注册表 | 两个通道依赖 `AGENT_RUNS` |
| 先停「新片到达」，再停推送中枢 | `push.arrivals` 依赖 `PUSH_HUB` |
| 后台任务执行器先于数据库释放 | `jobs` 依赖 `DB` |
| Agent 先于 HTTP 客户端和数据库释放 | `agent.runs` 激活晚于 `core.http-clients`，并依赖 `DB` |
| 站点客户端连接池先于数据库关闭 | `tracker.site-access` 依赖 `DB` |
| 最后刷统计、关数据库 | `core.database` 是根，最后释放 |

### 7.2 `build_lifespan` 变成薄壳

```python
def build_lifespan(settings: Settings):
    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        kernel = Kernel(settings=settings)
        app.state.kernel = kernel
        await kernel.start(BUILTIN_MANIFEST, patches=load_patches(settings))
        try:
            yield
        finally:
            await kernel.stop()
    return lifespan
```

签名不变，`tests/conftest.py` 的应用实例复用（替换 `lifespan_context`）和迁移模板快路径（扫描已加载
模块里的 `run_migrations` 并替换）都不用改。前提：`core.database` 所在模块在顶层
`from movieclaw_db.migrations import run_migrations`。

`reset_password.py` 这类命令行入口以后可以用「只含 core 组的子清单」启动，是「按需组装」的第一个受益者。

## 8. 插件开发体验：目标形态

这一节写的是第三阶段第三方开发者的体验。写在第一阶段文档里，是为了用它反推第一阶段的接口：
**下面的代码在第一阶段之后，除了「事件还没开放」和「打包加载器还没做」，其余写法应当已经成立。**

一个「按发布组屏蔽搜索结果」的插件：

```toml
# movieclaw-plugin.toml
[plugin]
id = "acme.group-blocklist"
title = "发布组黑名单"
version = "0.1.0"
entry = "group_blocklist:plugin"
runtime = "process"            # 默认进程外；"inline" 需要用户单独批准

[requires]
"search/results" = "^1.0"
```

```python
# group_blocklist.py
from movieclaw_sdk import Context, plugin
from movieclaw_sdk.search import SEARCH_RESULTS, SearchResults
from pydantic import BaseModel

class Config(BaseModel, frozen=True):
    groups: tuple[str, ...] = ()

@plugin("acme.group-blocklist", title="发布组黑名单", config=Config)
async def plugin(ctx: Context[Config]) -> None:
    async def drop_blocked(results: SearchResults, next):
        kept = tuple(r for r in results.items if r.group not in ctx.config.groups)
        return await next(results.model_copy(update={"items": kept}))

    ctx.on(SEARCH_RESULTS, drop_blocked)
```

```python
# test_group_blocklist.py
async def test_drops_blocked_group():
    async with KernelHarness(strict=True) as h:
        await h.mount(plugin, config={"groups": ["BAD"]})
        out = await h.events.waterfall(SEARCH_RESULTS, sample_results(), terminal=lambda r: r)
        assert all(item.group != "BAD" for item in out.items)
```

开发循环（第三阶段）：`mclaw plugin dev ./group-blocklist` 把本地插件以进程外方式连到正在运行的
MovieClaw（本机或 NAS），文件一改就重启插件进程——热重载靠重启进程实现，不碰主进程。

第一阶段为它准备好的部分：`@plugin`、`Context`、`ctx.on`、waterfall 语义（含不可变载荷、超时、
异常隔离）、`KernelHarness` 与严格模式、`requires` 版本检查、条目与配置分离。
留给后续阶段的部分：`movieclaw_sdk` 包（第一阶段的 `movieclaw_kernel` 加上开放的契约）、插件配置
schema（第二阶段）、`SEARCH_RESULTS` 事件（第二阶段）、打包格式、加载器、进程外运行器、`mclaw plugin`
命令（第三阶段）。

## 9. 启动容错（第一阶段唯一的行为变化）

- **关键插件**（清单 ✔ 项）失败：与现状一致，应用启动失败。没有数据库、配置、加密、网络出口、站点目录，
  大部分功能都无法降级运行。
- **非关键插件**失败或超时：标记 `FAILED`，依赖它的插件停在 `PENDING`，应用照常就绪。同时：
  - 打 error 日志（带条目 id 和堆栈）；
  - 内核发出 `kernel/plugin-state`，应用层一个小插件订阅它，复用 `system_notice.upsert_notice`
    写一条待处理事项「『微信通道』启动失败：<原因>」，插件恢复后用 `resolve_notices` 自动消退；
  - 诊断接口和页面可见（§10）。

内核本身不依赖 `system_notice`，保持叶子包；「失败 → 待处理事项」由一个普通的内置插件订阅事件完成，
这也是第一阶段唯一一个真实的事件订阅者，顺带验证了事件总线。

## 10. 诊断与禁用入口

### 10.1 诊断接口

`GET {API_V1}/app/plugins`（`app.plugins.list`），仅管理员可调。每个条目返回：

```json
{
  "id": "channel.weixin",
  "plugin": "channel.weixin",
  "title": "微信通道",
  "state": "failed",
  "critical": false,
  "provides": [],
  "inject": ["agent_runs"],
  "blocked_by": [],
  "incompatible": null,
  "error": "ConnectionError: ...",
  "apply_ms": 132,
  "parent": null,
  "source": "builtin",
  "disabled_by": null,
  "reloadable": true,
  "stats": {"events": 0, "failures": 0, "timeouts": 0, "dropped": 0, "tasks": 2, "breaker": "closed"}
}
```

另附 `contracts` 段：列出全部服务键、注册表键、事件的版本、稳定性，以及每个注册表的贡献项和覆盖关系。
这就是第二阶段契约目录的运行时版本。

### 10.2 诊断页面

在 Web 设置页「更新与维护」下加一个只读页签「模块」（实施时放进已有分区，避免新增一级入口）：插件列表（状态、启动耗时、失败原因、缺失依赖），
点开看指标和贡献项。复用设置页现有组件（`settings-ui`），不做操作按钮。

> 后续调整（第三阶段之后）：插件管理与诊断独立成「设置 → 系统 → 插件」分区，「模块」一词停用。
> 「插件」是总称：MovieClaw 自带的功能叫**内置插件**（「内置」页签，按功能分组，标「核心」的不能关闭、
> 标「可关闭」的可在 `data/plugins.yaml` 里关掉；分组规则见 `plugins/manifest.py` 的 `BUILTIN_GROUPS`）；
> 第三方开发者提供、经插件包（.mcplugin）安装的叫**第三方插件**，与**本地插件**一起在「已安装」页签。
> 配套 Chrome 扩展统一叫「浏览器扩展」，不再叫「浏览器插件」，免得与插件混淆。旧链接
> `/settings/app?tab=plugins|extensions` 重定向到新分区。

### 10.3 禁用补丁

`data/plugins.yaml`（不存在即视为空）：

```yaml
- id: jellyfin.discovery
  disabled: true
```

- 第一阶段只认 `disabled`；未知 id 打 warning 并忽略。
- 只有 `disableable=True` 的插件能被禁用，关键插件永远不能。第一阶段打开的范围：`jellyfin.discovery`、
  `channel.weixin`、`channel.im`（后拆成 `channel.telegram` / `channel.discord` / `channel.feishu`）、`cloud`、`push.arrivals`、`library.watch`、`library.ingest-watch`、
  `boost`，以及由环境变量映射的 `scheduler`。标准是「禁用后，调用到它的接口给出明确的降级结果，而不是 500」，
  逐个核对后才打开。
- 改补丁需要重启生效；运行中启停在第二阶段，只对 `reloadable` 的插件开放。

## 11. 第一阶段明确不做、但已预留位置的能力

| 能力 | 预留了什么 | 在哪个阶段做 |
|---|---|---|
| 可靠事件（事务内写入、提交后投递、死信） | 事件的 `delivery` 字段、监听器稳定 id、`DURABLE_EVENTS` 服务键 | 二 A |
| 宿主操作 `ctx.ops`（复用 OpenAPI 操作目录，以插件身份调用） | `ctx.origin` 发起方 | 二 A |
| 插件配置与表单 | 条目带 `config` 字段；`Context[Config]` 泛型 | 二 B |
| 运行时健康上报（如「凭据过期」，区别于生命周期状态） | 诊断接口结构可扩展 | 二 B（先接入微信 / IM 通道） |
| 数据包插件 | 注册表键的 `schema` 字段 | 二 B（先迁 `data/site-configs`） |
| 子进程托管 `ctx.spawn`（释放时杀整个进程组并等待退出） | `ctx.task` 的释放语义 | 二 B（转码会话收口时一起做） |
| 插件存储（专属数据目录 + 键值表，不给第三方主库会话） | 无 | 三 |
| 进程外运行器与代理 | 可跨进程约束（§5.3） | 三 |
| 安全模式（连续启动失败后自动禁用第三方插件） | 关键 / 非关键划分 | 三 |
| 插件贡献的操作接入成员权限 | 无 | 三 |

## 12. 测试与验证

### 12.1 内核单元测试（`tests/kernel/`）

- 依赖：未提供 → `PENDING`；提供后自动启动；与清单顺序无关；提供方释放 → 依赖方先释放并回到 `PENDING`；恢复后重新挂载。
- 失败与超时：`apply` 中途抛错 / 超时 → 已登记副作用逆序回滚；关键插件失败 → 已启动的全部释放并抛出。
- 静态校验：条目 id 重复、服务键重复提供、依赖成环 → 报错；`provides` 声明了没提供 → `FAILED`。
- 契约：`requires` 不满足 → `INCOMPATIBLE` 且插件代码未执行；第三方要求 `INTERNAL` 契约 → 拒绝。
- 注册表：id 冲突报错；覆盖栈生效与恢复；遍历顺序稳定；`watch` 收到增删；卸载自动撤回。
- 释放：逆序、串行、超时告警后继续；`ctx.task` 被取消并等待结束；结构变更串行、重入排队。
- 事件：三种模式的语义；非冻结载荷在定义时报错；监听器异常 / 超时 / 返回值不符的隔离（含 waterfall 在
  `next` 前后两种情况）；熔断开启、冷却、试探恢复；递归超限拒绝；模式与调用方法不匹配抛 `TypeError`；
  EMIT 队列满时丢弃计数、发出方不阻塞；插件释放后其监听器不再触发、消费协程已结束。
- 投递方式与因果：订阅 `DURABLE` 事件而无 `DURABLE_EVENTS` 提供方 → `PENDING` 且原因明确；`DURABLE` 监听器缺 `id`
  → 挂载时报错；`ctx.origin` 经 `ctx.task` 与事件分发正确传递；因果链超过上限被拒绝。
- 可观测：日志记录带条目 id；任务名带前缀；指标计数正确。
- 严格模式：故意泄漏一个协程 / 监听器 / 贡献，`KernelHarness` 退出时报错并指出是哪一项。

### 12.2 等价性测试（保证「行为零变化」）

- 完整启动后，原 lifespan 初始化的每个单例都已就绪（逐项断言 `get_xxx()` 可用）。
- 内核记录释放顺序，逐条断言 §7.1 的约束。
- 注册表里的任务 key 集合、处理器类型集合与改造前完全一致（改造前先生成一份基线快照）。
- `SCHEDULER_ENABLED=false`：调度器不启动，其余插件全部 `ACTIVE`，任务仍在注册表里。
- INTERVAL 任务注册后的下次触发时间与改造前一致。
- 现有全量测试不改断言即通过（只有装饰器替换这类机械改动）。

### 12.3 故障注入测试

- `channel.weixin` 的 `apply` 抛错：应用就绪；诊断显示 `FAILED`；待处理事项有记录；修复后重启记录消退；
  播放、媒体库接口正常。
- `channel.weixin` 的 `apply` 卡住超过超时：同上，状态为启动超时，启动总耗时有上界。
- `core.settings` 抛错：应用启动失败，错误指明条目 id；已启动的 `core.database` 等被正确释放。
- 补丁禁用 `jellyfin.discovery`：UDP 7359 未绑定；诊断显示 `disabled_by: "patch"`。

### 12.4 可重载测试（为第二阶段运行中启停打底）

对每个非关键内置插件，用 `KernelHarness`（严格模式）执行「挂载 → 卸载 → 再挂载 → 卸载」，断言：

- 没有泄漏的协程、监听器、贡献；线程数和打开的文件描述符数回到基线；
- 第二次挂载后功能正常（每个插件一条最小冒烟断言）。

通过的插件标记 `reloadable=True`；不通过的记录原因，作为第二阶段的改造清单。

**实施结果（PR 5）**：36 个非关键顶层插件（含子插件共 37 个）全部通过，均已标记 `reloadable=True`。
过程中发现并修正一处：调度器插件释放后单例仍指向已关停的实例，重新启用时被「重复初始化被忽略」
复用；现在释放时清空单例（`reset_scheduler`），重新启用建新实例。守护测试
`tests/api/test_plugin_reloadable.py` 要求非关键插件都可重载（或在 `NOT_RELOADABLE` 写明原因）。

### 12.5 端到端验证（NAS 真实环境）

按 `movieclaw-nas-dev-deploy` 流程部署开发版，用真实数据：

1. **启动**：对比改造前后的就绪耗时（各取 3 次中位数），差异在 ±10% 以内；诊断页的逐条目耗时与预期一致；
   用实测数据回填各插件的 `apply_timeout`。
2. **核心流程冒烟**：登录 → 浏览媒体库 → 网页播放一部需要转码的片子 → 站点搜索 → 手动投递下载 →
   手动触发一次订阅缺口搜索 → 确认推送到达手机 → 确认定时任务页的任务列表和下次触发时间与改造前一致。
3. **关闭**：转码播放进行中 `docker restart`，确认没有残留 ffmpeg、日志有「数据库连接已释放」。
4. **容错**：补丁禁用 `channel.weixin` 并重启，其余功能正常、诊断页显示已禁用；恢复后微信通道重新工作。

**实施结果（2026-10-09，NAS 开发版 0.34.1-dev.20261009.003816，源码 edccd07f）**：

| 项 | 结果 |
|---|---|
| 启动 | 45 个条目全部运行，0 失败、0 等待；「重启 → 健康」22.4 / 22.2 / 21.9 秒（中位数 22.2），改造前 23.2 / 22.1 / 22.1 秒（22.1），差 +0.5%；后端启动区间 2～3 秒（改造前 2 秒） |
| 启动超时 | 非关键插件实测最慢 454 毫秒（`agent.session-index`），其后 `playback.transcode` 382、`scheduler` 197、`channel.weixin` 182 毫秒；默认 30 秒留有约 66 倍余量，**不逐个回填**，保持默认 |
| 核心流程 | 媒体库、条目列表、定时任务（17 个，与改造前一致，全部有下次触发时间）、下载器、推送通道、6 站搜索（5 个正常、1 个站点自身 525）、订阅补缺搜索（34 秒内完成一轮并记动态）均正常。手动投递只验证到路由预览：真投会给 PT 账号加种，有分享率 / H&R 后果；推送只核对通道状态（深夜不发测试推送） |
| 关闭 | 本地档 2 会话与片头识别各一个 ffmpeg、外加一个远程 Worker 档 3 会话在跑时 `docker restart`：两个会话都记「服务关闭或重启」结束，远程 Worker 被告知离线并在重启后自动重连，容器内 ffmpeg 归零，日志有「数据库连接已释放」；每次关闭约 1 秒 |
| 容错 | `data/plugins.yaml` 禁用 `channel.weixin` 后 44 个运行、微信零日志；删补丁重启后两个收消息循环恢复、45 个运行 |
| 诊断页 | 「设置 → 更新与维护 → 模块」桌面与手机均正常，无页面错误 |

启动日志里「数据目录下发现未登记的条目」告警改造前就有，只是日志器名从 `movieclaw_api.lifespan` 变成了
`movieclaw_api.plugins.playback`（存储守护插件所在模块）。

### 12.6 性能预算

- 内核启动开销（排序、契约检查、状态机）：不超过 50 毫秒。
- EMIT：每个监听器一次 `put_nowait`；waterfall / bail：每个监听器一次计时和超时包装，单次分发额外开销在
  微秒级（单元测试里用基准测试锁住上限）。
- 第一阶段没有业务事件，请求热路径上没有任何新增开销。

## 13. 实施拆分

| PR | 内容 | 验证 |
|---|---|---|
| 1 | `movieclaw_kernel`：契约、插件与条目、上下文、注册表、内核、事件、可观测、测试工具；应用代码不动 | §12.1 |
| 2 | 内置插件清单；`build_lifespan` 变薄壳；任务注册暂时照旧（领域插件里 import 模块即可） | §12.2（除注册表相关项） |
| 3 | 任务与处理器改为注册表贡献；调度器和执行器改为注册表消费者 | §12.2 全部 + 调度器、执行器单测 |
| 4 | 启动容错与待处理事项；诊断接口与页面；`data/plugins.yaml` 禁用补丁 | §12.3 + 接口测试 + 页面截图 |
| 5 | 可重载测试与 `reloadable` 标记；NAS 端到端验证；回填启动超时 | §12.4、§12.5 |

每个 PR 单独可合并、单独可回滚。PR 1 只加不改，可以放心先合；PR 2 是启动和关闭顺序风险最集中的一个，
所以和注册表改动（PR 3）分开。

## 14. 做完之后达成的效果

**对用户：**

- 边缘子系统（微信、IM、云推送、局域网发现）启动失败或卡住，不再拖垮整个服务；待处理事项里告诉你
  哪一项、为什么。
- 不用的子系统可以在配置里关掉。

**对开发：**

- 新增子系统 = 新写一个插件模块、清单里加一行；关闭顺序由依赖保证并有测试守护。
- 定时任务和后台任务处理器有明确归属，卸载即撤下；不再有「靠路由碰巧 import」的注册。
- 每个子系统的启动耗时、事件处理、失败、后台任务数都能在诊断页看到；日志能看出是哪个插件打的。
- 测试可以用 `KernelHarness` 只组装需要的插件，并自动查泄漏。

## 15. 为后续阶段打下的基础

| 第一阶段的产出 | 后续直接用它做什么 |
|---|---|
| 服务键 / 注册表键 + 覆盖栈 | 二 B：下载器、站点框架、推送渠道、元数据源改为注册表，内置实现改为贡献；用户插件覆盖内置实现，停用即恢复 |
| 契约版本与稳定性分级 | 二：逐个把契约升为 `EXPERIMENTAL`；三：安装前就能判断兼容性 |
| 可跨进程约束 | 三：进程外代理按契约自动生成 |
| 事件总线（含不可变载荷、超时、熔断、批粒度规则） | 二 B：在订阅链路的搜索、候选淘汰、排序、选下载器、保存路径等决策点开钩子（清单见 `plugin-extension-model.md` §2.5） |
| 投递方式（实时 / 可靠）、监听器稳定 id、发起方与因果链 | 二 A：可靠事件只需补存储与投递器，内核接口不变；Webhook 成为可靠订阅者，推送中枢继续用实时事件 |
| 注册表的 `schema` | 二 B：数据包插件，`data/site-configs` 成为第一个数据包 |
| 条目与插件分离 | 二 B：插件配置表单；之后支持同一插件多实例 |
| 可撤销注册 + 可重载测试 | 二 B：设置页里运行中启停 `reloadable` 插件 |
| `KernelHarness` + 严格模式 | 二 A：本地受信插件的测试工具；三：原样作为第三方插件的测试工具 |
| 诊断接口与页面 | 三：演进成插件管理页 |

## 16. 风险

| 风险 | 应对 |
|---|---|
| 启动 / 关闭顺序回归（孤儿 ffmpeg、关库后仍有写入） | 清单顺序沿用现状；§7.1 每条约束一条断言；NAS 上做带转码的重启验证 |
| 循环导入（现 lifespan 大量函数内延迟 import 正是为了避环） | 插件模块保持「在 `apply` 内 import 领域模块」；只有 `core.database` 顶层 import `run_migrations` |
| 禁用插件后接口调到未初始化的单例报 500 | 只对逐个核对过的插件开放 `disableable`；故障注入测试覆盖 |
| 非关键插件失败不再中止启动，问题被忽视 | 待处理事项 + error 日志 + 诊断页三处可见 |
| 测试套件的应用复用、迁移快路径被打破 | `build_lifespan` 签名不变；PR 2 必须全量测试通过 |
| 启动超时误杀合法的慢启动（大库、NAS 慢盘） | 默认 30 秒偏宽；NAS 实测最慢 454 毫秒，余量充足，保持默认（§12.5） |
| 内核比 v1 大一倍，过度设计 | 每项都在 §17 写明「为什么现在做」；不能说明理由的砍掉；§11 的能力只预留不实现 |

## 17. 取舍记录

**为什么这些现在做，而不是等用到再做：**

| 项 | 理由 |
|---|---|
| 条目与插件分离 | 诊断、补丁、日志、指标都以 id 为键，以后改要动所有这些地方和用户的补丁文件 |
| 注册表键与覆盖栈 | 第一阶段就要用：定时任务和后台任务处理器就是注册表，内置插件当场验证 |
| 契约版本与稳定性 | 字段本身几乎零成本；以后再加，等于所有已有契约都没有版本历史 |
| 可跨进程约束 | 只是规则，零代码；但第二阶段开放契约时如果没有它，第三阶段就要破坏性重做 |
| 事件的不可变载荷、超时、校验、熔断 | 事件是第二阶段的主要扩展方式，语义一旦被插件依赖就改不动；先在内核里用单元测试锁死 |
| 投递方式、监听器稳定 id、发起方与因果链 | 场景推演证明可靠事件是自动化插件的必需品；这三项是接口形状，第二阶段再加就是破坏性修改 |
| 启动超时 | issue #162 真实发生过 |
| 结构变更串行化 | 级联卸载 / 重新挂载如果允许并发，正确性无法保证 |
| 归属、任务命名、内存指标 | 排查插件问题的基础设施，开销可以忽略 |
| `KernelHarness` 与严格模式 | 内置插件的可重载测试本身就需要；做好了就是第三方的测试工具 |

**考虑过但否决的方案：**

| 方案 | 否决理由 |
|---|---|
| 用 pluggy | 只有钩子，没有服务、依赖等待、可撤销注册、生命周期；核心部分仍要自己写 |
| 按类型注解自动注入依赖 | 隐式，出错难查；显式 `inject` 更可读，也能静态排序 |
| 插件之间按插件 id 互相依赖 | 耦合到具体实现；依赖服务键才能替换提供方 |
| 服务键也支持覆盖栈 | 「谁在提供数据库」不应该是隐式的；替换单例走补丁显式禁用 |
| 异步释放函数并发执行（Cordis 的做法） | 关闭顺序问题我们踩过很多，串行更确定 |
| 并行启动 | 改变 SQLite 并发形态，收益未知，以后单独评估 |
| 进程内代码热重载 | Python 的 `importlib.reload` 不可靠；进程外插件用重启进程替代 |
| 五种事件模式全做 | `serial` / `parallel` 暂无用途，用到再加 |

## 18. 决策记录

2026-10-08 用户要求「按计划逐步全部落地」，以下未单独答复的问题按本文推荐方案执行：

| 问题 | 采用 |
|---|---|
| 启动容错（§9） | 非关键子系统失败降级运行 + 待处理事项提醒 |
| 诊断页面（§10.2） | 第一阶段做只读页面 |
| 禁用补丁（§10.3） | 作为排障入口，在运维文档里简要说明，不进入普通用户文档 |
| 命名 | `movieclaw_kernel` / `movieclaw_api/plugins/` / 将来 `movieclaw_sdk` |
| 第三方默认进程外（§3.1） | 采用；§5.3 约束现在定死 |
| 数据包插件（§3.1） | 采用 |

### 18.1 原始问题

1. **启动容错**（§9）：非关键子系统启动失败改为「降级运行 + 待处理事项」，是否接受？
2. **诊断页面**（§10.2）：第一阶段做只读页面，还是只做接口、页面并入以后的插件管理页？
3. **禁用补丁**（§10.3）：`data/plugins.yaml` 写进用户文档，还是只作为排障用的隐藏入口？
4. **命名**：内核包 `movieclaw_kernel`、内置插件 `movieclaw_api/plugins/`、将来的 SDK 包 `movieclaw_sdk`，是否合适？
5. **第三方默认进程外**（§3.1）：代码插件默认独立进程、进程内运行需单独批准，这个方向是否认可？
   它决定了 §5.3 的约束是否要现在定死。
6. **数据包插件**（§3.1）：把站点定义、规则集、推送模板这类「纯数据」扩展也纳入插件体系，是否认可？

场景推演引出的待确认项见 `plugin-extension-model.md` §7。

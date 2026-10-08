# 插件体系第二阶段 B：开放扩展点

> 状态：实施中（2026-10-09）。总体模型见 `plugin-extension-model.md`（§2.3 关键字订阅、§2.5 订阅链路开放点与
> 提供方注册表），底座见 `plugin-phase2a.md`。二 A 让插件能「做事」和「对事情做出反应」；二 B 让插件能
> **改决策**（钩子）、**换实现**（提供方注册表、可替换阶段）、**插进流水线**（管线槽位）、**有自己的入口和数据**
> （路由、存储、健康）。

## 0. 现状要点（调研结论）

| 事实 | 位置 | 影响 |
|---|---|---|
| 内核早已实现 `waterfall` / `bail` 分发，但业务代码里一个都没用 | `movieclaw_kernel/events.py:345/443` | 钩子只差「业务侧拿到总线」和冻结载荷 |
| 业务模块拿不到内核总线；已有的做法是插件启动时把注册表绑到模块级（`bind_registry`） | `movieclaw_scheduler/registry.py`、`services/jobs.py` | 钩子同样绑定；没绑（CLI、单测）时直接走默认实现 |
| 订阅链路的公共流水线是 `evaluate_and_dispatch`：身份 → 规则 → 排序 → 智能决策 → 投递；主动搜索、被动匹配、智能到期都走它；死种换源走一条平行的小流水线 | `services/subscription/matching.py:732`、`replacement.py` | 钩子挂在公共流水线上，换源路径同步挂，避免「主流程能拦、换源不拦」 |
| 规则淘汰后的拒绝会写订阅动态（去重、标在工单上） | `matching.py:_log_rejection` | 插件只返回「淘汰哪些、原因」，记录由核心统一做 |
| 选下载器只在 `submit_torrent` 里按「显式指定 / 默认」二选一；投递预览重复了一遍 | `torrent_submit.py:224`、`dispatch.py:710` | 钩子要同时挂在两处，否则预览与实投不一致；显式指定的下载器（智能订阅的冻结意图、手动选择）不许被改 |
| 站点 YAML 的 `custom_class` 可以导入任意模块，没有白名单、没有基类校验；用户数据目录里的一个 YAML 就能执行任意代码 | `movieclaw_tracker/registry.py:97` | 二 B 收口：只认内置站点类与插件注册的站点类 |
| 下载器类型、站点认证方式在库里按枚举**成员名**存（`QBITTORRENT`），OpenAPI 里是封闭枚举 | `models/downloader_client.py`、`site_credential.py` | 改成开放注册表需要数据迁移和客户端兼容，二 B 只做站点，其余写清迁移路径后放到后面 |
| 没有通用的实体扩展字段；设置存储是整份覆盖、注册在导入期 | `settings/store.py` | 插件数据用一张新表承载（含挂在实体上的扩展字段） |
| 系统通知只有 warning / error 两级，前端按 `source` 推导跳转 | `services/system_notice.py`、`apps/web/lib/api/notices.ts` | 插件健康复用通知（降级 = warning），健康状态同时进诊断 |
| 运行中往已挂载的 FastAPI 路由器追加路由可行（0.142 的 `_IncludedRouter` 是活引用，OpenAPI 缓存按版本失效），但删除路由要调私有方法；规格哈希缓存不失效，且 `_route_signature` 在新版 FastAPI 下已经拿不到路由 | `fastapi/routing.py`、`spec_state.py` | 插件路由风险最高，放在二 B 后段，先修规格哈希 |

## 1. 钩子底座（PR B1）

- `movieclaw_api/hooks.py`：钩子契约与冻结载荷集中定义；`bind_bus(bus)` 由内核插件 `core.registries` 在启动时绑定。
- `await hooks.waterfall(EVENT, payload, terminal=...)` / `await hooks.bail(EVENT, payload)`：**没有监听器时直接调默认实现
  （或返回 None），零额外开销**；有监听器时交给内核总线（隔离、超时、熔断、单条链总时限都由内核负责）。
- 规则（写进每个钩子的文档）：钩子里不许有副作用；返回值不合法（类型不对、排序不是原集合的重排、选了不存在的下载器）
  按「这个监听器不存在」处理并记一次失败；默认实现永远兜底。
- 钩子全部是实验级契约，本地受信插件可以订阅。

## 2. 订阅链路的钩子（PR B2）

| 钩子 | 模式 | 位置 | 载荷 → 结果 | 约束 |
|---|---|---|---|---|
| `subscription.search.keywords` | waterfall | `recall_keywords` 调用处（主动搜索、换源） | 条目 + 内部推导的关键词 → 关键词元组 | 核心把结果截到 6 个以内（每个关键词都是一次全站搜索） |
| `subscription.candidates.filter` | waterfall | 规则评估之后、排序之前（每个条目一批） | 条目、订阅、候选批次 → 淘汰清单（候选键、原因码、原因文案） | 只能淘汰、不能添加；淘汰由核心写进订阅动态，原因码加 `plugin:` 前缀 |
| `subscription.candidates.rank` | waterfall | 排序之后 | 候选批次（已按核心顺序）→ 候选键的新顺序 | 必须是原集合的重排，否则忽略 |
| `dl.downloader.select` | bail | 投递与投递预览选下载器处 | 站点、种子标题、体积、条目类型、分类 → 下载器 id | 只在没有显式指定时询问；选中的下载器须启用且可用，否则忽略 |
| `dl.torrent.before-delete` | bail | `dl.torrent.delete` 执行前（演练不问） | 下载器、info_hash、是否删文件 → 否决原因 | 否决返回 409，原因写明是哪个插件；用于「H&R 未达标不许删」 |

不在这一批：**智能模式决策**（`smart.decide` 的状态机与重放记录耦合深，插件改决策会让重放失真）、**保存路径**
（六个调用方要求同一实现，挂钩需要先把调用方收敛）、**搜索结果批次**（与候选淘汰重复，入公共缓存前过滤会影响
所有订阅）。三者在 §3 的阶段契约里给出替换路线。

## 3. 订阅链路的可替换契约（用户长期约束）

用户要求「将来能兼容、完全扩展、替换整条订阅链路」。钩子解决「改一点」；「换一整段」的路线：

1. **整段替换已经可行的部分**：订阅的定时阶段（主动搜索 `search_wanted`、被动匹配、智能到期、换源）都是
   `SCHEDULED_TASKS` 注册表里的贡献，插件可以用 `override=True` 贡献同 key 的任务替换内置实现，卸载时自动恢复
   （注册表覆盖栈）。B2 用测试锁住这条路。
2. **选择策略**：规则与智能两种选择方式目前靠 `isinstance(ctx.spec, SmartPolicy)` 分叉（七处）。下一步把它们收敛成
   `SELECTION_STRATEGIES` 注册表（候选池 → 规划 → 决定），订阅的 `selection_mode` 存策略 id；插件贡献新的策略，
   订阅选它即可。这需要先把七处分叉收进一个策略对象，属于重构，放在二 B 之后单独做。
3. **订阅引擎服务**：上面两步完成后，`SUBSCRIPTION_ENGINE` 只剩「谁负责把缺口变成投递」这一层编排，届时评估是否值得
   定义；在此之前不引入（避免空壳抽象）。

## 4. 插件数据与实体扩展字段（PR B3）

- 新表 `plugin_data(entry_id, scope, key, value JSON, updated_at)`，唯一键 `(entry_id, scope, key)`；`scope` 形如
  `global`、`subscription:35`、`media_item:7192`、`library_file:24935`。
- 服务 `PLUGIN_DATA`（实验级）：`store = ctx.use(PLUGIN_DATA).scoped(ctx)`，`await store.get/set/delete/list(scope, key)`；
  插件只能读写自己条目 id 下的数据。值里标为秘密的字段用现有 SecretBox 加密。
- 实体删除时不级联（数据量小、插件可能还要用）；插件可以按可靠事件自行清理。诊断里显示每个插件的数据条数。

## 5. 插件健康（PR B4）

- 服务 `PLUGIN_HEALTH`（实验级）：`health.report(ctx, key, ok=False, message=..., action_href=...)`。
- 降级 → 系统通知（warning，键 `plugin:<id>:health:<key>`，与启动失败的 `plugin:<id>` 分开）；恢复 → 消退。
- 当前健康进诊断接口（每个插件的 `health` 列表），网页「模块」页签显示。
- 前端通知跳转在 `payload.action_href` 存在且是站内路径时优先使用。

## 6. 站点提供方与数据包（PR B5）

- `SITE_CLASSES` 注册表（实验级）：内置站点类（NexusPHP 框架、M-Team、SunnyPT、OurBits、TTG）以 `movieclaw.<名字>`
  贡献；插件可以贡献自己的站点类（插件 id 前缀）。
- YAML 的 `custom_class` **只认注册表里的名字**（同时兼容现有四个内置的完整导入路径写法，映射到注册名）；任意导入路径
  一律拒绝并告警，堵上「数据文件执行代码」。
- `SITE_DATA_PACKS`：插件可以贡献站点 YAML 目录，与内置、用户目录一起加载（优先级：用户 > 插件 > 内置）。
- 下载器类型、IM 渠道、Webhook 格式：迁移路径写进本文 §9，不在这一批改。

## 7. 入库管线槽位（PR B6）

- 槽位 `ingest.staged`：自定义目录（暂存）规则把文件整理到位后，按槽位里贡献的步骤为每个步骤创建一个持久化任务，
  挂在入库任务下（父任务 / 根任务），与入库结论同一次提交。
- 载荷：最终路径、季集、条目、来源种子、导入规则、按条目路由出的目标库（暂存规则本身按类型不按库）。部分失败
  的入库也要发（文件已经搬过去了，重试时不会再报）。

## 8. 插件路由与签名链接（PR B7，风险最高，放最后）

- 先修规格哈希：FastAPI 0.142 起 `app.routes` 里只剩「被包含的路由器」，`_route_signature` 一条路由都拿不到
  （同构应用的指纹缓存因此全部撞在同一个键上）；改为经 `iter_route_contexts` 展开实际生效的路由。
- 路由变化后的指纹：`spec_state.routes_changed(app)` 不再认基线，**后台线程**重算（防抖 1 秒，连续变化只认最后一次），
  算好之前沿用旧指纹。现场生成整份 spec 本机约 4 秒、NAS 更久，放在事件循环里会把重启后的第一批请求卡住。
  线程只基于在事件循环上取的生效路由快照生成——请求处理会按路由版本重建生效路由对象，线程里两遍遍历拿到
  不同对象时字段映射对不上（实测 `KeyError: (ModelField…, 'serialization')`）。算好后顺手回填 FastAPI 的
  OpenAPI 缓存（带快照时的路由版本），CLI 发现偏斜来拉 `/spec` 时不必再现场生成。
- 实现形态改为**服务**而不是注册表：`PLUGIN_ROUTES`（实验级，`kernel.plugin-routes` 提供），
  `routes.mount(ctx, router, zone=...)` 同步校验（operationId 必须以 `plugins.<条目 id>.` 开头、只收普通 HTTP 接口、
  条目 id 能当路径段），校验失败插件直接进 FAILED，错误原因可见；摘除登记为插件自己的 effect，卸载 / 依赖的服务
  重载时自动摘除。挂到宿主路由器 `/api/v1/plugins/<条目 id>/...`，鉴权在挂载时由宿主按区注入：`admin`（`require_admin`）、
  `member`（`require_login`）、`public`（本插件的签名，没签名 / 不对 / 过期一律 404）。插件主体（`mcpl_` 令牌）调插件路由
  同样要按 operationId 授权。
- 摘除路由：FastAPI 的路由版本是「自身版本 + 子路由器版本之和」，直接摘子路由器会让总和回退、可能撞上旧值而命中旧的
  路由表 / OpenAPI 缓存；摘除时把宿主路由器自身版本补到严格大于摘除前。
- 签名链接：`await routes.sign(ctx, path, params=..., expires_in=..., absolute=...)`。签名覆盖完整路径与全部查询参数；
  不传 `expires_in` 即不过期（写进 `.strm`）；`absolute=True` 拼「外部访问地址」，没配置时报错。每个插件一把密钥，
  首次使用时生成，存在它自己的插件数据里（键 `kernel.link-key`，加密），不与会话密钥共用：改密 / 轮换会话密钥、
  插件或服务重载都不会让已写出去的 `.strm` 失效。
- 已知限制：插件路由不进宿主操作目录（`HOST_OPS` 读构建期基线），插件之间暂不能经宿主操作互调对方路由；
  挂了路由的实例 `/health` 的 `spec_hash` 与发布产物的基线不同（NAS 开发版部署脚本的指纹校验要先摘掉验收插件）。

## 9. 不在二 B 的提供方注册表（迁移路径）

- **下载器类型**：库里存枚举成员名。路线：新增 `client_type_value` 文本列 → 回填 → 读取改为开放字符串、未知类型标「插件未加载」
  而不是整表报错 → OpenAPI 改为字符串 + 目录接口；客户端（网页 TS 联合类型）同步放宽。
- **IM 渠道**：`channel_account.channel_id` 已是开放字符串；`_SPECS` 改注册表即可，路由守卫改查注册表。
- **Webhook 格式**：设置里是封闭 Literal，未知值会让整个 Webhook 设置域校验失败；先改为容忍未知格式（跳过并标注），再开注册表。

## 10. 实施拆分

| PR | 内容 | 验收 |
|---|---|---|
| B0 | 本文 | — |
| B1 | 钩子底座 | 单测：无监听器零开销、监听器出错 / 超时 / 返回非法时走默认 |
| B2 | 订阅链路五个钩子；定时阶段可整段替换的守护测试 | 每个钩子一条端到端：真实流水线 + 运行中挂载的插件改变决策 |
| B3 | 插件数据与实体扩展字段 | 作用域隔离、秘密字段加密、重载后数据还在 |
| B4 | 插件健康 | 降级出通知、恢复消退、诊断可见 |
| B5 | 站点类注册表、`custom_class` 收口、站点数据包 | 任意导入被拒；内置站点照常；插件贡献的 YAML 站点可用 |
| B6 | 入库槽位 `ingest.staged` | 暂存入库后下游任务被创建且挂在入库任务下 |
| B7 | 规格哈希修复、插件路由、签名链接 | 路由随插件挂载 / 摘除；公开区验签；规格哈希随之变化 |
| B8 | 验收插件：关键字规则（2.3 A）、站点数据包、网盘上传（2.2，依赖 B6、B7） | CI 端到端 |

# 插件体系第二阶段 A：能力底座

> 状态：实施中（2026-10-09）。总体模型见 `plugin-extension-model.md`（§1 八种扩展形态、§3 宿主操作、§4 可靠事件、
> §5 阶段落位），内核见 `plugin-kernel.md`。本文是二 A 的详细设计与实施拆分。
>
> 二 A 的目标：插件能**以受控的身份做事**（宿主操作），能**可靠地对已发生的事做出反应**（可靠事件），领域侧补齐
> 这两件事需要的数据（文件来源、下载归属）和操作（关联查询、删除演练、按目录扫描），并允许用户显式开启的
> **本地受信插件**在进程内运行。两个验收插件（外部信号触发订阅、删片联动清理）进 CI 端到端测试。

## 0. 现状要点（调研结论）

| 事实 | 位置 | 对设计的影响 |
|---|---|---|
| 仓储层各自提交（`subscription_repo.save/add_activity/delete` 都 commit），一次业务动作是多次提交 | `movieclaw_db/repositories/subscription_repo.py` | 可靠事件不能等「整个业务事务」，而是在**记录该事实的那次提交之前** `session.add` 事件行，随那次提交一起成立 |
| 全库没有任何 `after_commit` 监听 | `movieclaw_db/engine.py` | 投递器靠「写入时登记提交钩子唤醒 + 低频轮询兜底」 |
| 推送中枢、Webhook 都是内存队列，提交后发、重启即丢 | `services/push/hub.py`、`services/webhook/dispatcher.py` | 保持不变；可靠事件是新增的一条通道，不替换它们 |
| `library_file` 只有 `site_id` / `torrent_id`，没有 `info_hash` / `downloader_id`；`upsert_by_path` 再次扫描同一路径会把来源字段覆盖成空 | `models/library_file.py`、`library_file_repo.py:355` | 新增两列；新列在扫描重试时**不被空值覆盖** |
| 入库时每个文件对应的订阅下载记录可取（`_DeliveryProvenance.attempt_for`），手动下载意图也在作用域内 | `services/library/ingest.py` | 入库直接写来源 |
| 原地下载靠扫描入库，作用域里没有种子信息 | `services/library/scan.py` | 扫描时按订阅下载记录的 `save_path/download_name` 前缀反查 |
| 手动下载意图没有归属列，入库成功即删除 | `models/manual_download_intent.py`、`ingest.py:1783` | 加 `owner`；来源已落到文件上，意图仍按原逻辑删除 |
| 删除条目 / 文件是硬删除，服务函数只返回计数；后台任务随后可能删掉 `media_item` 行 | `services/library/items.py:3262/3373` | 事件快照必须在服务函数提交前、按「实际删掉的行」拍 |
| Agent / MCP 主体都是 `is_admin=True`，操作范围只靠各自目录过滤 | `services/auth.py:805-830` | 插件主体需要新的执行点：`require_login` 末尾按匹配路由的 `operation_id` 校验授权 |
| MCP 已实现进程内经 ASGI 调用自身接口 | `movieclaw_mcp/dispatch.py` | `ctx.ops` 复用其目录与请求构造 |
| 任务来源 `origin` 只认 cli / web / agent / scheduler | `routes/jobs.py:40` 等 | 增加 `plugin` |
| 没有「按目录扫描」「删除演练」「条目关联的种子与订阅」对外操作 | `routes/libraries.py` | 二 A 新增 |

## 1. 内核补充（PR A1）

1. **第三方插件不得使用内部契约**：`requires` 已检查；补上 `inject` 的服务、`contribute` 的注册表、`ctx.on` 的事件也要求
   非 `INTERNAL`。违反时条目为 `INCOMPATIBLE`（加载期能判定的）或贡献调用抛错（运行期）。内置插件不受限。
2. **插件声明所需操作**：`@plugin(..., permissions=("subscriptions.create", "search.*"))`。内核不解释，只存储并进诊断；
   由宿主操作服务解释（§3）。
3. **可靠投递的上下文**：`current_delivery` 上下文变量，监听器内经 `ctx.delivery` 读到 `DeliveryInfo(event_id, name,
   occurred_at, origin, attempt)`。`origin` 是**事件发生时**的发起方，插件据此忽略自己引起的事件；监听器执行期间的
   `ctx.origin` 仍按因果链延长（`caused_by`），链长上限照旧生效。
4. 可靠事件的载荷必须是**冻结的 pydantic 模型**（要落库、跨进程），`Event(delivery=DURABLE)` 构造时校验。

## 2. 可靠事件（PR A2）

### 2.1 表

| 表 | 列 | 说明 |
|---|---|---|
| `domain_event` | `seq` 自增主键、`id`（ULID，唯一）、`name`、`version`、`payload`（JSON）、`origin_kind`、`origin_id`、`chain`（JSON）、`occurred_at` | 事件本体；`(name, seq)` 索引 |
| `event_consumer` | `consumer_id`（`<条目 id>:<监听器 id>`，主键）、`events`（JSON 名单）、`cursor`、`attempts`、`next_attempt_at`、`last_error`、`last_seen_at` | 每个可靠监听器一行，各自前进，互不影响 |
| `event_dead_letter` | `id`、`consumer_id`、`event_seq`、`event_id`、`name`、`error`、`attempts`、`created_at`、`resolved_at` | 超过重试次数的事件；诊断可见、可手动重放 |

### 2.2 写入

- `record(session, EVENT, payload)`：在业务会话里 `session.add` 一行，**不提交**——随调用方下一次提交成立，回滚即不存在。
  发起方取 `current_origin`。
- **零开销原则**：只有当某个事件名有登记过的消费者（`event_consumer` 行，含暂时停用的插件）时才写行；没有任何插件订阅时，
  `record` 是一次内存集合查找后直接返回。现阶段内置插件都不订阅，所以对现有功能没有任何新增写入。
- 写入时给会话登记一次 `after_commit` 钩子，提交后唤醒投递器；另有 5 秒轮询兜底（钩子漏触发、其他进程写入）。

### 2.3 投递

- 每个消费者一个协程（随订阅它的插件生死）：按 `seq` 顺序取 `cursor` 之后、名单内的事件，逐个交给监听器。
- 成功 → 前进游标；失败或超时（默认 60 秒）→ 退避重试 5 秒、30 秒、2 分钟、10 分钟、30 分钟；第 6 次仍失败 → 写死信、前进游标，
  不让一个坏事件堵死后续。**同一消费者内保序，至少一次**；消费方以 `ctx.delivery.event_id` 去重。
- 新消费者首次订阅时游标从当前最大 `seq` 开始，不回放历史；插件停用期间的事件在重新启用后补投。
- 保留：事件 14 天后清理（仍被未处理死信引用的保留）；30 天没有出现过的消费者行清理（插件已移除）。
- 诊断：`GET /app/plugins` 增加 `durable`（每个消费者的积压、重试、死信数）；新增 `POST /app/plugins/dead-letters/{id}/replay`、
  `.../dismiss`（管理员，危险等级 confirm）。

### 2.4 提供方

内置插件 `kernel.durable-events`（依赖 `DB`，提供 `DURABLE_EVENTS`，非关键、可停用、可重载）。它停用时，订阅可靠事件的插件
因缺少依赖进入等待；业务侧的 `record` 照常写行（名单由库里的消费者行决定），恢复后补投。

## 3. 插件主体与宿主操作（PR A5）

- **身份**：`Principal` 增加 `plugin: PluginGrant | None`。插件「代表谁」由条目配置 `act_as` 决定：缺省为超管；指定成员用户名时，
  主体的形状与该成员登录时完全一致（能力开关、库可见性照旧生效），再叠加插件授权——**有效权限 = 成员权限 ∩ 插件授权**。
  `interactive=False`，因此不能签发凭证、不能进入要求交互式会话的接口。
- **凭证**：插件激活时由宿主生成一枚只存在内存里的随机令牌（前缀 `mcpl_`），条目释放即作废；不落库、不能跨进程（第三阶段
  进程外插件再签真正的设备令牌）。
- **执行点**：`require_login` 末尾，主体带 `plugin` 时取匹配路由的 `operation_id`，不在授权集合里即 403
  `PLUGIN_OPERATION_DENIED`。授权支持领域通配（`subscriptions.*`），但**危险操作（`x-cli-dangerous`）必须逐个列出**，通配不覆盖。
  内置插件：声明即授权。本地受信插件：声明 ∩ 用户在 `plugins.yaml` 的 `grants` 里批准的（§6）。
- **调用**：服务 `HOST_OPS`（`EXPERIMENTAL`），插件 `ops = ctx.use(HOST_OPS).client(ctx)`，`await ops.call("subscriptions.create", {...})`。
  复用 MCP 的操作目录与请求构造，经 `httpx.ASGITransport` 调本进程应用；成功返回 `data`，失败抛 `OpsError(status, code, message,
  details)`。插件之间经事件串起来的调用链经上下文变量带进请求，因果链上限对宿主操作同样生效。
- **审计**：每次调用记一行日志（插件、操作、状态、耗时）；任务来源记 `origin="plugin"`、`actor_name="plugin:<id>"`；订阅的
  `created_by_member_id` 按 `act_as` 落。插件发起的请求不计入前台压力（不让后台重任务为它让路）。

## 4. 第一批领域事件（PR A3）

全部为可靠事件、`EXPERIMENTAL`、版本 `1.0`，载荷是冻结 pydantic 模型，定义集中在 `movieclaw_api/events/`。

| 事件 | 写入点（随哪次提交成立） | 载荷要点 |
|---|---|---|
| `library.item.deleted` | `delete_item_files` 提交前，按实际删除的行 | 条目快照（id、类型、片名、年份、TMDB）、库、`files[]`（id、季集、路径、体积、来源种子）、`links`：订阅 id、相关种子（info_hash、下载器、是否自有、是否 H&R、来源） |
| `library.file.deleted` | `delete_single_file` 提交前（升级为整条删除时发 `item.deleted`） | 同上，`files` 只有一个 |
| `library.file.trashed` / `.restored` / `.purged` | `recycle_file` / `restore_file` / `purge_file`（调用方提交），含到期清除 | 文件快照、原因（洗版替换、重复清理、取消订阅、到期、手动）、触发方 |
| `download.completed` | `download_progress` 首次转为完成时（判 `status != COMPLETED`） | 订阅、条目、季集、info_hash、下载器、站点、保存路径、用途（下载 / 洗版） |
| `library.ingest.imported` | 入库 `_save_record` 提交前（状态为已导入） | 条目、库、最终文件路径（按 `added_batch_id` 收集）、info_hash 列表、导入规则、下载意图归属 |
| `subscription.created` / `.deleted` | `create` 的 CREATED 动态提交前 / `delete_permanently`、`unsubscribe` 真删除前 | 订阅 id、条目快照、成员、是否带清理任务 |
| `subscription.status-changed` | `recompute_subscription_status`、`set_paused` 保存前 | 旧状态、新状态、原因 |
| `subscription.download-started` / `.fulfilled` | `dispatch` 的抓取动态提交前 / `close_fulfilled_wanted` 的导入动态提交前 | 与 Webhook 同名事件同构（`media`、`units`），加订阅 id 与 info_hash |

播放类事件（高频）不在第一批：等第一个真实插件需要时再加，届时零开销原则保证没有订阅时不写行。

## 5. 领域数据与新操作（PR A4、A6）

### 5.1 文件来源（A4）

- `library_file` 加 `info_hash`（小写，索引）、`downloader_id`（外键，删除置空）。
- 入库：订阅文件取 `delivery.attempt_for(...)`，手动下载取意图；扫描（原地下载）按订阅下载记录 `save_path/download_name`
  前缀反查，一次扫描只加载一次映射。
- `upsert_by_path`：两列新字段在传入为空时**保留原值**（不再被扫描重试抹掉）；原有 `site_id` / `torrent_id` 的覆盖行为不变。
- 迁移内回填：按 `(site_id, torrent_id)` 关联订阅下载记录补 `info_hash` / `downloader_id`。手动下载的意图已在入库时删除，
  这部分历史无法回填，接受。

### 5.2 下载归属（A4）

- `manual_download_intent` 加 `owner`（`manual` 或 `plugin:<条目 id>`），`dl.submit` 按调用主体自动填写。
- 插件经 `dl.submit` 投递且给了 `library_id` 时也锚定意图（原先只有 `auto_route` 锚定），入库时按意图认领身份；
  `library.ingest.imported` 事件带上 `intent_owner`，插件据此认出自己投递的下载。

### 5.3 新操作（A6）

| 操作 | 说明 |
|---|---|
| `library.items.relations`（GET `/libraries/{id}/items/{item}/relations`） | 条目关联的订阅与种子：来自订阅下载记录、文件来源、手动意图，去重后标明来源、下载器、是否自有、是否 H&R、涉及的文件 |
| `library.items.delete` / `.delete-file` 增加 `dry_run` | 只返回将要删除的路径、行、释放体积，不动磁盘和数据库 |
| `dl.torrent.delete` 增加 `dry_run` | 返回下载器、是否存在、将被打回「想要」的季集、将被取消的下载记录 |
| `library.scan.start` 增加可选 `paths` | 只扫这些一级目录（复用监控用的 `scope_paths`）；不在库根下的路径 400 |

「创建插件自己的持久化任务」在进程内直接调 `jobs.create_job`（插件只能创建自己贡献了处理器的任务类型），HTTP 操作留到第三阶段进程外插件。

## 6. 本地受信插件（PR A7）

- 位置：`data/plugins/<模块名>.py` 或 `data/plugins/<包名>/__init__.py`，模块里导出 `@plugin` 声明的插件对象。
- **显式开启**：只加载 `data/plugins.yaml` 里写了 `local: true` 的条目；目录里多出来的文件不会被执行。

  ```yaml
  - id: acme.delete-cascade        # 条目 id = 插件名
    local: true
    module: delete_cascade         # 可选，缺省为 id 里最后一段把 - 换成 _
    config: { enabled: true }
    grants: [subscriptions.delete, dl.torrent.delete, library.items.relations]
  ```

- 来源为 `local`，按第三方对待：只能用非内部契约、贡献 id 自动加前缀、授权取「声明 ∩ grants」。
- 导入失败、找不到插件对象、id 与插件名不符 → 条目 `FAILED` 并写明原因，不影响启动。
- 诊断页在条目上标「本地插件」，摘要里单独计数；启动日志醒目提示「已加载 N 个本地插件（进程内运行，拥有与主程序相同的权限）」。
- 存储登记 `plugins.local` → `data/plugins`。

## 7. 验收插件（PR A8）

放在 `src/movieclaw_agent/builtin-skills/movieclaw-plugin-dev/references/examples/`（随插件开发技能分发，Agent 照着写），CI 里以本地受信插件的方式加载、用真实应用生命周期跑端到端测试：

1. **`watchlist_feed`（场景 2.4，外部信号触发订阅）**：定时拉取一个 JSON / 文本片单（URL 或文件），新出现的片名 →
   `search.titles` 解析 → `subscriptions.create`；409 歧义取第一个候选；已处理的片名记在插件状态文件里，重复信号不重复订阅。
2. **`delete_cascade`（场景 2.1，删片联动）**：订阅 `library.item.deleted` / `library.file.deleted`；整部删除且有订阅 →
   `subscriptions.delete(delete_torrents=true)`；部分删除 → 对自有且非 H&R 的相关种子 `dl.torrent.delete(delete_files=true)`；
   配置 `dry_run: true` 时只调演练并记日志。忽略自己引起的事件。

## 8. 实施拆分

| PR | 内容 | 验证 |
|---|---|---|
| A0 | 本文；第一阶段 NAS 验收结果回填 `plugin-kernel.md` §12.5 | — |
| A1 | 内核：第三方契约门禁、`permissions`、`DeliveryInfo`、可靠事件载荷校验 | 内核单测 |
| A2 | 可靠事件：三张表 + 迁移、`record`、投递器与重试 / 死信、`kernel.durable-events` 插件、诊断与重放接口 | 单测（顺序、至少一次、回滚不投、重启续投、死信重放、零开销） |
| A3 | 第一批领域事件 | 每个写入点一条测试：真实接口触发 → 消费者收到正确快照；回滚路径不产生事件 |
| A4 | 文件来源、下载归属、迁移回填 | 入库 / 扫描 / 重扫保留 / 回填测试 |
| A5 | 插件主体、内存令牌、授权执行点、`HOST_OPS`、审计 | 授权矩阵测试（通配、危险操作、成员交集、令牌随条目作废） |
| A6 | 新操作 | 接口测试 + CLI 命令树快照 |
| A7 | 本地受信插件加载 | 加载、显式开启、失败隔离、内部契约拦截、诊断标注 |
| A8 | 两个验收插件 + 端到端测试 | CI 端到端；NAS 部署后用真实数据跑一遍（只做可逆操作） |

每个 PR 单独可合并、单独可回滚；A1→A2→A3 有依赖，A4、A5、A6 可并行，A7 依赖 A1，A8 依赖全部。

## 9. 不回退的保证

- 现有内置插件都不订阅可靠事件 → 业务路径上 `record` 只有一次内存查找，不新增数据库写入。
- 新列可空、新参数有默认值、新操作是新增；`dry_run` 缺省 `false`。
- 授权执行点只对带 `plugin` 的主体生效，其他主体的判定路径不变。
- 本地插件必须在 `plugins.yaml` 里显式开启，默认部署不会加载任何本地代码。

## 10. 实施结果（2026-10-09）

| PR | 内容 |
|---|---|
| #652 | 本文与第一阶段 NAS 验收结果 |
| #653 | A1 内核：第三方契约门禁（注入 / 提供 / 贡献 / 监听内部契约被拒，运行中挂载也做兼容检查）、`permissions`、`ctx.delivery`、可靠载荷须为冻结 pydantic 模型 |
| #654 | A2 可靠事件：三张表、`record`（无订阅零写入）、按消费者保序投递、退避重试、死信与重放 / 忽略接口、诊断 |
| #655 | A4 文件来源：`library_file.info_hash` / `downloader_id`（入库、原地下载扫描写入，重扫不抹，迁移回填）、下载意图 `owner` |
| #656 | A3 第一批领域事件（12 个）与条目关联查询服务 |
| #657 | A5 插件身份与宿主操作 |
| — | A6 新操作、A7 本地受信插件、A8 验收插件（见各 PR） |

与计划的出入：

- **A4 提前到 A3 之前**：删除事件的快照要用文件上的来源种子，先有数据再发事件。
- **`dl.submit` 不额外锚定意图**：插件要入库认领就用 `auto_route`（与网页手动下载同一条路），A5 只补了 `owner`。
- **删除联动插件对部分删除更保守**：属于在追订阅的种子不删——删了会把那几集打回「想要」重新下载，那是
  「删某集重下」而不是清理。整部删除时先删订阅、再删种子，种子删除时订阅已不在（端到端测试锁住了顺序）。
- **宿主操作的目录**与 CLI / MCP 同一入选口径：隐藏操作（含签发凭证类）不在插件可调用的目录里，绕过目录直接
  带凭证请求也过不了交互式会话的门槛，两层拦截。
- 插件发起的请求记为本次请求的发起方，插件的因果链穿过宿主操作进入请求：插件调用引起的可靠事件 `origin`
  就是插件本身，`ctx.delivery.origin.is_plugin(ctx.entry_id)` 即可忽略自己引起的事件。

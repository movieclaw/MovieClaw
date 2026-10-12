# 统一事件：一次产生，处处消费

> 状态：**设计稿**（2026-10-12）。调研基于 main `e3e200c4`。
>
> 目标：业务里每件「发生了的事」**只在一处产生、只产生一次**；通知（App + IM）、Webhook、插件、内置的事后动作
> 都作为订阅方从同一条总线取。新增一个事件只登记一处，所有消费方同时可用；同一件事在通知、Webhook、插件里
> 是同一个名字、同一份载荷、同一个口径。
>
> 前提（用户拍板）：插件与 Webhook 还没有需要照顾的存量用户，**不背兼容包袱**，事件名、载荷、Webhook 报文、
> 推送偏好键全部按本文重定。重构完要支持「插件声明自己的事件、经用户批准后给设备和 IM 发通知」（§7）。

## 0. 结论先行

1. **一份事件目录**：内核注册表，内置事件与插件事件都是它的贡献，插件装上 / 卸载时随之增减。
2. **一个产生入口**：`events.publish(session, 事件, build)`。载荷延迟构造（没人听不构造），随业务事务提交才发出、
   回滚即作废——「commit 之后再调」从约定变成机制。
3. **投递方式由订阅方选**：同一个事件，要做副作用的订阅方选可靠投递（落库、至少一次），通知这类选实时投递（内存、
   至多一次）。高频事件只能实时。
4. **事件和通知分层**：事件是事实，通知是发给人的消息。通知由「通知规则」从事件导出——简单的用声明式规则，
   剧卡这类需要合并状态的用聚合器。插件发通知 = 插件声明事件 + 声明通知规则，用户批准后由同一个通知引擎发。
5. **Webhook 是可靠订阅方**：每个地址一个消费者，重试、死信、重放直接复用可靠事件的那套；报文就是事件信封本身。

## 1. 现状（调研结论）

### 1.1 四套出口各自为政

| 出口 | 入口 | 事件定义 | 语义 | 消费方 |
|---|---|---|---|---|
| 推送中枢 | `services/push/events.py` → `hub.emit` / `notify` | 中枢里的 dataclass + `push/preferences.py` 的九种推送 | 内存，约定提交后调，重启丢 | App 推送、IM |
| Webhook | `services/webhook.emit_events` | `webhook/catalog.py` + `OutboundEvent` | 内存任务，重试 3 次 | 外部 HTTP |
| 可靠事件 | `domain_events.record_*` | `movieclaw_api/domain_events.py` | 事务内写库，至少一次 | 插件 |
| 实时事件 | `hooks.emit` | `movieclaw_sdk/library.py` | 内存，至多一次 | 插件 |

另有几处「事实 + 手挂推送」：待处理事项 `upsert_notice` 里直接调推送（`system_notice.py:75`），`subscription/twins.py:185`
绕开 `upsert_notice` 自己写库再推；新设备登录、使用提示同理。

### 1.2 由此产生的问题

- **同一处连调多次**：订阅开始下载（`subscription/dispatch.py:544/589/602`）、订阅入库（`wanted_fulfillment.py:106/129/136`）
  各连调三个出口，各拼各的载荷；开始播放、收藏各调两个（`playback/watch.py:416/426`、`marks.py:212/217`）。
- **名字不一致**：可靠事件 `subscription.download-started`，Webhook `subscription.download_started`；实时
  `library.item.favorited`，Webhook `item.favorited`；推送偏好 `download_started`、`imported`。
- **口径不一致**：订阅入库时推送只报订阅范围内的季集（`in_scope`），Webhook 和可靠事件报全部。
- **覆盖面不一致**：洗版完成只有推送；播放停止 / 看完 / 标记只有 Webhook；删除、回收站只有可靠事件；「媒体库有新片」
  只有推送；下载完成只有可靠事件。
- **没人听也有开销**：Webhook 的载荷在业务链路上拼，每次开始播放、停止、进度、标记、收藏都多查 1～2 次库，
  Webhook 关着也查（`playback/watch.py:415`、`marks.py:187`）。
- **事后动作硬编码**：入库后的章节图、跳片头、预告、重复检测（`library/ingest.py:2410-2418`、`scan.py:645/946/952`），
  通知 Emby/Jellyfin 刷新（`media_server_notify.py`，7 处调用）都在产生点直接调。

### 1.3 已经做对、要保留的

- 可靠事件的 outbox：事务内写、`after_commit` 唤醒、按消费者保序、退避重试、死信、重放（`services/durable_events.py`）。
- 内核总线：每个监听器一个有界队列、隔离执行、超时、熔断、因果链上限（`movieclaw_kernel/events.py`）。
- 推送中枢「业务只投事件、单消费者串行合并」的结构（`push/hub.py`、`push/cards.py`）。
- 「媒体库有新片」靠轮询台账判定，而不是在每条入库路径上挂钩子——入库路径太多，挂钩子必漏（`push/arrivals.py` 头注释）。
- 各端通知偏好页按服务端下发的目录渲染（`PushEventView`），只有「媒体库有新片」的选库是特例。

## 2. 边界：什么算事件

| 类别 | 现有机制 | 本设计 |
|---|---|---|
| **领域事实的广播**：发生了什么，谁关心谁来接 | 上面四套出口、待处理事项连带的推送、媒体服务器刷新、入库后排的任务 | 统一产生、统一消费 |
| **业务记录**：本身是事实源，业务会回头读 | 订阅动态（`subscription_activity`）、待处理事项（`system_notice`）、任务时间线（`job_event`）、播放日志、使用提示 | 仍是存储；写入处顺带 `publish`，代替手挂的推送 |
| **同步端口**：事务内同步完成、要返回值 | `AcquisitionBridge`、插件决策钩子（waterfall / bail） | 不并入：事件不能决定业务结果 |
| **进度流**：高频、面向单个会话 | 任务中心推流（`/jobs/stream`）、Agent 运行流 | 不并入：不是领域事实 |

## 3. 事件模型

### 3.1 命名

`<域>.<对象>.<动作>`：全小写，段内用下划线，动作用过去时。例：`subscription.download_started`、
`library.item.deleted`、`playback.completed`。

- 保留的域：`subscription`、`download`、`library`、`playback`、`account`、`system`。
- 插件事件以**插件 id** 开头：`acme.quota.exceeded`。插件 id 不得与保留的域同名（安装时校验）。
- 内核自己的生命周期事件（`kernel/ready`、插件状态）是内部契约，不进本目录。

### 3.2 信封

所有消费方看到同一份 JSON（插件拿到的是同构的冻结模型）：

```json
{
  "id": "01JA…",                       // ULID：时间有序、全局唯一，消费方按它去重
  "type": "subscription.fulfilled",
  "version": "1.0",
  "occurred_at": "2026-10-12T08:00:00+00:00",
  "origin": {"kind": "member", "id": 3},   // member / admin / plugin / scheduler / system
  "data": { … }                        // 各事件的载荷
}
```

Webhook 只在外面再加 `server`（实例 id、版本）。`origin` 来自现有的 `current_origin` 上下文，不由产生点手填。

### 3.3 载荷

- 冻结 pydantic 模型，能导出 JSON Schema（进程外插件、Webhook 文档都用它）。
- **快照自足**：消费方拿到载荷就能展示，不必回查库。共用引用类型：
  - `MediaRef`：`id`、`kind`、`title`、`original_title`、`year`、`tmdb_id`、`imdb_id`；
  - `UnitRef`：`season`、`episode`，电影没有单元（列表为空、单个为 `null`）——内部哨兵值（`(0,0)`、`(-1,-1)`）
    一律不外泄。单集标题这类要多查一次库的不进载荷，需要的消费方（如 Jellyfin 格式）投递时自己补查；
  - `FileRef`、`MemberRef`（id + 显示名）、`ClientRef`（客户端名、设备名、设备 id、版本）。
- 去掉现在标着「即将移除」的字段（`FileRef.info_hash`、`downloader_id`，`LibraryDeleted.links`），既然不背包袱就不再带。
- 同一件事只有一个口径，差异做成字段而不是做成两个事件：例如 `subscription.fulfilled` 带 `units`（本次确认入库的全部季集）
  和 `requested_units`（其中仍在订阅范围内的），推送用后者，Webhook 和插件两者都看得到；整部 / 整季标记已看是**一个**
  `playback.marked_played` 事件、带受影响的每一集（不再逐集一条再靠 batch_id 聚合）。

### 3.4 目录条目

```python
SUBSCRIPTION_FULFILLED = define(
    "subscription.fulfilled",
    SubscriptionFulfilled,
    title="订阅内容已入库",
    group="订阅",
    doc="订阅的季集经媒体库对账确认入库",
    sensitive=False,      # 见 §6.3
    high_frequency=False, # True = 只能实时订阅、不进 Webhook 默认勾选
)
```

- 定义集中在一个轻量包里（`movieclaw_sdk.events`，按域分模块），进程外插件导入不带数据库层。
- 目录是内核注册表 `EVENT_CATALOG`：内置事件由核心插件贡献；插件事件由插件清单贡献（§7），装上即出现、卸载即消失。
- 管理接口把目录下发给网页和 App：Webhook 的事件勾选、通知偏好、插件详情页的「会发出的事件」都从这里渲染。

## 4. 产生：`publish`

```python
# 事务内：随这次提交成立
await events.publish(session, SUBSCRIPTION_FULFILLED, lambda: SubscriptionFulfilled(...))
await session.commit()

# 没有业务事务的事实（检查到新版本、计时器触发的检测器）
events.publish_now(SYSTEM_UPDATE_AVAILABLE, lambda: UpdateAvailable(...))
```

1. **没人听就什么都不做**：没有可靠消费者、也没有实时监听器时直接返回，`build` 不调用。判定是一次内存查找
   （可靠消费者名单沿用 `durable_events._subscribed`，实时看总线的监听器表）。
2. 有人听：调 `build` 一次。有可靠消费者就在同一个会话里写 outbox 行；有实时监听器就把事件挂到 `session.info`。
3. **提交才发**：会话 `after_commit` 时按挂上的顺序 `bus.emit`；`after_rollback` 时丢掉。会话没提交就关掉，事件也作废。
4. **放在哪里**：仓储层会中途提交（`add_activity` 自己 commit），所以规则同可靠事件——`publish` 紧挨在「记录这件事」
   的那次提交之前。
5. **不抛错**：`build` 出错只记日志，事件丢掉，业务照常提交。没有事件循环（命令行）时 `publish_now` 什么都不做；
   别的线程用 `publish_threadsafe`。
6. **因果链**：沿用内核的层数上限，插件经事件互相触发成环时不再产生新事件。
7. **守护测试**：业务代码不准直接 import `push.notify`、`webhook` 投递器、`bus.emit`、`durable_events.record`，
   只能经 `events.publish*`。

## 5. 投递与订阅

| 方式 | 实现 | 语义 | 谁用 |
|---|---|---|---|
| 实时 | 内核总线：每个监听器一个有界队列 + 串行消费 | 至多一次，满了丢新的，重启丢 | 通知、strm 预探这类「错过一次无所谓」 |
| 可靠 | 现有 outbox：事件表 + 消费者进度 + 死信 | 至少一次、按消费者保序、退避重试、可重放 | Webhook、有副作用的插件、要保证执行的事后动作 |

- **投递方式由订阅方选**：`ctx.on(EVENT, handler, id="…", durable=True)`。内核去掉 `Event.delivery`，改成订阅时声明；
  `high_frequency` 的事件拒绝可靠订阅。`publish_now` 发的事件有可靠消费者时，自己开一个短会话写 outbox。
- 同一个消费者内保序；实时和可靠之间、不同消费者之间不保证先后。
- 写库开销只在「有人可靠订阅了这个事件」时发生：Webhook 没配、插件没订，就是零写入。

## 6. 消费方

### 6.1 通知（App + IM）

分三层：**事件 → 通知规则 → `notify()` → 渠道（App / IM）**。`notify()` 和渠道层就是 #813 统一好的那套，不动。

**通知规则**是新增的一层，两种：

- **声明式规则**：一个事件对应一条通知，模板 + 收件人 + 打扰级别，全部是数据。

  ```python
  rule(
      key="account.device.signed_in",   # 偏好开关的键，默认就是事件名
      event=ACCOUNT_DEVICE_SIGNED_IN,
      title="新设备登录：{device.name}",
      body="{device.client}",
      audience=Audience.member("member.id"),
      exclude_devices="device.id",
      level="time-sensitive",
      default=True,
      group="账号安全",
  )
  ```

- **聚合器**：需要跨事件合并状态的，仍是代码。剧卡（开始下载、订阅入库、手动下载入库、新片到达合成一张卡）、
  待处理事项攒 90 秒成批、洗版合并都属于这类。聚合器同样声明自己的偏好键和收件人，只是渲染在代码里。

**收件人**是声明式的，宿主负责解析：

| 写法 | 含义 |
|---|---|
| `admins` | 管理员 |
| `member("字段")` | 载荷里指定的成员 |
| `subscribers("字段")` | 订阅的发起人 + 关注者 |
| `actor` | 发起这次动作的人（来自 `origin`） |
| `media("字段")` | 订阅或关注了载荷里这部片的人（插件通知可用，§7.3） |

载荷里有 `MediaRef` 时，宿主**自动**按收件人做可见性过滤（库可见范围 + 内容分级），规则不用、也不能关掉这一步。

**偏好**按规则的 `key` 存，目录接口下发分组（内置分组 + 每个插件一组），各端照现在的方式通用渲染。
旧键（`imported`、`download_started`……）用一次数据迁移改成新键。

**推送中枢**作为一个实时监听器挂到总线上，收到事件转进自己的队列，保持「单消费者串行、合并状态不加锁」的前提
（直接让总线给每个事件各开一个消费者会破坏它）。

### 6.2 Webhook

- **每个地址一个可靠消费者**（内置插件 `webhook.delivery`，消费者 id `webhook.delivery:<地址 id>`），一个消费者订阅
  一组事件、按产生顺序投递。重试（退避到半小时）、死信、重放都用 outbox 那套，删掉 Webhook 自己的内存重试；
  内存里的「最近投递」记录保留给设置页排障。高频事件（`playback.progress`）走实时订阅，失败不重试。
- 配置保存后按新的勾选调整订阅；地址删了、关了，消费者行一并删，业务侧不再为它写事件。投递插件停着时产生的事件
  照常写进事件表，恢复后从停下的地方补投。每次投递读当前配置（改密钥不用重新订阅）。
- **报文就是信封**（§3.2）加 `server`，HMAC-SHA256 签名，`X-MovieClaw-Event`、`X-MovieClaw-Event-Id`（供幂等）。
- **事件勾选**按目录渲染、按分组全选；新建地址默认勾选非高频事件。老配置里的旧事件名按别名换新。
- **Jellyfin 兼容格式保留为一种输出格式**：它的价值是让为 Jellyfin Webhook 插件写的下游工具直接可用，这是功能不是包袱；
  只覆盖播放和用户数据类事件，名字映射留在格式化器里。`playback.stopped` 带 `completed`（停止时刚好看完），映射成
  `PlaybackStop` + `PlayedToCompletion`，所以 `playback.completed` 不再映射、也不用合并去重；级联标记按集各发一条。
  成员名、单集标题在投递时补查（业务链路之外）。
- 原来 `movieclaw_playback/events.py`、`subscription/events.py` 这两份拼 Webhook 载荷的代码删除。

### 6.3 插件

- `ctx.on` 订阅目录里任何非内部事件，进程外插件同样经代理收到（`plugin-phase3.md` §4.3），只是名字和载荷换成本文的。
- **敏感事件要单独批准**：播放、收藏、浏览、账号类事件带 `sensitive=True`（谁在什么时候看了什么）。订阅它们须在清单
  `[permissions] events = ["playback.*"]` 里声明，安装时向用户单独展示；只在 `requires` 里写是不够的。
- 插件之间可以互相订阅对方声明的事件（§7）。

### 6.4 内置的事后动作

入库后排章节图 / 跳片头 / 预告 / 重复检测、通知 Emby/Jellyfin 刷新，改成监听器（丢了要补的走可靠订阅）。
放在最后一期，逐个评估（P6）。

### 6.5 业务记录类存储

订阅动态、待处理事项继续由业务同步写入，它们不是消费方。改的是写入处：

- `upsert_notice` 新建或复发时 `publish(system.alert.raised)`，消退时 `publish(system.alert.resolved)`，不再直接调推送；
- `twins.py` 的「同名跳过只知会一次」：那行已消退的告警本身是给用户看的处理记录，照写，并靠它去重；第一次写入时
  发 `subscription.identity_skipped`，通知由规则推，不再直接调推送。

## 7. 插件自定义事件与通知

### 7.1 要不要在这次设计里考虑

要。它决定了这次的四个结构性选择，事后补会返工：

1. 目录必须是**可增减的注册表**，不能是一个写死的列表；
2. 载荷必须能用**语言无关的 JSON Schema** 描述（进程外插件、Go 插件）；
3. 通知必须有**声明式规则**这条通路，否则插件只能写代码渲染，宿主无从审查；
4. 偏好、收件人必须**按事件 / 规则泛化**，不能是九个写死的键。

所以这次的通知引擎直接按「插件也能用」来做：新设备登录、待处理事项单条、新版本、使用提示、同名跳过这几条
内置通知本身就改成声明式规则（P1），等于插件通知那条路先被内置功能走通。插件侧的清单、批准、发布接口放在后面单独一期（P7）。

### 7.2 插件怎么声明

```toml
[[events]]
name = "acme.quota.exceeded"            # 必须以插件 id 开头
title = "站点配额超限"
schema = "schemas/quota_exceeded.json"  # JSON Schema；Python SDK 可由 pydantic 模型导出

[[notifications]]
event = "acme.quota.exceeded"
title = "{site} 配额超限"
body = "剩余 {remaining_gb} GB，已暂停该站点的订阅搜索"
audience = "admins"                     # admins | member:<字段> | media:<字段>，见 §7.3
level = "active"                        # passive | active
default = true
open = "plugin"                         # 点开去哪：插件页，或载荷里的 media 对应的条目页
```

发布：`await ctx.publish(QUOTA_EXCEEDED, payload)`。进程内直接进总线；进程外经插件运行时的 HTTP 端点
（按插件令牌限定，`plugin-ipc-http.md`），语义同 `publish_now`。

### 7.3 发给谁

**插件不挑人，只声明「这条通知该谁关心」**；宿主在发出时把它解析成具体的人，再过每个人的偏好开关和可见性过滤。
收件人写在清单里、随安装批准，不能每次调用临时换，所以批准页能如实告诉用户「它会通知谁」。

第一版三种：

| 写法 | 谁收到 | 插件怎么拿到 | 典型场景 |
|---|---|---|---|
| `admins` | 管理员 | 不用拿 | 站点配额超限、网盘凭据失效、同步失败 |
| `member:<字段>` | 载荷里这个字段指定的成员 | 只能是宿主给过它的成员 id：成员调用它的 `member` 区路由时的调用者、它订阅的事件载荷里的成员（如 `playback.started` 的观看者）、它被批准的宿主操作返回的成员 | 成员在插件页点「转存到网盘」，完成后通知这个人 |
| `media:<字段>` | 订阅或关注了这部片的人（与内置订阅通知同一口径） | 载荷里放 `MediaRef` | 字幕插件找到了中文字幕、网盘插件预探完成 |

- 「谁触发就通知谁」不单列：插件在处理请求时把调用者 id 写进载荷，再用 `member:<字段>`。这样同步、异步完成的情况一个写法，
  载荷里也留下了「为谁做的」，Webhook 和别的插件也看得到。
- 宿主校验 `member:` 指向的是存在且启用的成员，不是就丢弃这条通知并记日志。插件能拿到哪些成员 id 取决于它已被批准的权限，
  宿主不为通知另开口子（比如不提供「列出所有成员」）。
- 群发给所有成员第一版不做，需要时再加 `everyone`（每个人默认关闭）。

### 7.4 用户怎么批准、怎么关

- **安装 / 升级时**：批准页列出「会发出的事件」和「会通知谁、通知什么」。会通知到普通成员的（`member:`、`media:`）要单独勾选，
  只通知管理员的随安装一起批准。升级时新增事件或扩大收件人范围算权限扩大，须重新批准（同 `plugin-phase3.md` §3）。
- **事后**：插件页有总开关「允许发通知」；每个人在「账号 → 通知」的插件分组里逐条开关。

### 7.5 宿主把关

第一版只做必须的几条，其余按需迭代：

| 项 | 规则 |
|---|---|
| 命名空间 | 只能发自己 id 下、且清单里声明过的事件 |
| 载荷 | 按声明的 Schema 校验 |
| 来源 | 通知上标「来自 插件名」，和系统通知区分开 |
| 可见性 | 载荷带 `MediaRef` 时照常按收件人过滤（通知引擎本来就做，不是额外工作） |
| 卸载 | 目录条目、通知规则随之消失；偏好行删除；Webhook 地址里对这些事件的勾选去掉；可靠消费者进度清理 |

**先不做**：频率控制、文案长度上限、打扰级别限制、配图。真遇到插件刷屏或滥用再加，届时都只是通知引擎里针对插件来源的一层检查，
不影响本设计的结构。

插件事件和内置事件同等对待：别的插件可以订阅，Webhook 也可以勾选。

## 8. 首批事件

| 事件 | 产生点 | 通知规则 | 敏感 | 高频 |
|---|---|---|---|---|
| `subscription.created` / `deleted` / `status_changed` | `subscription/core.py` | — | | |
| `subscription.download_started` | `subscription/dispatch.py` | 剧卡（聚合） | | |
| `subscription.fulfilled` | `wanted_fulfillment.py` | 剧卡（聚合） | | |
| `subscription.upgraded` | `subscription/upgrade.py` | 洗版合并（聚合） | | |
| `subscription.identity_skipped` | `subscription/twins.py` | 声明式，每个订阅一次 | | |
| `download.completed` | `download_progress.py` | — | | |
| `download.imported`（手动下载的内容全部入库） | `push/downloads.py` 的匹配逻辑挪到获取领域，产出事件 | 剧卡（聚合） | | |
| `library.ingest.completed` | `library/ingest.py` | — | | |
| `library.files.added` | `scan.py` / `ingest.py` 现有的 `emit_files_added` | — | | |
| `library.items.arrived`（新片到达，检测器产出） | `push/arrivals.py` 的检测部分 | 剧卡 / 新片汇总（聚合） | | |
| `library.item.deleted` / `library.file.deleted` | `routes/libraries.py` 删除 | — | | |
| `library.file.trashed` / `restored` / `purged` | `library/recycle.py` | — | | |
| `library.item.favorited` / `unfavorited` | `playback/marks.py` | — | ✓ | |
| `library.item.viewed` | Jellyfin 条目路由、`routes/libraries.py` | — | ✓ | ✓ |
| `playback.started` / `stopped` / `completed` | `playback/watch.py` | — | ✓ | |
| `playback.progress` | `playback/watch.py` | — | ✓ | ✓ |
| `playback.marked_played` / `marked_unplayed` | `playback/marks.py` | — | ✓ | |
| `account.device.signed_in` | `login_devices.py`、Jellyfin 登录 | 声明式（新设备） | ✓ | |
| `system.alert.raised` / `resolved` | `system_notice.py` | 聚合（攒 90 秒） | | |
| `system.update.available` | `app_update.py` | 声明式（管理员） | | |
| `system.tip.suggested` | `reels/clip_tip.py` | 声明式（管理员） | | |

只有订阅动态里出现、目前没有任何出口的事实（投递失败、换源、等用户确认集数提示等）不在首批，按需再加——加的时候只需登记一处。

## 9. 分期

每期都能单独合并；每期除单测外都做端到端验证（隔离预览环境 + 虚构数据，按真实使用场景走全链路）。

| 期 | 内容 | 验证 |
|---|---|---|
| P0 底座 | 事件定义包与目录注册表、信封、`publish` / `publish_now`、提交后统一发出、内核把投递方式移到订阅侧、守护测试 | 单测：回滚不发、没人听不构造、提交顺序、因果链；行为零变化 |
| P1 通知引擎 | 通知规则（声明式 + 聚合器）、收件人解析与可见性过滤、偏好按规则键（数据迁移）、目录接口；推送中枢挂总线；新设备 / 待处理事项 / 新版本 / 使用提示 / 同名跳过改成事件 + 声明式规则 | 网页、iPhone 偏好页渲染；新设备登录、触发告警的真实通知（推送出口 + IM） |
| P2 订阅 + Webhook | 订阅五个事件改单点 `publish`；剧卡改吃事件；Webhook 重写为可靠消费者 + 新报文 + 按目录勾选 | 真实「抓取→下载→入库」：剧卡、IM、Webhook 接收端、重启后 Webhook 补投、死信重放 |
| P3 播放与收藏 | 播放、标记、收藏、浏览改单点；敏感事件授权；Jellyfin 格式改吃新载荷 | Jellyfin 格式报文对照；strm 预探照常工作；业务链路上不再多查库 |
| P4 媒体库 | 入库、新增文件、删除、回收站；新片检测与手动下载匹配改为产出事件，通知只消费 | 同一集只在一张剧卡上出现；新片汇总 |
| P5 收口 | 删除旧入口（`push/events.py` 的产生函数、`webhook.emit_events`、`hooks.emit`、`domain_events.record_*`）；守护测试改严格 | 全量相关测试 |
| P6 事后动作 | 入库后排的任务、媒体服务器刷新改监听器，逐个评估要不要可靠订阅 | 入库后各任务照常排上；Emby/Jellyfin 收到刷新 |
| P7 插件通知 | 清单 `[[events]]` / `[[notifications]]`、`ctx.publish` 与进程外端点、批准页、来源标注、卸载清理；开发技能 `movieclaw-plugin-dev` 补文档 | 示例插件：声明事件 → 批准 → 发通知到 App 与 IM → 关开关 → 卸载 |

接口变化都要同步：成员白名单、CLI 快照、iOS 与 Android TV 的生成代码。

## 10. 约束

- 业务链路不阻塞、不抛错；没人听零开销（不构造载荷、不写库）。
- 提交才发；同一消费者内保序（剧卡依赖「开始下载」先于「入库」处理）。
- 通知仍是实时投递，重启丢失在途（重启后补发过时的通知比不发更糟）；剧卡状态仍只在内存。
- NAS 写库预算：可靠写入只发生在有可靠订阅时。Webhook 订了播放类事件时每次开始 / 停止各一行，P2/P3 在 NAS 上实测。

## 11. 不做

- 不把订阅动态、待处理事项、任务时间线改成从事件推导状态。
- 不引入外部消息队列。
- 不改 `AcquisitionBridge` 和插件决策钩子。
- 不承诺通知跨重启必达。

## 12. 决策记录（2026-10-12 用户拍板）

1. 插件、Webhook 不背兼容包袱，事件名、载荷、报文按本文重定；推送偏好旧键做一次数据迁移。
2. Webhook 可勾选目录里全部事件（含插件事件），新建地址默认勾选非高频事件。
3. 订阅入库的载荷同时带 `units` 和 `requested_units`。
4. 事后动作放到 P6，等前面稳定后再做。
5. 插件自定义事件与通知在本设计里定好结构，实现放 P7；第一版不做频率控制等限制，按需迭代。

## 13. 待定

- 敏感事件的授权粒度：按域（`playback.*`）还是逐个事件。
- 声明式模板是否需要最少量的格式化（季集号、时长、文件大小），还是只做字段替换。

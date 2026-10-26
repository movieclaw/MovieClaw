# 通用事件 Webhook 设计

> **已被取代的部分**（2026-10-12）：事件的产生与投递已改成统一事件（`domain-events.md` §6.2）——Webhook 是系统事件
> 总线上的一个可靠订阅方，报文就是事件信封（`id` / `type` / `occurred_at` / `origin` / `data` + `server`），事件名与载荷
> 和插件看到的一致，重试改由可靠事件负责。下文的信封字段、`emit_events` 产生点、内存重试、`item.favorited` 等旧名均已不再适用。

> 状态：**v1.1 P1/P2/P3 全部已实施**（2026-08-05）。P1 = 自有协议闭环（播放 +
> 收藏域）；P2 = Jellyfin 兼容格式 + `playback.progress`；P3 = 订阅域接入
>（首个非播放域，验证了「builder + 目录一行 + emit 一行」的扩展承诺）。
>
> 版本演进：v1.0 定名「播放事件 Webhook」；v1.1（2026-08-05 用户决策）① 收藏事件
> 确认纳入 P1；② 架构泛化为**全系统通用的事件出站通道**——播放域只是首发域，
> 订阅、入库等其他领域事件未来走同一条链路，报文相应引入信封/数据分层。
>
> 源起：issue #86（@kriskwok 提出）——Infuse 等播放器已通过 Jellyfin 兼容接口把播放
> 进度/已看状态写进 MovieClaw，但 Yamtrack、Home Assistant、自建统计等外部服务无法
> 及时获知这些变化，只能读库或轮询，与内部表结构耦合。需要一个可选的、通用的
> 事件 Webhook。
>
> 依据：main 分支 `b0e19b7` 的代码调研；jellyfin-plugin-webhook 官方文档（模板变量
> 与 Handlebars 助手清单）；Stripe / GitHub webhook 的管理与签名惯例。
>
> 关联文档：`docs/design/jellyfin-compat.md`（播放状态写入链路、§8.5 领域层/协议层
> 分离原则）。
>
> **本文档即实现契约**：对外报文格式、字段稳定性承诺、事件映射规则以本文为唯一裁判。

## 0. 定位与硬决策

定位一句话：**MovieClaw 内发生的领域事件（首发：播放与收藏），主动向用户配置的
一个或多个 HTTP endpoint 推送 JSON；每个 endpoint 可选「自有协议」或「Jellyfin
兼容」两种外发格式，前者面向新接入方，后者让已适配 Jellyfin Webhook 插件的下游
免适配接入。架构上任何领域的事件都能以极小成本接入这条出站链路。**

以下决策实现时不可突破：

1. **信封与数据分层**。所有事件共用统一信封（`spec_version` / `event_id` /
   `event` / `occurred_at` / `server` / `batch_id`），事件专属字段全部收进 `data`
   对象。信封是全系统契约，`data` 结构按事件类型各自承诺——新增领域不动信封。
2. **事件目录注册制**。每种事件在事件目录（catalog）中登记：事件名、所属分组、
   `data` 装配来源、Jellyfin 映射（可选）。新领域接入 = 领域侧一个 builder +
   目录登记一行 + 产生点一行 emit 调用，不改动投递链路任何代码。
3. **触发点在协议层/服务层、`session.commit()` 之后**。不放领域层，理由有三：
   ① 领域函数在 commit 前返回，领域层内发事件会推送尚未落库的状态；
   ② `stopped` 与 `completed` 在领域层无法区分（Jellyfin 协议里 Progress 与 Stopped
   共用 `record_playback_progress`，只有协议层知道本次上报是不是 Stopped）；
   ③ 客户端信息（Infuse / Apple TV）只在协议层的 `RequestIdentity` 里可达。
   领域包只提供事件 builder（纯装配，不投递），保持协议无关。
4. **推送绝不影响业务主链路**。同步签名 + `asyncio.create_task` fire-and-forget、
   任务强引用集合防 GC、异常全吞只记日志——完全对齐 `services/channel_push.py`
   的既有惯例。
5. **出站必须走 `movieclaw_net.egress_transport`**，新增服务标签 `webhook` 并在
   `BUILTIN_EGRESS_SERVICES` 登记；endpoint 可逐个选择 `LAN`（内网直连，默认）或
   `WAN`（走代理）出口。
6. **内部单位毫秒、时间 RFC3339 带时区、字段 snake_case**。ticks 只允许出现在
   Jellyfin formatter 的边界换算里（`position_ms × 10000`），与兼容层"入站把 ticks
   归一为 ms"方向对称。
7. **自有协议字段只增不改不删**。信封带 `spec_version`，演进只做加法，消费端必须
   忽略未知字段——与"数据库迁移只向前兼容"同一价值观。
8. **P1 零数据库迁移、零新增运行时依赖**。配置走 `app_setting`
   （namespace `webhook`）；HMAC 用标准库 `hmac`/`hashlib`；ULID 自实现
   （约 20 行，`os.urandom` + 时间戳，避免引入 `python-ulid` 触发
   `docker/runtime-version` bump）。**本功能 P1 无需 bump runtime-version。**

有意偏离清单：

- ① 偏离 issue 原始建议的「环境变量配置」——改走设置页 + `app_setting`，理由：
  项目三层配置边界（`settings/__init__.py` 备忘）规定运行时业务配置不走 env，且
  Stripe 式管理页需要运行时增删 endpoint。
- ② 偏离 Jellyfin Webhook 插件的「无签名」惯例——自有格式强制 HMAC 签名；
  Jellyfin 兼容格式为保持下游行为一致不签名，但支持自定义 header 供下游鉴权。
- ③ 偏离 issue 原始建议的扁平报文（media/playback 置顶层）——引入 `data` 分层，
  理由：v1.1 泛化为全系统事件通道后，顶层只能放跨领域共有的信封字段。
- ④ 现有 IM 推送（`channel_push`）**不并入**本链路——两者消费形态不同（IM 是
  人读消息，webhook 是机读事件），仅在产生点相邻调用；是否统一事件源见 §8。
- ⑤ 出站走 `egress_transport` 但**关闭熔断**（2026-08-05 审查修正，撤销 v1.1
  原定的"命中熔断快速失败"）——熔断器按服务标签全进程共享，而 webhook 的
  目标是逐 endpoint 的：一个宕机的 endpoint 会把共享熔断打开，拖垮其他健康
  endpoint 的投递。重试本身有界（3 次），失败代价可控；代理路由仍按
  `webhook` 标签生效。

## 1. 事件模型

### 1.1 事件目录

事件命名 `<domain>.<action>`。P1 落地两个域：

| 事件 | 触发时机 | 分期 |
| --- | --- | --- |
| `playback.started` | 客户端上报开始播放（`record_playback_start`） | P1 |
| `playback.stopped` | 客户端上报停止播放 | P1 |
| `playback.completed` | 本次上报使 `played` 从 False 翻转为 True（阈值判定见 `movieclaw_playback/progress.py`） | P1 |
| `playback.marked_played` | 手动标记已看（含整季/整剧级联，逐单元发） | P1 |
| `playback.marked_unplayed` | 手动取消已看（同上） | P1 |
| `item.favorited` | 收藏（电影/剧集/整季/整剧） | P1 |
| `item.unfavorited` | 取消收藏（同上） | P1 |
| `playback.progress` | 播放进度上报，按单元节流（默认间隔 30s），**默认关闭** | P2 |
| `webhook.test` | 设置页「发送测试」，载荷为示例数据 | P1 |

预留域（本期不实现，列出仅为验证目录设计的可扩展性；事件名接入时定稿）：
`subscription.*`（开始下载/订阅入库，产生点即通知事件（当时的 `notify_channels`）调用旁——
`services/subscription/dispatch.py:192`、`wanted_fulfillment.py:89`）、
`library.*`（新入库）、`system.*`（更新完成等）。

接入新域的完整清单（写进目录模块 docstring，作为后来者指引）：
① 领域侧写 builder（产出 `data` dict）；② 目录登记（事件名、分组、Jellyfin 映射
或 None）；③ 产生点 commit 后调用 `emit_events([...])`。投递链路零改动。

### 1.2 P1 触发点映射（`src/movieclaw_jellyfin/routes/playstate.py`）

legacy 别名路由与主路由共享同一批 handler，因此埋点共 8 处：

| handler | 触发事件 |
| --- | --- |
| `playing_start`（含 legacy） | `playback.started` |
| `playing_progress`（含 legacy） | `playback.completed`（仅当 played 翻转） |
| `playing_stopped`（含 legacy） | `playback.stopped`；若本次同时翻转 played，追加 `playback.completed` |
| `mark_played` | `playback.marked_played` × N（级联单元，共享 `batch_id`） |
| `mark_unplayed` | `playback.marked_unplayed` × N（同上） |
| `mark_favorite` | `item.favorited` |
| `unmark_favorite` | `item.unfavorited` |

`playing_ping` 心跳本就不落库，不触发任何事件。

配套的领域层小改动（保持协议无关）：`record_playback_progress` 的返回值补充
`newly_played: bool`（played 是否在本次从 False 翻转为 True），供协议层判定
`completed`；`mark_played` 已返回级联单元列表，无需改动。

### 1.3 统一信封 `OutboundEvent`

定义在新叶子包 `src/movieclaw_events/`（不依赖任何协议包与服务层，任何域包可
依赖它构造事件；ULID 生成器同包实现）：

```
OutboundEvent:
  event_id: str            # ULID，重试不变，消费端幂等去重键
  event: str               # 目录中登记的事件名
  occurred_at: datetime    # 带时区
  batch_id: str | None     # 级联批次共享，其余为 None
  data: dict               # 事件专属字段，由领域侧 builder 装配
```

`server` 对象由 formatter 统一附加（`jellyfin.compat` 的 server_id + 应用版本），
不进领域侧。

### 1.4 播放/收藏域的 `data` 结构

builder 在 `src/movieclaw_playback/events.py`，JOIN `media_item` 一次取标识与
标题；**不复用** `movieclaw_jellyfin/catalog.py` 的 `load_bundles`（避免领域层
反向依赖协议包，且它装载的内容远超所需）。

`playback.*` 事件：

```
data:
  media:
    type: "movie" | "episode"
    tmdb_id: int           # 必填唯一锚（media_item.tmdb_id 非空唯一）
    imdb_id: str | None
    title / original_title: str
    year: int | None
    season_number / episode_number: int | None   # 电影为 None（内部 (0,0) 哨兵不外泄）
  playback:
    position_ms / duration_ms: int | None
    played: bool
    play_count: int
  client:                  # 可空；来自协议层 RequestIdentity，未来网页端可能没有
    name / device_name / device_id / version
```

`item.favorited` / `item.unfavorited` 事件：

```
data:
  media:
    type: "movie" | "series" | "season" | "episode"   # 收藏目标层级
    tmdb_id / imdb_id / title / original_title / year
    season_number: int | None    # season/episode 层级时有值
    episode_number: int | None   # episode 层级时有值
  favorite: bool
  client: 同上，可空
```

收藏层级由内部哨兵单元翻译而来（`(0,0)`→movie、`(s,-1)`→season、
`(-1,-1)`→series、其余→episode），哨兵数值**不外泄**。

### 1.5 订阅域的 `data` 结构（P3 定稿）

builder 在 `src/movieclaw_api/services/subscription/events.py`，纯装配不查库。
订阅域事件描述**已发生的外部动作**（种子已提交下载器 / 库存对账确认入库），
不依赖当前事务落库，产生点与 IM 推送相邻调用（这是对硬决策 3 的域内澄清，
不是偏离——「commit 之后」针对的是描述数据库状态的事件）。

`subscription.download_started`：

```
data:
  media:
    item_id / tmdb_id / imdb_id / title / original_title / year
    type: "movie" | "series"     # 订阅是条目级，无 episode 层
  units: [[season, episode], …]  # 本次投递覆盖的单元；电影为 []（哨兵不外泄）
  torrent: { site_id, title, spec }   # spec 为人读规格摘要
```

`subscription.fulfilled`：同上去掉 `torrent`。

两个事件 `jellyfin_type=None`——没有 Jellyfin 对应物，仅自有协议 endpoint
可订阅（设置页自动禁用勾选）。

## 2. 自有协议（`format: movieclaw`）

### 2.1 报文

`POST <url>`，`Content-Type: application/json; charset=utf-8`，UTF-8 snake_case：

```json
{
  "spec_version": "1",
  "event_id": "01JG8YQ4TZKX5H3M9W2E7R6VBN",
  "event": "playback.completed",
  "occurred_at": "2026-08-04T20:30:00+08:00",
  "batch_id": null,
  "server": { "id": "a1b2c3", "name": "MovieClaw", "version": "1.4.0" },
  "data": {
    "media": {
      "type": "episode",
      "tmdb_id": 1399,
      "imdb_id": null,
      "title": "权力的游戏",
      "year": 2011,
      "season_number": 2,
      "episode_number": 4
    },
    "playback": {
      "position_ms": 3120000,
      "duration_ms": 3300000,
      "played": true,
      "play_count": 1
    },
    "client": { "name": "Infuse", "device_name": "Apple TV" }
  }
}
```

### 2.2 字段稳定性承诺

- **信封字段**（所有事件、永远出现，取不到值时为 `null`）：`spec_version`、
  `event_id`、`event`、`occurred_at`、`batch_id`、`server.id`。
- **播放/收藏域稳定字段**（`data` 内永远出现）：`media.type`、`media.tmdb_id`、
  `media.season_number`、`media.episode_number`；播放事件另有
  `playback.position_ms`、`playback.played`；收藏事件另有 `favorite`——覆盖
  issue 要求的全部稳定字段。
- **便利字段**（尽力提供，内容可能随元数据刷新变化）：`media.item_id`
  （MovieClaw 内部条目 ID，可用于回调 Jellyfin 兼容 API）、`media.title`、
  `media.year`、`media.imdb_id`、`media.episode_title`（单集标题，非剧集单元
  为 null）、`playback.duration_ms`、`playback.play_count`。
- **可空对象**：`client` 整体可为 `null`（非播放器入口）。
- 演进只加字段，消费端必须忽略未知字段；新领域事件只新增 `data` 结构承诺，
  不改信封。

### 2.3 HTTP 头与签名

```
X-MovieClaw-Event: playback.completed
X-MovieClaw-Delivery: <event_id>          ← 重试不变，幂等去重键
X-MovieClaw-Signature: sha256=<hex(HMAC-SHA256(secret, raw_body))>
User-Agent: MovieClaw/<version>
```

secret 由服务端在创建 endpoint 时生成（`mcwh_` 前缀 + 32 字节随机 hex），签名对
**原始请求体字节**计算（GitHub 惯例）。

### 2.4 投递语义

- fire-and-forget，超时 10s，失败重试 2 次（间隔 5s / 30s），共 3 次尝试；
- 语义为 at-least-once（有重试）但**不承诺必达**（无持久队列，进程重启丢弃在途任务）；
- 不保证顺序，消费端按 `occurred_at` + `event_id`（ULID 时间有序）排序；
- 出站熔断关闭（见有意偏离 ⑤）：endpoint 之间互不影响，失败全部进投递记录。

## 3. Jellyfin 兼容格式（`format: jellyfin`，P2）

### 3.1 兼容等式

Jellyfin Webhook 插件没有固定报文——它让用户粘贴 Handlebars 模板，用固定的
**变量字典**渲染后 POST。因此免适配的兼容等式是：

> MovieClaw 提供同名变量字典 + 渲染用户粘贴的同一段模板。

下游文档里写「在 Jellyfin webhook 插件里粘贴这段模板」，用户把同一段粘进
MovieClaw 即可。

### 3.2 NotificationType 映射与去重

映射关系登记在事件目录中；**没有映射的事件对 jellyfin 格式 endpoint 不可订阅**
（设置页直接禁用勾选），未来 `subscription.*` 等无 Jellyfin 对应物的域天然只走
自有格式。

| MovieClaw 事件 | Jellyfin NotificationType | 备注 |
| --- | --- | --- |
| `playback.started` | `PlaybackStart` | |
| `playback.stopped` | `PlaybackStop`（`PlayedToCompletion=false`） | |
| `playback.completed` | `PlaybackStop`（`PlayedToCompletion=true`） | Jellyfin 无独立 completed |
| `playback.marked_played` / `marked_unplayed` | `UserDataSaved`（`Played`/`PlayCount` 区分） | |
| `item.favorited` / `unfavorited` | `UserDataSaved`（`Favorite` 变量区分） | |
| `playback.progress` | `PlaybackProgress` | |

**去重规则**：同一次上报同时产生 `stopped` + `completed` 时，自有格式发两条，
Jellyfin 格式**只发一条** `PlaybackStop`（`PlayedToCompletion=true`）——`completed`
吸收 `stopped`。该逻辑放在 formatter 层，佐证内部事件与外发报文必须分层。

### 3.3 变量子集

按插件官方文档实现以下子集（缺失项渲染为空字符串，文档中注明对齐的插件版本）：

- Server：`ServerId` / `ServerName` / `ServerUrl`（复用 `jellyfin.compat` 设置的
  `server_id` / `server_name` / `published_server_url`）、`ServerVersion`、
  `NotificationType`
- Item：`ItemId`（**与 Jellyfin 兼容 API 对外的条目 ID 同源**，下游可回调
  MovieClaw 的 Jellyfin API 查详情拉海报）、`ItemType`、`Name`、`Year`、
  `RunTime` / `RunTimeTicks`、`Provider_tmdb` / `Provider_imdb`、
  `Timestamp` / `UtcTimestamp`
- Episode：`SeriesName`、`SeasonNumber` / `SeasonNumber00`、
  `EpisodeNumber` / `EpisodeNumber00`、`SeriesId`
- Playback：`PlaybackPosition` / `PlaybackPositionTicks`、`PlayedToCompletion`、
  `Played`、`PlayCount`、`Favorite`
- Device：`DeviceName` / `DeviceId` / `ClientName`
- User：`UserId` / `NotificationUsername`（单管理员形态，取兼容层虚拟用户）

P1 不提供媒体流类变量（`Audio_0_*` / `Video_0_*` 等）。

### 3.4 最小 Handlebars 渲染器

Python 无维护良好的 Handlebars 库（pybars3 已停滞），自实现最小子集
（约 150 行纯函数，落在 `movieclaw_api/services/webhook/handlebars.py`）：
`{{Var}}` 插值 + 官方 5 个助手 `if_equals` / `if_exist` / `link_to` /
`url_encode` / `json_encode` + `{{else}}`。这覆盖了下游文档模板的绝对主流写法；
冷门语法按需求迭代。

## 4. 配置与设置页（Stripe 式管理）

### 4.1 设置 Schema

`src/movieclaw_api/settings/webhook.py`，
`@register_setting(namespace="webhook", title="事件 Webhook")`：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `enabled` | bool | 总开关，默认 False |
| `endpoints` | list | endpoint 列表，见下 |

endpoint 结构：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | str | 服务端生成（ULID） |
| `name` | str | 显示名，如 "Yamtrack" |
| `url` | str | 目标地址 |
| `format` | `"movieclaw"` \| `"jellyfin"` | 外发格式 |
| `enabled` | bool | 单端点开关 |
| `events` | list[str] | 订阅的事件（目录中的精确事件名，多选） |
| `secret` | str | 仅 movieclaw 格式；服务端生成，加密落库 |
| `template` | str \| None | 仅 jellyfin 格式；用户粘贴的 Handlebars 模板 |
| `headers` | dict[str, str] | 自定义请求头（jellyfin 格式下游鉴权用） |
| `egress_scope` | `"lan"` \| `"wan"` | 出口，默认 lan |

实现注意：`register_setting` 的 `secret_fields` 只加密**顶层**字段，endpoint 的
secret 嵌套在列表里，需在 Schema 序列化钩子里用同一加密助手逐项加解密，导出/
读取接口一律打码（`mcwh_****`）。

### 4.2 管理 API

路由文件 `src/movieclaw_api/api/routes/webhook.py`，
`APIRouter(prefix="/webhook", tags=["webhook"])`，统一 `require_login` +
`ApiResponse` 规范：

| 接口 | 方法 | 说明 |
| --- | --- | --- |
| `/webhook` | GET | 读配置（secret 打码）+ 事件目录（分组、名称、jellyfin 可订阅性，供前端渲染多选） |
| `/webhook` | PUT | 全量更新（新建 endpoint 时响应**一次性**返回 secret 明文，Stripe 惯例） |
| `/webhook/endpoints/{id}/rotate-secret` | POST | 轮换 secret，一次性返回新明文 |
| `/webhook/endpoints/{id}/test` | POST | 发送 `webhook.test` 示例事件，同步返回状态码/耗时/错误 |
| `/webhook/endpoints/{id}/deliveries` | GET | 最近投递记录（内存环形缓冲，每端点 50 条） |

事件目录随 GET 下发而非前端硬编码，未来新域上线后前端零改动。投递记录字段：
时间、事件、HTTP 状态码、耗时 ms、尝试次数、错误摘要。P1 存内存（重启丢失，
纯诊断用途），P2 视需求落表支持重放。

### 4.3 设置页 UI

- `apps/web/lib/mock-data.ts` 的「系统」组新增分区
  `{ id: "webhook", label: "Webhook", description: "向外部服务推送播放、收藏等事件" }`
  （排在「网络与代理」之前）；
- 新组件 `apps/web/components/webhook-section.tsx`，参照
  `im-push-section.tsx` / `downloader-config-section.tsx` 的既有形态：
  - endpoint 列表：名称、URL、格式徽标、启用开关、最近一次投递状态（绿/红点）；
  - 新建/编辑抽屉：URL、格式选择（选 jellyfin 时显示模板输入框 + 变量说明、
    自定义 header，且事件多选中禁用无映射事件；选 movieclaw 时显示 secret
    展示/复制/轮换）、事件多选（按目录分组渲染，组级全选）、出口选择；
  - 新建成功弹出 secret 明文并提示「仅显示一次」；
  - 每行「发送测试」按钮，展开可见最近投递记录列表。

## 5. 投递器

`src/movieclaw_api/services/webhook/dispatcher.py`：

- 对外唯一入口 `emit_events(events: list[OutboundEvent]) -> None`：**领域无关**，
  任何产生点（协议层 handler、订阅服务等）commit 后调用。同步签名，内部
  `create_task`；任务加入模块级强引用集合 `_tasks` 并
  `add_done_callback(discard)`（事件循环只持弱引用，不留强引用推送会无声丢失——
  仓内既有共识）；无事件循环时优雅跳过（供同步测试路径）。
- 任务内：读 `SettingStore` 配置 → 过滤 enabled endpoint 与事件订阅 → 按 format
  调 formatter → `httpx.AsyncClient(timeout=10, transport=egress_transport("webhook", scope))`
  发送 → 失败按 §2.4 重试 → 写环形缓冲。任何异常 `logger.exception` 吞掉，
  日志用中文写明「Webhook 推送失败：<endpoint 名> <原因>」。
- formatter 接口：`format(event) -> (body: bytes, headers: dict)`，P1 实现
  `MovieClawFormatter`，P2 实现 `JellyfinFormatter`。
- 事件目录 `src/movieclaw_api/services/webhook/catalog.py`：事件名 → 分组 /
  Jellyfin 映射 / 是否默认订阅，目录同时供管理 API 下发给前端。

安全边界：URL 由管理员配置（单管理员产品形态，SSRF 风险等级低），但仍然：
不跟随跨协议/跨主机重定向、响应体最多读 4KB（只为日志摘要）、超时硬上限。

## 6. 分期实施与验收

### P1（自有协议闭环：播放 + 收藏域）

| # | 步骤 | 验证 |
| --- | --- | --- |
| 1 | `movieclaw_events` 叶子包：`OutboundEvent` + ULID 生成 | 新建 `tests/events/`，单测覆盖 ULID 单调性与信封构造 |
| 2 | `movieclaw_playback/events.py`：播放/收藏 builder | 新建 `tests/playback/`，单测覆盖电影/剧集/级联/收藏层级翻译（哨兵不外泄） |
| 3 | 领域函数返回值补 `newly_played` | 既有 `tests/jellyfin/test_protocol_units.py` 不回归 + 新增翻转判定单测 |
| 4 | `settings/webhook.py` Schema + 嵌套 secret 加密 | 单测：落库密文、读取解密、导出打码 |
| 5 | 事件目录 + dispatcher + `MovieClawFormatter` + 签名 + 重试 + 环形缓冲；`BUILTIN_EGRESS_SERVICES` 登记 `webhook` | `httpx.MockTransport` 单测：签名可验、重试次数、熔断路径、异常不外抛 |
| 6 | `playstate.py` 8 处埋点（handler 注入 `RequestIdentity`），commit 后 emit | `tests/jellyfin/test_http_flow.py` 扩展：完整播放/收藏流断言各事件的产生与去重 |
| 7 | 管理 API 5 个接口 | 路由测试：打码、一次性明文、测试发送、目录下发 |
| 8 | 前端 `webhook-section.tsx` + 分区注册 | `pnpm web:lint` + `pnpm web:typecheck` |
| 9 | 用户文档（含消费端对接示例：HA、通用 HMAC 校验代码片段） | — |

合并 gate：`pytest`、`ruff check .`、`pnpm web:lint`、`pnpm web:typecheck` 全绿；
手工验收：Infuse 真实播放 + 收藏 → 本地 http 接收端收到
started/stopped/completed/favorited，签名校验通过。

### P2（Jellyfin 兼容 + 增强）

1. 最小 Handlebars 渲染器（验收用例：Yamtrack 与 HA 社区文档里的真实模板）；
2. `JellyfinFormatter`：变量字典、NotificationType 映射、stopped/completed 合并；
3. `playback.progress` 事件 + 按单元 30s 节流；
4. 视反馈：投递日志落表 + 失败重放（届时才需要 Alembic 迁移与 APScheduler 重试任务）。

### P3（预留域接入示范）

订阅域（`subscription.*`）作为第一个非播放域接入，验证「builder + 目录一行 +
emit 一行」的扩展承诺；产生点与通知事件调用相邻。

## 7. 风险与对策

| 风险 | 对策 |
| --- | --- |
| 级联标记整剧产生几十条事件冲击下游 | 逐条发但共享 `batch_id` 供下游聚合；P1 不限流，观察真实反馈 |
| Jellyfin 插件变量集漂移 | 文档声明对齐的插件版本与支持子集，不承诺全集 |
| 下游模板用到未实现的 Handlebars 语法 | 渲染失败计入投递记录并中文报错，按需求迭代助手 |
| 进程重启丢在途投递与记录 | 契约明示"不承诺必达"；P2 落表 |
| secret 嵌套加密遗漏导致明文落库 | 单测强制断言 `app_setting.value_json` 中不出现明文 secret |
| 事件目录膨胀后前端多选失控 | 目录带分组随 GET 下发，前端按组渲染 + 组级全选 |

## 8. 开放问题

1. IM 推送（`channel_push`）与 webhook 的事件源是否统一为同一份目录——本期两者
   独立（消费形态不同），若后续 IM 推送也要逐事件开关化，可评估共享事件目录。
2. ~~`webhook.test` 事件对 jellyfin 格式端点如何呈现~~——已定稿（P2）：用示例
   变量渲染用户模板，`NotificationType` 按最常见的 `PlaybackStop` 分支。
3. `progress` 节流间隔是否需要可配置——当前固定 30 秒，按反馈再定。
4. ~~预留域的具体事件名与 `data` 结构~~——订阅域已在 §1.5 定稿（P3）；
   library/system 域各自接入时继续在本文档追加。
5. 投递日志是否落表支持失败重放——仍视用户反馈决定（届时才需要 Alembic 迁移）。
6. `SettingStore.export_all` 对 webhook 域的嵌套 secret 打码/明文导出均不生效
   （打码只遍历顶层 `secret_fields`，而序列化钩子已把嵌套 secret 加密）——
   当前 `export_all` 无调用方，属已知限制；将来接入"配置备份导出"功能时需
   一并处理（密文绑定本机密钥，跨机恢复会失效）。

## 9. 实现状态与落点（2026-08-05，P1/P2/P3 全部完成）

| 设计章节 | 实现落点 |
| --- | --- |
| §1.3 统一信封 | `src/movieclaw_events/__init__.py`（OutboundEvent + 自实现 ULID） |
| §1.4 播放/收藏 builder | `src/movieclaw_playback/events.py`；`state.py` 的 `record_playback_progress` 返回值扩展为 `(row, newly_played)`、`record_playback_start` 返回状态行 |
| §1.2 埋点 | `src/movieclaw_jellyfin/routes/playstate.py`（8 处，handler 注入 `RequestIdentity`） |
| §4.1 配置域 | `src/movieclaw_api/settings/webhook.py`（namespace `webhook`，endpoint secret 由模型校验/序列化钩子逐项加解密） |
| §1.1 事件目录 / §5 投递器 | `src/movieclaw_api/services/webhook/`（catalog / formatter / dispatcher / deliveries） |
| §4.2 管理 API | `src/movieclaw_api/api/routes/webhook.py` + `services/webhook_config.py` |
| §4.3 设置页 | `apps/web/components/webhook-section.tsx` + `lib/api/webhook.ts`（P1 编辑卡中 jellyfin 格式禁用，注明「即将支持」） |
| 出站服务标签 | `settings/network.py` `BUILTIN_EGRESS_SERVICES` 新增 `webhook` |
| §3.4 Handlebars 渲染器（P2） | `services/webhook/handlebars.py`（变量 + 5 个官方助手 + `{{else}}` + 空白控制；未知语法中文报错进投递记录） |
| §3.2/§3.3 Jellyfin 格式器（P2） | `services/webhook/jellyfin_formatter.py`（变量字典、NotificationType 映射、completed 吸收 stopped、ticks 边界换算、ItemId 与兼容 API 同源） |
| `playback.progress`（P2） | `routes/playstate.py`（每单元 30s 节流，completed 优先抑制 progress）；目录 `default_on=False`，新建 endpoint 默认不勾选 |
| §1.5 订阅域（P3） | `services/subscription/events.py` + `dispatch.py` / `wanted_fulfillment.py` 各一行 emit + 目录两行登记——扩展承诺兑现，投递链路零改动 |
| 测试 | `tests/events/`、`tests/playback/`、`tests/jellyfin/test_webhook_emission.py`、`tests/api/test_webhook_{dispatcher,api,handlebars,jellyfin_formatter}.py`、`tests/api/test_subscription_webhook_events.py` |

## 附录 A：消费端对接示例（自有协议）

**校验签名（Python）**——对收到的原始请求体字节重算 HMAC 并与
`X-MovieClaw-Signature` 比对：

```python
import hashlib, hmac

def verify(body: bytes, signature_header: str, secret: str) -> bool:
    expected = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature_header)
```

**Home Assistant**——`configuration.yaml` 无需任何配置，直接用 webhook 触发器：

```yaml
automation:
  - alias: "MovieClaw 看完通知"
    trigger:
      - platform: webhook
        webhook_id: movieclaw            # endpoint URL 填 http://<HA>:8123/api/webhook/movieclaw
        allowed_methods: [POST]
        local_only: true
    condition:
      - condition: template
        value_template: "{{ trigger.json.event == 'playback.completed' }}"
    action:
      - service: notify.mobile_app
        data:
          message: >
            看完了 {{ trigger.json.data.media.title }}
            {% if trigger.json.data.media.type == 'episode' %}
            S{{ trigger.json.data.media.season_number }}E{{ trigger.json.data.media.episode_number }}
            {% endif %}
```

消费端务必按 `X-MovieClaw-Delivery`（= `event_id`）幂等去重：投递重试会带来
重复请求，且事件到达顺序不保证。

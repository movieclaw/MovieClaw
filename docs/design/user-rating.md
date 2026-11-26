# 个人评分（User Rating）

关联上游 issue：[movieclaw/MovieClaw#1292](https://github.com/movieclaw/MovieClaw/issues/1292)。

## 1. 背景与目标

MovieClaw 此前只有外部元数据评分（TMDB / NFO 的 `vote_average`），缺少「当前成员自己给这部作品打几分」的个人维度表达；收藏只是二值开关，无法区分喜欢程度。

本设计为每个成员提供独立的个人评分能力，与 Plex、Jellyfin / Emby、Trakt 保持刻度零换算，后端基础先行落地（PR 1），不阻塞前端、墙面筛选排序与外部同步的后续迭代。

## 2. 刻度与语义

| 维度 | 约定 | 说明 |
|---|---|---|
| 展示刻度 | 5 星、支持半星 | 0.5 ~ 5.0 星，共 10 档 |
| 存储值 | `1..10` 整数；`NULL` = 未评分 | `1` = 0.5 星，`2` = 1 星，…，`10` = 5 星；与 Plex (`userRating`)、Jellyfin (`UserItemData.Rating`)、Trakt (`rating`) 零换算 |
| 成员隔离 | 按 `member_id` 隔离（`0` = 超管） | 每个成员各自评分，互不可见；详情页只返回当前成员自己的评分，不展示他人评分或平均分 |
| 取消已看 | 不清除个人评分 | `mark_unplayed` 仅重置 `played / position_ms / play_count / last_played_at`，与收藏一致 |
| 评分时间 | 单独记录 `rated_at` | 与 `favorited_at` 同理：`updated_at` 会被播放进度、轨记忆等写入改写；改分或首次评分时刷新，清除评分时置 `NULL` |

## 3. 数据模型与迁移

在 `playback_state` 表新增两列（做法与 #1246 的 `continue_dismissed` 一致）：

```sql
user_rating  SMALLINT NULL  -- 1..10 整数；NULL = 未评分
rated_at     DATETIME NULL  -- 最近一次评分的服务器时间（naive UTC）；清除时置 NULL
```

- **哨兵单元**：完全复用 `services/playback/marks.py` 中收藏的落点约定（`favorite_unit()` / `item_favorite_unit()`）：
  - 电影：`(media_item_id, 0, 0)`
  - 整部剧：`(media_item_id, -1, -1)`
  - 未来扩展（第一期不开放）：整季 `(media_item_id, season, -1)`、单集 `(media_item_id, season, episode)`，无需再次变更表结构。
- **自然继承的能力**：
  - `member_id` 唯一约束与成员级隔离；
  - 删除成员时随 `playback_state` 一并清理（`@register_member_scoped`）；
  - 重新识别 / 改锚（`services/library/reanchor.py`）时保留已有评分；
  - 后续同步接口（`playback.sync.*`）与 Jellyfin 兼容层共用同一张表。
- **Alembic 迁移**：
  - 版本：`c4e8a1d7f293`（`20261126_1000_c4e8a1d7f293_playback_state_user_rating.py`）
  - 接在当前线性 head `be3b7498a20c` 之后（issue #1292 撰写时 head 为 `a7d2e9c41b58`，上游随后合并了 `be3b7498a20c_downloader_verification_lease`）。
  - 使用 `op.batch_alter_table("playback_state")` 纯新增两列可空列、无默认值，存量行全部为 `NULL`；SQLite 与 PostgreSQL 均可执行，旧版本回退不受影响。

## 4. 接口与服务层

### 4.1 标记接口：`POST /api/v1/playback/marks` 与 `GET /api/v1/playback/marks`

- **请求体 `PlaybackMarksRequest`** 新增字段：
  - `rating: int | None = None`
    - 省略 / `null`：保持原评分不变；
    - `0`：清除评分（库内置 `user_rating = NULL`、`rated_at = NULL`）；
    - `1..10`：设置或修改评分；
    - 越界整数（`< 0` 或 `> 10`）：返回 `400 BAD_REQUEST`（`errors.playback.ratingInvalid`）；
    - 第一期传入 `season_number` 或 `episode_number`：返回 `400 BAD_REQUEST`（`errors.playback.ratingItemOnly`）。
  - `played`、`favorite`、`rating` 三者至少提供其一，否则返回 `400`（`errors.playback.markRequired`）。
- **响应体 `PlaybackMarksView`** 新增字段：
  - `user_rating: int | None = None`（`1..10` 或 `null`）。
- **条目可见性**：沿用 `_mark_target` 的 `assert_item_visible`，对不可见库或不存在的条目返回 `404`。

### 4.2 条目详情接口：`GET /api/v1/libraries/{library_id}/items/{media_item_id}`

- **`LibraryItemDetailView`** 新增可选字段：
  - `user_rating: int | None = None`
- 实现直接复用 `get_library_item` 已批量取出的 `watch_states`，按 `item_favorite_unit(item.id, item.kind)` 查表，不增加额外数据库查询。
- 公开分享投影（`SharedItemView`）不包含 `user_rating`，避免泄露成员个人偏好。

### 4.3 服务层

- 领域存取：`movieclaw_playback.state.set_rating(session, unit, *, member_id, rating)`
  - 校验 `rating` 为 `None` 或 `1..10` 整数；
  - 仅改写 `user_rating`、`rated_at`、`updated_at`，不触碰 `position_ms`、`played`、`play_count`、`last_played_at`、`is_favorite` 等字段；
  - 返回 `(row, previous_rating)` 供事件载荷构造。
- 应用服务：`movieclaw_api.services.playback.marks.set_rating(session, target, *, member_id, client, rating)`
  - 形状与 `marks.set_favorite()` 一致：按 `favorite_unit()` 解析落点 → 落库 → 发出领域事件 → `session.commit()`。

### 4.4 墙条目批量字段与 `badges=my_rating`（PR 2）

- **`LibraryItemView`** 新增可空字段：`user_rating: int | None = None`。覆盖全部墙列表接口：
  - 单库海报墙：`GET /api/v1/libraries/{library_id}/items`
  - 跨库类型墙：`GET /api/v1/libraries/kinds/{kind}/items`
  - 我的收藏：`GET /api/v1/playback/favorites`
  - 合集成员：`GET /api/v1/collections/{collection_id}/items`
  - 相似推荐：`GET /api/v1/libraries/{library_id}/items/{media_item_id}/similar`
- **按需计算与查询数上界**：
  - `WALL_BADGE_GROUPS` 新增 `"my_rating"`，不传 `badges=my_rating` 时不跑对应 SQL、`user_rating` 为 `null`（与既有五个角标字段 `dynamic_range` / `has_atmos` / `has_chinese_subtitle` / `progress_percent` / `unplayed_count` 同一约定）。
  - 单独请求 `badges=my_rating` 时，整页仅追加 **1 条** `playback_state` 批量查询（按 `member_id` + `media_item_id IN (...)` + `user_rating IS NOT NULL` 取回后按哨兵单元过滤）。
  - 与 `progress` / `unwatched` 同时请求时，合并为 **同 1 条** `playback_state` 批量查询（`_viewer_states_many`），全开相对全关的额外查询数上界维持不变（固定 **+4 条**：中文字幕 2 + Atmos 1 + 合并观看/评分状态 1），**完全 O(1)、不随页面条目数增长**。

### 4.5 墙排序与筛选（PR 2）

- **排序 `WallSort` 新增 `my_rating`**（单库墙、kind 墙、合集、收藏均可用）：
  - 自然方向（`order` 省略或 `desc`）：`user_rating` 倒序，未评分沉底，同分以 `media_item_id DESC` 收尾；
  - 反向（`order=asc`）：`user_rating` 升序，未评分仍沉底，同分以 `media_item_id ASC` 收尾；
  - SQL 实现：按 `(member_id, media_item_id, 哨兵单元)` 外连接 `playback_state`（唯一键保证每条目至多 1 行，无行膨胀），通过 `func.max(PlaybackState.user_rating)` 满足 PostgreSQL 严格 `GROUP BY`，配合显式 `NULLS LAST`（`sqlalchemy.nullslast`）消除 SQLite 与 PostgreSQL 默认 `NULL` 排序方向差异，保证跨页不重不漏。
- **筛选参数**：
  - `w=rated`：筛选当前成员打过分（哨兵单元 `user_rating IS NOT NULL`）的作品；同步纳入 `relax` 放宽建议（`facets.watch` 保持既有 5 档不变，与 `w=seen` 同口径）。
  - `my_rating_gte=<n>`：筛选当前成员个人评分 `>= n` 的作品（`1..10` 整数）；越界或非合法范围在路由层以 `BadRequestException`（`errors.playback.ratingFilterInvalid`）返回 **400**（与 PR 1 路由层校验口径一致）。

### 4.6 首页数据源：`GET /api/v1/playback/rated`（PR 2）

- 形状对齐 `GET /api/v1/playback/favorites`：
  - 鉴权：`require_login`，已登记到成员权限白名单（`tests/api/test_member_auth.py`），范围收紧到当前账号可见库内且仍有在位文件的作品。
  - CLI 契约：`operation_id="playback.rated"`、`openapi_extra={"x-cli-hidden": True}`（与 `/playback/favorites` 相同，不进入 CLI 命令树）。
  - 参数：`limit`（1–200，默认 20）、`offset`（≥ 0，默认 0）、`min_rating`（1–10 整数，默认 `8` 即 4 星及以上，越界返回 **400**）、`sort`（默认 `my_rating`，另支持 `rated_at` 及单库墙各档位）、`order`（`asc` / `desc`）、`badges`（复用 `wall_badges`）。
  - 默认顺序：`user_rating DESC` → `rated_at DESC NULLS LAST` → `media_item_id DESC`。
  - 响应 `RatedItemsView = {items: list[RatedItemView], total: int}`：`RatedItemView` 继承 `LibraryItemView`，必带落点库 `library_id` 与 `rated_at`；由于列表查询本身已取回 `PlaybackState` 行，`user_rating` 直接随卡片回填（零额外查询，同时向 `_aggregate_wall_views` 剔除 `my_rating` 避免重复查表），查询数同样保持每页固定上界。

### 4.7 同步接口扩展：`playback.sync.catalog` 与 `playback.sync.state`（PR 4）

- **`GET /api/v1/playback/sync/catalog`**：
  - 叶子单元（`SyncUnit`，电影 / 单集 / 其他视频）新增 `user_rating: int | None = None` 与 `rated_at: datetime | None = None`；
  - 整剧 `(-1, -1)` 与整季 `(s, -1)` 哨兵行导出模型 `SyncFavorite` / `SyncSeasonFavorite`（挂载在 `media.favorite` 与 `media.season_favorites`）同步带上 `user_rating` 与 `rated_at`，复用同一套 `updated_at` 做 compare-and-set 写回，不增加额外数据库查询。
- **`POST /api/v1/playback/sync/state`**：
  - `SyncChangeIn` 新增可选字段 `user_rating: int | None = Field(default=None, ge=0, le=10)`（拒绝 `bool` 与越界值，返回 422 且不落库）；
  - 语义与 `/playback/marks` 对齐：省略 / `null` = 保持不变（旧格式同步包不带该字段时不改动已有评分，不误当 `0`）；`0` = 清除 `user_rating` 与 `rated_at`；`1..10` = 设置或修改并刷新 `rated_at`；
  - 幂等防回环：与现值相同（含未评分时传 `0`）返回 `unchanged` 且不推进 `updated_at`；不触碰播放进度，不发出 `library.item.(un)rated` 事件；支持电影 `(0,0)` 与整剧 `(-1,-1)`（及季/集哨兵行）。

### 4.8 Jellyfin 兼容层（PR 5）

- **`UserData` 输出**（`movieclaw_jellyfin.catalog._leaf_user_data` / `_folder_user_data`）：
  - 当当前成员对该条目（电影 `(0,0)`、整剧 `(-1,-1)`、整季 `(s,-1)`、单集 `(s,e)`）存有 `user_rating` 时，输出 `Rating`（原值 `1..10`）与 `Likes`（`float(Rating) >= 6.5` → `true`，否则 `false`；对应 1–10 整数刻度为 `1..6 → false`、`7..10 → true`）；
  - 未评分时遵循本层 `WhenWritingNull` 约定省略 `Rating` / `Likes`（客户端读为 `null`），不破坏既有 SDK 契约测试。
- **评分写接口**（`movieclaw_jellyfin.routes.playstate`，挂在根路径与 `/emby` 别名下，同时支持现代与旧版路径）：
  - `POST /UserItems/{item_id}/Rating` 与 `POST /Users/{user_id}/Items/{item_id}/Rating`：`likes=true` 写 `10`、`likes=false` 写 `1`、省略 `likes` 清除评分、非法值返回 400（`router.py` 的 `_KNOWN_QUERY_KEYS` 登记 `"likes"` 以兼容 PascalCase `?Likes=true`）；
  - `DELETE /UserItems/{item_id}/Rating` 与 `DELETE /Users/{user_id}/Items/{item_id}/Rating`：清除评分；
  - 鉴权与可见性：通过 `require_device`（未登录返回 401）+ `viewer_scope` / `load_bundles` 校验库可见性与分级约束（无权访问返回 404，不落库）；
  - 统一复用 `marks.set_rating()`：落库不触碰播放进度，返回最新 `UserItemDataDto`，并自动发出 `library.item.rated` / `library.item.unrated` 事件（通过 Jellyfin Webhook 格式化器映射为 `UserDataSaved`）。

## 5. 事件与扩展

在 `movieclaw_sdk.events.library` 定义载荷 `ItemRating` 与两个系统事件（均标记 `sensitive=True`）：

- `library.item.rated`：设置或修改个人评分时发出（`rating` 为 `1..10`，`previous_rating` 为旧值或 `None`）
- `library.item.unrated`：清除个人评分时发出（`rating` 为 `None`，`previous_rating` 为旧值或 `None`）

载荷字段：`member_id`、`media`（`MediaRef`）、`level`（`movie` / `series` / `season` / `episode`）、`rating`、`previous_rating`、`season`、`episode`、`client`（`ClientRef | None`）。

同步登记位置：

- 契约表面快照：`src/movieclaw_sdk/surface.json`
- Webhook 目录与 Jellyfin 映射：`src/movieclaw_api/services/webhook/catalog.py`（均映射为 Jellyfin `UserDataSaved`）
- 插件扩展点目录：`src/movieclaw_agent/builtin-skills/movieclaw-plugin-dev/references/extension-points.md`
- 领域事件清单：`docs/design/domain-events.md`

## 6. 实现范围与分期落地

- **PR 1（后端基础）**：`playback_state` 新增 `user_rating` / `rated_at` 及 Alembic 迁移；`state.set_rating` / `marks.set_rating`、`POST/GET /playback/marks` 扩展、条目详情 `user_rating`；`library.item.rated` / `library.item.unrated` 事件及 `surface.json`、Webhook 映射、插件文档登记。
- **PR 2（后端列表）**：墙条目 `user_rating` 与 `badges=my_rating`（O(1) 查询数上界）、`WallSort=my_rating`（双库一致 `NULLS LAST` + 稳定分页）、`w=rated` 与 `my_rating_gte` 筛选、`GET /playback/rated` 首页数据源及 SQLite / PostgreSQL 测试覆盖。
- **PR 3（网页端）**：详情页 5 星半星控件、媒体库排序与筛选（含 facets 计数）、首页内置行 `rated`（「我的高分作品」，无数据时整行隐藏）、海报角标 `my_rating`（默认开且优先于 TMDB 评分，未评分外观不变）及中/英/德 i18n。
- **PR 4（同步接口）**：`playback.sync.catalog` 导出 `user_rating` / `rated_at`（含整剧/整季哨兵行），`playback.sync.state` 支持写回与清除，完全向后兼容旧版无评分字段同步包。
- **PR 5（Jellyfin 兼容层）**：`UserData` 输出 `Rating` / `Likes`（`>= 6.5`），新增 `POST/DELETE /UserItems/{item_id}/Rating`（含 `/Users/{user_id}/Items/{item_id}/Rating` 与 `/emby` 别名），经 `marks.set_rating` 打通 `UserDataSaved` Webhook。
- **仍明确不做**：季/单集网页评分界面、他人评分或平均分、文字短评、写回 NFO `<userrating>`、全局智能合集条件、内置 Trakt/豆瓣同步。

## 7. 待维护者确认的 5 个问题与本次默认方案

对应 issue #1292「想请维护者确认的点」：

| # | 待确认问题 | 本次（PR 1）采用的默认方案 | 理由与可逆性 |
|---|---|---|---|
| 1 | 存储放在 `playback_state` 加列，还是单独建表？ | **在 `playback_state` 加 `user_rating`、`rated_at` 两列** | 复用已有的 `member_id` 成员隔离、删除清理、哨兵单元、reanchor 迁移与单表批量读取；收藏已经落在这张表上，避免重复维护第二份同类结构。 |
| 2 | 海报角标的共存方式及 `my_rating` 默认开是否可接受？ | **暂不在 PR 1 实现**（属于 PR 2 / PR 3）；默认建议：`my_rating` 默认开，打过分的显示个人评分、未打分的按原 `rating` 与 `min_rating` 显示 TMDB 分，`min_rating` 只过滤 TMDB 分 | 升级后零存量评分不改变既有墙面，后续 PR 落地前维护者仍可拍板调整。 |
| 3 | 首页「我的高分作品」的门槛（固定 ≥ 4 星还是可配置）与默认位置？ | **暂不在 PR 1 实现**（属于 PR 2 / PR 3）；默认建议：门槛 `min_rating=8`（4 星及以上），默认排在「我的收藏」之后，无满足条件条目时不显示 | 不影响 PR 1 的数据模型与基础接口，可在 PR 2 / PR 3 按维护者决定收口。 |
| 4 | 接口用 `rating=0` 表示清除是否可以，还是更希望单独的 `DELETE` 路由？ | **沿用 `POST /playback/marks` 并以 `rating=0` 表示清除**（不传 = 不改，1–10 = 设置） | 与 `played` / `favorite` 共用同一条幂等标记端点，一次请求可组合提交且直接返回最新 `PlaybackMarksView`；服务层 `marks.set_rating` 使用 `None` 表示清除，若后续决定增加独立 `DELETE` 路由可直接复用服务层。 |
| 5 | 同步接口（PR 4）和 Jellyfin 兼容层（PR 5）要不要并进第一期？ | **不并入 PR 1**，保持独立 PR 拆分（PR 4 / PR 5） | 保持每个 PR 体积小、审阅聚焦；PR 1 已将表结构、哨兵单元与领域服务准备就绪，PR 4 / PR 5 可直接复用，无返工成本。 |

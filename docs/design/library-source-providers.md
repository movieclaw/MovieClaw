# 外部库源（插件登记的媒体库来源）

> 状态：**已实施**（2026-10-30，分支 `feat/external-library-sources-hooks`）。
> 定位见 `library-boundary.md` 的同一把尺子：外部媒体服务器（飞牛影视、Emby、
> Plex……）是对接外部软件、每人只用一两家、协议还随版本变 → **插件**。
> 主线只提供"把一种外部来源变成和内置库齐平的库"的机制。
> 关联文档：[library.md](library.md)、[library-other-kind.md](library-other-kind.md)、
> [downloader-adapters.md](downloader-adapters.md)（同一套注册表范式）、
> [jellyfin-compat.md](jellyfin-compat.md)。

## 1. 结论

- 库的**身份来源**（`Library.source`）从 `tmdb / local` 放开为"内置来源 ∪ 插件登记
  的来源"。插件往注册表 `library.source-providers`（`EXPERIMENTAL`）登记一个
  `LibrarySourceProvider`，就得到一种新来源。
- **能力档案由插件自带**：登记项里带 `(形态 → LibraryProfile)`。扫描 / 展示 / 播放 /
  Jellyfin 四条消费链全读能力位，`profile_for` 查不到内置档案表时回落注册表——
  主线消费代码**零改动**。
- **连接配置主线不解释**：库行 `source_config` 存插件定义的连接/映射信息，主线按登记项
  声明的 JSON Schema 校验后透传存储。
- 插件停用 / 卸载时库不消失：`profile_of` 回落**孤儿档案**（保守能力位、不对 Jellyfin
  暴露），库仍可浏览、可改名；插件回来即恢复全部能力。

## 2. 契约

模块：`src/movieclaw_api/services/library/source_providers.py`

| 名字 | 说明 |
|---|---|
| `LIBRARY_SOURCE_PROVIDERS` | 注册表键（`library.source-providers`，`EXPERIMENTAL`） |
| `LibrarySourceProvider.source` | 存进 `Library.source` 的来源值，全局唯一，不得撞内置的 `tmdb` / `local` |
| `.title` | 展示名（库卡片与建库向导用），如「飞牛影视」 |
| `.profiles` | 各形态的能力档案：`{"movie": LibraryProfile, "tv": LibraryProfile, ...}`；键集合即支持的形态。档案的 `source` 必须等于 `source`、`kind.value` 必须等于键（构造时校验） |
| `.config_schema` | `Library.source_config` 的 JSON Schema（空对象 = 无来源专属配置）。建库/编辑时按它校验；前端据此渲染连接表单 |
| `.icon` / `.help` | 前端标识与向导里的一句话说明 |
| `bind_source_providers(registry)` | 由 `core.registries` 插件绑定；无插件内核时注册表为空（命令行、单测照常工作） |
| `provider_of(source)` / `registered_providers()` / `known_source(source)` / `is_external_source(source)` | 查询帮助函数 |

### 2.1 登记示例

```python
from movieclaw_api.services.library.profile import IgnoreProfile, LibraryProfile
from movieclaw_api.services.library.source_providers import (
    LIBRARY_SOURCE_PROVIDERS,
    LibrarySourceProvider,
)
from movieclaw_media.models import MediaKind

PNOS_PROFILES = {
    MediaKind.MOVIE.value: LibraryProfile(
        kind=MediaKind.MOVIE, source="fnos",
        scraped=False,        # 元数据用飞牛自己的，不走 TMDB 识别链
        naming=False,         # 内容已由飞牛整理，主线不重命名
        ignore_rules=IgnoreProfile.PLAIN,
        write_nfo=False,      # 一期不往飞牛库回写
        subscribable=True,    # 能映射到 media_item 就可以当订阅目标
        jellyfin_type="Movie", jellyfin_collection="movies",
        default_aspect=2 / 3, media_exts=frozenset({".mkv", ".mp4"}),
        playable=True, jellyfin_exposed=True,
    ),
    # 剧集库同理，jellyfin_type="Series" / jellyfin_collection="tvshows"
}

PROVIDER = LibrarySourceProvider(
    source="fnos",
    title="飞牛影视",
    profiles=PNOS_PROFILES,
    config_schema={
        "type": "object",
        "required": ["base_url"],
        "properties": {
            "base_url": {"type": "string", "title": "服务器地址"},
            "library_id": {"type": "string", "title": "飞牛媒体库 ID"},
        },
    },
    icon="fnos",
    help="把飞牛影视里已整理好的媒体库映射成 movieclaw 的库",
)

# 插件 apply 里：ctx.registry(LIBRARY_SOURCE_PROVIDERS).add("fnos", PROVIDER, entry_id=...)
```

## 3. 数据与接口

- `library` 两列（迁移 `b8f21c4a90d3`）：
  - `source_config` JSON NULL —— 外部库源的连接/映射配置，主线不读内部键；
  - `last_source_sync_at` datetime NULL —— 插件同步完回写，管理页展示"最后同步"。
- `LibraryPayload.source` 接受"内置 ∪ 已登记来源"；未登记的值 400（清单见下）。
  `source_config` 只在来源已登记时接受，内置来源带它一律 400。
- 外部来源的库**允许空根路径**（内容在远程服务器上）；建库时无根就不排首轮扫描
  （扫描是本地目录的事，同步是插件的职责）。
- `GET /libraries/source-providers`（`library.list-source-providers`）：来源列表与
  各形态能力位、`config_schema`，建库向导的数据源。无插件时返回空数组。
- `LibraryView` 增加 `source_title` / `source_icon` / `source_configured` /
  `last_source_sync_at` 四个只读展示字段；前端按 `capabilities` 显隐功能，不按来源名分叉。

## 4. 四条消费链怎么自动获得新来源

| 链 | 机制 |
|---|---|
| 扫描 / 整理 | `profile_of(library)` → 插件档案的 `scraped` / `naming` / `ignore_rules` / `media_exts` |
| 展示（海报墙、详情、统计） | 同一档案：`default_aspect`、`playable`、`episodic` 决定卡片形态与区块 |
| 播放 / 进度 / 最近观看 | 条目落进 `library_file`（可映射 `media_item`）即免费获得，播放决策不看来源 |
| Jellyfin 兼容层 | `jellyfin_collection` / `jellyfin_type` / `jellyfin_exposed`；`list_libraries` 逐库按档案过滤暴露 |

**插件侧要自己做的**：远程 API 客户端（认证、列库、拉条目、取地址）、同步任务
（`JOB_HANDLERS` + 事件总线，把条目写进 `library_file` / `media_item`）、连接测试与
远程库列表的插件路由、同步完成后回写 `last_source_sync_at`。主线不提供这些。

## 5. 生命周期与降级

| 时点 | 行为 |
|---|---|
| 插件注册 | 来源出现在 `/libraries/source-providers`，可建库；`profile_for` 命中插件档案 |
| 插件停用 / 卸载 | `profile_of` 回落**孤儿档案**：不刮削、不命名、不可订阅、`jellyfin_exposed=False`。库仍可浏览与改名（空根仍放行），Jellyfin 客户端列表里消失而不是报错 |
| 停用期间改配置 | 400：`source_config` 只接受已登记来源的写入（写进一行主线不解释的配置等于埋雷）；先启用插件 |
| 插件重新启用 | `profile_for` 重新命中登记档案，能力位与 Jellyfin 暴露全部恢复；台账未动 |

孤儿档案的判定只看"来源是否属于外部"（`is_external_source`），不看注册表是否在线——
库"没有本地根"的事实不随插件可用性变化。

## 6. 明确不做

- 不内置任何具体来源（飞牛 / Emby / Plex 的名字都不进主线）。
- 不提供同步引擎、不规定远程 API 形态：不同服务器的条目结构差异太大，抽象成统一同步器
  只会长出一个勉强够用的最大公约数。
- 不做"外部库 → 本地库"的自动搬运；需要本地化时用既有的批量转移 / 监听导入。
- 不在插件停用时清空或迁移台账：配置与身份锚随库保留，插件回来继续用。

## 7. 飞牛（fnOS）插件的落地清单

1. 抓包确认认证与接口（登录态、媒体库列表、条目/季集、播放地址）。
2. 用 §2.1 的骨架登记 `fnos`（先只开 `movie`，验证完再开 `tv`）。
3. 插件自己的设置页存服务器地址与凭据（`SECRETS` 加密，与站点凭据同一套），
   `source_config` 只放"这个库对应飞牛哪个库"这类非敏感映射。
4. 同步任务：分页拉条目 → `MediaLibraryService.ensure_media_item`（能锚 TMDB 的就锚，
   锚不上的走本地临时身份）→ upsert `library_file`（文件寻址信息按飞牛给的路径/直链）→
   刷新库统计 → 回写 `last_source_sync_at`。
5. 播放：先复用既有取流（若飞牛库在本机目录树里），需要直链/转码时在插件侧提供地址；
   主线的播放决策只看 `library_file`。
6. 连接测试与远程库列表做成插件路由，供建库向导二次确认。

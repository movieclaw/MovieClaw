"""飞牛影视库源（本地受信插件，进程内运行）。

把 fnOS 影视登记成 MovieClaw 的一种媒体库来源（library.source-providers 注册表，
即外部库源机制）：库行 source="trim"，飞牛条目同步进主线的 media_item /
library_file 台账，浏览、详情、Jellyfin、订阅对账、观看进度全部走主线——
与内置库同一体验；插件停用时主线回落孤儿档案，库照常浏览（不消失、不报错）。

同步口径（docs/design/library-source-providers.md §7 的落地）：
- 飞牛条目的 trim_id 带 tt/tm 前缀，去前缀即 TMDB id → ensure_media_item 以
  TMDB 为锚建档，海报/简介/影人全由主线刮削，插件不碰元数据；
- 分集：剧 → /season/list → /episode/list 递归；电影直接 /item/list；
- 台账：upsert_by_path 写 library_file。file_path 写「本机视角」：
  - 飞牛库目录在本机挂载可见（source_config.local_root 映射）时写真实路径
    （local_bytes=True），播放走本地直出，飞牛挂了照样播；
  - 不可见时写虚拟路径（/trim/{server_guid}/{guid}.video，local_bytes=False），
    播放由插件的取流端点换直链。
- 删除对账：远端没了的台账行标 missing（不动磁盘——文件在飞牛那边）。

为什么是本地插件（runtime 默认 inline）：写台账要用主程序内部的仓储层
（MediaLibraryService / LibraryFileRepository），这些内部服务不对第三方
插件开放；本地受信插件与主程序同一进程、同一权限，是官方允许的形态
（docs/design/plugin-phase2a.md §6）。
"""

from __future__ import annotations

import asyncio
import os
from typing import Any

from fastapi import APIRouter, HTTPException, Response
from pydantic import BaseModel, Field, SecretStr
from sqlmodel import or_, select

from movieclaw_api.plugins.keys import (
    HOST_OPS,
    PLUGIN_DATA,
    PLUGIN_FILES,
    PLUGIN_ROUTES,
)
from movieclaw_api.services.library.profile import IgnoreProfile, LibraryProfile
from movieclaw_api.services.library.source_providers import (
    LIBRARY_SOURCE_PROVIDERS,
    LibrarySourceProvider,
)
from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    Library,
    LibraryFile,
    MediaItem,
)
from movieclaw_db.models import (
    MediaSegmentState as MediaSegment,
)
from movieclaw_db.repositories.library_file_repo import LibraryFileRepository
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_kernel import Context, plugin
from movieclaw_media.models import MediaKind
from movieclaw_scheduler import SCHEDULED_TASKS, TaskDefinition, TriggerType
from movieclaw_sdk.events import (
    PLAYBACK_COMPLETED,
    PLAYBACK_PROGRESS,
    PLAYBACK_STOPPED,
)
from movieclaw_sdk.jobs import (
    JOB_HANDLERS,
    PLUGIN_JOBS,
    JobBlocked,
    JobContext,
    JobRetry,
    RegisteredJobHandler,
)

from .align import (
    AlignReport,
    apply_matched,
    apply_reuse,
    apply_unmatched,
    count_reusable_files,
    enrich_file_info,
    inventory,
    match,
)
from .realtime import (
    _FAST_INTERVAL,
    _FAST_ROUNDS,
    activity_recent,
    ensure_season_index,
    handle_playback_event,
    note_activity,
    pull_tick,
    push_markers,
    skip_values_from_segments,
)
from .trim_api import (
    CATEGORY_MOVIE,
    CATEGORY_TV,
    TYPE_MOVIE,
    TYPE_TV,
    TrimAuthError,
    TrimClient,
    TrimError,
    TrimItem,
)

PLUGIN_ID = "trim-media-src"
SYNC_JOB_TYPE = f"{PLUGIN_ID}:sync"
SOURCE = "trim"

# 虚拟路径前缀（本机看不到飞牛目录时的台账寻址；.video 后缀让它不进任何扫描遍历）
_VIRTUAL_ROOT = "/trim"

# ---------------------------------------------------------------- 能力档案
#: 外部库源的能力位（设计文档 §2.1 的口径）：
#: - scraped=True：走主线的 TMDB 识别/刮削/定时刷新链——这是"与内置库同一体验"
#:   的关键（海报墙、详情、合集、每周元数据保鲜全都依赖它）。飞牛已刮好的元数据
#:   不参与：同步时用条目自带的 TMDB id 严丝合缝地锚定，不靠文件名猜。
#: - naming=False：内容已由飞牛整理，主线不重命名
#: - subscribable=True：条目锚了 TMDB，可以当订阅目标
#: - jellyfin_exposed=True：对 Jellyfin 兼容层暴露（Infuse 等客户端直接能看）
_MOVIE_PROFILE = LibraryProfile(
    kind=MediaKind.MOVIE,
    source=SOURCE,
    scraped=True,
    naming=False,
    ignore_rules=IgnoreProfile.PLAIN,
    write_nfo=False,
    subscribable=True,
    jellyfin_type="Movie",
    jellyfin_collection="movies",
    default_aspect=2 / 3,
    media_exts=frozenset({".mkv", ".mp4", ".avi", ".ts", ".m2ts", ".wmv", ".mov", ".iso"}),
    playable=True,
    jellyfin_exposed=True,
)
_TV_PROFILE = LibraryProfile(
    kind=MediaKind.TV,
    source=SOURCE,
    scraped=True,
    naming=False,
    ignore_rules=IgnoreProfile.PLAIN,
    write_nfo=False,
    subscribable=True,
    jellyfin_type="Series",
    jellyfin_collection="tvshows",
    default_aspect=2 / 3,
    media_exts=_MOVIE_PROFILE.media_exts,
    playable=True,
    jellyfin_exposed=True,
)

PROVIDER = LibrarySourceProvider(
    source=SOURCE,
    title="飞牛影视",
    profiles={"movie": _MOVIE_PROFILE, "tv": _TV_PROFILE},
    config_schema={
        "type": "object",
        "required": ["library_guid"],
        "properties": {
            "library_guid": {"type": "string", "title": "飞牛媒体库 GUID"},
            "library_name": {"type": "string", "title": "飞牛库名（展示用）"},
            # 本机挂载映射：飞牛库目录在容器里的可见路径（如 /downloads/Media/Movies）。
            # 给了它台账就写真实路径，播放本地直出，飞牛挂了照样播
            "local_root": {"type": "string", "title": "本机挂载路径（可选）"},
            "server_url": {"type": "string", "title": "飞牛地址（展示用）"},
        },
    },
    icon="fnos",
    help=(
        "把飞牛影视里已整理好的媒体库接成 MovieClaw 的库：同步条目、锚 TMDB 刮削、可订阅；"
        "插件停用时库保留可浏览"
    ),
)


# ---------------------------------------------------------------- 配置
class Settings(BaseModel):
    """设置页表单：连接信息。库映射走「建库」（source=trim + source_config）。"""

    base_url: str = Field(
        "",
        title="飞牛地址",
        description="影视服务地址，如 http://192.168.1.10:5666（带不带 /v 都行）",
    )
    username: str = Field("", title="用户名")
    password: SecretStr | None = Field(None, title="密码")
    access_code: SecretStr | None = Field(
        None, title="访问码（可选）", description="飞牛开启了设备访问码才填"
    )
    verify_tls: bool = Field(
        True,
        title="校验证书（HTTPS 建议开启）",
        description=(
            "飞牛走 HTTPS 时校验服务器证书。用自签证书（飞牛远程默认的 5667 端口）"
            "连不上时再关掉；关掉后凭据可能被冒充的服务器拿到"
        ),
    )
    member_username: str = Field(
        "",
        title="这个飞牛账号对应哪个成员",
        description=(
            "填写 MovieClaw 成员的用户名。留空表示超管本人：只有这个成员的观看进度会写进飞牛，"
            "从飞牛拉回的进度也只记在这个成员名下。不填的话，家里其他成员在飞牛里看到的进度会归到超管"
        ),
    )
    # —— 自动接入 ——
    auto_import: bool = Field(
        True,
        title="自动接入新库",
        description="飞牛上新建的媒体库在下次同步时自动建成本地的库；关掉后只同步已接入的库",
    )
    name_prefix: str = Field(
        "飞牛",
        title="库名前缀",
        description="自动建的库叫什么，如「飞牛 · 国产剧」；留空则直接用飞牛库名",
    )
    path_map_from: str = Field(
        "",
        title="飞牛路径前缀",
        description=(
            "可选。飞牛库目录在本机可见时，填飞牛侧的目录前缀（就是飞牛里那批文件的路径开头），"
            "再配上下面一项，库就以「本机可见模式」接入。留空则全部走远程模式"
        ),
    )
    sync_markers: bool = Field(
        True,
        title="同步片头片尾到飞牛",
        description=(
            "MovieClaw 识别出的片头片尾写回飞牛（每集一个「跳过片头/片尾」秒数），"
            "之后在飞牛里播也会自动跳过。按当前登录用户存，不影响别的用户"
        ),
    )
    sync_progress: bool = Field(
        True,
        title="同步观看进度到飞牛",
        description="在 MovieClaw 里的播放进度写回飞牛，两边接着看的位置一致",
    )
    path_map_to: str = Field(
        "",
        title="本机路径前缀",
        description=(
            "可选。上面那个前缀在 MovieClaw 容器里对应的路径。两个都填了才换算："
            "换算成功的库走「本机可见模式」（真实文件、本地直出、飞牛挂了也照常播）；"
            "留空或换算不出来的库走远程模式"
        ),
    )


def client_of(settings: Settings) -> TrimClient:
    return TrimClient(
        settings.base_url,
        settings.username,
        settings.password.get_secret_value() if settings.password else "",
        settings.access_code.get_secret_value() if settings.access_code else "",
        verify=settings.verify_tls,
    )


async def _write_strm_once(files: Any, path: str, url: str) -> None:
    """写 .strm 占位文件（内容与现有一致就跳过；临时文件 + 改名避免半截）。"""
    try:
        handle = await files.open(path, "rb")
        with handle:
            current = (await asyncio.to_thread(handle.read)).decode("utf-8", "replace").strip()
        if current == url:
            return
    except (OSError, PermissionError, FileNotFoundError):
        pass
    tmp = f"{path}.tmp"
    handle = await files.open(tmp, "wb")
    with handle:
        await asyncio.to_thread(handle.write, (url + "\n").encode("utf-8"))
    await files.rename(tmp, path)


def map_remote_to_local(path: str, frm: str, to: str) -> str | None:
    """飞牛侧目录 → 本机容器内路径；不在映射前缀下返回 None。"""
    raw = (path or "").strip()
    prefix = (frm or "").strip()
    base = (to or "").strip().rstrip("/")
    # 两个前缀都得由用户自己配：只配一半等于没配，宁可回落远程模式，
    # 也不要生成 "/电影" 这种以根目录开头的半截路径。
    if not raw or not prefix or not base or not raw.startswith(prefix):
        return None
    tail = raw[len(prefix):].strip("/")
    return f"{base}/{tail}" if tail else base


def pick_roots(local_dirs: list[str]) -> list[str]:
    """同一个飞牛库的多条目录 → 去冗余后的根列表。

    父目录也在列表里时丢掉子目录（父已经覆盖它）：飞牛自身常把「分类目录」
    与「全部分类目录的父目录」一起挂在一个库里，照抄会让同一批文件被扫两遍。
    不同父目录下的子目录都保留（那是真正的多根，内容互补）。
    """
    uniq = sorted({d.strip().rstrip("/") for d in local_dirs if d and d.strip()})
    keep: list[str] = []
    for d in uniq:
        if any(d != other and d.startswith(other + "/") for other in uniq):
            continue  # 被同库的父目录覆盖
        keep.append(d)
    return keep


def roots_conflict(roots: list[str], occupied: list[tuple[str, str]]) -> tuple[str, str] | None:
    """库根与已占用根是否相同或嵌套（平台的硬约束）；冲突时返回（库名, 根）。"""
    for root in roots:
        r = root.rstrip("/")
        for name, other in occupied:
            s = other.rstrip("/")
            if r == s or r.startswith(s + "/") or s.startswith(r + "/"):
                return name, other
    return None


#: 蓝光原盘的内部结构目录：里面的 .m2ts 是同一部片的分片，不是独立影片，
#: 计进来会让「漏了 N 个文件」变成误报（实测：一部 BDMV 电影能报出 254 个）。
_SKIP_DIR_NAMES = frozenset({"@eaDir", "BDMV", "CERTIFICATE", "VIDEO_TS", "AUDIO_TS"})


def _walk_videos(root: str, exts: set[str]) -> list[str]:
    """列出一个根下的视频文件（跳过隐藏目录、系统目录与蓝光结构目录）。

    与主程序扫描同一套扩展名口径；只读、不改动任何东西。
    """
    found: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [
            d for d in dirnames if not d.startswith(".") and d not in _SKIP_DIR_NAMES
        ]
        for name in filenames:
            if os.path.splitext(name)[1].lower() in exts:
                found.append(os.path.join(dirpath, name))
    return found


def _iso_now() -> str:
    from datetime import UTC, datetime

    return datetime.now(UTC).replace(tzinfo=None).isoformat()


def _read_log_tail(path: str, *, max_bytes: int = 400_000) -> list[str]:
    """读日志文件尾部（只读最后一段，几十 MB 的日志也不会拖慢请求）。"""
    try:
        with open(path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            start = max(0, size - max_bytes)
            handle.seek(start)
            data = handle.read()
    except OSError:
        return []
    lines = data.decode("utf-8", "replace").splitlines()
    if start > 0 and lines:
        lines = lines[1:]  # 第一行多半被截断，丢掉
    return lines


def _parse_log_line(line: str) -> dict[str, str] | None:
    """``2026-11-02 09:27:27 | INFO | movieclaw.plugin.trim-media-src | 消息``"""
    parts = line.split(" | ", 3)
    if len(parts) != 4:
        return None
    return {
        "ts": parts[0].strip(),
        "level": parts[1].strip(),
        "logger": parts[2].strip(),
        "message": parts[3].strip(),
    }


def _virtual_path(server_guid: str, guid: str) -> str:
    return f"{_VIRTUAL_ROOT}/{server_guid}/{guid}.video"


# ---------------------------------------------------------------- 主插件
@plugin(
    PLUGIN_ID,
    title="飞牛影视库源",
    inject=(HOST_OPS, PLUGIN_DATA, PLUGIN_FILES, PLUGIN_ROUTES, PLUGIN_JOBS),
    # 只用主程序的「观看状态写回」接口（它带成员可见性、compare-and-set 与事件抑制）
    permissions=("playback.sync.state",),
    config=Settings,
    reloadable=True,
)
async def apply(ctx: Context) -> None:
    settings = (
        ctx.config
        if isinstance(ctx.config, Settings)
        else Settings.model_validate(ctx.config or {})
    )
    store = ctx.use(PLUGIN_DATA).scoped(ctx)
    files = ctx.use(PLUGIN_FILES).scoped(ctx)
    routes = ctx.use(PLUGIN_ROUTES)
    ops = await ctx.use(HOST_OPS).client(ctx)
    jobs = ctx.use(PLUGIN_JOBS).scoped(ctx)
    log = ctx.logger

    # ---- 登记：飞牛成为媒体库的一种来源（你 PR 的机制）----
    ctx.registry(LIBRARY_SOURCE_PROVIDERS).add(
        SOURCE, PROVIDER, entry_id=ctx.entry_id,
    )

    if not settings.base_url or not settings.username or settings.password is None:
        log.info("飞牛影视库源：连接信息没填完整，到「设置 → 插件 → 飞牛影视库源」里填")

    def client() -> TrimClient:
        return client_of(settings)

    # ---- 同步引擎 -------------------------------------------------------
    async def _ensure_items(
        session: Any, items: list[TrimItem], kind: MediaKind, library_id: int
    ) -> tuple[dict[str, int], int]:
        """条目 → media_item（锚 TMDB）；返回 (guid → media_item_id, 本轮新建条目数)。"""
        from movieclaw_api.services.media_discover import get_tmdb_client
        from movieclaw_api.services.media_library import MediaLibraryService

        service = MediaLibraryService(session, get_tmdb_client(), scrape_library_id=library_id)
        guid_map: dict[str, int] = {}
        # 每 40 条提交一次：几千条一口气写会长时间占着数据库写锁，
        # 和同期的扫描/播放写入相互等待（实测触发过 database is locked）
        batch = 0
        # 「本轮有多少条是新建的」：批量查一次已有 TMDB 集合（每 500 个一次查询），
        # 而不是逐条 SELECT —— 6000 条逐个查就是 6000 次白打的库
        wanted = sorted({int(i.tmdb_id) for i in items if i.tmdb_id})
        existing_tmdb: set[int] = set()
        for chunk in [wanted[i : i + 500] for i in range(0, len(wanted), 500)]:
            existing_tmdb.update(
                (await session.execute(
                    select(MediaItem.tmdb_id).where(
                        MediaItem.kind == kind.value, MediaItem.tmdb_id.in_(chunk)
                    )
                )).scalars().all()
            )
        created = len(set(wanted) - existing_tmdb)
        for item in items:
            if item.tmdb_id is None:
                continue  # 锚不上 TMDB 的（飞牛没刮到）一期跳过，记日志
            try:
                media = await service.ensure_media_item(kind, item.tmdb_id, library_id=library_id)
                if media.id is not None:
                    guid_map[item.guid] = media.id
            except Exception as exc:  # noqa: BLE001 -- 单条失败不拖垮整轮
                log.warning("建档失败（tmdb %s）：%s", item.tmdb_id, exc)
            batch += 1
            if batch >= 40:
                # 小事务 + 前台让路（主程序 scan.py 同款）：一次只锁几十毫秒，
                # 用户在点页面时先退一步，不和前台抢数据库与 CPU
                await session.commit()
                batch = 0
                try:
                    from movieclaw_api.services.foreground import yield_to_foreground

                    await yield_to_foreground()
                except Exception:  # noqa: BLE001
                    await asyncio.sleep(0)
        if batch:
            await session.commit()
        return guid_map, created

    async def sync_library_row(
        session: Any, library: Library, *, light: bool = False
    ) -> dict[str, Any]:
        """同步一个库行：拉飞牛条目 → 锚 TMDB 建档 → 落台账。

        两种寻址模式（由库的 root_paths 与 source_config.local_root 决定）：

        - **本机可见模式**（root_paths 就指向飞牛库目录在本机的挂载路径）：
          只负责建档与触发主线扫描——真实文件由主程序扫描入账，拿到探规格、
          本地直出播放、字幕/抓帧全部原生能力。飞牛进程挂了这套照常工作。
        - **远程模式**（没有本地根）：写虚拟台账行（local_bytes=False），
          播放由插件的取流端点换飞牛直链，飞牛不可用时条目显示失联。
        """
        config = library.source_config or {}
        guid = str(config.get("library_guid") or "")
        if not guid:
            return {"library": library.name, "error": "source_config 里没有 library_guid"}
        if light:
            # 轻同步：只把 MC 已有的片头片尾推给飞牛（不建档、不写台账、不排扫描）
            if not library.root_paths:
                return {"library": library.name, "mode": "light", "note": "远程模式无需附加同步"}
            try:
                async with client() as trim_light:
                    await trim_light.ensure_login()
                    extras = await sync_extras(session, library, trim_light)
            except (TrimAuthError, TrimError) as exc:
                return {"library": library.name, "mode": "light", "error": str(exc)}
            if extras:
                log.info("库「%s」轻同步（识别任务在跑）：%s", library.name, extras)
            return {"library": library.name, "mode": "light", "extras": extras}
        kind = MediaKind(library.kind)
        local_mode = bool(library.root_paths)

        async with client() as trim:
            await trim.ensure_login()
            top = await trim.all_items(guid)
            videos: list[TrimItem] = [
                i for i in top if i.type == TYPE_MOVIE and kind is MediaKind.MOVIE
            ]
            failed_seasons = 0
            if kind is MediaKind.TV:
                tvs = [i for i in top if i.type == TYPE_TV and i.guid]
                for tv in tvs:
                    episodes, failed = await trim.tv_episodes(tv.guid)
                    videos.extend(episodes)
                    failed_seasons += failed
            if failed_seasons:
                # 有季没拉到：这一轮「没出现在结果里」不等于「飞牛上删了」，
                # 对账要整体收手，否则一次网络抖动就会把整季标成 missing。
                log.warning(
                    "库「%s」有 %d 个季的分集没拉到，本轮跳过缺失对账（不把台账标 missing）",
                    library.name, failed_seasons,
                )
            videos = [i for i in videos if i.guid and (i.tmdb_id is not None)]

        guid_map, newly_created = await _ensure_items(session, videos, kind, library.id or 0)
        if local_mode:
            # 片头片尾 / 观看进度：本机模式才有真实的指纹与进度可同步
            try:
                async with client() as trim2:
                    await trim2.ensure_login()
                    extras = await sync_extras(session, library, trim2)
                if extras:
                    log.info("库「%s」附加同步：%s", library.name, extras)
            except (TrimAuthError, TrimError) as exc:
                log.warning("附加同步（片头片尾/进度）没做成：%s", exc)
            # 本机可见：真实文件由主线扫描入账（识别拿 TMDB 锚后与上面建的档幂等合并）。
            # 之前远程模式留下的虚拟台账行要清掉——否则同一部片会出现两条文件记录
            # （一条真实文件、一条指向取流端点的 .video），体积与规格统计都对不上。
            strm_dir = files.path("plugin", "hls")
            stale = (
                await session.execute(
                    select(LibraryFile).where(
                        LibraryFile.library_id == library.id,
                        or_(
                            LibraryFile.file_path.startswith(_VIRTUAL_ROOT),
                            LibraryFile.file_path.like(f"{strm_dir}/%"),
                        ),
                    )
                )
            ).scalars().all()
            if stale:
                await LibraryFileRepository(session).delete_by_ids([r.id for r in stale])
                log.info(
                    "库「%s」转为本机可见模式，清理 %d 条旧虚拟台账行", library.name, len(stale)
                )
            await session.commit()
            # 只在「本轮真的有新条目」且距上次扫描超过 30 分钟时才排扫描。
            # 之前每轮同步都无条件排一次，6000 集的库等于每 6 小时触发一轮全库扫描，
            # 扫描收尾又会排整季片头片尾比对（那是个几百条 UPDATE 的大事务），
            # 叠起来把 SQLite 写锁占满 —— 实测就是 database is locked 的主要来源。
            # 对齐并复用：同一份文件在别的库已识别好/已探好/已算出片头片尾，
            # 直接搬过来，扫描时这些路径就是「已知行」，识别链与探测全部跳过
            try:
                stats = await apply_reuse(session, library_id=library.id or 0, log=log)
                if stats.get("specs") or stats.get("segments"):
                    log.info("库「%s」复用：规格 %d 行、片头片尾 %d 行",
                             library.name, stats.get("specs", 0), stats.get("segments", 0))
            except Exception as exc:  # noqa: BLE001 -- 复用失败不影响扫描自己识别
                log.warning("复用失败（扫描会自行识别/探测）：%s", exc)

            import time as _time

            scan_key = f"last_scan_ts:{library.id}"
            last_scan = int(await store.get(scan_key) or 0)
            if newly_created and _time.time() - last_scan > 1800:
                try:
                    from movieclaw_api.services.library.scan import enqueue_scan_job

                    await enqueue_scan_job(session, library.id, library.name, origin="plugin")
                    await session.commit()
                    await store.set(scan_key, int(_time.time()))
                except Exception as exc:  # noqa: BLE001 -- 扫描排不上不阻断同步（下次对账会收尾）
                    log.warning("库「%s」扫描没排上（主线定时对账会兜底）：%s", library.name, exc)
            elif newly_created:
                log.info("库「%s」本轮新增 %d 条，距上次扫描不足 30 分钟，扫描交给主线对账",
                         library.name, newly_created)
            return {
                "library": library.name,
                "mode": "local",
                "remote": len(videos),
                "anchored": len(guid_map),
                "ledger": 0,
                "missing": 0,
                "note": "本机可见模式：已建档，台账由主线扫描真实文件",
            }

        repo = LibraryFileRepository(session)
        written = 0
        seen_paths: set[str] = set()
        # 远程模式的台账寻址：插件私有目录里的 .strm（内容指向插件的 HLS 代理）。
        # 用真实文件而不是虚拟路径，是因为主线的播放链只认「读得出地址的 .strm」——
        # 这样直出、转码、Jellyfin 全都自动可用，与网盘 STRM 同一套机制。
        strm_dir = files.path("plugin", "hls")
        await files.makedirs(strm_dir)
        for item in videos:
            media_id = guid_map.get(item.guid)
            if media_id is None:
                continue
            strm_path = os.path.join(strm_dir, f"{item.guid}.strm")
            try:
                link = await routes.sign(ctx, f"/hls/{item.guid}/playlist.m3u8", absolute=True)
                await _write_strm_once(files, strm_path, link)
            except Exception as exc:  # noqa: BLE001 -- 单条写失败不影响其他条目
                log.warning("写播放占位失败（%s）：%s", item.guid, exc)
                continue
            path = strm_path
            seen_paths.add(path)
            row = LibraryFile(
                library_id=library.id,
                media_item_id=media_id,
                season_number=item.season_number or 0,
                episode_number=item.episode_number or 0,
                file_path=path,
                size_bytes=0,
                file_mtime_ns=None,
                container="strm",  # 占位文件：真实容器由主线探直链时得到
                local_bytes=True,  # .strm 本身就落在这里，地址在里面
                state="in_place",
                # 台账行的来源类别：外部库源同步进来的存量（不是下载入库）
                source="scanned",
            )
            existing = await repo.get_by_path(path)
            await repo.upsert_by_path(row, existing=existing)
            written += 1
            # 与建档同一套节奏：每 200 行提交一次，别把几千行憋在一个事务里
            # 长时间占写锁（本机模式由主线扫描写台账，只有远程模式走这里）。
            if written % 200 == 0:
                await session.commit()
                try:
                    from movieclaw_api.services.foreground import yield_to_foreground

                    await yield_to_foreground()
                except Exception:  # noqa: BLE001
                    await asyncio.sleep(0)
        # 远端没了的行标 missing（文件在飞牛那边，绝不动磁盘）。
        # 只有「这一轮完整拉到飞牛条目」时才敢这么判——拉取失败的那几个季里，
        # 条目没出现是查询失败，不是被删了。
        missing = 0
        if not failed_seasons:
            rows = (
                await session.execute(
                    select(LibraryFile).where(
                        LibraryFile.library_id == library.id,
                        LibraryFile.file_path.like(f"{strm_dir}/%"),  # type: ignore[attr-defined]
                    )
                )
            ).scalars().all()
            for row in rows:
                if row.file_path not in seen_paths and row.state == "in_place":
                    await repo.mark_missing(row.id, since=None)
                    missing += 1
        await session.commit()
        await LibraryRepository(session).refresh_stats([library.id])
        await session.commit()
        # 回写「最后同步」
        from movieclaw_db.models.base import utcnow

        library.last_source_sync_at = utcnow()
        session.add(library)
        await session.commit()
        return {
            "library": library.name,
            "mode": "remote",
            "remote": len(videos),
            "anchored": len(guid_map),
            "ledger": written,
            "missing": missing,
            "fetch_failed": failed_seasons,
        }

    async def check_coverage(session: Any, library: Library, trim: Any) -> dict[str, Any] | None:
        """飞牛库的实际目录范围，MC 这边的库根覆盖了多少（只读统计，不动任何根）。

        为什么要这个：飞牛库里可能挂着一个父目录（例如「国产剧」库的目录就是
        `TV_Shows/`，涵盖所有剧），而 MC 这边的库根可能只是它的一个子目录。
        不同步出来，用户根本不会发现「飞牛里有、MC 里没有」——台账上干干净净，
        播放时就是找不到片。

        结果按库缓存，页面直接读；范围对得上时 `uncovered=0`。
        """
        cfg = library.source_config or {}
        guid = str(cfg.get("library_guid") or "")
        if not guid or not library.root_paths:
            return None  # 远程模式没有本机根，无从比对
        try:
            remote_libs = await trim.libraries()
        except (TrimAuthError, TrimError):
            return None
        remote = next((lib for lib in remote_libs if lib.guid == guid), None)
        if remote is None:
            return None
        local_roots: list[str] = []
        for remote_dir in remote.dir_list:
            local = map_remote_to_local(remote_dir, settings.path_map_from, settings.path_map_to)
            if local and await asyncio.to_thread(os.path.isdir, local):
                local_roots.append(local.rstrip("/"))
        if not local_roots:
            return None
        # 飞牛常把「父目录」和「其中的子目录」一起挂在一个库里，逐条 walk 会把同一批
        # 文件数两遍。先按主线同一套口径去冗余：父目录在的，子目录丢掉。
        local_roots = pick_roots(local_roots)

        # 「收没收录」按**全部库**算：同一批文件可能在另一个库（例如国漫单独成库）
        # 已经入账，那就不算漏，避免把一个目录重复建两次库。
        known: set[str] = set()
        for root in local_roots:
            rows = (
                await session.execute(
                    select(LibraryFile.file_path).where(
                        LibraryFile.file_path.like(f"{root}/%"),
                    )
                )
            ).scalars().all()
            known.update(rows)

        exts = set(_MOVIE_PROFILE.media_exts)
        total = 0
        missing_by_dir: dict[str, int] = {}
        sample: list[str] = []
        for root in local_roots:
            found = await asyncio.to_thread(_walk_videos, root, exts)
            for path in found:
                total += 1
                if path in known:
                    continue
                rel = os.path.relpath(path, root)
                key = rel.split(os.sep)[0] if os.sep in rel else "."
                missing_by_dir[key] = missing_by_dir.get(key, 0) + 1
                if len(sample) < 20:
                    sample.append(path)
        uncovered = sum(missing_by_dir.values())
        data = {
            "checked_at": _iso_now(),
            "remote_dirs": list(remote.dir_list),
            "local_roots": local_roots,
            "library_roots": list(library.root_paths or []),
            "files": total,
            "covered": total - uncovered,
            "uncovered": uncovered,
            "top_uncovered": [
                {"dir": name, "files": count}
                for name, count in sorted(missing_by_dir.items(), key=lambda kv: -kv[1])[:12]
            ],
            "sample": sample,
        }
        await store.set(f"coverage:{library.id}", data)
        if uncovered:
            log.info(
                "库「%s」范围覆盖异常：飞牛目录下 %d 个视频文件，MC 只收了 %d 个（未覆盖 %d）",
                library.name, total, data["covered"], uncovered,
            )
        return data

    async def _skip_segments_running(session: Any) -> bool:
        """片头片尾识别**正在写**的时候才算（它整季写回是一个大事务，最容易撞写锁）。

        排队中（``phase=queued``）的任务不碰数据库，不该拖住同步——实测启动时
        会排两个 queued 任务，若照旧让路，同步就永远跑不起来。

        用主程序的 jobs 服务查，不自己写 join —— 任务状态的判定口径只有一处。
        """
        from movieclaw_api.services.jobs import list_jobs
        from movieclaw_db.models import ACTIVE_JOB_STATUSES

        rows = await list_jobs(
            session, job_type="library.skip_segments",
            statuses=tuple(ACTIVE_JOB_STATUSES), limit=5,
        )
        for row in rows:
            progress = getattr(row, "progress", None)
            if isinstance(progress, dict) and str(progress.get("phase") or "") == "queued":
                continue
            return True
        return False

    async def _library_busy(session: Any, library_id: int | None) -> bool:
        """这个库有没有在跑的扫描 / 整理任务（有就别跟它抢写锁）。"""
        if library_id is None:
            return False
        from movieclaw_api.services.jobs import list_jobs_by_resource
        from movieclaw_db.models import ACTIVE_JOB_STATUSES

        grouped = await list_jobs_by_resource(
            session, resource_type="library", resource_ids=[library_id], limit_per_resource=3
        )
        return any(job.status in ACTIVE_JOB_STATUSES for job in grouped.get(str(library_id), []))

    async def sync_extras(session: Any, library: Library, trim: Any) -> dict[str, Any]:
        """同步时的附加工作：把 MC 识别出的片头片尾写回飞牛。

        观看进度不在这里做——它由播放事件（近实时）和 3 分钟轮询负责，
        在同步里再写一遍只会和那两条路径打架。片头片尾只在整轮同步时推，
        因为它是「库里所有条目」的批量动作，且飞牛侧只有一次性配置。
        """
        if not settings.sync_markers:
            return {}
        config = library.source_config or {}
        guid = str(config.get("library_guid") or "")
        if not guid:
            return {}
        # 飞牛的片头片尾是**按季**生效的：写单集 guid 播放信息读不到，写季 guid
        # 整季每一集立刻生效（实测）。所以要一份 (TMDB, 季) → 季 guid 的索引。
        season_index = await ensure_season_index(
            trim, library_id=library.id or 0, config=config, kind=library.kind, log=log
        )
        if not season_index:
            return {}
        state_key = f"markers:{guid}"
        state = await store.get(state_key)
        if not isinstance(state, dict):
            state = {}
        rows = (
            await session.execute(
                select(MediaItem.tmdb_id, LibraryFile.season_number, LibraryFile.episode_number,
                       LibraryFile.duration_seconds, MediaSegment.segments, MediaItem.title)
                .join(LibraryFile, LibraryFile.media_item_id == MediaItem.id)
                .join(MediaSegment, MediaSegment.library_file_id == LibraryFile.id)
                .where(
                    LibraryFile.library_id == library.id,
                    LibraryFile.state == "in_place",
                    MediaSegment.fingerprint_status == "ok",
                )
            )
        ).all()
        # 先按（剧, 季）聚合：同一季每集的识别值会有几秒浮动（129/125、130/121…），
        # 而飞牛一季只能存一套秒数 —— 取中位数，比"取最后一集"更稳。
        buckets: dict[tuple[int, int], list[tuple[int, int]]] = {}
        titles: dict[tuple[int, int], str] = {}
        for tmdb_id, season, _episode, duration, segments, title in rows:
            if tmdb_id is None:
                continue
            values = skip_values_from_segments(segments, duration)
            if values is None:
                continue
            key = (int(tmdb_id), int(season or 0))
            buckets.setdefault(key, []).append(values)
            titles.setdefault(key, title or "")
        pushes: list[tuple[str, int, int, str]] = []
        for (tmdb_id, season), values_list in buckets.items():
            season_guid = season_index.get((tmdb_id, season))
            if not season_guid:
                continue
            openings = sorted(v[0] for v in values_list)
            endings = sorted(v[1] for v in values_list)
            skip_opening = openings[len(openings) // 2]
            skip_ending = endings[len(endings) // 2]
            label = f"{titles[(tmdb_id, season)]} S{season:02d}（{len(values_list)} 集）"
            pushes.append((season_guid, skip_opening, skip_ending, label))
        stats = await push_markers(trim, rows=pushes, state=state, log=log)
        await store.set(state_key, dict(list(state.items())[-4000:]))
        # 页面上的「已写回多少季」要准：state 里还留着早期按集写的旧键，
        # 直接数它会虚高，所以另存一份本轮口径的快照。
        await store.set(
            f"markers_meta:{guid}",
            {
                "seasons": len(pushes),
                "written": stats.get("written", 0),
                "skipped": stats.get("skipped", 0),
                "failed": stats.get("failed", 0),
                "at": _iso_now(),
            },
        )
        return {"markers": stats, "seasons": len(season_index)}

    async def discover_and_import(session: Any) -> dict[str, list[str]]:
        """发现飞牛上的库并按需自动接入（幂等）。

        规则（平台的库根不能跨库嵌套，所以顺序与取舍都要讲得清）：

        1. 飞牛每个库的 dir_list → 按 path_map 换成本机路径，只留真实存在的；
        2. 同一个库内去冗余：父目录也在的，丢掉子目录（父已覆盖）；
        3. **父目录先建**：按根路径长度升序处理，覆盖范围大的库先占了根；
        4. 后面那些被完全覆盖的库跳过，并在结果里点名说明（内容不丢，只是不单独建库）；
        5. 一个本机目录都换不出来的库走远程模式（空根 + 取流端点）。

        已接入的库按 library_guid 认，不会重复建。
        """
        report: dict[str, list[str]] = {"created": [], "skipped": [], "existed": []}
        if not settings.auto_import:
            return report
        # 路径映射是用户自己的环境信息，代码里不给默认值。没配的时候说明白：
        # 新库会以远程模式接入（能看能播，但要走插件的取流代理）。
        if not (settings.path_map_from.strip() and settings.path_map_to.strip()):
            log.info(
                "没有配置路径映射（飞牛路径前缀 → 本机路径前缀）：新接入的库走远程模式；"
                "想把库接成本机直连（飞牛挂了也能播），在插件设置里把这两个前缀填上"
            )
        async with client() as trim:
            await trim.ensure_login()
            remote_libs = await trim.libraries()

        rows = (await session.execute(select(Library))).scalars().all()
        mapped_guids = {
            str((row.source_config or {}).get("library_guid"))
            for row in rows
            if row.source == SOURCE
        }
        # 已占用的根：全部库（含内置来源的库）都算——冲突只跟别的库有关
        occupied: list[tuple[str, str]] = [
            (row.name, root) for row in rows for root in (row.root_paths or [])
        ]
        names = {row.name for row in rows}

        pending: list[tuple[str, str, str, list[str]]] = []  # (guid, 名称, kind, 根)
        for lib in remote_libs:
            if lib.guid in mapped_guids:
                report["existed"].append(lib.name)
                continue
            if lib.category not in (CATEGORY_MOVIE, CATEGORY_TV):
                report["skipped"].append(f"{lib.name}（分类 {lib.category} 不支持）")
                continue
            kind = "movie" if lib.category == CATEGORY_MOVIE else "tv"
            locals_ = []
            for remote_dir in lib.dir_list:
                local = map_remote_to_local(
                    remote_dir, settings.path_map_from, settings.path_map_to
                )
                if local and await asyncio.to_thread(os.path.isdir, local):
                    locals_.append(local)
            pending.append((lib.guid, lib.name, kind, pick_roots(locals_)))

        # 父目录先建：根路径短的（覆盖大的）优先占位
        pending.sort(key=lambda p: (min((len(r) for r in p[3]), default=0)))

        # 建库走媒体库配置服务（评审意见）：它统一做名称/根路径校验、与「自动入库」
        # 目录的冲突检查、内置合集初始化，并刷新实时监控——直接写仓储会绕过这些。
        from movieclaw_api.services.library.config import LibraryConfigService

        service = LibraryConfigService(session)
        for guid, remote_name, kind, roots in pending:
            conflict = roots_conflict(roots, occupied) if roots else None
            if conflict is not None:
                report["skipped"].append(
                    f"{remote_name}（根 {roots[0]} 与「{conflict[0]}」重叠：内容已在那个库里）"
                )
                continue
            name = (
                f"{settings.name_prefix} · {remote_name}" if settings.name_prefix else remote_name
            )
            candidate = name
            suffix = 2
            while candidate in names:  # 库名全局唯一
                candidate = f"{name} ({suffix})"
                suffix += 1
            try:
                await service.create(
                    name=candidate,
                    kind=MediaKind(kind),
                    root_paths=roots,
                    source=SOURCE,
                    source_config={
                        "library_guid": guid,
                        "library_name": remote_name,
                        "local_root": roots[0] if roots else "",
                        "server_url": settings.base_url,
                        "server_guid": str(await store.get("server_guid") or "trim"),
                    },
                    realtime_watch=bool(roots),
                    generate_thumbnails=bool(roots),
                )
            except Exception as exc:  # noqa: BLE001 -- 单个库建失败不影响其他库
                await session.rollback()
                report["skipped"].append(f"{remote_name}（建库失败：{exc}）")
                continue
            occupied.extend((candidate, root) for root in roots)
            names.add(candidate)
            report["created"].append(f"{candidate}（{'本机可见' if roots else '远程'}）")
            log.info("自动接入飞牛库「%s」→ MovieClaw 库「%s」%s", remote_name, candidate,
                     f"根 {roots}" if roots else "（远程模式）")
        return report

    async def sync_all(progress: JobContext | None = None) -> list[dict[str, Any]]:
        db = get_database()
        results: list[dict[str, Any]] = []
        async with db.session() as session:
            # 先把飞牛上新出现的库接进来，再统一同步（新库当轮就能同步到）
            try:
                report = await discover_and_import(session)
                if any(report.values()):
                    log.info(
                        "飞牛库发现：新建 %d、已接入 %d、跳过 %d",
                        len(report["created"]), len(report["existed"]), len(report["skipped"]),
                    )
                    for line in report["skipped"]:
                        log.info("  跳过 %s", line)
            except (TrimAuthError, TrimError):
                raise
            except Exception as exc:  # noqa: BLE001 -- 发现失败不该拖垮同步
                log.warning("自动发现飞牛库失败（仅同步已接入的库）：%s", exc)
            rows = (
                await session.execute(select(Library).where(Library.source == SOURCE))
            ).scalars().all()
            for library in rows:
                if progress is not None:
                    await progress.raise_if_cancelled()
                # 库正在扫描 / 整理时不要插进来写：SQLite 只有一个写锁，
                # 同步（建档 + 台账 + 进度）和扫描（几千个文件）会互相等到超时，
                # 实测会一起报 database is locked。跳过本轮，下一轮再来。
                # 片头片尾识别正在写库时，不走「整轮跳过」：跳过建档与台账（那才是
                # 跟它抢写锁的部分），只做写飞牛那半（片头片尾推送，纯 HTTP）。
                # 识别一跑就是几小时，整轮让路等于同步停摆。
                light = await _skip_segments_running(session)
                if await _library_busy(session, library.id):
                    # 扫描/整理期间同样只做轻同步：写台账的活由扫描自己干
                    log.info("库「%s」正在扫描/整理，本轮只做轻同步（不抢写锁）", library.name)
                    light = True
                try:
                    result = await sync_library_row(session, library, light=light)
                except TrimAuthError as exc:
                    raise JobBlocked(f"飞牛登录失败：{exc}") from exc
                except TrimError as exc:
                    raise JobRetry(f"飞牛暂时不可用：{exc}", delay_seconds=120) from exc
                results.append(result)
                log.info("库「%s」同步完成：%s", library.name, result)
                if library.root_paths:
                    try:
                        async with client() as trim_cov:
                            await trim_cov.ensure_login()
                            coverage = await check_coverage(session, library, trim_cov)
                        if coverage and coverage.get("uncovered"):
                            result = dict(result, coverage=coverage)
                    except (TrimAuthError, TrimError) as exc:
                        log.warning("库「%s」范围检查跳过：%s", library.name, exc)
                    except Exception as exc:  # noqa: BLE001 -- 统计失败不该让同步失败
                        log.warning("库「%s」范围检查出错：%s", library.name, exc)
        import time as _time

        await store.set("last_sync_ts", int(_time.time()))
        # 最近一轮的结果摘要：页面直接读，不用翻日志（只留关键字段，别把 coverage 存进来）
        keys = ("library", "mode", "remote", "anchored", "ledger", "missing", "fetch_failed",
                "skipped", "note", "error")
        summary = []
        for item in results:
            row = {k: item[k] for k in keys if k in item}
            extras = item.get("extras") or {}
            markers = extras.get("markers") if isinstance(extras, dict) else None
            if isinstance(markers, dict):
                row["markers"] = markers
            summary.append(row)
        await store.set("last_sync_result", {"at": _iso_now(), "libraries": summary})
        return results

    async def sync_job(context: JobContext, data: dict[str, Any]) -> dict[str, Any]:
        try:
            return {"libraries": await sync_all(progress=context)}
        except PermissionError as exc:
            raise JobBlocked(str(exc)) from exc

    ctx.contribute(
        JOB_HANDLERS, SYNC_JOB_TYPE,
        RegisteredJobHandler(sync_job, frozenset({1}), title="同步飞牛影视库"),
    )

    async def scheduled_sync() -> None:
        ref = await jobs.create(SYNC_JOB_TYPE, input={}, dedupe_key="all")
        if not ref.created:
            log.info("上一轮飞牛同步还在进行，本轮跳过")

    ctx.contribute(SCHEDULED_TASKS, "sync", TaskDefinition(
        key=f"{PLUGIN_ID}.sync", title="同步飞牛影视库",
        description="拉取飞牛条目，锚 TMDB 建档、写台账、对账缺失（不动磁盘）",
        handler=scheduled_sync,
        default_trigger_type=TriggerType.INTERVAL, default_interval_seconds=6 * 3600,
        default_enabled=True,
    ))

    # ---- 远程模式的取流：HLS 代理（公开区，签名链接） -------------------
    # 飞牛本地文件只输出 HLS 转码流（.m3u8 + ts 分片），且分片要带它的会话凭证；
    # 播放器拿不到那份凭证，所以由插件代理：playlist 改写成分片走插件自身，
    # 每个分片地址带宿主签发的签名（分片路径各不相同，逐个签）。
    hls_router = APIRouter()
    _hls_cache: dict[str, tuple[float, str]] = {}

    async def _hls_playlist_text(guid: str) -> str:
        """取并改写 m3u8（分片地址 → 插件签名链接）；结果缓存 2 分钟。"""
        import time as _time

        cached = _hls_cache.get(guid)
        now = _time.monotonic()
        if cached is not None and cached[0] > now:
            return cached[1]
        async with client() as trim:
            await trim.ensure_login()
            url, headers = await trim.open_stream(guid)
            data, _ctype = await trim.fetch_bytes(url, headers)
        media_hash = url.rsplit("/", 2)[-2]  # .../v/media/<hash>/preset.m3u8
        lines: list[str] = []
        for line in data.decode("utf-8", "replace").splitlines():
            raw = line.strip()
            if not raw or raw.startswith("#"):
                lines.append(line)
                continue
            seg = await routes.sign(ctx, f"/hls/{guid}/{media_hash}/{raw}", absolute=True)
            lines.append(seg)
        text = "\n".join(lines) + "\n"
        _hls_cache[guid] = (now + 120, text)
        return text

    @hls_router.get(
        "/hls/{guid}/playlist.m3u8",
        operation_id=f"plugins.{PLUGIN_ID}.hls-playlist",
        summary="飞牛条目的 HLS 播放列表（远程模式，分片由本插件代理）",
    )
    async def hls_playlist(guid: str) -> Response:
        try:
            text = await _hls_playlist_text(guid)
        except TrimAuthError as exc:
            raise HTTPException(status_code=502, detail=f"飞牛登录失败：{exc}") from exc
        except TrimError as exc:
            raise HTTPException(status_code=502, detail=f"飞牛取流失败：{exc}") from exc
        return Response(content=text, media_type="application/vnd.apple.mpegurl")

    @hls_router.get(
        "/hls/{guid}/{media_hash}/{segment}",
        operation_id=f"plugins.{PLUGIN_ID}.hls-segment",
        summary="飞牛 HLS 分片转发（远程模式）",
    )
    async def hls_segment(guid: str, media_hash: str, segment: str) -> Response:
        host = (settings.base_url or "").rstrip("/")
        if host.endswith("/v"):
            host = host[:-2]
        if not host.startswith("http"):
            raise HTTPException(status_code=502, detail="飞牛地址没配好")
        url = f"{host}/v/media/{media_hash}/{segment}"
        try:
            async with client() as trim:
                await trim.ensure_login()
                data, ctype = await trim.fetch_bytes(url, trim._session_headers())
        except TrimAuthError as exc:
            raise HTTPException(status_code=502, detail=f"飞牛登录失败：{exc}") from exc
        except TrimError as exc:
            raise HTTPException(status_code=502, detail=f"飞牛分片取流失败：{exc}") from exc
        return Response(content=data, media_type=ctype)

    routes.mount(ctx, hls_router, zone="public")

    # ---- 管理路由 -------------------------------------------------------
    router = APIRouter()

    @router.get(
        "/status",
        operation_id=f"plugins.{PLUGIN_ID}.status",
        summary="运行状态：连接信息、source=trim 的库清单与最近同步",
    )
    async def status() -> dict:
        db = get_database()
        # 每个库的范围覆盖快照（同步时算并缓存，页面不现场 walk 目录）
        coverage_map: dict[int, Any] = {}
        async with db.session() as session:
            rows = (
                await session.execute(select(Library).where(Library.source == SOURCE))
            ).scalars().all()
            for row in rows:
                cached = await store.get(f"coverage:{row.id}")
                if cached:
                    coverage_map[row.id] = cached
            libraries = []
            for lib in rows:
                cfg = lib.source_config or {}
                guid = str(cfg.get("library_guid") or "")
                pushed = await store.get(f"markers_meta:{guid}") if guid else None
                libraries.append({
                    "id": lib.id,
                    "name": lib.name,
                    "kind": lib.kind,
                    # 网页用的字段名（fn_guid / fn_name / root_paths / item_count…）
                    "fn_guid": (lib.source_config or {}).get("library_guid"),
                    "fn_name": (lib.source_config or {}).get("library_name") or "",
                    "fn_guid_text": (lib.source_config or {}).get("library_guid") or "",
                    "local_root": (lib.source_config or {}).get("local_root"),
                    "root_paths": list(lib.root_paths or []),
                    "source_configured": bool(lib.source_config),
                    "item_count": lib.stats_item_count,
                    "last_sync_at": (
                        lib.last_source_sync_at.isoformat() if lib.last_source_sync_at else None
                    ),
                    "stats": {
                        "item_count": lib.stats_item_count,
                        "file_count": lib.stats_file_count,
                        "missing_count": lib.stats_missing_count,
                    },
                    "coverage": coverage_map.get(lib.id),
                    # 已经写回飞牛的片头片尾季数（飞牛按季存，一季一套秒数）
                    "markers_pushed": (
                        int(pushed.get("seasons") or 0) if isinstance(pushed, dict) else 0
                    ),
                    "markers_at": pushed.get("at") if isinstance(pushed, dict) else None,
                })
        return {
            "plugin": PLUGIN_ID,
            "configured": bool(settings.base_url and settings.username and settings.password),
            "base_url": settings.base_url,
            "server_guid": str(await store.get("server_guid") or "trim"),
            # 全局最近一次同步时刻（页面状态条直接用，不必自己再算）
            "last_sync_at": max(
                (
                    lib["last_sync_at"]
                    for lib in libraries
                    if lib.get("last_sync_at")
                ),
                default=None,
            ),
            "libraries": libraries,
            # 配置层的当前生效值（页面上直接显示，免得用户去猜）
            "member_username": settings.member_username.strip(),
            "verify_tls": settings.verify_tls,
            "auto_import": settings.auto_import,
            "sync_markers": settings.sync_markers,
            "sync_progress": settings.sync_progress,
            "last_sync_result": await store.get("last_sync_result"),
        }

    @router.get(
        "/check-coverage",
        operation_id=f"plugins.{PLUGIN_ID}.check-coverage",
        summary="检查库范围覆盖：飞牛库目录下有多少视频文件，MC 台账收了哪些",
    )
    async def check_coverage_route(library_id: int | None = None) -> dict:
        """`library_id` 不传就检查全部 source=trim 的库。

        只统计、只写一份缓存快照，不动库根、不动台账。派上用场的地方：飞牛把
        一个父目录挂成了库，而 MC 这边的库根只是其中一小块——用户看不到差别，
        一点检查就知道漏了多少。
        """
        lib_id = library_id
        db = get_database()
        out: list[dict] = []
        async with db.session() as session:
            query = select(Library).where(Library.source == SOURCE)
            if lib_id:
                query = query.where(Library.id == int(lib_id))
            rows = (await session.execute(query)).scalars().all()
            targets = [row for row in rows if row.root_paths]
            if not targets:
                return {"libraries": []}
            async with client() as trim:
                await trim.ensure_login()
                for row in targets:
                    data = await check_coverage(session, row, trim)
                    if data:
                        out.append({"library": row.name, "library_id": row.id, **data})
        return {"libraries": out}

    @router.get(
        "/libraries",
        operation_id=f"plugins.{PLUGIN_ID}.libraries",
        summary="飞牛侧媒体库清单：目录、本机映射根、是否已接入、与已有库是否重叠",
    )
    async def remote_libraries() -> list[dict]:
        """飞牛上现在有哪些库、能不能接、接了会落在哪个本机目录。

        与自动接入（discover_and_import）同一套判定：路径映射 → 只留本机真实存在
        的目录 → 同库内父子去冗余 → 与所有库根比是否重叠。网页据此标
        「已接入 / 重叠 / 未接入」，用户点接入时心里有数。
        """
        db = get_database()
        async with db.session() as session:
            rows = (await session.execute(select(Library))).scalars().all()
        mapped: dict[str, Library] = {}
        occupied: list[tuple[str, str]] = []
        for row in rows:
            cfg = row.source_config or {}
            if row.source == SOURCE and cfg.get("library_guid"):
                mapped[str(cfg["library_guid"])] = row
            occupied.extend((row.name, root) for root in (row.root_paths or []))

        try:
            async with client() as trim:
                await trim.ensure_login()
                remote = await trim.libraries()
        except TrimAuthError as exc:
            raise HTTPException(status_code=400, detail=f"飞牛登录失败：{exc}") from exc
        except TrimError as exc:
            raise HTTPException(status_code=502, detail=str(exc)) from exc

        result: list[dict] = []
        for lib in remote:
            local_dirs = []
            for remote_dir in lib.dir_list:
                local = map_remote_to_local(
                    remote_dir, settings.path_map_from, settings.path_map_to
                )
                if local and await asyncio.to_thread(os.path.isdir, local):
                    local_dirs.append(local)
            roots = pick_roots(local_dirs)
            row = mapped.get(lib.guid)
            conflict = None
            if roots:
                # 已接入的库不算跟自己的根冲突
                others = [(n, r) for (n, r) in occupied if not row or n != row.name]
                conflict = roots_conflict(roots, others)
            result.append(
                {
                    "guid": lib.guid,
                    "name": lib.name,
                    "category": lib.category,
                    "dirs": list(lib.dir_list),
                    "local_roots": roots,
                    "supported": lib.category in (CATEGORY_MOVIE, CATEGORY_TV),
                    "imported": row is not None,
                    "library_id": row.id if row else None,
                    "library_name": row.name if row else None,
                    "overlap": {"library": conflict[0], "root": conflict[1]} if conflict else None,
                }
            )
        return result

    @router.get(
        "/account",
        operation_id=f"plugins.{PLUGIN_ID}.account",
        summary="飞牛账号：当前登录账号、账号列表与权限档（管理员可见全部）",
    )
    async def account(refresh: bool = False) -> dict:
        """账号面板的数据源。

        飞牛只有这一套账号信息（``user/info`` / ``manager/user/list`` /
        ``manager/template/permission``），没有会员等级、下载额度这类字段——
        页面只展示接口真给的东西，别编概念。

        结果缓存 5 分钟：页面每次打开都拉一遍太浪费（账号信息几乎不变），
        点「刷新」时带 ``refresh=true`` 跳过缓存。
        """
        from datetime import UTC, datetime

        cache_key = "account:snapshot"
        if not refresh:
            cached = await store.get(cache_key)
            if isinstance(cached, dict) and cached.get("current"):
                return cached
        async with client() as trim:
            await trim.ensure_login()
            info = await trim.user_info()
            users = await trim.users()
            template = await trim.permission_template()

        def stamp(value: Any) -> str | None:
            """飞牛的 last_login_time 是 unix 秒；0 表示从没登录过。"""
            try:
                seconds = int(value or 0)
            except (TypeError, ValueError):
                return None
            if seconds <= 0:
                return None
            # 带 +00:00：前端按本地时区换算，别退化成「8 小时前」
            return datetime.fromtimestamp(seconds, UTC).isoformat()

        def compact(row: dict[str, Any]) -> dict[str, Any]:
            libraries = row.get("mediadb_list") or []
            return {
                "guid": row.get("guid"),
                "username": row.get("username") or "",
                "is_admin": bool(row.get("is_admin")),
                "media_permission": row.get("media_permission"),
                "library_count": len(libraries) if isinstance(libraries, list) else 0,
                "libraries": [
                    str(lib.get("title") or "")
                    for lib in (libraries if isinstance(libraries, list) else [])
                    if isinstance(lib, dict)
                ][:12],
                "last_login_at": stamp(row.get("last_login_time")),
                "sources": [
                    str(src.get("source_name") or src.get("source") or "")
                    for src in (row.get("sources") or [])
                    if isinstance(src, dict)
                ],
            }

        # /user/info 只给身份字段；可见库、权限档、最近登录在账号列表里。
        # 同一份数据不重复请求，按 guid 合并一次即可（当前账号也可能不是管理员）。
        by_guid = {str(row.get("guid")): row for row in users if row.get("guid")}
        current_row: dict[str, Any] = dict(by_guid.get(str(info.get("guid"))) or {})
        for key in ("guid", "username", "is_admin", "lan", "audio_lan", "sources"):
            if info.get(key) is not None:
                current_row[key] = info[key]

        snapshot = {
            "configured": True,
            "current": compact(current_row) if current_row else None,
            "users": [compact(row) for row in users],
            "is_admin": bool(info.get("is_admin")) if info else False,
            "template": {
                "media_permission": (template or {}).get("media_permission"),
                "library_count": len((template or {}).get("mediadb_list") or []),
            },
            "checked_at": _iso_now(),
        }
        await store.set(cache_key, snapshot)
        return snapshot

    @router.get(
        "/runtime-logs",
        operation_id=f"plugins.{PLUGIN_ID}.runtime-logs",
        summary="最近运行日志（按插件过滤，页面每几秒轮询一次）",
    )
    async def logs(limit: int = 200, keyword: str = "") -> dict:
        """返回最近 ``limit`` 条与本插件有关的日志，按时间从旧到新。

        只读主程序的按天日志文件尾部（``log_dir/movieclaw-YYYY-MM-DD.log``），
        今天不够就往昨天找。过滤口径是「这一行里有 trim-media-src」——
        插件自己的 logger、它排的定时任务、任务执行结果都会带上这个 id。
        """
        from datetime import datetime, timedelta

        from movieclaw_api.core.config import get_settings as _settings

        cfg = _settings()
        log_dir = os.path.abspath(str(getattr(cfg, "log_dir", "./data/logs")))
        want = max(1, min(int(limit or 200), 1000))
        needle = keyword.strip().lower() or PLUGIN_ID.lower()

        picked: list[dict[str, str]] = []
        today = datetime.now()
        for offset in range(0, 3):  # 今天、昨天、前天
            day = (today - timedelta(days=offset)).strftime("%Y-%m-%d")
            path = os.path.join(log_dir, f"movieclaw-{day}.log")
            if not os.path.isfile(path):
                continue
            lines = await asyncio.to_thread(_read_log_tail, path)
            hit: list[dict[str, str]] = []
            for line in reversed(lines):
                if needle not in line.lower():
                    continue
                parsed = _parse_log_line(line)
                if parsed:
                    hit.append(parsed)
            picked.extend(hit)
            if len(picked) >= want:
                break
        items = list(reversed(picked[:want]))
        return {"items": items, "count": len(items), "log_dir": log_dir}

    @router.post(
        "/test",
        operation_id=f"plugins.{PLUGIN_ID}.test",
        summary="测试连接：探测、登录、返回飞牛库列表",
    )
    async def test() -> dict:
        try:
            async with client() as trim:
                result = await trim.test()
                # 记下服务端 guid：建库、网页展示与播放定位都用它
                server_guid = (
                    result.get("server_guid") if isinstance(result, dict) else None
                ) or ""
                if server_guid:
                    await store.set("server_guid", server_guid)
                return result
        except TrimAuthError as exc:
            raise HTTPException(status_code=400, detail=f"登录失败：{exc}") from exc
        except TrimError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

    @router.post(
        "/create-library",
        operation_id=f"plugins.{PLUGIN_ID}.create-library",
        summary="建一个 source=trim 的库（飞牛库 → MovieClaw 库）",
    )
    async def create_library(body: dict) -> dict:
        """body: {name, kind: movie|tv, library_guid, library_name?, local_root?, server_guid?}"""
        name = str(body.get("name") or "").strip()
        kind = str(body.get("kind") or "").strip()
        guid = str(body.get("library_guid") or "").strip()
        if not name or kind not in ("movie", "tv") or not guid:
            raise HTTPException(status_code=400, detail="需要 name、kind（movie/tv）、library_guid")
        # 本机挂载路径填了就按「本机直连」建库：真实文件由主程序扫描入账、本地直出播放；
        # 留空则走远程模式（虚拟台账 + 插件取流端点）。
        local_root = str(body.get("local_root") or "").strip().rstrip("/")
        roots: list[str] = []
        if local_root:
            if not await asyncio.to_thread(os.path.isdir, local_root):
                raise HTTPException(
                    status_code=400,
                    detail=f"本机路径不存在：{local_root}（容器里看不到就留空走远程模式）",
                )
            roots = [local_root]
        db = get_database()
        async with db.session() as session:
            repo = LibraryRepository(session)
            existing = await repo.list_all()
            for row in existing:
                cfg = row.source_config or {}
                if row.source == SOURCE and cfg.get("library_guid") == guid:
                    raise HTTPException(status_code=409, detail=f"飞牛库已映射为「{row.name}」")
            if any(row.name == name for row in existing):
                raise HTTPException(status_code=409, detail=f"库名「{name}」已存在")
            if roots:
                conflict = roots_conflict(
                    roots,
                    [(row.name, root) for row in existing for root in (row.root_paths or [])],
                )
                if conflict is not None:
                    raise HTTPException(
                        status_code=409,
                        detail=f"目录与「{conflict[0]}」的 {conflict[1]} 重叠，平台不允许库根嵌套",
                    )
            # 与自动接入走同一个入口：名称/根路径校验、自动入库目录冲突检查、
            # 内置合集初始化与实时监控刷新都由它统一做（评审意见）。
            from movieclaw_api.services.library.config import LibraryConfigService

            try:
                row = await LibraryConfigService(session).create(
                    name=name,
                    kind=MediaKind(kind),
                    root_paths=roots,
                    source=SOURCE,
                    source_config={
                        "library_guid": guid,
                        "library_name": str(body.get("library_name") or name),
                        "local_root": local_root,
                        "server_url": settings.base_url,
                        "server_guid": str(body.get("server_guid") or "trim"),
                    },
                    realtime_watch=bool(roots),
                    generate_thumbnails=bool(roots),  # 本机可见才抓帧；远程留给飞牛自己
                )
            except Exception as exc:  # noqa: BLE001 -- 交给调用方看清原因
                await session.rollback()
                raise HTTPException(status_code=400, detail=f"建库失败：{exc}") from exc
            lib_id = row.id
        ref = await jobs.create(SYNC_JOB_TYPE, input={}, dedupe_key="all")
        return {"library_id": lib_id, "sync_job": ref.id, "created": ref.created}

    @router.get(
        "/play/{item_guid}",
        operation_id=f"plugins.{PLUGIN_ID}.play",
        summary="飞牛条目的播放出口：换出直链 302（远程模式下 .video 台账行的取流）",
    )
    async def play(item_guid: str) -> Any:
        """换飞牛直链并 302。直链有时效，每次现取。

        本机可见模式用不到这个端点（播放器直接读本地文件）。
        """
        from fastapi.responses import RedirectResponse

        try:
            async with client() as trim:
                await trim.ensure_login()
                link = await trim.play_link(item_guid)
        except TrimAuthError as exc:
            raise HTTPException(status_code=502, detail=f"飞牛登录失败：{exc}") from exc
        except TrimError as exc:
            raise HTTPException(status_code=502, detail=f"取飞牛直链失败：{exc}") from exc
        return RedirectResponse(link.url, status_code=302)

    @router.post(
        "/align",
        operation_id=f"plugins.{PLUGIN_ID}.align",
        summary="库对齐：先看飞牛条目与 MC 已有识别成果的匹配情况（apply=false 只出报告）",
    )
    async def align_libraries(body: dict) -> dict:
        """body: {library_id?: int, apply?: bool}

        三级匹配：L1 TMDB / L2 同一文件 / L3 标题年份；都没命中的进「待识别」清单。
        ``apply=false``（默认）只读，产出报告不写任何数据。
        """
        from sqlmodel import select

        target = body.get("library_id")
        do_apply = bool(body.get("apply"))
        db = get_database()
        reports: list[dict] = []
        async with db.session() as session:
            query = select(Library).where(Library.source == SOURCE)
            if target:
                query = query.where(Library.id == int(target))
            rows = (await session.execute(query)).scalars().all()
            if not rows:
                raise HTTPException(status_code=404, detail="没有找到飞牛来源的库")
            for library in rows:
                report = AlignReport(library=library.name, library_id=library.id or 0)
                config = library.source_config or {}
                guid = str(config.get("library_guid") or "")
                if not guid:
                    report.errors.append("source_config 缺少 library_guid")
                    reports.append(report.as_dict())
                    continue
                try:
                    async with client() as trim:
                        await trim.ensure_login()
                        entries = await inventory(
                            trim, library_guid=guid, kind=library.kind, log=log
                        )
                        report.trim_entries = len(entries)
                        await enrich_file_info(trim, entries, log=log)
                        l1, l2, l3, unmatched = await match(
                            session, entries,
                            library_id=library.id or 0,
                            path_map=(settings.path_map_from, settings.path_map_to),
                        )
                        report.l1_tmdb = len(l1.entries)
                        report.l2_file = len(l2.entries)
                        report.l3_title = len(l3.entries)
                        report.unmatched = len(unmatched)
                        report.unmatched_titles = [
                            f"{e.title or e.original_title or e.guid}"
                            + (f" ({e.year})" if e.year else "")
                            for e in unmatched
                        ]
                        report.reusable_files = await count_reusable_files(
                            session, library_id=library.id or 0
                        )
                        if do_apply:
                            path_map = (settings.path_map_from, settings.path_map_to)
                            # 1) L2/L3 命中的：补台账行挂已有身份，扫描时跳过识别
                            linked = await apply_matched(
                                session, l2.entries + l3.entries,
                                library_id=library.id or 0, path_map=path_map, log=log,
                            )
                            report.applied["linked"] = linked
                            # 2) 文件级数据（规格/片头片尾）按同一文件搬过来
                            stats = await apply_reuse(session, library_id=library.id or 0, log=log)
                            report.applied.update(stats)
                            # 3) 都没命中的：建临时身份 + 待识别标记，交给用户认领
                            added = await apply_unmatched(
                                session, unmatched,
                                library_id=library.id or 0, kind=library.kind,
                                path_map=path_map, log=log,
                            )
                            report.applied["unidentified_added"] = added
                except (TrimAuthError, TrimError) as exc:
                    report.errors.append(f"飞牛接口失败：{exc}")
                except Exception as exc:  # noqa: BLE001 -- 单个库失败不影响其他库
                    log.warning("库「%s」对齐失败：%s", library.name, exc)
                    report.errors.append(f"{type(exc).__name__}: {exc}")
                reports.append(report.as_dict())
                log.info("库「%s」对齐完成：%s", library.name, report.as_dict())
        return {"applied": do_apply, "libraries": reports}

    @router.post(
        "/sync-now",
        operation_id=f"plugins.{PLUGIN_ID}.sync-now",
        summary="立即同步全部 source=trim 的库",
    )
    async def sync_now() -> dict:
        ref = await jobs.create(SYNC_JOB_TYPE, input={}, dedupe_key="all")
        return {"job_id": ref.id, "created": ref.created}

    routes.mount(ctx, router)

    # 启动后补一次同步（防数据过期），但必须让开启动窗口：
    # 主程序启动时要跑迁移、建索引、起各领域插件，此时插进来一次几千条的全量同步
    # 会拖住启动（实测把启动拖到了超时阈值，主程序判定"上次没稳定运行"进安全模式），
    # 也会和扫描抢数据库写锁。所以延后 5 分钟，并且距上次同步不足 1 小时就不跑。
    async def startup_sync() -> None:
        import time as _time

        await asyncio.sleep(300)
        try:
            last = int(await store.get("last_sync_ts") or 0)
            if _time.time() - last < 3600:
                log.info("距上次同步不到一小时，启动补同步跳过")
                return
            await sync_all()
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001 -- 启动补同步失败不影响运行
            log.warning("启动补同步失败（下次定时任务会重试）：%s", exc)

    ctx.task(startup_sync(), name="startup-sync")

    # ---- 观看进度：事件驱动（MC → 飞牛）+ 轮询（飞牛 → MC）----------------
    #: 成员名 → 成员 id 的小缓存（事件与轮询都查，没必要每次都打库）
    _member_cache: dict[str, Any] = {"at": 0.0, "id": 0}

    async def target_member_id() -> int:
        """配置里的「这个飞牛账号对应哪个成员」→ 成员 id；超管是 0。

        飞牛的观看进度是按飞牛账号存的，MovieClaw 这边是按成员存的。不建立这个
        对应关系，全家的进度会一起写进插件配置的那个飞牛账号，而拉回来时又都算到
        超管头上（评审指出的串号问题）。
        """
        name = settings.member_username.strip()
        if not name:
            return 0
        import time as _time

        now = _time.monotonic()
        if now - float(_member_cache.get("at") or 0.0) < 300:
            return int(_member_cache.get("id") or 0)
        member_id = 0
        try:
            from movieclaw_api.services.auth import get_admin_account
            from movieclaw_db.models import Member

            admin = await get_admin_account()
            if admin and (admin.username or "").lower() == name.lower():
                member_id = 0  # 超管不在 member 表里
            else:
                db2 = get_database()
                async with db2.session() as session:
                    row = (
                        await session.execute(
                            select(Member).where(Member.username == name)
                        )
                    ).scalars().first()
                if row is None or row.id is None:
                    log.warning(
                        "插件设置的成员「%s」在 MovieClaw 里不存在，进度按超管处理", name
                    )
                else:
                    member_id = int(row.id)
        except Exception as exc:  # noqa: BLE001 -- 查不到就按超管，不影响同步
            log.debug("解析成员 %s 失败（按超管处理）：%s", name, exc)
        _member_cache["at"] = now
        _member_cache["id"] = member_id
        return member_id

    def library_kind_of(tmdb_kind: str) -> str:
        return "movie" if tmdb_kind == "movie" else "tv"

    async def on_playback(payload: Any, *, force: bool) -> None:
        if not settings.sync_progress:
            return
        note_activity()  # 有人在看片：让进度轮询临时加速
        try:
            await handle_playback_event(
                payload=payload,
                client_factory=client,
                log=log,
                force=force,
                member_id=await target_member_id(),
            )
        except Exception as exc:  # noqa: BLE001 -- 事件处理失败不影响播放
            log.debug("播放事件同步进度失败：%s", exc)

    async def on_progress(payload: Any) -> None:
        await on_playback(payload, force=False)

    async def on_stopped(payload: Any) -> None:
        await on_playback(payload, force=True)

    async def on_completed(payload: Any) -> None:
        await on_playback(payload, force=True)

    ctx.on(PLAYBACK_PROGRESS, on_progress)
    ctx.on(PLAYBACK_STOPPED, on_stopped)
    ctx.on(PLAYBACK_COMPLETED, on_completed)

    async def pull_progress_task() -> None:
        """飞牛 → MC 的进度同步。

        周期在「设置 → 定时任务」里调（主程序限最低 60 秒）。如果 MC 这边刚有播放
        活动，说明用户正在看片，这个任务会在本次执行里每 5 秒补拉一轮（最多约 1 分钟），
        让进度看起来是实时的；静默 2 分钟后自动停回常态。
        """
        if not settings.sync_progress:
            return
        trim = client()
        try:
            await trim.ensure_login()
            member_id = await target_member_id()
            await pull_tick(trim=trim, ops=ops, log=log, member_id=member_id)
            rounds = 0
            while rounds < _FAST_ROUNDS and activity_recent():
                await asyncio.sleep(_FAST_INTERVAL)
                await pull_tick(trim=trim, ops=ops, log=log, member_id=member_id)
                rounds += 1
        finally:
            await trim.close()

    ctx.contribute(SCHEDULED_TASKS, "pull-progress", TaskDefinition(
        key=f"{PLUGIN_ID}.pull-progress", title="同步飞牛观看进度",
        description="把飞牛「继续观看」里的真实进度写回 MovieClaw（两边都有的片才同步）",
        handler=pull_progress_task,
        default_trigger_type=TriggerType.INTERVAL, default_interval_seconds=60,
        default_enabled=True,
    ))

    log.info("飞牛影视库源已加载（source=%s）", SOURCE)

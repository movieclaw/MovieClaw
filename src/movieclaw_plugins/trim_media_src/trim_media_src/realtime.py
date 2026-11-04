"""实时进度同步：让「飞牛里看的」和「MC 里看的」进度几乎立刻互相看见。

两个方向：

**MC → 飞牛（事件驱动，近实时）**
    订阅 MC 的播放事件（进度/停止/看完），把位置写给飞牛的 ``play/record``。
    - 进度事件本身每集最多 30 秒一条，这里再加一道 20 秒节流：同一文件 20 秒内
      只写一次（飞牛是家用 NAS，不能按事件频率打）；
    - 停止 / 看完事件**不节流**——这两个是用户真正离开或看毕的时刻，必须准。

**飞牛 → MC（轮询，3 分钟）**
    拉飞牛的「继续观看」列表（十几条），逐条取条目详情的真实进度，再交给主程序的
    **``playback.sync.state``** 写回（不自己动 PlaybackState 表——那个接口做了
    成员可见性、compare-and-set 与事件抑制，重复实现只会引入不一致）。
    实测 ``/play/list`` 自带的 ``watched_ts`` 恒为 0，真实进度只在条目详情里，
    所以候选集用 play/list、数值用 ``/item/{guid}``。

映射关系：两侧靠 **(TMDB id, 季号, 集号)** 收敛。事件里给的是 ``media_item_id``，
先查 media_item 拿 tmdb_id，再查缓存好的「飞牛条目索引」。索引在同步/对齐时构建，
缺失时按需重建一次。
"""

from __future__ import annotations

import asyncio
import time
from typing import Any

#: 同一文件的进度写入最小间隔（秒）
_PROGRESS_MIN_GAP = 20.0
#: (library_id) → {(tmdb_id, season, episode): 飞牛条目 guid}
_INDEX: dict[int, dict[tuple[int, int, int], str]] = {}
#: (library_id) → {(tmdb_id, 季号): 飞牛季 guid}
_SEASON_INDEX: dict[int, dict[tuple[int, int], str]] = {}
#: 索引构建时间，用于判断要不要重建
_INDEX_AT: dict[int, float] = {}
#: 每个飞牛 guid 上次写进度的时间（节流用）
_LAST_WRITE: dict[str, float] = {}
#: 每轮只查前 N 条详情（见 pull_tick）。轮询周期由「定时任务」配置，不在代码里写死。
#:
#: 加速窗口：定时任务按用户配置的周期跑（默认 60 秒）；但如果 MC 刚有播放活动，
#: 说明用户正在看片，这时把间隔压到 5 秒补拉几轮，让「飞牛里看完 → MC 跟上」
#: 感觉是实时的。静默 2 分钟后自动停回常态，不做无意义的空转。
_FAST_INTERVAL = 5.0
_FAST_WINDOW = 120.0
_FAST_ROUNDS = 12  # 单次任务最多补 12 轮（约 1 分钟），下个周期再判断
_LAST_ACTIVITY = 0.0
#: 每轮只查前 N 条的详情。play/list 是按最近观看排序的，正在看的就在最前面；
#: 全量查 15 条详情要 168ms，只查前 5 条只要一半，10 秒一轮的总成本再降一半。
_DETAIL_LIMIT = 5


async def build_indexes(
    trim: Any, *, library_guid: str, kind: str, log: Any
) -> tuple[dict[tuple[int, int, int], str], dict[tuple[int, int], str]]:
    """从飞牛拉一遍条目，一次产出两份索引：

    - ``(tmdb, 季, 集) → 集 guid``：播放事件定位用；
    - ``(tmdb, 季) → 季 guid``：写片头片尾用（飞牛只认季级配置）。

    走的是同一个「剧 → 季 → 集」遍历，所以顺路把季 guid 收下来，不多发请求。
    """
    from .trim_api import TYPE_MOVIE, TYPE_TV

    episodes_map: dict[tuple[int, int, int], str] = {}
    seasons_map: dict[tuple[int, int], str] = {}
    try:
        top = await trim.all_items(library_guid)
    except Exception as exc:  # noqa: BLE001 -- 建索引失败就当没有（事件侧会跳过）
        log.warning("构建飞牛条目索引失败：%s", exc)
        return episodes_map, seasons_map
    if kind == "movie":
        for item in top:
            if item.type == TYPE_MOVIE and item.guid and item.tmdb_id:
                episodes_map[(int(item.tmdb_id), 0, 0)] = item.guid
        return episodes_map, seasons_map
    for tv in [i for i in top if i.type == TYPE_TV and i.guid and i.tmdb_id]:
        tv_tmdb = int(tv.tmdb_id)
        try:
            seasons = await trim.seasons(tv.guid)
        except Exception:  # noqa: BLE001 -- 单部剧失败不影响其他
            continue
        for season in seasons:
            if not season.guid or season.season_number is None:
                continue
            seasons_map[(tv_tmdb, int(season.season_number))] = season.guid
            try:
                episodes = await trim.episodes(season.guid)
            except Exception:  # noqa: BLE001 -- 单季失败不影响其他
                continue
            for ep in episodes:
                tmdb = ep.tmdb_id or tv_tmdb
                if not tmdb or ep.episode_number is None:
                    continue
                key = (int(tmdb), int(season.season_number), int(ep.episode_number))
                episodes_map[key] = ep.guid
    return episodes_map, seasons_map


async def build_index(
    trim: Any, *, library_guid: str, kind: str, log: Any
) -> dict[tuple[int, int, int], str]:
    """只要「集索引」（播放事件定位用）。"""
    return (await build_indexes(trim, library_guid=library_guid, kind=kind, log=log))[0]


async def ensure_index(
    trim: Any, *, library_id: int, config: dict, kind: str, log: Any, max_age: float = 1800.0
) -> dict[tuple[int, int, int], str]:
    """取（必要时重建）某库的飞牛条目索引。"""
    now = time.monotonic()
    cached = _INDEX.get(library_id)
    if cached is not None and now - _INDEX_AT.get(library_id, 0) < max_age:
        return cached
    guid = str((config or {}).get("library_guid") or "")
    if not guid:
        return {}
    mapping, seasons = await build_indexes(trim, library_guid=guid, kind=kind, log=log)
    _INDEX[library_id] = mapping
    _SEASON_INDEX[library_id] = seasons
    _INDEX_AT[library_id] = now
    log.info("飞牛条目索引已建立：库 #%s，%d 集 / %d 季", library_id, len(mapping), len(seasons))
    return mapping


async def ensure_season_index(
    trim: Any, *, library_id: int, config: dict, kind: str, log: Any, max_age: float = 1800.0
) -> dict[tuple[int, int], str]:
    """取（必要时重建）某库的「季索引」：``(tmdb, 季) → 季 guid``。"""
    now = time.monotonic()
    cached = _SEASON_INDEX.get(library_id)
    if cached is not None and now - _INDEX_AT.get(library_id, 0) < max_age:
        return cached
    await ensure_index(
        trim, library_id=library_id, config=config, kind=kind, log=log, max_age=max_age
    )
    return _SEASON_INDEX.get(library_id, {})


def forget_index(library_id: int) -> None:
    _INDEX.pop(library_id, None)
    _SEASON_INDEX.pop(library_id, None)
    _INDEX_AT.pop(library_id, None)


async def push_one(
    trim: Any,
    *,
    item_guid: str,
    position_ms: int,
    played: bool,
    force: bool = False,
    log: Any,
) -> bool:
    """把一条进度写给飞牛；节流窗口内跳过（``force`` 用于停止/看完）。"""
    now = time.monotonic()
    last = _LAST_WRITE.get(item_guid, 0.0)
    if not force and now - last < _PROGRESS_MIN_GAP:
        return False
    try:
        await trim.record_progress(
            item_guid, ts=max(0, int(position_ms) // 1000), watched=1 if played else 0
        )
        _LAST_WRITE[item_guid] = now
        return True
    except Exception as exc:  # noqa: BLE001 -- 单条失败记日志，下一条继续
        log.warning("写飞牛观看进度失败（%s）：%s", item_guid, exc)
        return False


#: (tmdb_id, season, episode) → 飞牛 guid 的解析缓存（按标题搜到的结果）
_RESOLVED: dict[tuple[int, int, int], str | None] = {}


async def resolve_guid(
    trim: Any, *, tmdb_id: int, title: str, season: int = 0, episode: int = 0, log: Any
) -> str | None:
    """MC 的条目 → 飞牛条目 guid：按标题搜索，再用 TMDB 号核对。

    为什么不用「已接入库的索引」：用户看的片可能属于某个**没接入的飞牛库**
    （与 MC 自有库路径重叠、自动接入时被跳过的那些），索引里根本没有它。
    搜索接口不限库，按 trim_id 核对又足够严，是唯一不依赖库接入的定位方式。

    结果按 (TMDB, 季, 集) 缓存：命中过就不再搜。
    """
    key = (int(tmdb_id), int(season), int(episode))
    if key in _RESOLVED:
        return _RESOLVED[key]
    if not title:
        return None
    try:
        rows = await trim._request("GET", "/search/list", params={"q": title})
    except Exception as exc:  # noqa: BLE001 -- 搜索失败就当这次没找到
        log.debug("飞牛搜索失败（%s）：%s", title, exc)
        return None
    for row in rows or []:
        trim_id = str(row.get("trim_id") or "")
        if trim_id[:2] not in ("tm", "tt") or not trim_id[2:].isdigit():
            continue
        if int(trim_id[2:]) != int(tmdb_id):
            continue  # 同名不同片：以 TMDB 号为准
        guid = row.get("guid")
        row_type = str(row.get("type") or "")
        if not guid:
            continue
        if episode:
            # 剧集：搜到的是剧本体，还要按季集找到具体那一集
            try:
                seasons = await trim.seasons(str(guid))
                for s in seasons:
                    if int(s.season_number or 0) != int(season):
                        continue
                    for ep in await trim.episodes(s.guid):
                        if int(ep.episode_number or 0) == int(episode):
                            _RESOLVED[key] = ep.guid
                            return ep.guid
            except Exception:  # noqa: BLE001
                return None
            return None
        if row_type in ("Movie", "Video"):
            _RESOLVED[key] = str(guid)
            return str(guid)
    _RESOLVED[key] = None
    return None


async def handle_playback_event(
    *,
    payload: Any,
    libraries: list[tuple[int, str, dict]],
    client_factory: Any,
    log: Any,
    force: bool,
    member_id: int = 0,
) -> int:
    """处理一次播放事件：定位到飞牛条目后写进度。

    :param libraries: [(library_id, kind, source_config)] —— 该用户可见的飞牛库
    :param force: 停止 / 看完事件不节流
    :param member_id: 这个飞牛账号对应的 MovieClaw 成员（超管为 0）。
        只有这个成员的事件会写进飞牛——飞牛的进度是按飞牛账号存的，
        把全家人的进度都写进同一个账号，家人看过的片会在超管那边显示已看。
    """
    who = int(getattr(payload, "member_id", 0) or 0)
    if who != member_id:
        log.debug("成员 %s 的播放进度不写飞牛（只同步成员 %s）", who, member_id)
        return 0
    position_ms = getattr(payload, "position_ms", None)
    if position_ms is None:
        return 0
    media = getattr(payload, "media", None)
    media_item_id = getattr(media, "id", None) if media is not None else None
    if media_item_id is None:
        return 0
    unit = getattr(payload, "unit", None)
    # UnitRef 的字段名是 season / episode（不是 season_number / episode_number）。
    # 取错名字会一直拿到 0，剧集就被当成电影去飞牛里找，永远找不到 —— 实测踩过。
    season = int(getattr(unit, "season", 0) or 0) if unit is not None else 0
    episode = int(getattr(unit, "episode", 0) or 0) if unit is not None else 0
    played = bool(getattr(payload, "played", False))

    from movieclaw_db.engine import get_database
    from movieclaw_db.models import MediaItem

    db = get_database()
    async with db.session() as session:
        item = await session.get(MediaItem, media_item_id)
        if item is None or item.tmdb_id is None:
            return 0
        # 在 session 内把要用的字段取出来：出了这个块 ORM 对象就 detached，
        # 再访问属性会抛 MissingGreenlet
        tmdb_id = int(item.tmdb_id)
        item_title = str(item.title or "")

    log.info(
        "收到播放事件：media_item=%s tmdb=%s S%sE%s position=%sms played=%s force=%s",
        media_item_id, tmdb_id, season, episode, position_ms, played, force,
    )
    written = 0
    async with client_factory() as trim:
        await trim.ensure_login()
        guid = await resolve_guid(
            trim, tmdb_id=tmdb_id, title=item_title, season=season, episode=episode, log=log
        )
        if guid is None:
            log.info("飞牛里找不到这部（TMDB %s《%s》），跳过进度回写", tmdb_id, item_title)
            return 0
        log.info("定位到飞牛条目：%s（《%s》）", guid, item_title)
        if await push_one(
            trim, item_guid=guid, position_ms=position_ms,
            played=played, force=force, log=log,
        ):
            written = 1
            log.info("已把进度写进飞牛：%s → %ds", item_title, int(position_ms) // 1000)
        else:
            log.info("跳过写入（%ss 节流窗口内）：%s", _PROGRESS_MIN_GAP, item_title)
    return written


async def pull_tick(
    *,
    trim: Any,
    ops: Any,
    log: Any,
    member_id: int = 0,
) -> int:
    """飞牛 → MC：拉「继续观看」，把真实进度交给主程序的 ``playback.sync.state``。

    **不按「库是否接入」过滤**：飞牛条目自带 TMDB 编号（``trim_id``），直接用它
    匹配 MC 的 media_item 就够了。早先版本只认「已接入的飞牛库」，结果用户在
    飞牛里看的是未接入的库（例如与 MC 自有库路径重叠、自动接入时被跳过的
    MC_电影 / MC_剧集）时，进度就悄悄丢了。

    也不自己写 ``PlaybackState``：那个接口带成员可见性、compare-and-set
    （``expected_updated_at``）与事件抑制，重复实现只会让两边版本号打架。
    """
    from datetime import UTC

    from sqlmodel import select

    from movieclaw_db.engine import get_database
    from movieclaw_db.models import MediaItem, PlaybackState

    applied = 0
    db = get_database()
    async with db.session() as session:
        # 「继续观看」是全局的，不分库：一次拉完，逐条问详情拿真实进度。
        # 客户端由 pull_loop 持有并复用（见那里的说明），这里不重复登录。
        try:
            rows = await trim._request("GET", "/play/list") or []
        except Exception as exc:  # noqa: BLE001
            log.warning("拉飞牛继续观看列表失败：%s", exc)
            return 0

        changes: list[dict[str, Any]] = []
        # 只取前 N 条查详情：列表按最近观看排序，正在看的在最前面
        for row in rows[:_DETAIL_LIMIT]:
            guid = row.get("guid")
            if not guid:
                continue
            try:
                detail = await trim._request("GET", f"/item/{guid}") or {}
            except Exception:  # noqa: BLE001
                continue
            ts = int(detail.get("watched_ts") or 0)
            watched = bool(detail.get("is_watched"))
            if ts <= 0 and not watched:
                continue
            # trim_id = "tm1242898" / "tt31227572"：去前缀即 TMDB 编号
            trim_id = str(detail.get("trim_id") or "")
            tmdb_id = (
                int(trim_id[2:])
                if trim_id[:2] in ("tm", "tt") and trim_id[2:].isdigit()
                else None
            )
            if not tmdb_id:
                continue
            item_type = str(detail.get("type") or "")
            kind = "movie" if item_type == "Movie" else "tv"
            season = int(detail.get("season_number") or 0)
            episode = int(detail.get("episode_number") or 0)
            if kind == "tv" and episode <= 0:
                continue
            item = (
                await session.execute(
                    select(MediaItem).where(
                        MediaItem.tmdb_id == tmdb_id, MediaItem.kind == kind
                    )
                )
            ).scalars().first()
            if item is None or item.id is None:
                continue
            state = (
                await session.execute(
                    select(PlaybackState).where(
                        PlaybackState.member_id == member_id,
                        PlaybackState.media_item_id == item.id,
                        PlaybackState.season_number == season,
                        PlaybackState.episode_number == episode,
                    )
                )
            ).scalars().first()
            # 冲突处理：允许回拖和重看，只在「MC 已经看完、飞牛还没看完」时不让倒退
            # （那是两边不同步的旧状态，写回去会把人拉回未看完）。
            # 位置靠前靠后都以飞牛为准——飞牛是用户刚才真正在用的那个播放器。
            if state is not None:
                if state.played and not watched:
                    continue
                # 值完全没变就别发请求：飞牛那边在看的进度几秒才动一次，
                # 每轮都发既浪费，也会让 apply_state 每条都 touch 一遍
                if state.played == watched and abs(state.position_ms - ts * 1000) <= 1000:
                    continue
            change: dict[str, Any] = {
                "media_item_id": int(item.id),
                "kind": kind,
                "tmdb_id": int(tmdb_id),
                # 数据库里的 datetime 是**朴素 UTC**（无 tzinfo）。直接
                # ``astimezone(UTC)`` 会把它当本地时间再减 8 小时，接口那边的
                # compare-and-set 就对不上、每次都判 conflict（实测踩过）。
                # 朴素值按 UTC 理解，有 tzinfo 的才做转换。
                "expected_updated_at": _iso_utc(
                    state.updated_at if state is not None else None
                ),
                "played": watched,
            }
            if not watched and ts > 0:
                change["position_ms"] = ts * 1000
            # 观看时间只在新记录时给，**已有的必须原样保留**：
            # 每轮都写「现在」的话，按 last_played_at 排序的「最近观看」会被
            # 轮询反复重排（用户真的会看到列表在跳、记录像被挤没了）。
            # 飞牛不提供观看时刻，拿不到就沿用 MC 已有的值。
            from datetime import datetime as _dt

            if state is not None and state.last_played_at is not None:
                change["last_played_at"] = _iso_utc(state.last_played_at)
            else:
                change["last_played_at"] = _dt.now(UTC).isoformat()
            if kind == "movie":
                change.update(season=0, episode=0)
            else:
                change.update(season=season, episode=episode)
            changes.append(change)

        if not changes:
            return 0
        # 主程序的接口一次最多 100 条
        for start in range(0, len(changes), 100):
            batch = changes[start : start + 100]
            result = await ops.call(
                "playback.sync.state",
                {"member_id": member_id, "changes": batch},
            )
            # 接口逐条给结论：applied / unchanged / conflict / mismatch / not_found
            outcomes = (result or {}).get("outcomes") or []
            for outcome in outcomes:
                status = str((outcome or {}).get("status") or "")
                if status == "applied":
                    applied += 1
                elif status and status != "unchanged":
                    log.info("进度写回被跳过（%s）：可能是版本冲突或身份不匹配", status)
            if not outcomes:
                applied += len(batch)
    if applied:
        log.info("从飞牛拉回观看进度：%d 条", applied)
    return applied


def note_activity() -> None:
    """登记「MC 这边刚有播放动作」，供定时任务决定要不要加速轮询。"""
    global _LAST_ACTIVITY
    _LAST_ACTIVITY = time.monotonic()


def activity_recent() -> bool:
    """最近 ``_FAST_WINDOW`` 秒内有没有播放活动。"""
    return time.monotonic() - _LAST_ACTIVITY < _FAST_WINDOW


def _iso_utc(value: Any) -> str | None:
    """数据库里的朴素 datetime（UTC）→ 带时区的 ISO 字符串。"""
    from datetime import UTC, datetime

    if value is None:
        return None
    if isinstance(value, str):
        try:
            value = datetime.fromisoformat(value)
        except ValueError:
            return None
    if getattr(value, "tzinfo", None) is None:
        return value.replace(tzinfo=UTC).isoformat()
    return value.astimezone(UTC).isoformat()


def _key_by_guid(index: dict[tuple[int, int, int], str], guid: Any) -> tuple[int, int, int] | None:
    """反向查：飞牛 guid → (tmdb, 季, 集)。"""
    if not guid:
        return None
    target = str(guid)
    for key, value in index.items():
        if value == target:
            return key
    return None


async def push_markers(
    trim: Any,
    *,
    rows: list[tuple[str, int, int, str]],
    state: dict[str, Any],
    log: Any,
    max_writes: int = 400,
) -> dict[str, int]:
    """把 MC 识别出的片头片尾写进飞牛（``skip_opening`` / ``skip_ending`` 秒）。

    这一项主程序没有对应能力（是飞牛特有的配置），所以留在插件里；
    但换算与去重都按最省的方式做：值没变就不调接口。
    """
    written = skipped = failed = 0
    for guid, skip_opening, skip_ending, label in rows:
        if written >= max_writes:
            break
        prev = state.get(guid)
        if (
            isinstance(prev, (list, tuple))
            and len(prev) == 2
            and int(prev[0]) == skip_opening
            and int(prev[1]) == skip_ending
        ):
            skipped += 1
            continue
        try:
            await trim.set_play_config(guid, skip_opening, skip_ending)
            state[guid] = [skip_opening, skip_ending]
            written += 1
            log.info(
                "飞牛片头片尾已写：%s（片头 %ds / 片尾 %ds）", label, skip_opening, skip_ending
            )
        except Exception as exc:  # noqa: BLE001 -- 单条失败不影响其他
            failed += 1
            log.warning("写飞牛片头片尾失败（%s）：%s", label, exc)
        await asyncio.sleep(0.12)  # 家用 NAS：别按接口上限打
    return {"written": written, "skipped": skipped, "failed": failed}


def skip_values_from_segments(segments: Any, duration_seconds: Any) -> tuple[int, int] | None:
    """MovieClaw 的片头片尾结论 → 飞牛的 (skip_opening, skip_ending) 秒。

    - ``skip_opening``：片头结束时刻（跳过多少秒）；
    - ``skip_ending``：片尾开始时刻距结尾还有多少秒。

    没有结论返回 None（不写，避免把飞牛已有配置覆盖成 0）；
    荒谬值（片头 >10 分钟、片尾 >15 分钟）当识别噪声丢掉。
    """
    import json as _json

    if not segments:
        return None
    try:
        items = _json.loads(segments) if isinstance(segments, str) else segments
    except (TypeError, ValueError):
        return None
    if not isinstance(items, (list, tuple)) or not items:
        return None
    intro_end_ms = None
    outro_start_ms = None
    for seg in items:
        if not isinstance(seg, dict):
            continue
        if seg.get("type") == "intro" and seg.get("end_ms"):
            intro_end_ms = int(seg["end_ms"])
        elif seg.get("type") == "outro" and seg.get("start_ms") is not None:
            outro_start_ms = int(seg["start_ms"])
    skip_opening = int(intro_end_ms // 1000) if intro_end_ms else 0
    skip_ending = 0
    if outro_start_ms is not None and duration_seconds:
        dur_ms = int(float(duration_seconds) * 1000)
        if 0 < outro_start_ms < dur_ms:
            skip_ending = int((dur_ms - outro_start_ms) // 1000)
    if skip_opening <= 0 and skip_ending <= 0:
        return None
    if skip_opening > 600 or skip_ending > 900:
        return None
    return skip_opening, skip_ending

"""播放日志的读侧：活动页「播放记录」与「观看统计」（docs/design/activity.md）。

数据全部来自 ``playback_log``（写侧在 services/playback/watch.py）。两个口径：

- 播放记录：每场一行，按开始时间倒序；片名与海报走活动页同一套可见范围
  折叠（范围外只报个数）；
- 观看统计：一段时间内的播放次数、观看时长、看完次数、活跃成员，以及按成员 /
  按客户端 / 按天 / 按作品的分解。聚合在 Python 里做——家庭服务器几十天的日志
  也就几千行，比跨方言的 SQL 分组省心，且按天分组要用浏览器时区。统计的单位
  是「一次观看」（:class:`_Viewing`：续播接着看的几行合成一场），只统计算一场的
  观看；播放记录则每行照列。

没收到停止的行（播放器异常退出）按「最后一次心跳超过会话保鲜期」视为已结束，
结束时间取最后一次心跳；仍在保鲜期内的视为进行中。
"""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Iterator
from dataclasses import dataclass, field
from datetime import datetime, timedelta

from sqlalchemy import and_, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.schemas.playback import (
    MediaActivityTarget,
    PlaybackHistoryView,
    PlaybackLogEntryView,
    PlaybackStatsClientRow,
    PlaybackStatsDayRow,
    PlaybackStatsMemberRow,
    PlaybackStatsTierRow,
    PlaybackStatsTitleRow,
    PlaybackStatsTotals,
    PlaybackWatchStatsView,
)
from movieclaw_api.services.playback_activity import (
    VisibilityScope,
    _load_unit_contexts,
    _member_names,
    _target,
    libraries_by_item,
)
from movieclaw_api.services.playback_up_next import _progress_percent
from movieclaw_db.models import PlaybackLog, PlaybackMetric
from movieclaw_db.models.base import utcnow
from movieclaw_media.models import MediaKind
from movieclaw_playback import activity
from movieclaw_playback.progress import MAX_RESUME_PCT, MIN_RESUME_PCT
from movieclaw_playback.state import Unit

#: 顶部作品榜的长度
_TOP_TITLES = 10

#: 一场播放计入统计的最低实际观看时长。点开就退、试播挑版本、拖进度条看一眼都会
#: 记一行日志——NAS 实测三十天 1281 行里 823 行不足一分钟、264 行是 0 秒；把它们
#: 算成「场次」，场次被放大近三倍、看完率被稀释，「看过的人数」也被一个点开两秒的
#: 成员抬高（最受欢迎冠军总共只看了 11 秒）。
MIN_PLAY_WATCHED_MS = 60_000


#: 续播合并：同一成员同一集，新的一行从上一行停下的位置（容差内）接着播、且间隔
#: 不超过这么久，算同一次观看。NAS 上 461 场里 122 场是接着上一场续播的，间隔中位
#: 8 分钟（退到后台、换设备、暂停太久都会拆行）；三小时覆盖「吃完饭回来接着看」，
#: 又不会把「今早接着看昨晚那部」并进去，也不像按自然日那样在零点硬切。
_RESUME_GAP = timedelta(hours=3)
_RESUME_POSITION_SLACK_MS = 60_000


def _reached_end(row: PlaybackLog, duration_ms: int | None) -> bool:
    """这一行播进了片尾区：与续播阈值同一把尺；片长未知时退回写侧的已看翻转标记。"""
    return row.completed or bool(
        duration_ms
        and (
            row.end_position_ms * 100 >= duration_ms * MAX_RESUME_PCT
            or row.end_position_ms >= duration_ms - 1000
        )
    )


def _watched_through(watched_ms: int, span_ms: int) -> bool:
    """实际观看至少覆盖播放跨度的三分之一：跳片头片尾、两三倍速都过得去，看五分钟就
    拖到结尾过不去。"""
    return watched_ms > 0 and watched_ms * 3 >= span_ms


def finished(row: PlaybackLog, duration_ms: int | None) -> bool:
    """这一行有没有看完：播进了片尾区，而且是看过去的、不是拖过去的。

    不能直接用写侧的 ``completed``：它记的是「已看在这一场翻转」，重看一部已看过的
    片子看到结尾永远不会翻转（NAS 上播到片尾的 148 行有 40 行因此没算看完）；反过来
    从开头直接拖到片尾也会翻转（30 天里 30 行看了不到一分钟就「看完」）。
    """
    span = max(row.end_position_ms - row.start_position_ms, 0)
    return _reached_end(row, duration_ms) and _watched_through(row.watched_ms, span)


@dataclass
class _Viewing:
    """一次观看：同一成员同一集、接着上一段续播的几行日志合成的一场。

    场次、看完、「算不算一场」都按整次观看判断——三段各看 40 秒合起来两分钟算一场，
    哪一段播进片尾整场就算看完；观看时长仍按每一段实际发生的时间与设备记。
    """

    segments: list[PlaybackLog]
    reached_end: bool = False

    @property
    def first(self) -> PlaybackLog:
        return self.segments[0]

    @property
    def watched_ms(self) -> int:
        return sum(s.watched_ms for s in self.segments)

    @property
    def finished(self) -> bool:
        span = sum(max(s.end_position_ms - s.start_position_ms, 0) for s in self.segments)
        return self.reached_end and _watched_through(self.watched_ms, span)

    @property
    def counts(self) -> bool:
        """算不算一场：实际看了至少一分钟，或者看完了（续播点在 88% 的那一场只看最后
        几十秒，却是把这一集看完的那一场；短片同理）。"""
        return self.watched_ms >= MIN_PLAY_WATCHED_MS or self.finished


def _continues(last: PlaybackLog, row: PlaybackLog, duration_ms: int | None) -> bool:
    """``row`` 是不是接着 ``last`` 看的：间隔不太久，起点接上了终点。

    片头 5% 以内停下不留续播点（movieclaw_playback.progress），下一段从 0 开始；
    这时只要上一段停在片头区，从 0 开始也算接着看。
    """
    if row.started_at - last.last_seen_at > _RESUME_GAP:
        return False
    if abs(row.start_position_ms - last.end_position_ms) <= _RESUME_POSITION_SLACK_MS:
        return True
    return (
        row.start_position_ms == 0
        and bool(duration_ms)
        and last.end_position_ms * 100 < (duration_ms or 0) * MIN_RESUME_PCT
    )


def _group_viewings(
    rows: list[PlaybackLog], durations: dict[Unit, int | None]
) -> list[_Viewing]:
    """按开始时间把日志行串成一次次观看（见 :data:`_RESUME_GAP`）。

    接续看的是新一行的起点：它取自开播时的续播点，换设备接着看也成立；看完以后
    续播点清零，重看从头开始，自然另起一场。
    """
    viewings: list[_Viewing] = []
    latest: dict[tuple[int, Unit], _Viewing] = {}
    for row in sorted(rows, key=lambda r: (r.started_at, r.id or 0)):
        unit = (row.media_item_id, row.season_number, row.episode_number)
        viewing = latest.get((row.member_id, unit))
        last = viewing.segments[-1] if viewing else None
        if viewing is not None and last is not None and _continues(last, row, durations.get(unit)):
            viewing.segments.append(row)
        else:
            viewing = latest[(row.member_id, unit)] = _Viewing([row])
            viewings.append(viewing)
        viewing.reached_end = viewing.reached_end or _reached_end(row, durations.get(unit))
    return viewings


def _spread(row: PlaybackLog, offset: timedelta) -> Iterator[tuple[datetime, int]]:
    """一行的观看时长按墙钟均摊到它经过的每个本地整点：(该小时的本地起点, 毫秒)。

    观看时长在开始与最后一次上报之间累加，分不出其中哪段暂停过，均摊是最好的近似；
    余数给最后一个小时，各小时之和恒等于这一行的观看时长。曾经整场归到开始的那个
    小时，23 点开始的两小时电影全堆在 23 点、跨零点的算错日期。
    """
    if row.watched_ms <= 0:
        return
    start = row.started_at + offset
    end = max(row.last_seen_at + offset, start)
    total = (end - start).total_seconds()
    hour = start.replace(minute=0, second=0, microsecond=0)
    given = 0
    while True:
        following = hour + timedelta(hours=1)
        if following >= end or total <= 0:
            yield hour, row.watched_ms - given
            return
        share = int(row.watched_ms * (following - max(hour, start)).total_seconds() / total)
        given += share
        yield hour, share
        hour = following


def effective_end(row: PlaybackLog, now: datetime) -> datetime | None:
    """一行的结束时间：收到停止用停止时间；没收到但心跳已过保鲜期，用最后心跳；
    仍在保鲜期内视为进行中（None）。"""
    if row.ended_at is not None:
        return row.ended_at
    if (now - row.last_seen_at).total_seconds() > activity.SESSION_TTL_SECONDS:
        return row.last_seen_at
    return None


def _fallback_target(row: PlaybackLog) -> MediaActivityTarget:
    """条目已删：用日志里的片名快照，没有海报与落点。"""
    try:
        kind = MediaKind(row.kind)
    except ValueError:
        kind = MediaKind.VIDEO
    return MediaActivityTarget(
        media_item_id=row.media_item_id,
        library_id=None,
        browsable=False,
        kind=kind,
        title=row.title,
        year=None,
        poster_url=None,
        season_number=row.season_number,
        episode_number=row.episode_number,
        episode_title=None,
    )


async def _targets_for(
    session: AsyncSession,
    rows: list[PlaybackLog],
    *,
    browsable_library_ids: set[int] | None,
    fold_hidden: bool,
) -> tuple[dict[Unit, MediaActivityTarget | None], dict[Unit, int | None]]:
    """一批日志行的媒体目标与片长；范围内折叠的单元目标映射为 None。"""
    units = {(r.media_item_id, r.season_number, r.episode_number) for r in rows}
    contexts = await _load_unit_contexts(session, units, set())
    scope = VisibilityScope(
        await libraries_by_item(session, {u[0] for u in units}),
        browsable_library_ids,
        fold_hidden=fold_hidden,
    )
    by_row = {(r.media_item_id, r.season_number, r.episode_number): r for r in rows}
    targets: dict[Unit, MediaActivityTarget | None] = {}
    durations: dict[Unit, int | None] = {}
    for unit in units:
        ctx = contexts.get(unit)
        durations[unit] = ctx.duration_ms if ctx else None
        if ctx is None:
            targets[unit] = _fallback_target(by_row[unit])
            continue
        placement = scope.place(unit[0], ctx.file.library_id if ctx.file else None)
        if placement.hidden:
            targets[unit] = None
            continue
        targets[unit] = _target(
            unit, ctx, library_id=placement.library_id, browsable=placement.browsable
        )
    return targets, durations


async def playback_history(
    session: AsyncSession,
    *,
    limit: int,
    before: int | None = None,
    days: int | None,
    member_id: int | None,
    browsable_library_ids: set[int] | None,
    fold_hidden: bool,
) -> PlaybackHistoryView:
    """最近的播放记录（每场一行），按开始时间倒序、游标翻页。

    ``before`` 是上一页最后一行的 id：下一页取 (started_at, id) 严格小于它的行。
    用游标而不是 offset，是因为记录会一直往前追加——滚动续载期间新开的一场
    会把 offset 整体后推，同一行就会在两页里各出现一次。多取一行判断
    ``has_more``；折叠掉的行照常推进游标，换口径重拉即可。
    """
    statement = select(PlaybackLog).order_by(PlaybackLog.started_at.desc(), PlaybackLog.id.desc())  # type: ignore[union-attr]
    if days is not None:
        statement = statement.where(PlaybackLog.started_at >= utcnow() - timedelta(days=days))
    if member_id is not None:
        statement = statement.where(PlaybackLog.member_id == member_id)
    if before is not None:
        anchor = await session.get(PlaybackLog, before)
        if anchor is not None:
            statement = statement.where(
                or_(
                    PlaybackLog.started_at < anchor.started_at,
                    and_(
                        PlaybackLog.started_at == anchor.started_at,
                        PlaybackLog.id < anchor.id,  # type: ignore[operator]
                    ),
                )
            )
    rows = list((await session.execute(statement.limit(limit + 1))).scalars())
    has_more = len(rows) > limit
    rows = rows[:limit]
    next_cursor = rows[-1].id if has_more and rows else None
    names = await _member_names(session, {r.member_id for r in rows})
    targets, durations = await _targets_for(
        session, rows, browsable_library_ids=browsable_library_ids, fold_hidden=fold_hidden
    )
    now = utcnow()
    entries: list[PlaybackLogEntryView] = []
    hidden = 0
    for row in rows:
        unit = (row.media_item_id, row.season_number, row.episode_number)
        target = targets[unit]
        if target is None:
            hidden += 1
            continue
        duration_ms = durations[unit]
        entries.append(
            PlaybackLogEntryView(
                id=row.id or 0,
                member_name=names[row.member_id],
                media=target,
                client=row.client,
                device_name=row.device_name,
                started_at=row.started_at,
                ended_at=effective_end(row, now),
                watched_ms=row.watched_ms,
                start_position_ms=row.start_position_ms,
                end_position_ms=row.end_position_ms,
                duration_ms=duration_ms,
                progress_percent=_progress_percent(row.end_position_ms, duration_ms),
                completed=finished(row, duration_ms),
            )
        )
    return PlaybackHistoryView(
        entries=entries, hidden_count=hidden, has_more=has_more, next_cursor=next_cursor
    )


#: 网页播放的档位名（movieclaw_playback.decide.PlaybackTier 的展示口径）
_TIER_LABELS = {0: "直连", 1: "重封装", 2: "音频转码", 3: "硬件转码", 4: "软件转码"}


def _day_series(
    viewings: list[_Viewing],
    segments: list[PlaybackLog],
    *,
    since: datetime,
    until: datetime,
    offset: timedelta,
) -> list[PlaybackStatsDayRow]:
    """按浏览器本地日期分桶，补齐没有播放的日子；行数 = 周期天数 + 1。

    场次与看完记在一次观看开始的那天，时长按实际经过的时段摊到各天。
    """
    buckets: dict[str, dict] = defaultdict(
        lambda: {"plays": 0, "watched": 0, "done": 0, "members": set()}
    )
    for viewing in viewings:
        day = buckets[(viewing.first.started_at + offset).strftime("%Y-%m-%d")]
        day["plays"] += 1
        day["done"] += int(viewing.finished)
        if viewing.first.member_id >= 0:
            day["members"].add(viewing.first.member_id)
    for row in segments:
        for hour, watched in _spread(row, offset):
            day = buckets[hour.strftime("%Y-%m-%d")]
            day["watched"] += watched
            if row.member_id >= 0:
                day["members"].add(row.member_id)
    out: list[PlaybackStatsDayRow] = []
    cursor = (since + offset).date()
    last = (until + offset).date()
    while cursor <= last:
        key = cursor.strftime("%Y-%m-%d")
        day = buckets.get(key)
        out.append(
            PlaybackStatsDayRow(
                date=key,
                plays=day["plays"] if day else 0,
                watched_ms=day["watched"] if day else 0,
                completed=day["done"] if day else 0,
                members=len(day["members"]) if day else 0,
            )
        )
        cursor += timedelta(days=1)
    return out


@dataclass
class _TitleAgg:
    """一部作品在一个周期内的聚合：场次、时长、看过的人。"""

    unit: Unit
    plays: int = 0
    watched_ms: int = 0
    members: set[int] = field(default_factory=set)

    def row(self, target: MediaActivityTarget) -> PlaybackStatsTitleRow:
        return PlaybackStatsTitleRow(
            media=target, plays=self.plays, watched_ms=self.watched_ms, members=len(self.members)
        )


def _aggregate_titles(
    viewings: list[_Viewing], segments: list[PlaybackLog]
) -> dict[int, _TitleAgg]:
    """按条目聚合：场次数观看，时长与看过的人按行；剧集取最近一行的那一集当展示锚
    （行按开始时间升序，后来的覆盖）。"""
    titles: dict[int, _TitleAgg] = {}
    for row in sorted(segments, key=lambda r: (r.started_at, r.id or 0)):
        unit = (row.media_item_id, row.season_number, row.episode_number)
        agg = titles.setdefault(row.media_item_id, _TitleAgg(unit=unit))
        agg.unit = unit
        agg.watched_ms += row.watched_ms
        agg.members.add(row.member_id)
    for viewing in viewings:
        titles[viewing.first.media_item_id].plays += 1
    return titles


#: 最受欢迎榜的长度（领奖台：金银铜）
_FAVORITES = 3


def _favorites(
    titles: dict[int, _TitleAgg], targets: dict[Unit, MediaActivityTarget]
) -> list[PlaybackStatsTitleRow]:
    """最受欢迎前三：看过的成员最多，并列按时长、再按场次。

    与作品榜「看得最多」（按时长）是两个问题：一个人刷完一整季会稳居时长榜首，
    但三个成员各看一遍的电影才是「家里谁都在看的」。家庭服务器成员就三五个，
    并列很常见，第二排序键不能省。范围外的作品跳过，由后面可见的顶上。
    """
    rows: list[PlaybackStatsTitleRow] = []
    for agg in sorted(
        titles.values(), key=lambda t: (len(t.members), t.watched_ms, t.plays), reverse=True
    ):
        target = targets.get(agg.unit)
        if target is not None:
            rows.append(agg.row(target))
            if len(rows) == _FAVORITES:
                break
    return rows


def _totals(viewings: list[_Viewing], segments: list[PlaybackLog]) -> PlaybackStatsTotals:
    return PlaybackStatsTotals(
        plays=len(viewings),
        watched_ms=sum(r.watched_ms for r in segments),
        completed=sum(int(v.finished) for v in viewings),
        # 活跃成员只数家里的账号：分享访客（-1 哨兵）的时长照算，人不算
        active_members=len({r.member_id for r in segments if r.member_id >= 0}),
    )


async def playback_stats(
    session: AsyncSession,
    *,
    days: int,
    tz_offset_minutes: int,
    member_id: int | None = None,
    browsable_library_ids: set[int] | None,
    fold_hidden: bool,
) -> PlaybackWatchStatsView:
    """一段时间内的观看统计，当前周期与上一周期成对。

    ``tz_offset_minutes`` 是浏览器时区相对 UTC 的分钟数（东八区 = 480），按天与
    按小时分桶都用它，否则晚上的观看会被算到第二天。一次把两个周期的日志取回来，
    在 Python 里切分聚合——家庭服务器几十天的日志也就几千行。
    """
    now = utcnow()
    since = now - timedelta(days=days)
    previous_since = since - timedelta(days=days)
    offset = timedelta(minutes=tz_offset_minutes)

    statement = select(PlaybackLog).where(PlaybackLog.started_at >= previous_since)
    if member_id is not None:
        statement = statement.where(PlaybackLog.member_id == member_id)
    logged = list((await session.execute(statement)).scalars())
    # 片长判「看完」要用，范围折叠也在这一步；两个周期一次取齐
    targets, durations = await _targets_for(
        session, logged, browsable_library_ids=browsable_library_ids, fold_hidden=fold_hidden
    )

    # 一次观看归到它开始的那个周期；它的每一行按各自的开始时间归周期（上期开始、本期
    # 接着看完的那部片，场次算上期，本期接着看的时长算本期）
    counted = [v for v in _group_viewings(logged, durations) if v.counts]
    viewings = [v for v in counted if v.first.started_at >= since]
    previous_viewings = [v for v in counted if v.first.started_at < since]
    counted_rows = [r for v in counted for r in v.segments]
    rows = [r for r in counted_rows if r.started_at >= since]
    previous_rows = [r for r in counted_rows if r.started_at < since]
    # 上一周期要被日志完整覆盖才能拿来对照：日志从某天才开始记，只覆盖了上期最后两天
    # 也会有数据，拿它比会得出「+949%」。覆盖看全表最早一行，不随成员钻取变——某个
    # 成员上期没看是真实的 0，不是缺数据。
    first_logged = (await session.execute(select(func.min(PlaybackLog.started_at)))).scalar()
    previous_available = first_logged is not None and first_logged <= previous_since

    names = await _member_names(session, {r.member_id for r in rows})

    by_member: dict[int, list[int]] = defaultdict(lambda: [0, 0, 0])  # plays, watched, completed
    by_client: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    by_hour = [[0] * 24 for _ in range(7)]
    # 场次与看完记在一次观看的第一行（谁、用什么开始看的）；时长记在每一行自己身上
    for viewing in viewings:
        member = by_member[viewing.first.member_id]
        member[0] += 1
        member[2] += int(viewing.finished)
        by_client[viewing.first.client or "未知客户端"][0] += 1
    for row in rows:
        by_member[row.member_id][1] += row.watched_ms
        by_client[row.client or "未知客户端"][1] += row.watched_ms
        # 时段热力图按实际经过的时段摊开，回答「什么时候有人在看」
        for hour, watched in _spread(row, offset):
            by_hour[hour.weekday()][hour.hour] += watched

    titles = _aggregate_titles(viewings, rows)
    top_titles: list[PlaybackStatsTitleRow] = []
    hidden_titles = 0
    for agg in sorted(titles.values(), key=lambda t: (t.watched_ms, t.plays), reverse=True):
        target = targets.get(agg.unit)
        if target is None:
            hidden_titles += 1
            continue
        if len(top_titles) < _TOP_TITLES:
            top_titles.append(agg.row(target))

    # 网页播放的档位分解来自播放质量指标（一次播放一行）；Jellyfin 客户端恒为直连
    # 与场次同一口径：故障注入实验台的实验不算（30 天里七成的指标行是实验），
    # 不到一分钟的也不算
    metric_statement = select(PlaybackMetric.tier, func.count()).where(
        PlaybackMetric.created_at >= since,
        PlaybackMetric.lab_scenario == "",
        PlaybackMetric.watched_ms >= MIN_PLAY_WATCHED_MS,
    )
    if member_id is not None:
        metric_statement = metric_statement.where(PlaybackMetric.member_id == member_id)
    tier_counts = dict(
        (await session.execute(metric_statement.group_by(PlaybackMetric.tier))).all()
    )
    by_tier = [
        PlaybackStatsTierRow(tier=tier, label=label, plays=int(tier_counts.get(tier, 0)))
        for tier, label in _TIER_LABELS.items()
        if tier_counts.get(tier)
    ]

    return PlaybackWatchStatsView(
        days=days,
        current=_totals(viewings, rows),
        previous=_totals(previous_viewings, previous_rows),
        previous_available=previous_available,
        by_day=_day_series(viewings, rows, since=since, until=now, offset=offset),
        previous_by_day=_day_series(
            previous_viewings, previous_rows, since=previous_since, until=since, offset=offset
        ),
        by_hour=by_hour,
        by_member=sorted(
            (
                PlaybackStatsMemberRow(
                    member_id=mid,
                    member_name=names[mid],
                    plays=plays,
                    watched_ms=watched,
                    completed=done,
                )
                for mid, (plays, watched, done) in by_member.items()
            ),
            key=lambda r: (r.watched_ms, r.plays),
            reverse=True,
        ),
        by_client=sorted(
            (
                PlaybackStatsClientRow(client=client, plays=plays, watched_ms=watched)
                for client, (plays, watched) in by_client.items()
            ),
            key=lambda r: (r.watched_ms, r.plays),
            reverse=True,
        ),
        by_tier=by_tier,
        top_titles=top_titles,
        hidden_title_count=hidden_titles,
        favorites=_favorites(titles, targets),
        # 上一周期的最受欢迎只用来对照（「蝉联」还是「上期是谁」），同样按可见范围折叠
        previous_favorites=_favorites(
            _aggregate_titles(previous_viewings, previous_rows), targets
        ),
    )

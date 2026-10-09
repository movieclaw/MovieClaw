"""公开演示站的「活动」与「订阅」数据（docs/design/demo-site.md §6）。

演示站没有真实的家庭成员在看片、追片，活动页、「我的订阅」「继续观看」「我的收藏」
全是空的，访客看不出这些功能长什么样。这里用媒体库里真实的片子造出一个家庭的数据：

- **订阅**：库里每部片都有一条已收齐的订阅，最近几天「刚刚入库」几部；时间线只有
  「订阅 → 入库 → 收齐」，不出现任何站点与种子信息（演示站不接 PT）。每部片的
  「入库时间」同时约束观看记录：不会出现还没入库就看过的片子；

- **历史**（``playback_log`` / ``playback_metric`` / ``playback_state``）：每次演示模式
  启动时按「当天」重新生成最近 180 天的播放记录。统计窗口都相对当前时间
  （7 / 30 / 90 天及其上一个周期），数据若只在建站时造一次，几天后就会过期变空；
  每日还原会重启容器，于是每天都是新鲜的。随机数按日期播种，同一天重启结果一致。
- **正在播放**：活动页的实时会话只在进程内存里（``movieclaw_playback.activity``），
  这里不往注册表里塞假会话（会过期、会被真实访客的同设备会话覆盖、还会被取流
  鉴权读到），而是按当前时间确定性地算出几路「正在播放」，由活动接口合并进快照：
  三路设备各自按片长轮播，进度随时间推进，每次轮询都连贯。

造出的行全部用 ``demo-`` 开头的设备标识，与访客真实的播放记录区分：重建时只删
这些行；访客隐私脱敏（services/demo.anonymous_playback_client）也放过它们——
它们的客户端名与设备名是这里写死的，不是访客填的。
"""

from __future__ import annotations

import logging
import random
import time
import zlib
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.services import demo as demo_service
from movieclaw_api.services.rule_sets import RuleSetService
from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    ActivityType,
    LibraryFile,
    MediaItem,
    PlaybackLog,
    PlaybackState,
    Subscription,
    SubscriptionActivity,
    SubscriptionFollower,
    SubscriptionStatus,
    WantedItem,
    WantedStatus,
)
from movieclaw_db.models.library import Library
from movieclaw_db.models.member import Member, MemberLibraryAccess
from movieclaw_db.models.playback_metric import PlaybackMetric
from movieclaw_playback.activity import PlaySession
from movieclaw_playback.events import ClientInfo

logger = logging.getLogger("movieclaw_api.demo_activity")

SEEDED_DEVICE_PREFIX = "demo-"
HISTORY_DAYS = 180
# 演示站的访客大多在国内：造数据时的「晚上」「周末」按东八区算
_LOCAL_OFFSET = timedelta(hours=8)


@dataclass(frozen=True)
class _Device:
    device_id: str
    client: str
    device_name: str
    version: str = ""
    # 播放引擎（写进 playback_metric，只影响统计里的档位分布口径）
    engine: str = "direct"


@dataclass(frozen=True)
class _Viewer:
    """一个「家庭成员」的观看习惯：每天平均看几场、几点看、用哪些设备。"""

    username: str
    plays_per_day: float
    hours: tuple[int, ...]
    devices: tuple[_Device, ...]


# 按用户名对上 demo/accounts.json 的角色；admin 走超管哨兵 member_id=0
_VIEWERS: tuple[_Viewer, ...] = (
    _Viewer(
        "admin",
        0.9,
        (20, 21, 22, 23),
        (
            _Device("demo-admin-mac", "MovieClaw Web", "Chrome · macOS", engine="direct"),
            _Device("demo-admin-iphone", "MovieClaw iOS", "iPhone · iOS 26.0", "1.0", "native"),
        ),
    ),
    _Viewer(
        "family",
        1.3,
        (19, 20, 21, 22),
        (
            _Device("demo-family-atv", "Infuse", "客厅 Apple TV", "8.1", "jellyfin"),
            _Device("demo-family-ipad", "MovieClaw iOS", "iPad · iPadOS 26.0", "1.0", "native"),
        ),
    ),
    _Viewer(
        "kids",
        1.8,
        (16, 17, 18, 19),
        (_Device("demo-kids-ipad", "MovieClaw iOS", "iPad · iPadOS 26.0", "1.0", "native"),),
    ),
    _Viewer(
        "guest",
        0.4,
        (13, 15, 21),
        (_Device("demo-guest-pc", "MovieClaw Web", "Edge · Windows", engine="direct"),),
    ),
)


@dataclass(frozen=True)
class _Unit:
    item_id: int
    kind: str
    title: str
    library_id: int
    file_id: int
    duration_ms: int
    size_bytes: int


@dataclass(frozen=True)
class _LiveChannel:
    """「正在播放」的一路：谁、在哪台设备、轮播哪些片。"""

    member_id: int
    device: _Device
    units: tuple[_Unit, ...]
    # 只在部分时段出现（0~1）：让「正在播放」的路数有起有落，而不是恒定三路
    presence: float


_live_channels: tuple[_LiveChannel, ...] = ()


def _seeded_devices() -> dict[str, _Device]:
    return {d.device_id: d for v in _VIEWERS for d in v.devices}


def is_seeded_device(device_id: str) -> bool:
    """这个设备标识是不是演示数据用的那几台（而不是访客的真实设备）。

    按完整标识精确匹配，不看前缀：访客走 Jellyfin 兼容层登录时设备标识是
    客户端自报的，能随便填 ``demo-xxx``。即便填中了某台演示设备的标识也无妨——
    展示时一律换成那台演示设备的预设文案（见 ``display_client``）。
    """
    return device_id in _seeded_devices()


def display_client(device_id: str, client: str, device_name: str) -> tuple[str, str]:
    """活动页 / 播放记录里一行的（客户端名, 设备名）该怎么展示。

    演示设备：用预设文案，**不信库里或会话里存的文字**——访客冒用演示设备标识
    时，自报的客户端名也只会被换成预设值；其他设备：按访客脱敏规则处理。
    """
    seeded = _seeded_devices().get(device_id)
    if seeded is not None:
        return seeded.client, seeded.device_name
    return demo_service.anonymous_playback_client(client, device_name)


def seeded_client_names() -> frozenset[str]:
    """演示数据用到的客户端名（统计里的「按客户端」据此判断要不要脱敏）。"""
    return frozenset(d.client for v in _VIEWERS for d in v.devices)


# ---------------------------------------------------------------------------
# 历史：启动时按当天重建
# ---------------------------------------------------------------------------


async def _load_units(session: AsyncSession) -> list[_Unit]:
    """媒体库里在位、可播放的片子（图片库不算）。"""
    rows = await session.execute(
        select(
            LibraryFile.media_item_id,
            MediaItem.kind,
            MediaItem.title,
            LibraryFile.library_id,
            LibraryFile.id,
            LibraryFile.duration_seconds,
            LibraryFile.size_bytes,
        )
        .join(MediaItem, MediaItem.id == LibraryFile.media_item_id)
        .join(Library, Library.id == LibraryFile.library_id)
        .where(
            LibraryFile.state == "in_place",
            LibraryFile.media_item_id.is_not(None),
            LibraryFile.season_number == 0,
            Library.kind != "photo",
        )
        .order_by(LibraryFile.media_item_id)
    )
    units: dict[int, _Unit] = {}
    for item_id, kind, title, library_id, file_id, seconds, size in rows:
        if item_id in units or not seconds:
            continue
        units[item_id] = _Unit(
            item_id, kind, title, library_id, file_id, int(seconds) * 1000, int(size or 0)
        )
    return list(units.values())


async def _viewer_members(session: AsyncSession) -> dict[str, tuple[int, set[int] | None]]:
    """用户名 → (member_id, 可见库 id；None=全部)。停用的成员不造数据。"""
    result: dict[str, tuple[int, set[int] | None]] = {"admin": (0, None)}
    members = (await session.execute(select(Member))).scalars().all()
    for member in members:
        if member.status != "active" or member.id is None:
            continue
        visible: set[int] | None = None
        if not member.all_libraries:
            visible = set(
                (
                    await session.execute(
                        select(MemberLibraryAccess.library_id).where(
                            MemberLibraryAccess.member_id == member.id
                        )
                    )
                ).scalars()
            )
        result[member.username] = (member.id, visible)
    return result


def _local_start(rng: random.Random, day: datetime, hours: tuple[int, ...]) -> datetime:
    """某一天（东八区日期）里的一个开播时刻，返回 naive UTC。"""
    weekend = day.weekday() >= 5
    hour = rng.choice(hours if not weekend or rng.random() < 0.5 else (10, 14, 15, 16))
    local = day.replace(hour=hour, minute=rng.randrange(60), second=rng.randrange(60))
    return local - _LOCAL_OFFSET


# 最近几天「刚刚入库」的片数（订阅首页的「刚刚入库」、首页横幅都靠它）
_RECENT_ARRIVALS = 3
# 由家庭成员（而不是超管）发起的订阅数：成员的「我的订阅」只看自己发起与关注的
_FAMILY_SUBSCRIPTIONS = 2


def _import_plan(units: list[_Unit], now: datetime, rng: random.Random) -> dict[int, datetime]:
    """每部片的「入库时间」：几部落在最近几天，其余分散在过去半年。"""
    recent = rng.sample(units, k=min(_RECENT_ARRIVALS, len(units)))
    plan = {
        u.item_id: now - timedelta(hours=hours)
        for u, hours in zip(recent, (5, 31, 80), strict=False)
    }
    for unit in units:
        plan.setdefault(unit.item_id, now - timedelta(days=rng.uniform(12, HISTORY_DAYS - 10)))
    return plan


async def _seed_subscriptions(
    session: AsyncSession,
    units: list[_Unit],
    members: dict[str, tuple[int, set[int] | None]],
    imported: dict[int, datetime],
    rng: random.Random,
) -> int:
    """重建演示订阅：只替换上次造的那批（创建记录带 ``demo_seed`` 标记）。

    公开访客建不了订阅，但审核账号能（demo-site.md §9）：它建的真订阅原样保留，
    已有真订阅的片子也不再造一条假的。
    """
    seeded = select(SubscriptionActivity.subscription_id).where(
        SubscriptionActivity.type == ActivityType.CREATED,
        func.json_extract(SubscriptionActivity.payload, "$.demo_seed") == 1,
    )
    # 工单、时间线、关注随外键级联删除
    await session.execute(delete(Subscription).where(Subscription.id.in_(seeded)))
    real_items = set(
        (await session.execute(select(Subscription.media_item_id))).scalars().all()
    )
    units = [u for u in units if u.item_id not in real_items]
    rule_set = await RuleSetService(session).ensure_default()
    family = members.get("family")
    ordered = sorted(units, key=lambda u: imported[u.item_id])
    family_owned = {u.item_id for u in ordered[-_FAMILY_SUBSCRIPTIONS:]} if family else set()
    for unit in ordered:
        imported_at = imported[unit.item_id]
        created_at = imported_at - timedelta(days=rng.uniform(0.5, 20))
        owner = family[0] if family and unit.item_id in family_owned else None
        sub = Subscription(
            media_item_id=unit.item_id,
            kind=unit.kind,
            selected_seasons=[],
            follow_future=False,
            rule_set_id=rule_set.id,
            status=SubscriptionStatus.COMPLETED,
            created_by_member_id=owner,
            last_activity_at=imported_at,
            created_at=created_at,
            updated_at=imported_at,
        )
        session.add(sub)
        await session.flush()
        wanted = WantedItem(
            subscription_id=sub.id,
            media_item_id=unit.item_id,
            season_number=0,
            episode_number=0,
            status=WantedStatus.IMPORTED,
            in_scope=True,
            grabbed_at=imported_at - timedelta(minutes=rng.randrange(40, 240)),
            downloaded_at=imported_at - timedelta(minutes=rng.randrange(3, 30)),
            imported_at=imported_at,
            created_at=created_at,
            updated_at=imported_at,
        )
        session.add(wanted)
        await session.flush()
        for kind, message, at in (
            (ActivityType.CREATED, f"订阅了《{unit.title}》", created_at),
            (ActivityType.IMPORTED, "正片已入库", imported_at),
            (
                ActivityType.COMPLETED,
                "订阅已收齐：期望的内容都已安排完毕，且暂无会新增的内容",
                imported_at + timedelta(seconds=2),
            ),
        ):
            session.add(
                SubscriptionActivity(
                    subscription_id=sub.id,
                    wanted_item_id=wanted.id if kind == ActivityType.IMPORTED else None,
                    type=kind,
                    message=message,
                    payload={"demo_seed": True} if kind == ActivityType.CREATED else {},
                    created_at=at,
                    updated_at=at,
                )
            )
        # 家庭成员除了自己发起的，还关注了几部超管订的
        if family and owner is None and rng.random() < 0.4:
            session.add(SubscriptionFollower(subscription_id=sub.id, member_id=family[0]))
    return len(ordered)


async def seed_demo_data(now: datetime | None = None) -> None:
    """按当天重建演示用的订阅、播放记录、档位统计、续播与收藏。幂等：只替换演示数据。"""
    now = (now or datetime.now(UTC)).replace(tzinfo=None, microsecond=0)
    rng = random.Random(f"movieclaw-demo-{now.date().isoformat()}")
    async with get_database().session() as session:
        units = await _load_units(session)
        members = await _viewer_members(session)
        if not units:
            logger.warning("演示站媒体库里还没有可播放的片子，跳过生成演示数据")
            return
        imported = _import_plan(units, now, rng)
        recent_ids = {i for i, at in imported.items() if now - at < timedelta(days=7)}
        subscriptions = await _seed_subscriptions(session, units, members, imported, rng)

        await session.execute(
            delete(PlaybackLog).where(PlaybackLog.device_id.like(f"{SEEDED_DEVICE_PREFIX}%"))
        )
        # 档位统计没有设备维度可区分，整表重建（演示站每天还原，访客的数据本就不留）
        await session.execute(delete(PlaybackMetric))

        today_local = (now + _LOCAL_OFFSET).replace(hour=0, minute=0, second=0)
        logs: list[PlaybackLog] = []
        metrics: list[PlaybackMetric] = []
        channels: list[_LiveChannel] = []
        for viewer in _VIEWERS:
            if viewer.username not in members:
                continue
            member_id, visible = members[viewer.username]
            pool = [u for u in units if visible is None or u.library_id in visible]
            # 超管还没看过刚入库的片：订阅首页的「刚刚入库」按「这个人看没看过」过滤
            watchable = [
                u for u in pool if viewer.username != "admin" or u.item_id not in recent_ids
            ]
            if not watchable:
                continue
            for back in range(HISTORY_DAYS, -1, -1):
                day = today_local - timedelta(days=back)
                count = sum(rng.random() < viewer.plays_per_day / 2 for _ in range(2))
                for _ in range(count):
                    started = _local_start(rng, day, viewer.hours)
                    unit = rng.choice(watchable)
                    if started < imported[unit.item_id] + timedelta(hours=1):
                        continue  # 入库之前看不到这部片
                    device = rng.choice(viewer.devices)
                    complete = rng.random() < 0.7
                    start_pos = (
                        0
                        if complete or rng.random() < 0.6
                        else int(unit.duration_ms * rng.uniform(0.1, 0.5))
                    )
                    end_pos = (
                        int(unit.duration_ms * rng.uniform(0.95, 1.0))
                        if complete
                        else min(
                            unit.duration_ms,
                            start_pos + int(unit.duration_ms * rng.uniform(0.15, 0.6)),
                        )
                    )
                    watched = max(1000, end_pos - start_pos)
                    ended = started + timedelta(milliseconds=watched + rng.randrange(5, 90) * 1000)
                    if ended >= now - timedelta(minutes=10):
                        continue  # 不造「还没发生」或「疑似仍在播放」的记录
                    logs.append(
                        PlaybackLog(
                            member_id=member_id,
                            media_item_id=unit.item_id,
                            kind=unit.kind,
                            title=unit.title,
                            device_id=device.device_id,
                            client=device.client,
                            device_name=device.device_name,
                            started_at=started,
                            last_seen_at=ended,
                            ended_at=ended,
                            start_position_ms=start_pos,
                            end_position_ms=end_pos,
                            watched_ms=watched,
                            completed=end_pos >= unit.duration_ms * 0.9,
                            created_at=started,
                            updated_at=ended,
                        )
                    )
                    if device.engine != "jellyfin":
                        # 网页 / App 播放才有档位快照；演示片子都能直连，偶有封装转换
                        tier = 0 if rng.random() < 0.85 else 1
                        metrics.append(
                            PlaybackMetric(
                                member_id=member_id,
                                library_file_id=unit.file_id,
                                tier=tier,
                                engine="direct" if tier == 0 else "hls.js",
                                ttff_ms=rng.randrange(350, 1600),
                                rebuffer_ms=0 if rng.random() < 0.9 else rng.randrange(200, 2500),
                                seek_count=rng.randrange(0, 4),
                                watched_ms=watched,
                                created_at=started,
                                updated_at=ended,
                            )
                        )
            channels.append(
                _LiveChannel(
                    member_id=member_id,
                    device=viewer.devices[0],
                    units=tuple(watchable),
                    presence={"admin": 0.5, "guest": 0.3}.get(viewer.username, 0.85),
                )
            )

        session.add_all(logs)
        session.add_all(metrics)
        await _rebuild_states(session, rng, logs, members, units, now)
        await session.commit()

    global _live_channels
    _live_channels = tuple(channels)
    logger.info(
        "演示站数据已按今天重建：订阅 %d 条、播放记录 %d 条、档位快照 %d 条",
        subscriptions,
        len(logs),
        len(metrics),
    )


async def _rebuild_states(
    session: AsyncSession,
    rng: random.Random,
    logs: list[PlaybackLog],
    members: dict[str, tuple[int, set[int] | None]],
    units: list[_Unit],
    now: datetime,
) -> None:
    """按造出的播放记录回填 playback_state：已看、次数、最近播放、续播点、收藏。

    每人最近一场不看完——「继续观看」一行才有东西；再各挑两三部收藏。
    """
    by_key: dict[tuple[int, int], list[PlaybackLog]] = {}
    for log in logs:
        by_key.setdefault((log.member_id, log.media_item_id), []).append(log)
    latest_per_member: dict[int, PlaybackLog] = {}
    for log in logs:
        best = latest_per_member.get(log.member_id)
        if best is None or log.started_at > best.started_at:
            latest_per_member[log.member_id] = log

    member_ids = {member_id for member_id, _ in members.values()}
    existing = {
        (row.member_id, row.media_item_id): row
        for row in (
            await session.execute(
                select(PlaybackState).where(
                    PlaybackState.member_id.in_(member_ids),
                    PlaybackState.season_number == 0,
                    PlaybackState.episode_number == 0,
                )
            )
        ).scalars()
    }

    def state(member_id: int, item_id: int) -> PlaybackState:
        row = existing.get((member_id, item_id))
        if row is None:
            row = PlaybackState(member_id=member_id, media_item_id=item_id)
            session.add(row)
            existing[(member_id, item_id)] = row
        return row

    durations = {u.item_id: u.duration_ms for u in units}
    for (member_id, item_id), rows in by_key.items():
        rows.sort(key=lambda r: r.started_at)
        last = rows[-1]
        row = state(member_id, item_id)
        row.play_count = len(rows)
        row.last_played_at = last.ended_at
        row.played = any(r.completed for r in rows)
        row.position_ms = 0
        if latest_per_member.get(member_id) is last or not last.completed:
            # 续播点：停在最后一场的位置（最近一场强制留成半截）
            position = last.end_position_ms
            if last.completed:
                position = int(durations.get(item_id, last.end_position_ms) * 0.45)
            row.position_ms = position
            row.played = False
        row.updated_at = last.ended_at or now

    for _username, (member_id, visible) in members.items():
        pool = [u for u in units if visible is None or u.library_id in visible]
        for unit in rng.sample(pool, k=min(3, len(pool))):
            row = state(member_id, unit.item_id)
            row.is_favorite = True
            row.favorited_at = now - timedelta(
                days=rng.randrange(1, 120), minutes=rng.randrange(600)
            )
            row.updated_at = max(row.updated_at or row.favorited_at, row.favorited_at)


# ---------------------------------------------------------------------------
# 正在播放：按当前时间确定性地算出来
# ---------------------------------------------------------------------------

_LIVE_GAP_SECONDS = 90  # 一部放完到下一部开播之间的空档


def live_sessions(now_epoch: float | None = None) -> list[PlaySession]:
    """此刻「正在播放」的几路会话（与真实会话同形，交给活动快照统一装配）。

    每一路把自己的片单排成一轮：每部片占「片长 + 空档」的时段，一轮放完再按新
    顺序开下一轮。位置由当前时间算出，同一时刻多次调用结果一致，进度随时间连续
    推进。``presence`` 按「这一轮的这部片」决定这一路是否出现，让路数有起有落。

    时段按每部片自己的长度切，而不是统一按最长的片：片单里多是两三分钟的短片，
    统一按十几分钟切的话大半时间都是空档，活动页约四分之一的时候一路都没有。
    """
    now_epoch = now_epoch if now_epoch is not None else time.time()
    now = datetime.fromtimestamp(now_epoch, UTC).replace(tzinfo=None)
    sessions: list[PlaySession] = []
    for index, channel in enumerate(_live_channels):
        slots = [u.duration_ms // 1000 + _LIVE_GAP_SECONDS for u in channel.units]
        cycle = sum(slots)
        if cycle <= 0:
            continue
        # 各路错开相位，避免同时开播、同时结束
        shifted = now_epoch + index * cycle / len(_live_channels)
        round_no = int(shifted // cycle)
        offset = shifted - round_no * cycle
        # 每一轮换一个播放顺序（按轮次确定性打乱），免得每轮都是同一个次序
        order = sorted(
            range(len(channel.units)),
            key=lambda k, r=round_no: zlib.crc32(f"{channel.device.device_id}:{r}:{k}".encode()),
        )
        pick = order[-1]
        for k in order:
            if offset < slots[k]:
                pick = k
                break
            offset -= slots[k]
        unit = channel.units[pick]
        roll = zlib.crc32(f"{channel.device.device_id}:{round_no}:{pick}".encode())
        if (roll % 1000) / 1000 >= channel.presence:
            continue
        elapsed_ms = int(offset * 1000)
        if elapsed_ms >= unit.duration_ms:
            continue  # 这部片已经放完，处在到下一部之间的空档
        started = now - timedelta(milliseconds=elapsed_ms)
        client = ClientInfo(
            name=channel.device.client,
            device_name=channel.device.device_name,
            device_id=channel.device.device_id,
            version=channel.device.version,
        )
        sessions.append(
            PlaySession(
                device_id=channel.device.device_id,
                member_id=channel.member_id,
                client=client,
                unit=(unit.item_id, 0, 0),
                position_ms=elapsed_ms,
                paused=roll % 17 == 0,
                started_at=started,
                last_report_at=now,
                local_streamed=True,
                bytes_transferred=(
                    unit.size_bytes * elapsed_ms // unit.duration_ms if unit.duration_ms else 0
                ),
            )
        )
    return sessions


def live_rate(device_id: str, bytes_sent: int | None, position_ms: int | None) -> float | None:
    """演示会话的「实时速率」：按已传输 / 已播放时长折算成平均码率，带一点抖动。"""
    if not bytes_sent or not position_ms:
        return None
    jitter = 0.85 + (zlib.crc32(f"{device_id}:{int(time.time() // 8)}".encode()) % 30) / 100
    return bytes_sent / (position_ms / 1000) * jitter

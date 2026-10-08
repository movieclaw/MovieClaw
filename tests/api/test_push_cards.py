"""剧卡推送的端到端测试（docs/design/cloud-push.md §5.1）。

一部剧的一批下载只占一张通知卡：开始下载 → 可以先看了 → 静默进度 → 全部到齐 / 卡住，
同一个 collapse_id 原地替换，每批最多响两次；文案按收件人的观看进度写。

走真实链路：订阅投递（``download_started``）、库存对账（``close_fulfilled_wanted``）→ 推送事件
中枢 → 剧卡状态机 → 加密 → 假中继 → 用 App 的密钥解开。定时用可控时钟推进（生产的计时
常量原样不改），不靠真实等待，测试不受机器负载影响。
"""

# 夹具 client、world 从 test_cloud_push 导入，用例参数与它们同名是 pytest 的用法
# ruff: noqa: F811
from __future__ import annotations

import asyncio
import time
from datetime import date, timedelta

import pytest
from fastapi.testclient import TestClient
from tests.api.test_cloud_push import (  # noqa: F401 -- 夹具
    _ADMIN,
    _MEMBER,
    World,
    _app_login,
    _as_app,
    _connect,
    _create_member,
    _data,
    _open,
    _register,
    _wait,
    client,
    world,
)

ADMIN_TOKEN = "a1" * 32
MEMBER_TOKEN = "b1" * 32
TITLE = "余红旧事"


class _Timer:
    def __init__(self) -> None:
        self.cancelled = False

    def cancel(self) -> None:
        self.cancelled = True


class FakeClock:
    """替换推送事件中枢的时钟和定时：``advance`` 推进时间、按先后触发到点的定时。"""

    def __init__(self) -> None:
        self.t = 10_000.0
        self.timers: list[tuple[float, int, object, _Timer]] = []
        self.seq = 0

    def now(self) -> float:
        return self.t

    def later(self, delay: float, event: object) -> _Timer:
        handle = _Timer()
        self.seq += 1
        self.timers.append((self.t + max(0.0, delay), self.seq, event, handle))
        return handle

    async def advance(self, seconds: float) -> None:
        from movieclaw_api.services.push import cards, hub

        target = self.t + seconds
        while True:
            await hub.drain()
            due = sorted(
                (t for t in self.timers if not t[3].cancelled and t[0] <= target),
                key=lambda t: (t[0], t[1]),
            )
            if not due:
                break
            at, _, event, handle = due[0]
            handle.cancelled = True
            self.t = max(self.t, at)
            await cards.handle(event)
        self.timers = [t for t in self.timers if not t[3].cancelled]
        self.t = target


@pytest.fixture
def clock(world, monkeypatch):  # type: ignore[no-untyped-def]
    from movieclaw_api.services.push import cards, hub

    fake = FakeClock()
    monkeypatch.setattr(hub, "now", fake.now)
    monkeypatch.setattr(hub, "later", fake.later)
    # 用生产的计时（test_cloud_push 的夹具为了真实等待缩短过）
    monkeypatch.setattr(cards, "STARTED_QUIET_S", 30.0)
    monkeypatch.setattr(cards, "QUIET_S", 120.0)
    return fake


def test_first_pushes_share_collapse_key(client, monkeypatch):  # type: ignore[no-untyped-def]
    """首次并发推送只创建一把密钥，之后同一张卡的 ID 才能保持不变。"""
    from movieclaw_api.services.push.images import collapse_key
    from movieclaw_api.settings import get_setting_store

    async def go() -> None:
        store = get_setting_store()
        save = store.set

        async def slow_save(config):  # type: ignore[no-untyped-def]
            await asyncio.sleep(0.01)
            await save(config)

        monkeypatch.setattr(store, "set", slow_save)
        keys = await asyncio.gather(*(collapse_key() for _ in range(8)))
        assert len(set(keys)) == 1
        store.invalidate("push.channels")
        assert await collapse_key() == keys[0]

    assert client.portal is not None
    client.portal.call(go)


class Show:
    """一部订阅了的剧：剧集库、季集表、管理员发起 + 家人关注的订阅、每集一个工单。"""

    def __init__(self, client: TestClient, clock: FakeClock) -> None:
        self.client = client
        self.clock = clock
        self.library_id = 0
        self.item_id = 0
        self.subscription_id = 0
        self.files = 0

    def call(self, fn, *args):  # type: ignore[no-untyped-def]
        assert self.client.portal is not None
        return self.client.portal.call(fn, *args)

    def seed(
        self,
        *,
        episodes: int,
        aired: int | None = None,
        next_air: date | None = None,
        status: str = "Returning Series",
    ) -> None:
        """``aired``：前几集已播（默认全部）；``next_air``：第 aired+1 集的播出日期。"""
        from movieclaw_db.engine import get_database
        from movieclaw_db.models import (
            MediaEpisode,
            MediaItem,
            MediaSeason,
            RuleSet,
            Subscription,
            SubscriptionFollower,
            WantedItem,
            utcnow,
        )
        from movieclaw_db.repositories.library_repo import LibraryRepository

        aired = episodes if aired is None else aired
        today = utcnow().date()

        async def go() -> None:
            async with get_database().session() as session:
                library = await LibraryRepository(session).create(
                    name="剧集", kind="tv", root_paths=["/media/tv"]
                )
                library.created_at = utcnow() - timedelta(days=30)
                item = MediaItem(
                    kind="tv",
                    tmdb_id=424242,
                    title=TITLE,
                    original_title="Yu Hong",
                    year=2026,
                    status=status,
                    backdrop_path="/backdrop.jpg",
                )
                rule_set = RuleSet(name="默认", spec={})
                session.add_all([library, item, rule_set])
                await session.commit()
                await session.refresh(item)
                await session.refresh(rule_set)
                session.add(
                    MediaSeason(media_item_id=item.id, season_number=1, episode_count=episodes)
                )
                for episode in range(1, episodes + 1):
                    if episode <= aired:
                        air = today - timedelta(days=40 - episode)
                    elif episode == aired + 1 and next_air is not None:
                        air = next_air
                    else:
                        air = today + timedelta(days=7 * (episode - aired))
                    session.add(
                        MediaEpisode(
                            media_item_id=item.id,
                            season_number=1,
                            episode_number=episode,
                            air_date=air,
                            still_path=f"/still-{episode}.jpg",
                        )
                    )
                subscription = Subscription(
                    media_item_id=item.id, kind="tv", rule_set_id=rule_set.id, library_id=library.id
                )  # 管理员发起
                session.add(subscription)
                await session.commit()
                await session.refresh(subscription)
                session.add(SubscriptionFollower(subscription_id=subscription.id, member_id=1))
                for episode in range(1, episodes + 1):
                    session.add(
                        WantedItem(
                            subscription_id=subscription.id,
                            media_item_id=item.id,
                            season_number=1,
                            episode_number=episode,
                            air_date=today - timedelta(days=40 - episode)
                            if episode <= aired
                            else today + timedelta(days=7),
                        )
                    )
                await session.commit()
                self.library_id = library.id or 0
                self.item_id = item.id or 0
                self.subscription_id = subscription.id or 0

        self.call(go)

    def grab(
        self, episodes: range | list[int], *, source: str = "来自 hdsky 的「余红旧事 S01」"
    ) -> None:
        """订阅投递了一个种子（和 dispatch 一样：工单标已投递，再投「开始下载」事件）。"""
        from sqlmodel import select

        from movieclaw_api.services.push import events as push_events
        from movieclaw_api.services.push import hub
        from movieclaw_db.engine import get_database
        from movieclaw_db.models import WantedItem, WantedStatus, utcnow

        wanted = list(episodes)

        async def go() -> None:
            async with get_database().session() as session:
                rows = (
                    await session.execute(
                        select(WantedItem).where(
                            WantedItem.media_item_id == self.item_id,
                            WantedItem.episode_number.in_(wanted),  # type: ignore[attr-defined]
                        )
                    )
                ).scalars()
                for row in rows:
                    row.status = WantedStatus.GRABBED.value
                    row.grabbed_at = utcnow()
                    session.add(row)
                await session.commit()
            push_events.download_started(
                subscription_id=self.subscription_id,
                item_id=self.item_id,
                units=[(1, e) for e in wanted],
                detail="2160p",
                upgrade=False,
                source=source,
                spec="2160p · WEB-DL",
            )
            await hub.drain()

        self.call(go)

    def land(self, episodes: range | list[int]) -> None:
        """这几集的文件入库，库存对账（真实的 close_fulfilled_wanted）关掉工单、投「入库」事件。"""
        from movieclaw_api.services.push import hub
        from movieclaw_api.services.subscription.wanted_fulfillment import close_fulfilled_wanted
        from movieclaw_db.engine import get_database
        from movieclaw_db.models import FileSource, LibraryFile

        landing = list(episodes)

        async def go() -> None:
            async with get_database().session() as session:
                for episode in landing:
                    self.files += 1
                    session.add(
                        LibraryFile(
                            library_id=self.library_id,
                            media_item_id=self.item_id,
                            season_number=1,
                            episode_number=episode,
                            file_path=f"/media/tv/{TITLE}/S01E{episode:02d}-{self.files}.mkv",
                            size_bytes=1,
                            source=FileSource.IMPORTED,
                        )
                    )
                await session.commit()
                await close_fulfilled_wanted(session, self.item_id)
            await hub.drain()

        self.call(go)

    def watched(self, member_id: int, played: list[int], *, days_ago: float = 0.1) -> None:
        """这个人看完了这几集，最后一集是 ``days_ago`` 天前看的。"""
        from sqlmodel import delete

        from movieclaw_db.engine import get_database
        from movieclaw_db.models import PlaybackState, utcnow

        async def go() -> None:
            async with get_database().session() as session:
                await session.execute(
                    delete(PlaybackState).where(
                        PlaybackState.member_id == member_id,
                        PlaybackState.media_item_id == self.item_id,
                    )
                )
                last = utcnow() - timedelta(days=days_ago)
                for index, episode in enumerate(played):
                    session.add(
                        PlaybackState(
                            member_id=member_id,
                            media_item_id=self.item_id,
                            season_number=1,
                            episode_number=episode,
                            played=True,
                            last_played_at=last - timedelta(minutes=len(played) - index),
                        )
                    )
                await session.commit()

        self.call(go)

    def advance(self, seconds: float) -> None:
        self.call(self.clock.advance, seconds)


@pytest.fixture
def phones(client: TestClient, world: World):  # type: ignore[no-untyped-def]
    """管理员和家人各一台手机，都登记了推送。返回 (管理员密钥, 家人密钥, 家人令牌)。"""
    _connect(client, world)
    _create_member(client)
    admin_bearer = _app_login(client, _ADMIN, installation="card-admin", name="管理员的手机")
    member_bearer = _app_login(client, _MEMBER, installation="card-member", name="家人的手机")
    _, admin_key = _register(client, admin_bearer, token=ADMIN_TOKEN)
    _, member_key = _register(client, member_bearer, token=MEMBER_TOKEN)
    world.relays["push.test"].messages.clear()
    return admin_key, member_key, member_bearer, admin_bearer


def _mine(world: World, token: str) -> list[dict]:
    return [m for m in world.relays["push.test"].messages if m["token"] == token]


def _expect(world: World, token: str, count: int) -> list[dict]:
    """等这台手机正好收到 ``count`` 条（多等一会儿确认没有多余的）。"""
    _wait(lambda: len(_mine(world, token)) >= count)
    time.sleep(0.3)
    got = _mine(world, token)
    assert len(got) == count, [m.get("aps") for m in got]
    return got


def _rings(message: dict) -> bool:
    return (message.get("aps") or {}).get("sound") == "default"


# ----------------------------------------------------------------------
# 一张卡的一生
# ----------------------------------------------------------------------


def test_season_pack_is_one_card_that_rings_twice(
    client: TestClient, world: World, clock: FakeClock, phones, monkeypatch
) -> None:  # type: ignore[no-untyped-def]
    """33 集季包：开始下载（不响）→ 可以先看了（响）→ 进度（不响）→ 第 1 季已全部入库（响）。"""
    admin_key, member_key, _, admin_bearer = phones
    im: list[str] = []

    async def record_im(text: str, photo: bytes | None = None) -> int:
        im.append(text)
        return 1

    monkeypatch.setattr("movieclaw_api.services.channel_push.push_to_all_channels", record_im)
    monkeypatch.setattr("movieclaw_api.services.channel_push._fetch_image", _no_image)
    # 管理员打开了「开始下载」（默认关），家人没开
    _data(
        _as_app(
            client,
            admin_bearer,
            "PUT",
            "/api/v1/push/me/preferences",
            json={"events": {"download_started": True}},
        )
    )
    show = Show(client, clock)
    show.seed(episodes=33)

    # 10:08 两个种子先后投递（单集种 + 剩下的季包），30 秒内合成一条「开始下载」
    show.grab(range(1, 2), source="来自 hdsky 的「余红旧事 E01」")
    show.advance(10)
    show.grab(range(2, 34))
    show.advance(30)
    (started,) = _expect(world, ADMIN_TOKEN, 1)
    plain = _open(started, admin_key)
    assert plain["title"] == "余红旧事 开始下载"
    assert plain["body"] == "第 1 季第 1–33 集 · 2160p，第一批下好就告诉你"
    assert plain["thread"] == f"item-{show.item_id}"
    assert not _rings(started) and started["aps"]["interruption-level"] == "passive"
    assert _mine(world, MEMBER_TOKEN) == []  # 家人没开「开始下载」
    _wait(lambda: len(im) == 1)
    assert im[0] == (
        "📥 开始下载:《余红旧事》(2026) 第 1 季第 1–33 集\n来自 2 个资源\n2160p · WEB-DL"
    )

    # 10:16 第一批 10 集入库：还有 23 集在路上，先不发；15 分钟时发「可以先看了」
    show.advance(8 * 60)
    show.land(range(1, 11))
    show.advance(5 * 60)
    _expect(world, ADMIN_TOKEN, 1)
    show.advance(10 * 60)
    partial = _expect(world, ADMIN_TOKEN, 2)[-1]
    plain = _open(partial, admin_key)
    assert plain["title"] == "余红旧事 可以先看了"
    assert plain["body"] == "第 1–10 集已入库，其余 23 集还在下载"
    assert _rings(partial)
    assert partial["collapse_id"] == started["collapse_id"]  # 同一张卡原地替换
    member_partial = _expect(world, MEMBER_TOKEN, 1)[0]
    assert _rings(member_partial)
    assert _open(member_partial, member_key)["body"] == "第 1–10 集已入库，其余 23 集还在下载"

    # 又到了 15 集：静默更新进度（离上次发送满 5 分钟才更新）
    show.advance(60)
    show.land(range(11, 26))
    show.advance(3 * 60)
    _expect(world, ADMIN_TOKEN, 2)
    show.advance(2 * 60)
    progress = _expect(world, ADMIN_TOKEN, 3)[-1]
    plain = _open(progress, admin_key)
    assert plain["title"] == "余红旧事 可以先看了"
    assert plain["body"] == "第 1–25 集已入库，其余 8 集还在下载"
    assert not _rings(progress) and progress["collapse_id"] == started["collapse_id"]

    # 最后 8 集到齐：安静 2 分钟后收尾，离上次响已超过 15 分钟 → 响
    show.advance(20 * 60)
    show.land(range(26, 34))
    show.advance(2 * 60)
    final = _expect(world, ADMIN_TOKEN, 4)[-1]
    plain = _open(final, admin_key)
    assert plain["title"] == "余红旧事 第 1 季已全部入库"
    assert plain["body"] == "33 集都能看了，点开从第 1 集开始"
    assert plain["open"] == f"/library/{show.library_id}/item/{show.item_id}?season=1&episode=1"
    assert _rings(final) and final["collapse_id"] == started["collapse_id"]
    assert plain["category"] == "item"
    assert plain["actions"] == [
        {"id": "play", "title": "播放第 1 集", "open": f"/play/{show.item_id}/s01e01"},
        {
            "id": "open",
            "title": "查看全部剧集",
            "open": f"/library/{show.library_id}/item/{show.item_id}",
        },
        {"id": "mute", "title": "这部剧不再提醒", "item": show.item_id},
    ]
    assert plain["grid"] == {"season": 1, "cells": "d" * 33}
    # 家人：可以先看了、进度、全部入库，一共响两次
    member = _expect(world, MEMBER_TOKEN, 3)
    assert [_rings(m) for m in member] == [True, False, True]
    assert len({m["collapse_id"] for m in member}) == 1
    # IM：开始下载、可以先看、全部入库，进度不发
    _wait(lambda: len(im) == 3)
    assert im[1] == "🎬 可以先看了:《余红旧事》(2026) 第 1 季第 1–10 集已入库，其余 23 集还在下载"
    assert im[2] == "🎬 已入库:《余红旧事》(2026) 第 1 季已全部入库（33 集）"

    # 收尾后再报同一批（对账重跑）不会再响
    show.land([])
    show.advance(10 * 60)
    _expect(world, ADMIN_TOKEN, 4)


async def _no_image(_url: str) -> None:
    return None


def test_quick_batch_rings_once_and_close_rings_merge(
    client: TestClient, world: World, clock: FakeClock, phones
) -> None:  # type: ignore[no-untyped-def]
    """15 分钟内全部到齐只发一条；「可以先看」后很快到齐，收尾不再响。"""
    admin_key, _, _, _ = phones
    show = Show(client, clock)
    show.seed(episodes=12)
    show.grab(range(1, 13))
    show.advance(60)
    show.land(range(1, 7))
    show.advance(6 * 60)
    show.land(range(7, 13))
    show.advance(2 * 60)
    (only,) = _expect(world, ADMIN_TOKEN, 1)
    assert _rings(only)
    assert _open(only, admin_key)["title"] == "余红旧事 第 1 季已全部入库"

    # 第 2 批：先看了之后 3 分钟就到齐 → 收尾安静送达
    world.relays["push.test"].messages.clear()
    show2 = Show(client, clock)
    show2.item_id, show2.library_id, show2.subscription_id = (
        show.item_id,
        show.library_id,
        show.subscription_id,
    )
    show2.files = 100

    async def add_season_two() -> None:
        from movieclaw_db.engine import get_database
        from movieclaw_db.models import MediaEpisode, MediaSeason, WantedItem, utcnow

        async with get_database().session() as session:
            session.add(MediaSeason(media_item_id=show.item_id, season_number=2, episode_count=4))
            for episode in range(1, 5):
                session.add(
                    MediaEpisode(
                        media_item_id=show.item_id,
                        season_number=2,
                        episode_number=episode,
                        air_date=utcnow().date() - timedelta(days=3),
                    )
                )
                session.add(
                    WantedItem(
                        subscription_id=show.subscription_id,
                        media_item_id=show.item_id,
                        season_number=2,
                        episode_number=episode,
                        status="grabbed",
                        grabbed_at=utcnow(),
                    )
                )
            await session.commit()

    show.call(add_season_two)
    _land_season_two(show2, [1, 2])
    show.advance(15 * 60)
    partial = _expect(world, ADMIN_TOKEN, 1)[-1]
    plain = _open(partial, admin_key)
    assert plain["title"] == "余红旧事 可以先看了"
    # 有两季了：写季号
    assert plain["body"] == "第 2 季第 1–2 集已入库，其余 2 集还在下载"
    assert _rings(partial)
    show.advance(60)
    _land_season_two(show2, [3, 4])
    show.advance(2 * 60)
    final = _expect(world, ADMIN_TOKEN, 2)[-1]
    plain = _open(final, admin_key)
    assert plain["title"] == "余红旧事 第 2 季已全部入库"
    assert plain["body"] == "4 集都能看了，点开从第 1 季第 1 集开始"
    assert not _rings(final) and final["aps"]["interruption-level"] == "passive"


def _land_season_two(show: Show, episodes: list[int]) -> None:
    from movieclaw_api.services.push import hub
    from movieclaw_api.services.subscription.wanted_fulfillment import close_fulfilled_wanted
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import FileSource, LibraryFile

    async def go() -> None:
        async with get_database().session() as session:
            for episode in episodes:
                show.files += 1
                session.add(
                    LibraryFile(
                        library_id=show.library_id,
                        media_item_id=show.item_id,
                        season_number=2,
                        episode_number=episode,
                        file_path=f"/media/tv/{TITLE}/S02E{episode:02d}-{show.files}.mkv",
                        size_bytes=1,
                        source=FileSource.IMPORTED,
                    )
                )
            await session.commit()
            await close_fulfilled_wanted(session, show.item_id)
        await hub.drain()

    show.call(go)


def test_stuck_and_missing_endings(
    client: TestClient, world: World, clock: FakeClock, phones
) -> None:  # type: ignore[no-untyped-def]
    """剩下几集 2 小时没进展：说清楚还没下好；季包里缺的几集：说清楚还没找到资源。"""
    admin_key, _, _, _ = phones
    show = Show(client, clock)
    show.seed(episodes=33)
    show.grab(range(1, 34))
    show.advance(60)
    show.land(range(1, 31))
    show.advance(15 * 60)
    partial = _expect(world, ADMIN_TOKEN, 1)[0]
    assert _open(partial, admin_key)["body"] == "第 1–30 集已入库，其余 3 集还在下载"
    show.advance(2 * 3600)
    stuck = _expect(world, ADMIN_TOKEN, 2)[-1]
    plain = _open(stuck, admin_key)
    assert plain["title"] == "余红旧事 第 1–30 集已入库"
    assert plain["body"] == "第 31–33 集还没下好，下好了再告诉你"
    assert _rings(stuck) and stuck["collapse_id"] == partial["collapse_id"]
    assert plain["grid"] == {"season": 1, "cells": "d" * 30 + "www"}

    # 后来剩下的 3 集到了：新的一批，说的是这 3 集
    show.land(range(31, 34))
    show.advance(2 * 60)
    late = _expect(world, ADMIN_TOKEN, 3)[-1]
    assert _open(late, admin_key)["title"] == "余红旧事 第 1 季已全部入库"


def test_missing_episodes_are_named(
    client: TestClient, world: World, clock: FakeClock, phones
) -> None:  # type: ignore[no-untyped-def]
    admin_key, _, _, _ = phones
    show = Show(client, clock)
    show.seed(episodes=33)
    show.grab(range(1, 31))  # 季包里只有前 30 集，31–33 集早就播了、一直没找到
    show.advance(60)
    show.land(range(1, 31))
    show.advance(2 * 60)
    (final,) = _expect(world, ADMIN_TOKEN, 1)
    plain = _open(final, admin_key)
    assert plain["title"] == "余红旧事 第 1–30 集已入库"
    assert plain["body"] == "第 31–33 集还没找到资源，找到了再告诉你"
    assert plain["grid"] == {"season": 1, "cells": "d" * 30 + "mmm"}


# ----------------------------------------------------------------------
# 按观看进度说话
# ----------------------------------------------------------------------


def test_weekly_episode_speaks_to_each_viewer(
    client: TestClient, world: World, clock: FakeClock, phones
) -> None:  # type: ignore[no-untyped-def]
    from movieclaw_db.models import utcnow

    admin_key, member_key, _, _ = phones
    show = Show(client, clock)
    next_air = utcnow().date() + timedelta(days=7)
    show.seed(episodes=16, aired=8, next_air=next_air)
    show.grab(range(1, 8))
    show.land(range(1, 8))
    show.advance(3 * 60)
    _expect(world, ADMIN_TOKEN, 1)  # 前 7 集那一批（发完再清，免得晚到的混进下一批）
    _expect(world, MEMBER_TOKEN, 1)
    world.relays["push.test"].messages.clear()
    clock.t += 7 * 3600  # 一周后（早已不在「收尾后 6 小时」里）

    show.watched(0, list(range(1, 8)))  # 管理员正好追到第 7 集
    show.watched(1, [1, 2, 3])  # 家人看到第 3 集
    show.grab([8])
    show.land([8])
    show.advance(2 * 60)

    admin = _open(_expect(world, ADMIN_TOKEN, 1)[0], admin_key)
    assert admin["title"] == "余红旧事 第 8 集来了"
    assert admin["body"] == (
        f"你看到第 7 集，正好接上 · 第 9 集 {next_air.month} 月 {next_air.day} 日更新"
    )
    assert admin["open"].endswith("?season=1&episode=8")
    assert admin["actions"][0] == {
        "id": "play",
        "title": "播放第 8 集",
        "open": f"/play/{show.item_id}/s01e08",
    }
    assert admin["grid"]["cells"] == "s" * 7 + "d" + "-" * 8

    member_message = _expect(world, MEMBER_TOKEN, 1)[0]
    member = _open(member_message, member_key)
    assert member["title"] == "余红旧事 第 8 集来了"
    assert member["body"] == "你还有第 4–8 集没看，点开接着看第 4 集"
    assert member["open"].endswith("?season=1&episode=4")
    assert member["actions"][0]["title"] == "播放第 4 集"
    assert _rings(member_message)
    assert member_message["aps"]["relevance-score"] == 1.0  # 在追：通知摘要里排最前

    # 下一周：管理员一个多月没看（弃剧）→ 安静送达；家人清空了记录（没开始看）
    world.relays["push.test"].messages.clear()
    clock.t += 7 * 3600
    show.watched(0, list(range(1, 8)), days_ago=40)
    show.watched(1, [])

    async def air_nine() -> None:
        from sqlmodel import select

        from movieclaw_db.engine import get_database
        from movieclaw_db.models import WantedItem

        async with get_database().session() as session:
            row = (
                await session.execute(
                    select(WantedItem).where(
                        WantedItem.media_item_id == show.item_id, WantedItem.episode_number == 9
                    )
                )
            ).scalar_one()
            row.air_date = utcnow().date() - timedelta(days=1)
            session.add(row)
            await session.commit()

    show.call(air_nine)
    show.grab([9])
    show.land([9])
    show.advance(2 * 60)
    admin_message = _expect(world, ADMIN_TOKEN, 1)[0]
    admin = _open(admin_message, admin_key)
    assert admin["title"] == "余红旧事 第 9 集已入库"
    assert admin["body"] == "第 1 季第 9 集"
    assert not _rings(admin_message)
    assert admin_message["aps"]["interruption-level"] == "passive"
    assert admin["open"] == f"/library/{show.library_id}/item/{show.item_id}"
    member = _open(_expect(world, MEMBER_TOKEN, 1)[0], member_key)
    assert member["title"] == "余红旧事 更新到第 9 集了"
    assert member["body"] == "第 1–9 集都能看，点开从第 1 集开始"
    assert member["open"].endswith("?season=1&episode=1")


# ----------------------------------------------------------------------
# 这部剧不再提醒
# ----------------------------------------------------------------------


def test_mute_one_show(client: TestClient, world: World, clock: FakeClock, phones) -> None:  # type: ignore[no-untyped-def]
    _, member_key, member_bearer, _ = phones
    show = Show(client, clock)
    show.seed(episodes=10)

    view = _data(
        _as_app(client, member_bearer, "PUT", f"/api/v1/push/me/muted-items/{show.item_id}")
    )
    assert view["muted_items"] == [{"id": show.item_id, "title": TITLE, "year": 2026, "kind": "tv"}]
    assert (
        _as_app(client, member_bearer, "PUT", "/api/v1/push/me/muted-items/987654").status_code
        == 404
    )
    show.grab([1])
    show.land([1])
    show.advance(3 * 60)
    _expect(world, ADMIN_TOKEN, 1)
    assert _mine(world, MEMBER_TOKEN) == []  # 静音了：订阅照常，只是不推

    view = _data(
        _as_app(client, member_bearer, "DELETE", f"/api/v1/push/me/muted-items/{show.item_id}")
    )
    assert view["muted_items"] == []
    clock.t += 7 * 3600
    show.grab([2])
    show.land([2])
    show.advance(3 * 60)
    assert _open(_expect(world, MEMBER_TOKEN, 1)[0], member_key)["title"].startswith(TITLE)


# ----------------------------------------------------------------------
# 不碍主链路
# ----------------------------------------------------------------------


def test_emit_never_blocks_business(client: TestClient, world: World, monkeypatch) -> None:  # type: ignore[no-untyped-def]
    """业务侧只入队：消费者卡死时业务照常、几千个事件也只是几毫秒；积压到上限丢弃不报错。"""
    from movieclaw_api.services.push import cards, hub

    hub.emit(hub.Tick(key=(None, 1)))  # 没有事件循环（命令行工具）：直接丢，不报错

    gate = asyncio.Event()
    handled: list[object] = []

    async def stuck_consumer(event: object) -> None:
        handled.append(event)
        await gate.wait()

    monkeypatch.setattr(cards, "handle", stuck_consumer)
    monkeypatch.setattr(hub, "QUEUE_MAX", 2000)

    async def burst() -> float:
        hub.reset_state()
        started = time.perf_counter()
        for index in range(5000):
            hub.emit(hub.Tick(key=(None, index)))
        return time.perf_counter() - started

    assert client.portal is not None
    elapsed = client.portal.call(burst)
    assert elapsed < 0.5, elapsed  # 5000 次入队（含 3000 次满了丢弃）
    _wait(lambda: len(handled) == 1)  # 消费者卡在第一个事件上，业务没有被拖住

    async def release() -> None:
        gate.set()
        hub.reset_state()

    client.portal.call(release)

"""订阅链路的决策钩子（docs/design/plugin-phase2b.md §1、§2）。

真实的匹配流水线（dry-run 投递）+ 内核测试工具挂上的插件：插件淘汰 / 重排候选、追加关键词、
分流下载器、否决删种，都能改变决策；出错、超时、返回非法时一律回到默认实现。
"""

from __future__ import annotations

from contextlib import asynccontextmanager

import pytest
import pytest_asyncio
from sqlmodel import select
from tests.api.test_subscription_pipeline import (
    _EN,
    _KO,
    _S1_PACK_ATTRS,
    _ZH,
    _activities,
    _fake_search_by_keyword,
    _insert_torrent,
    _movie_hit,
    _service,
)

from movieclaw_api import hooks
from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import ConflictException
from movieclaw_api.services.subscription.matching import evaluate_and_dispatch
from movieclaw_api.settings.store import init_setting_store, reset_setting_store
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import ConfigStatus, DownloaderClient
from movieclaw_kernel import plugin
from movieclaw_kernel.testing import KernelHarness
from movieclaw_media.models import MediaKind


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    # 与 test_subscription_pipeline 同一套环境：dry-run 投递，隔离站点 / 下载器
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'hooks.db'}")
    monkeypatch.setenv("SUBSCRIPTION_DISPATCH_DRY_RUN", "true")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    init_setting_store()
    yield get_database()
    reset_setting_store()
    await dispose_db()
    get_settings.cache_clear()


@asynccontextmanager
async def listening(*bindings):
    """挂一个插件监听给定钩子，并把内核总线交给业务侧的钩子入口。"""

    @plugin("test.hooks", title="钩子测试")
    async def apply(ctx) -> None:
        for event, handler in bindings:
            ctx.on(event, handler)

    async with KernelHarness() as h:
        hooks.bind_bus(h.kernel.bus)
        try:
            fiber = await h.mount(apply)
            assert fiber.state.value == "active", fiber.error
            yield h
            await h.unmount(fiber)
        finally:
            hooks.unbind_bus(h.kernel.bus)


async def _show_with_single_and_pack(session):
    sub = await _service(session).create(MediaKind.TV, 200, selected_seasons=[1])
    single = await _insert_torrent(
        session,
        "single",
        "Test Show S01E01 2160p WEB-DL",
        {**_S1_PACK_ATTRS, "episodes": [1], "complete": None},
        seeders=500,
    )
    pack = await _insert_torrent(
        session, "pack", "Test Show S01 2160p WEB-DL", _S1_PACK_ATTRS, seeders=3
    )
    return sub, single, pack


async def _grabbed(session, sub_id) -> list[str]:
    return [
        a.payload["torrent_id"] for a in await _activities(session, sub_id) if a.type == "grabbed"
    ]


# ---------------------------------------------------------------------- 零开销
async def test_without_listeners_no_batch_is_built(db, monkeypatch) -> None:
    from movieclaw_api.services.subscription import matching

    def boom(*args, **kwargs):
        raise AssertionError("没有插件在听时不该构造候选批次")

    monkeypatch.setattr(matching, "_batch", boom)
    async with db.session() as session:
        sub, single, pack = await _show_with_single_and_pack(session)
        await evaluate_and_dispatch(session, [single, pack], source="被动匹配")
        assert await _grabbed(session, sub.id) == ["pack"]


# ---------------------------------------------------------------------- 淘汰
async def test_plugin_rejection_changes_the_pick_and_is_logged(db) -> None:
    async def no_packs(batch: hooks.CandidateBatch, next_) -> hooks.FilterResult:
        result = await next_()
        mine = tuple(
            hooks.Rejection(key=c.key, reason_code="no-pack", reason_text="本插件不要整季包")
            for c in batch.candidates
            if c.is_pack
        )
        return hooks.FilterResult(rejected=result.rejected + mine)

    async with listening((hooks.CANDIDATES_FILTER, no_packs)), db.session() as session:
        sub, single, pack = await _show_with_single_and_pack(session)
        await evaluate_and_dispatch(session, [single, pack], source="被动匹配")
        assert await _grabbed(session, sub.id) == ["single"]
        rejected = [a for a in await _activities(session, sub.id) if a.type == "match_rejected"]
        assert [a.payload["reason_code"] for a in rejected] == ["plugin:no-pack"]
        assert "本插件不要整季包" in rejected[0].message


async def test_broken_filter_falls_back_to_default(db) -> None:
    async def broken(batch, next_):
        raise RuntimeError("插件自己的 bug")

    async with listening((hooks.CANDIDATES_FILTER, broken)), db.session() as session:
        sub, single, pack = await _show_with_single_and_pack(session)
        await evaluate_and_dispatch(session, [single, pack], source="被动匹配")
        assert await _grabbed(session, sub.id) == ["pack"]


# ---------------------------------------------------------------------- 排序
async def test_plugin_rank_reorders_candidates(db) -> None:
    async def seeders_first(batch: hooks.CandidateBatch, next_) -> hooks.RankResult:
        await next_()
        ordered = sorted(batch.candidates, key=lambda c: -(c.seeders or 0))
        return hooks.RankResult(order=tuple(c.key for c in ordered))

    async with listening((hooks.CANDIDATES_RANK, seeders_first)), db.session() as session:
        sub, single, pack = await _show_with_single_and_pack(session)
        await evaluate_and_dispatch(session, [single, pack], source="被动匹配")
        # 单集先投（补 E01），整季包补剩下的 E02
        assert await _grabbed(session, sub.id) == ["single", "pack"]


async def test_rank_that_is_not_a_permutation_is_ignored(db) -> None:
    async def drops_one(batch: hooks.CandidateBatch, next_) -> hooks.RankResult:
        return hooks.RankResult(order=(batch.candidates[-1].key,))

    async with listening((hooks.CANDIDATES_RANK, drops_one)), db.session() as session:
        sub, single, pack = await _show_with_single_and_pack(session)
        await evaluate_and_dispatch(session, [single, pack], source="被动匹配")
        assert await _grabbed(session, sub.id) == ["pack"]


# ---------------------------------------------------------------------- 关键词
async def test_plugin_keywords_are_searched_and_capped(db, monkeypatch) -> None:
    from movieclaw_api.services.subscription.wanted_search import search_wanted

    calls: list = []
    _fake_search_by_keyword(
        monkeypatch,
        {"别名甲": [_movie_hit("alias1", f"{_EN} 2026 1080p WEB-DL", size_bytes=6 * 1024**3)]},
        calls,
    )

    async def more(payload: hooks.Keywords, next_) -> tuple:
        base = await next_()
        assert payload.purpose == "wanted" and payload.media.title
        return (*base, "别名甲", *(f"多余{i}" for i in range(10)))

    async with listening((hooks.SEARCH_KEYWORDS, more)):
        async with db.session() as session:
            await _service(session).create(MediaKind.MOVIE, 104)
        await search_wanted()
    # 内部推导的三个词在前，插件追加的跟在后面，总数截到 6
    assert calls[:4] == [_EN, _ZH, _KO, "别名甲"]
    assert len(calls) == hooks.MAX_KEYWORDS


# ---------------------------------------------------------------------- 下载器
async def _two_downloaders(session) -> tuple[int, int, int]:
    rows = [
        DownloaderClient(
            name="默认",
            client_type="qbittorrent",
            url="http://a",
            is_default=True,
            enabled=True,
            status=ConfigStatus.ACTIVE,
        ),
        DownloaderClient(
            name="大文件",
            client_type="qbittorrent",
            url="http://b",
            enabled=True,
            status=ConfigStatus.ACTIVE,
        ),
        DownloaderClient(
            name="停用的",
            client_type="qbittorrent",
            url="http://c",
            enabled=False,
            status=ConfigStatus.ACTIVE,
        ),
    ]
    session.add_all(rows)
    await session.commit()
    return rows[0].id, rows[1].id, rows[2].id


async def test_plugin_routes_big_downloads_to_another_downloader(db) -> None:
    from movieclaw_api.services.torrent_submit import pick_downloader

    async with db.session() as session:
        default_id, big_id, disabled_id = await _two_downloaders(session)

    def by_size(query: hooks.DownloaderQuery) -> hooks.DownloaderChoice | None:
        if (query.size_bytes or 0) > 50 * 1024**3:
            return hooks.DownloaderChoice(downloader_id=big_id, reason="大于 50 GB")
        if query.title == "要停用的":
            return hooks.DownloaderChoice(downloader_id=disabled_id)
        return None

    async with listening((hooks.DOWNLOADER_SELECT, by_size)), db.session() as session:
        big = await pick_downloader(
            session, hooks.DownloaderQuery(site_id="s", size_bytes=80 * 1024**3)
        )
        small = await pick_downloader(
            session, hooks.DownloaderQuery(site_id="s", size_bytes=1024**3)
        )
        bad = await pick_downloader(session, hooks.DownloaderQuery(title="要停用的"))
        unasked = await pick_downloader(session, None)
    assert (big.id, small.id, bad.id, unasked.id) == (big_id, default_id, default_id, default_id)


# ---------------------------------------------------------------------- 删种否决
async def test_plugin_can_veto_a_torrent_deletion(db, monkeypatch) -> None:
    from movieclaw_api.services import download_tasks

    async with db.session() as session:
        default_id, _, _ = await _two_downloaders(session)
    deleted: list[str] = []

    class Adapter:
        async def delete_torrent(self, info_hash, *, delete_files=False):
            deleted.append(info_hash)

        async def close(self):
            return None

    monkeypatch.setattr(download_tasks, "create_downloader", lambda config: Adapter())
    monkeypatch.setattr(
        download_tasks.DownloaderRepository, "decrypted_password", lambda self, row: None
    )

    def hr_guard(event: hooks.TorrentDeletion) -> hooks.Veto | None:
        return hooks.Veto(reason="H&R 还差 20 小时") if event.info_hash.startswith("a") else None

    async with listening((hooks.TORRENT_BEFORE_DELETE, hr_guard)), db.session() as session:
        with pytest.raises(ConflictException, match="H&R 还差 20 小时"):
            await download_tasks.delete_download_task(
                session, downloader_id=default_id, info_hash="a" * 40
            )
        await download_tasks.delete_download_task(
            session, downloader_id=default_id, info_hash="b" * 40
        )
    assert deleted == ["b" * 40]


async def test_downloaders_selected_explicitly_are_never_overridden(db) -> None:
    async with db.session() as session:
        _, big_id, _ = await _two_downloaders(session)
        rows = (await session.execute(select(DownloaderClient))).scalars().all()
        assert len(rows) == 3
    # submit_torrent 只在 downloader_id 为空时才调 pick_downloader（见 torrent_submit.py）；
    # 这里锁住契约：显式指定的下载器（智能订阅冻结的意图、手动选择）不经过钩子
    import inspect

    from movieclaw_api.services import torrent_submit

    source = inspect.getsource(torrent_submit.submit_torrent)
    explicit = source.index("if downloader_id is not None:")
    picked = source.index("pick_downloader(session, route_hint)")
    assert explicit < picked

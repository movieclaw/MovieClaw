"""订阅上限下的整包（docs/design/subscription-episode-cap.md §4）。

夹具：《长篇漫剧》站点上只有一个 12 集的整季包。订阅上限先订阅前 3 集，包以暂停态进下载器、
只勾前 3 个文件；用户调大上限后，下一批候选仍是**同一个包**——

- 严格取舍：带上限的规则订阅，整包选不出文件时**不回落全量**（整包可能是上千集）；
- 并入已有的包：新单元的文件并进它的选中集合并恢复下载，而不是当作重复投递。
  此前规则模式下新工单会永远挂在 GRABBED 上（已存在的任务不动文件选中集合），
  智能模式下候选被「与本订阅已有下载记录相同」拒掉。
"""

from __future__ import annotations

from datetime import timedelta
from types import SimpleNamespace

import httpx
import pytest
import pytest_asyncio
from sqlmodel import select

import movieclaw_api.services.subscription.pack_extension as pack_extension
import movieclaw_api.services.torrent_submit as torrent_submit_service
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.media_library import MediaLibraryService
from movieclaw_api.services.site_access import SiteUnavailableError
from movieclaw_api.services.subscription import SubscriptionService
from movieclaw_api.services.subscription.dispatch import dispatch
from movieclaw_api.services.subscription.episode_cap import EpisodeCap
from movieclaw_api.services.subscription.file_selection import UnsatisfiableSelection
from movieclaw_api.services.subscription.pack_extension import (
    ExtensionRefused,
    extend_owned_pack,
)
from movieclaw_api.services.subscription.smart_profiles import save_profile
from movieclaw_api.settings.store import init_setting_store, reset_setting_store
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    DownloadAttemptStatus,
    DownloaderClient,
    MediaItem,
    Subscription,
    SubscriptionActivity,
    SubscriptionDownloadAttempt,
    WantedItem,
    WantedStatus,
)
from movieclaw_db.models.base import utcnow
from movieclaw_db.models.site_credential import ConfigStatus
from movieclaw_downloader.models import SubmitResult, TorrentFile, TorrentStatus
from movieclaw_enrich.models import TorrentAttrs
from movieclaw_matcher import IdentityMatch, RuleVerdict, TorrentCandidate
from movieclaw_matcher.smart import SmartPreferences
from movieclaw_media.models import MediaKind
from movieclaw_media.tmdb import TmdbClient

_KEY = "0123456789abcdef0123456789abcdef"
_AIRED = (utcnow().date() - timedelta(days=30)).isoformat()
HASH = "c" * 40
PACK_FILES = [
    f"Long.Comic.Drama.S01/Long.Comic.Drama.S01E{n:02d}.1080p.WEB-DL.mkv" for n in range(1, 13)
]
_ROUTES = {
    "/3/tv/1043": {
        "id": 1043,
        "name": "长篇漫剧",
        "original_name": "Long Comic Drama",
        "first_air_date": "2025-01-01",
        "status": "Ended",
        "external_ids": {},
        "alternative_titles": {"results": []},
        "translations": {"translations": []},
        "seasons": [{"season_number": 1}],
    },
    "/3/tv/1043/season/1": {
        "name": "第 1 季",
        "air_date": "2025-01-01",
        "episodes": [
            {"episode_number": n, "name": f"E{n}", "air_date": _AIRED} for n in range(1, 13)
        ],
    },
}


# ---------------------------------------------------------------------------
# 夹具：数据库、假 TMDB、假站点、有状态的假下载器
# ---------------------------------------------------------------------------


def _fake_tmdb() -> TmdbClient:
    def handler(request: httpx.Request) -> httpx.Response:
        payload = _ROUTES.get(request.url.path)
        return httpx.Response(200 if payload else 404, json=payload or {})

    return TmdbClient(_KEY, transport=httpx.MockTransport(handler))


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'pack.db'}")
    monkeypatch.setenv("SUBSCRIPTION_DISPATCH_DRY_RUN", "false")
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    init_setting_store()
    yield get_database()
    reset_setting_store()
    await dispose_db()
    get_settings.cache_clear()


@pytest_asyncio.fixture
async def downloader_row_id(db) -> int:
    async with db.session() as session:
        row = DownloaderClient(
            name="家里的 qBittorrent",
            client_type="qbittorrent",
            url="http://192.168.1.10:8080",
            save_path="/downloads",
            enabled=True,
            is_default=True,
            status=ConfigStatus.ACTIVE,
        )
        session.add(row)
        await session.commit()
        return row.id


def _service(session) -> SubscriptionService:
    return SubscriptionService(session, MediaLibraryService(session, _fake_tmdb()))


class _FakeSite:
    async def download_torrent(self, url: str) -> bytes:
        return b"torrent-bytes"


class _FakeSiteAccess:
    async def get(self, site_id: str):
        if site_id == "nosite":
            raise SiteUnavailableError(f"站点未配置：{site_id}")
        return _FakeSite()


class _Downloader:
    """有状态的假下载器：任务、文件选中、标签随调用变化，调用顺序可断言。"""

    def __init__(self) -> None:
        self.tasks: dict[str, dict] = {}
        self.requests: list = []
        self.selection_calls: list[tuple[str, list[int]]] = []
        self.resume_calls: list[str] = []
        self.deleted: list[tuple[str, bool]] = []
        self.ignore_selection = False  # 模拟写了优先级却回读不一致

    def add_task(self, files: list[str], *, selected: int | None = None, tags=()) -> None:
        count = len(files) if selected is None else selected
        self.tasks[HASH] = {
            "files": [
                TorrentFile(index=i, path=path, size_bytes=1_000, selected=i < count)
                for i, path in enumerate(files)
            ],
            "tags": list(tags),
            "state": "completed",
        }

    def selected(self) -> list[int]:
        return [f.index for f in self.tasks[HASH]["files"] if f.selected]

    async def submit(self, request):
        self.requests.append(request)
        existed = HASH in self.tasks
        if not existed:
            self.add_task(PACK_FILES, tags=request.tags)
            self.tasks[HASH]["state"] = "paused" if request.paused else "downloading"
        return SubmitResult(info_hash=HASH, name="Pack", already_exists=existed)

    async def get_torrent(self, info_hash: str, *, include_files: bool = True):
        task = self.tasks.get(info_hash)
        if task is None:
            return None
        return TorrentStatus(
            info_hash=info_hash,
            name="Pack",
            progress=0.0,
            completed=False,
            save_path="/downloads",
            state=task["state"],
            tags=task["tags"],
            files=[f.model_copy() for f in task["files"]],
        )

    async def set_file_selection(self, info_hash: str, selected_indices: list[int]) -> None:
        self.selection_calls.append((info_hash, selected_indices))
        if self.ignore_selection:
            return
        for f in self.tasks[info_hash]["files"]:
            f.selected = f.index in selected_indices

    async def resume(self, info_hash: str) -> None:
        self.resume_calls.append(info_hash)
        self.tasks[info_hash]["state"] = "downloading"

    async def delete_torrent(self, info_hash: str, *, delete_files: bool = False) -> None:
        self.deleted.append((info_hash, delete_files))
        self.tasks.pop(info_hash, None)

    async def close(self) -> None:
        pass


def _install_for_submit(monkeypatch, downloader: _Downloader) -> None:
    monkeypatch.setattr(torrent_submit_service, "create_downloader", lambda config: downloader)
    monkeypatch.setattr(torrent_submit_service, "get_site_access", lambda: _FakeSiteAccess())


_SUBMIT = dict(
    site_id="mteam",
    download_url="https://example.org/download.php?id=1",
    tags=["movieclaw-sub"],
    selection_owner="movieclaw-cap-1",
    strict_selection=True,
)
_FIRST_THREE = {(1, 1), (1, 2), (1, 3)}


# ---------------------------------------------------------------------------
# 严格取舍：新任务选不出文件时不回落全量
# ---------------------------------------------------------------------------


class TestStrictSelection:
    async def test_new_task_keeps_only_the_needed_files(
        self, db, downloader_row_id, monkeypatch
    ) -> None:
        fake = _Downloader()
        _install_for_submit(monkeypatch, fake)
        async with db.session() as session:
            result, _row = await torrent_submit_service.submit_torrent(
                session, **_SUBMIT, select_units=_FIRST_THREE, known_seasons=[1]
            )
        assert fake.requests[0].paused is True and "movieclaw-cap-1" in fake.requests[0].tags
        assert fake.selected() == [0, 1, 2]
        assert fake.resume_calls == [HASH]
        assert result.skipped_file_count == 9 and result.already_exists is False

    async def test_unmappable_pack_is_never_downloaded_in_full(
        self, db, downloader_row_id, monkeypatch
    ) -> None:
        """包里缺第 2、3 集的文件：宽松路径会全量恢复（整包可能上千集），严格路径移除任务。

        文件清单的结论按 ``UnsatisfiableSelection`` 原样抛出（不包成下载器故障），
        调用方据此收窄。"""

        class _ShortPack(_Downloader):
            async def submit(self, request):
                self.requests.append(request)
                self.add_task(PACK_FILES[:1], tags=request.tags)
                self.tasks[HASH]["state"] = "paused"
                return SubmitResult(info_hash=HASH, name="Pack")

        fake = _ShortPack()
        _install_for_submit(monkeypatch, fake)
        async with db.session() as session:
            with pytest.raises(UnsatisfiableSelection):
                await torrent_submit_service.submit_torrent(
                    session, **_SUBMIT, select_units=_FIRST_THREE, known_seasons=[1]
                )
        assert fake.resume_calls == []  # 绝不恢复成全量下载
        assert fake.deleted == [(HASH, False)]  # 刚加的暂停任务移除，且不碰落点上的文件

    async def test_existing_task_is_left_alone(self, db, downloader_row_id, monkeypatch) -> None:
        fake = _Downloader()
        fake.add_task(PACK_FILES)  # 用户自己的在途任务，没有我们的标签
        _install_for_submit(monkeypatch, fake)
        async with db.session() as session:
            result, _row = await torrent_submit_service.submit_torrent(
                session, **_SUBMIT, select_units=_FIRST_THREE, known_seasons=[1]
            )
        assert result.already_exists is True
        assert fake.selection_calls == [] and fake.resume_calls == [] and fake.deleted == []
        assert fake.selected() == list(range(12))


# ---------------------------------------------------------------------------
# 并入已有的包：extend_owned_pack
# ---------------------------------------------------------------------------


def _candidate(torrent_id: str = "pack") -> TorrentCandidate:
    return TorrentCandidate(
        site_id="testsite",
        torrent_id=torrent_id,
        title="Long Comic Drama S01 1080p WEB-DL",
        subtitle="",
        attrs=TorrentAttrs.model_validate(
            {"media_type": "tv", "year": 2025, "seasons": [1], "complete": True}
        ),
    )


async def _owned_attempt(
    session,
    sub: Subscription,
    downloader_id: int | None,
    *,
    status: str = DownloadAttemptStatus.COMPLETED,
    owned: bool = True,
    units=((1, 1), (1, 2), (1, 3)),
) -> SubscriptionDownloadAttempt:
    attempt = SubscriptionDownloadAttempt(
        subscription_id=sub.id,
        downloader_id=downloader_id,
        info_hash=HASH,
        site_id="testsite",
        torrent_id="pack",
        torrent_title="Long Comic Drama S01",
        units=[list(u) for u in units],
        status=status,
        owned_by_movieclaw=owned,
        last_progress_at=utcnow(),
    )
    session.add(attempt)
    await session.commit()
    return attempt


@pytest.fixture
def adapter(monkeypatch) -> _Downloader:
    fake = _Downloader()
    monkeypatch.setattr(pack_extension, "create_downloader", lambda config: fake)
    return fake


_NEXT_THREE = {(1, 4), (1, 5), (1, 6)}


class TestExtendOwnedPack:
    async def test_adds_new_files_to_the_selection_and_resumes(
        self, db, downloader_row_id, adapter
    ) -> None:
        adapter.add_task(PACK_FILES, selected=3)
        async with db.session() as session:
            sub = await _service(session).create(
                MediaKind.TV, 1043, selected_seasons=[1], episode_caps={1: EpisodeCap(1, 6)}
            )
            await _owned_attempt(session, sub, downloader_row_id)
            extended = await extend_owned_pack(
                session, subscription=sub, candidate=_candidate(), targets=_NEXT_THREE
            )
        assert extended is not None
        result, row = extended
        # 选中集合 = 此前认领的 ∪ 新单元，只增不减
        assert adapter.selected() == [0, 1, 2, 3, 4, 5]
        assert adapter.resume_calls == [HASH]
        assert result.info_hash == HASH and result.skipped_file_count == 6
        assert result.already_exists is False and row.id == downloader_row_id

    @pytest.mark.parametrize(
        "case", ["no_attempt", "not_ours", "cancelled", "downloader_off", "gone_from_downloader"]
    )
    async def test_not_applicable_returns_none_and_touches_nothing(
        self, db, downloader_row_id, adapter, case
    ) -> None:
        if case != "gone_from_downloader":
            adapter.add_task(PACK_FILES, selected=3)
        async with db.session() as session:
            sub = await _service(session).create(
                MediaKind.TV, 1043, selected_seasons=[1], episode_caps={1: EpisodeCap(1, 6)}
            )
            if case != "no_attempt":
                await _owned_attempt(
                    session,
                    sub,
                    downloader_row_id,
                    owned=case != "not_ours",
                    status=(
                        DownloadAttemptStatus.CANCELLED
                        if case == "cancelled"
                        else DownloadAttemptStatus.COMPLETED
                    ),
                )
            if case == "downloader_off":
                row = await session.get(DownloaderClient, downloader_row_id)
                row.enabled = False
                session.add(row)
                await session.commit()
            result = await extend_owned_pack(
                session, subscription=sub, candidate=_candidate(), targets=_NEXT_THREE
            )
        assert result is None
        assert adapter.selection_calls == [] and adapter.resume_calls == []

    async def test_refuses_when_the_pack_lacks_a_needed_unit(
        self, db, downloader_row_id, adapter
    ) -> None:
        adapter.add_task(PACK_FILES[:5], selected=3)  # 包里没有第 6 集
        async with db.session() as session:
            sub = await _service(session).create(
                MediaKind.TV, 1043, selected_seasons=[1], episode_caps={1: EpisodeCap(1, 6)}
            )
            await _owned_attempt(session, sub, downloader_row_id)
            with pytest.raises(ExtensionRefused):
                await extend_owned_pack(
                    session, subscription=sub, candidate=_candidate(), targets=_NEXT_THREE
                )
        assert adapter.selection_calls == [] and adapter.resume_calls == []

    async def test_unverified_selection_is_not_resumed(
        self, db, downloader_row_id, adapter
    ) -> None:
        adapter.add_task(PACK_FILES, selected=3)
        adapter.ignore_selection = True
        async with db.session() as session:
            sub = await _service(session).create(
                MediaKind.TV, 1043, selected_seasons=[1], episode_caps={1: EpisodeCap(1, 6)}
            )
            await _owned_attempt(session, sub, downloader_row_id)
            with pytest.raises(RuntimeError):
                await extend_owned_pack(
                    session, subscription=sub, candidate=_candidate(), targets=_NEXT_THREE
                )
        assert adapter.resume_calls == []


# ---------------------------------------------------------------------------
# 端到端：调大上限 → 下一批认领 → 并入原来的包（真实 dispatch 台账）
# ---------------------------------------------------------------------------


async def _dispatch(session, sub, rows, *, versions=None):
    return await dispatch(
        session,
        subscription=sub,
        item=await session.get(MediaItem, sub.media_item_id),
        wanted_rows=rows,
        candidate=_candidate(),
        verdict=RuleVerdict(accepted=True, score=1),
        source="测试",
        match=IdentityMatch(pack_seasons=frozenset({1})),
        selection_versions=versions,
    )


async def _wanted(session, sub_id: int) -> dict[tuple[int, int], WantedItem]:
    rows = (
        (await session.execute(select(WantedItem).where(WantedItem.subscription_id == sub_id)))
        .scalars()
        .all()
    )
    return {(w.season_number, w.episode_number): w for w in rows}


async def _attempts(session, sub_id: int) -> list[SubscriptionDownloadAttempt]:
    return list(
        (
            await session.execute(
                select(SubscriptionDownloadAttempt).where(
                    SubscriptionDownloadAttempt.subscription_id == sub_id
                )
            )
        )
        .scalars()
        .all()
    )


def _stub_submit(monkeypatch, downloader_id: int, *, smart: bool = False) -> dict:
    """第一批走真实台账，只把「网络提交」换成桩；记下投递层收到的参数。"""
    from importlib import import_module

    module = import_module("movieclaw_api.services.subscription.dispatch")
    seen: dict = {"calls": 0}

    async def submit(*args, **kwargs):
        seen["calls"] += 1
        seen["kwargs"] = kwargs
        if smart:
            await kwargs["before_submit"](HASH, downloader_id)
        return SubmitResult(info_hash=HASH, name="Pack"), SimpleNamespace(id=downloader_id)

    monkeypatch.setattr(module, "_submit_real", submit)
    return seen


async def test_rules_mode_next_batch_extends_the_pack_instead_of_resubmitting(
    db, downloader_row_id, adapter, monkeypatch
) -> None:
    seen = _stub_submit(monkeypatch, downloader_row_id)
    async with db.session() as session:
        service = _service(session)
        sub = await service.create(
            MediaKind.TV, 1043, selected_seasons=[1], episode_caps={1: EpisodeCap(1, 3)}
        )
        rows = await _wanted(session, sub.id)
        assert await _dispatch(session, sub, [rows[(1, n)] for n in (1, 2, 3)])
        # 带上限的规则订阅：投递层要求严格取舍，且给任务打上稳定的所有者标签
        assert seen["kwargs"]["strict_selection"] is True
        assert seen["kwargs"]["selection_owner"] == f"movieclaw-cap-{sub.id}"
        assert seen["kwargs"]["select_units"] == _FIRST_THREE

        # 第一批下完：下载器里的包只勾了前 3 个文件；用户调大上限
        adapter.add_task(PACK_FILES, selected=3)
        await service.update(sub.id, episode_caps={1: EpisodeCap(1, 6)})
        rows = await _wanted(session, sub.id)
        assert all(rows[(1, n)].status == WantedStatus.WANTED for n in (4, 5, 6))
        assert await _dispatch(session, sub, [rows[(1, n)] for n in (4, 5, 6)])

        assert seen["calls"] == 1  # 第二批没有重新投递
        assert adapter.selected() == [0, 1, 2, 3, 4, 5] and adapter.resume_calls == [HASH]
        rows = await _wanted(session, sub.id)
        for n in (4, 5, 6):
            assert rows[(1, n)].status == WantedStatus.GRABBED and rows[(1, n)].info_hash == HASH
        (attempt,) = await _attempts(session, sub.id)
        assert sorted(attempt.units) == [[1, n] for n in range(1, 7)]
        assert attempt.status == DownloadAttemptStatus.ACTIVE and attempt.owned_by_movieclaw
        grabbed = [
            a
            for a in (
                await session.execute(
                    select(SubscriptionActivity).where(
                        SubscriptionActivity.subscription_id == sub.id,
                        SubscriptionActivity.type == "grabbed",
                    )
                )
            ).scalars()
        ]
        assert [a.payload["info_hash"] for a in grabbed] == [HASH, HASH]


async def test_smart_mode_next_batch_extends_the_pack_and_drops_its_intent(
    db, downloader_row_id, adapter, monkeypatch
) -> None:
    """智能订阅：下一批的意图并进原来的尝试，意图行不留在「提交中」。"""
    seen = _stub_submit(monkeypatch, downloader_row_id, smart=True)
    async with db.session() as session:
        await save_profile(session, "tv", SmartPreferences(wait_seconds=0), 0)
        service = _service(session)
        sub = await service.create(
            MediaKind.TV,
            1043,
            selected_seasons=[1],
            selection_mode="smart",
            smart_profile_revision=1,
            episode_caps={1: EpisodeCap(1, 3)},
        )
        rows = await _wanted(session, sub.id)
        first = [rows[(1, n)] for n in (1, 2, 3)]
        assert await _dispatch(
            session, sub, first, versions={r.id: r.selection_version for r in first}
        )

        adapter.add_task(PACK_FILES, selected=3)
        await service.update(sub.id, episode_caps={1: EpisodeCap(1, 6)})
        rows = await _wanted(session, sub.id)
        second = [rows[(1, n)] for n in (4, 5, 6)]
        assert await _dispatch(
            session, sub, second, versions={r.id: r.selection_version for r in second}
        )

        assert seen["calls"] == 1
        assert adapter.selected() == [0, 1, 2, 3, 4, 5] and adapter.resume_calls == [HASH]
        rows = await _wanted(session, sub.id)
        for n in (4, 5, 6):
            assert rows[(1, n)].status == WantedStatus.GRABBED and rows[(1, n)].info_hash == HASH
            assert rows[(1, n)].selection_state["reason"] == "submitted"
        (attempt,) = await _attempts(session, sub.id)  # 第二批的意图行已并入、不残留
        assert sorted(attempt.units) == [[1, n] for n in range(1, 7)]
        assert attempt.status == DownloadAttemptStatus.ACTIVE


async def test_refused_extension_releases_the_claim_without_looping(
    db, downloader_row_id, adapter, monkeypatch
) -> None:
    """包里补选不了这批集：工单回到 wanted，不留「提交中」的意图被恢复任务反复重放。"""
    _stub_submit(monkeypatch, downloader_row_id, smart=True)
    async with db.session() as session:
        await save_profile(session, "tv", SmartPreferences(wait_seconds=0), 0)
        service = _service(session)
        sub = await service.create(
            MediaKind.TV,
            1043,
            selected_seasons=[1],
            selection_mode="smart",
            smart_profile_revision=1,
            episode_caps={1: EpisodeCap(1, 3)},
        )
        rows = await _wanted(session, sub.id)
        first = [rows[(1, n)] for n in (1, 2, 3)]
        await _dispatch(session, sub, first, versions={r.id: r.selection_version for r in first})

        adapter.add_task(PACK_FILES[:5], selected=3)  # 包里没有第 6 集
        await service.update(sub.id, episode_caps={1: EpisodeCap(1, 6)})
        rows = await _wanted(session, sub.id)
        second = [rows[(1, n)] for n in (4, 5, 6)]
        assert not await _dispatch(
            session, sub, second, versions={r.id: r.selection_version for r in second}
        )

        rows = await _wanted(session, sub.id)
        assert all(rows[(1, n)].status == WantedStatus.WANTED for n in (4, 5, 6))
        assert adapter.resume_calls == []
        statuses = sorted(a.status for a in await _attempts(session, sub.id))
        assert statuses == [DownloadAttemptStatus.ACTIVE, DownloadAttemptStatus.FAILED]

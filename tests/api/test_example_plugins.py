"""二 A 的验收插件端到端（docs/design/plugin-phase2a.md §7）。

把 ``examples/plugins/`` 里的插件当本地受信插件装进临时数据目录，真实应用、真实鉴权
（只有测试自己的请求用超管登录，插件经宿主操作用自己的凭证），走完用户场景：

- 删片联动（场景 2.1）：删条目 → 可靠事件 → 插件先删订阅、再删自有且无 H&R 的种子；演练模式不删；
  部分删除时不动在追订阅的季包；
- 片单订阅（场景 2.4）：片单里的新片名 → 搜索 → 订阅；重复出现不重复订阅。
"""

from __future__ import annotations

import asyncio
import json
import shutil
import textwrap
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient
from sqlmodel import func, select
from tests.api.test_domain_events import seed_show

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import durable_events
from movieclaw_db.engine import get_database
from movieclaw_db.models import EventConsumer, Subscription

EXAMPLES = Path(__file__).resolve().parents[2] / "examples" / "plugins"
ADMIN = {"username": "admin", "password": "s3cret-pass"}
HASH = "c" * 40


@pytest.fixture(params=["inline", "process"])
def runtime(request) -> str:
    """同一个插件在主进程里跑一遍、在独立进程里再跑一遍。

    plugin-phase3.md §0 的硬指标：运行位置对插件透明。
    """
    return request.param


@pytest.fixture
def data_dir(tmp_path, monkeypatch):
    import sys

    from movieclaw_api.services.auth import reset_auth_state
    from movieclaw_api.settings import reset_setting_store
    from movieclaw_db.crypto import reset_secret_box

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'examples.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "0" * 32)
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    (tmp_path / "plugins").mkdir()
    yield tmp_path
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    get_settings.cache_clear()


def install(data_dir: Path, module: str, patch_yaml: str) -> None:
    shutil.copy(EXAMPLES / f"{module}.py", data_dir / "plugins" / f"{module}.py")
    (data_dir / "plugins.yaml").write_text(textwrap.dedent(patch_yaml), encoding="utf-8")


def wait(client: TestClient, check, timeout: float = 10.0) -> None:
    async def poll() -> None:
        async with asyncio.timeout(timeout):
            while not await check():
                await asyncio.sleep(0.05)

    client.portal.call(poll)


async def consumers_ready(n: int) -> bool:
    async with get_database().session() as session:
        count = await session.scalar(select(func.count()).select_from(EventConsumer))
    return (count or 0) >= n


async def subscription_count() -> int:
    async with get_database().session() as session:
        return await session.scalar(select(func.count()).select_from(Subscription)) or 0


class FakeDownloader:
    """记录删种调用，并记下删种那一刻订阅还在不在（验证「先删订阅」）。"""

    def __init__(self) -> None:
        self.deleted: list[tuple[str, bool, int]] = []
        self.looked_up: list[str] = []

    def adapter(self, config):
        fake = self

        class Adapter:
            async def get_torrent(self, info_hash, *, include_files=True):
                from movieclaw_downloader import TorrentStatus

                fake.looked_up.append(info_hash)
                return TorrentStatus(
                    info_hash=info_hash,
                    name="Test.Show.S01.1080p",
                    progress=1.0,
                    completed=True,
                    save_path="/downloads",
                    files=[],
                )

            async def delete_torrent(self, info_hash, *, delete_files=False):
                fake.deleted.append((info_hash, delete_files, await subscription_count()))

            async def close(self):
                return None

        return Adapter()


@pytest.fixture
def downloader(monkeypatch) -> FakeDownloader:
    from movieclaw_api.services import download_tasks

    fake = FakeDownloader()
    monkeypatch.setattr(download_tasks, "create_downloader", fake.adapter)
    monkeypatch.setattr(
        download_tasks.DownloaderRepository, "decrypted_password", lambda self, row: None
    )
    return fake


def start(data_dir: Path) -> tuple[object, TestClient]:
    from movieclaw_api.app import create_app

    app = create_app()
    return app, TestClient(app)


def login_admin(client: TestClient) -> None:
    resp = client.post("/api/v1/auth/bootstrap", json=ADMIN)
    assert resp.status_code == 200, resp.text


# ---------------------------------------------------------------------- 删片联动
CASCADE_YAML = """
- id: examples.delete-cascade
  local: true
  runtime: {runtime}
  config: {{delete_files: true, dry_run: {dry_run}}}
  grants: [subscriptions.delete, dl.torrent.delete]
"""


def test_deleting_a_show_removes_its_subscription_then_its_torrent(
    data_dir, downloader, runtime
) -> None:
    install(data_dir, "delete_cascade", CASCADE_YAML.format(dry_run="false", runtime=runtime))
    app, client = start(data_dir)
    with client:
        login_admin(client)
        plugins = {p["id"]: p for p in client.get("/api/v1/app/plugins").json()["data"]["plugins"]}
        assert plugins["examples.delete-cascade"]["state"] == "active"
        assert plugins["examples.delete-cascade"]["source"] == "local"
        wait(client, lambda: consumers_ready(2))

        seeded = client.portal.call(lambda: seed_show(get_database(), data_dir, info_hash=HASH))
        resp = client.delete(f"/api/v1/libraries/{seeded['library_id']}/items/{seeded['item_id']}")
        assert resp.status_code == 200, resp.text

        async def cleaned() -> bool:
            return bool(downloader.deleted) and await subscription_count() == 0

        wait(client, cleaned)
    # 删种时订阅已经不在：否则那几集会被打回「想要」重新下载
    assert downloader.deleted == [(HASH, True, 0)]


def test_dry_run_only_rehearses(data_dir, downloader, runtime) -> None:
    install(data_dir, "delete_cascade", CASCADE_YAML.format(dry_run="true", runtime=runtime))
    app, client = start(data_dir)
    with client:
        login_admin(client)
        wait(client, lambda: consumers_ready(2))
        seeded = client.portal.call(lambda: seed_show(get_database(), data_dir, info_hash=HASH))
        resp = client.delete(f"/api/v1/libraries/{seeded['library_id']}/items/{seeded['item_id']}")
        assert resp.status_code == 200

        async def rehearsed() -> bool:
            return bool(downloader.looked_up)

        wait(client, rehearsed)
        assert client.portal.call(subscription_count) == 1
    assert downloader.deleted == []
    assert downloader.looked_up == [HASH]


def test_deleting_one_episode_keeps_the_season_pack_of_a_followed_show(
    data_dir, downloader, runtime
) -> None:
    install(data_dir, "delete_cascade", CASCADE_YAML.format(dry_run="false", runtime=runtime))
    app, client = start(data_dir)
    with client:
        login_admin(client)
        wait(client, lambda: consumers_ready(2))
        seeded = client.portal.call(lambda: seed_show(get_database(), data_dir, info_hash=HASH))
        resp = client.delete(
            f"/api/v1/libraries/{seeded['library_id']}/items/{seeded['item_id']}"
            f"/files/{seeded['file_ids'][0]}"
        )
        assert resp.status_code == 200

        async def handled() -> bool:
            async with get_database().session() as session:
                state = await session.get(EventConsumer, "examples.delete-cascade:file")
            return state is not None and state.cursor > 0

        wait(client, handled)
        assert client.portal.call(subscription_count) == 1
    assert downloader.deleted == []


# ---------------------------------------------------------------------- 片单订阅
def test_watchlist_titles_become_subscriptions_once(data_dir, monkeypatch, runtime) -> None:
    from movieclaw_api.api.routes import subscriptions as subscription_routes
    from movieclaw_api.schemas.discover import DiscoveredTitleView
    from movieclaw_api.services.title_discovery import (
        TitleSearchOutcome,
        get_title_discovery_service,
    )
    from movieclaw_media.models import MediaKind, MediaSource
    from movieclaw_media.tmdb import TmdbClient

    movie = {
        "id": 100,
        "title": "测试电影",
        "original_title": "Test Movie",
        "release_date": "2024-01-01",
        "status": "Released",
        "external_ids": {},
        "alternative_titles": {"titles": []},
        "translations": {"translations": []},
    }

    def tmdb_handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/3/movie/100":
            return httpx.Response(200, json=movie)
        return httpx.Response(404, json={})

    tmdb = TmdbClient("0" * 32, transport=httpx.MockTransport(tmdb_handler))
    monkeypatch.setattr(subscription_routes, "get_tmdb_client", lambda: tmdb)

    searched: list[str] = []

    class FakeTitles:
        async def search_titles(self, query, provider):
            searched.append(query)
            titles = []
            if query == "测试电影":
                titles = [
                    DiscoveredTitleView(
                        title_ref="tmdb:movie:100",
                        provider=MediaSource.TMDB,
                        external_id="100",
                        media_type=MediaKind.MOVIE,
                        title="测试电影",
                        poster_url="",
                    )
                ]
            return TitleSearchOutcome(raw_items=[], titles=titles, providers=[])

    feed = data_dir / "watchlist.json"
    feed.write_text(json.dumps(["测试电影", "查无此片", "测试电影"]), encoding="utf-8")
    install(
        data_dir,
        "watchlist_feed",
        f"""
        - id: examples.watchlist-feed
          local: true
          runtime: {runtime}
          config: {{source: "{feed}", interval_minutes: 0.01}}
          grants: [search.titles, subscriptions.create]
          paths: [{{path: "{data_dir}", mode: read}}]
        """,
    )
    app, client = start(data_dir)
    app.dependency_overrides[get_title_discovery_service] = lambda: FakeTitles()
    with client:

        async def subscribed() -> bool:
            # 等它至少又轮了一次（第二轮不该重复订阅已处理的片名）
            return await subscription_count() == 1 and searched.count("查无此片") >= 2

        wait(client, subscribed)
        assert client.portal.call(subscription_count) == 1
        # 处理过的片名记在插件数据里
        from movieclaw_api.services.plugin_data import PluginStore

        store = PluginStore(get_database(), "examples.watchlist-feed")
        assert client.portal.call(lambda: store.get("done")) == ["测试电影"]
    # 处理过的片名不再搜索；搜不到的片名每轮重试
    assert searched.count("测试电影") == 1

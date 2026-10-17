"""网盘文件夹挂在媒体库上：纳管、复查、操作动态（docs/design/cloud-storage.md §4、§9、§14.3）。

假网盘插件（主进程与独立进程各跑一遍）从一个 JSON 文件读目录树与操作动态，测试改文件就是
「用户在网盘 App 里动了文件」。TMDB 为假实现。验证：

- 建库时挂网盘目录：整树列举一次，视频按文件名识别入账（只在网盘上 + 副本已核验），原盘、ISO、
  样片跳过并计数，非视频不算；纳管报告；入账的文件立刻可以取流；
- 复查：网盘上删了的标缺失，挪了位置的认回原行（台账路径不变），新出现的入账，删了又还原的认回来；
- 本地扫描不碰只在网盘上的行：对账不标缺失，重新下载同一版本不会劫持它；
- 操作动态：删掉的已入账文件直接标缺失，落在库目录里的变化只重新列那个目录；
- 目录选择器、重叠校验、账号在用时不让删、拿掉目录只删台账。
"""

from __future__ import annotations

import json
import sys
import textwrap
import time
from functools import partial
from pathlib import Path

import httpx
import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import durable_events

ADMIN = {"username": "admin", "password": "s3cret-pass"}

PLUGIN = """
import json
from pathlib import Path

from pydantic import BaseModel

from movieclaw_sdk import plugin
from movieclaw_sdk.drives import (
    DRIVE_BACKENDS,
    AccountInfo,
    Capabilities,
    Change,
    ChangePage,
    DirectLink,
    DriveBackend,
    Login,
    LoginResult,
    NotFound,
    RemoteDir,
    RemoteFile,
    RemoteTree,
)


class Config(BaseModel):
    state: str


class FakeDrive(DriveBackend):
    type = "fake"
    title = "假网盘"
    capabilities = Capabilities(
        writable=True, list_hashes=True, change_feed=True, default_qps=1000.0,
        default_daily_budget=100000,
    )
    login = Login(cookie_domains=("fake.example",))

    def __init__(self, state):
        self.state = Path(state)

    def _load(self):
        return json.loads(self.state.read_text(encoding="utf-8"))

    async def login_with_cookie(self, cookie_header):
        return LoginResult(user_id="u1", display_name="测试盘", credentials={"token": "ok"})

    async def account_info(self, account):
        return AccountInfo(display_name="测试盘")

    async def list_dir(self, account, dir_id):
        return [RemoteDir(**d) for d in self._load()["dirs"].get(dir_id, [])]

    async def list_tree(self, account, dir_id):
        tree = self._load()["trees"].get(dir_id)
        if tree is None:
            raise NotFound("目录不存在")
        return RemoteTree(
            files=tuple(RemoteFile(**f) for f in tree["files"]),
            dir_ids=tuple(tree.get("dir_ids", ())),
        )

    async def changes(self, account, cursor):
        feed = self._load().get("feed", [])
        last = feed[-1]["seq"] if feed else 0
        if cursor is None:
            return ChangePage(cursor=f"c{last}")
        after = int(cursor[1:])
        events = tuple(
            Change(**{k: v for k, v in e.items() if k != "seq"}) for e in feed if e["seq"] > after
        )
        return ChangePage(cursor=f"c{last}", changes=events)

    async def stat(self, account, remote_id):
        raise NotFound("没有这个文件")

    async def direct_link(self, account, remote_id, user_agent):
        return DirectLink(url=f"http://127.0.0.1:9/{remote_id}", expires_in=600)


@plugin("fake-drive", title="假网盘", config=Config)
async def apply(ctx) -> None:
    ctx.contribute(DRIVE_BACKENDS, "fake", FakeDrive(ctx.config.state))
"""

_TMDB = {
    "/3/movie/693134": {
        "id": 693134,
        "title": "沙丘2",
        "original_title": "Dune: Part Two",
        "release_date": "2024-02-27",
        "runtime": 167,
    },
    "/3/movie/872585": {
        "id": 872585,
        "title": "奥本海默",
        "original_title": "Oppenheimer",
        "release_date": "2023-07-19",
        "runtime": 181,
    },
    "/3/movie/27205": {
        "id": 27205,
        "title": "盗梦空间",
        "original_title": "Inception",
        "release_date": "2010-07-15",
        "runtime": 148,
    },
}
_SEARCH = {"沙丘": 693134, "奥本海默": 872585, "盗梦空间": 27205}


def _fake_tmdb():
    from movieclaw_media.tmdb import TmdbClient

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path == "/3/search/movie":
            query = request.url.params.get("query", "")
            results = [
                {
                    k: _TMDB[f"/3/movie/{tmdb_id}"][k]
                    for k in ("id", "title", "original_title", "release_date")
                }
                for needle, tmdb_id in _SEARCH.items()
                if needle in query
            ]
            return httpx.Response(200, json={"results": results})
        if path.startswith("/3/search/"):
            return httpx.Response(200, json={"results": []})
        payload = _TMDB.get(path)
        if payload is None:
            return httpx.Response(404, json={})
        full = {
            "status": "Released",
            "external_ids": {},
            "alternative_titles": {"titles": []},
            "translations": {"translations": []},
            **payload,
        }
        return httpx.Response(200, json=full)

    return TmdbClient("0123456789abcdef0123456789abcdef", transport=httpx.MockTransport(handler))


def _file(remote_id: str, rel_path: str, size: int = 4_000_000_000) -> dict:
    return {
        "remote_id": remote_id,
        "name": rel_path.rsplit("/", 1)[-1],
        "size": size,
        "sha1": remote_id.upper().ljust(40, "0")[:40],
        "rel_path": rel_path,
    }


def _initial_state() -> dict:
    return {
        "dirs": {
            "": [{"remote_id": "d-media", "name": "影视", "has_children": True}],
            "d-media": [
                {"remote_id": "d-movies", "name": "电影", "has_children": True, "video_count": 4},
                {"remote_id": "d-tv", "name": "剧集", "has_children": True, "video_count": 0},
            ],
        },
        "trees": {
            "d-movies": {
                "files": [
                    _file("f-dune", "沙丘2 (2024)/Dune.Part.Two.2024.2160p.mkv"),
                    _file("f-sample", "沙丘2 (2024)/sample.mkv", 50_000_000),
                    _file("f-poster", "沙丘2 (2024)/poster.jpg", 300_000),
                    _file("f-opp", "奥本海默 (2023)/Oppenheimer.2023.1080p.mkv", 3_000_000_000),
                    _file("f-noname", "未命名(3).mkv", 1_000_000_000),
                    _file("f-bd1", "原盘/阿凡达 (2009)/BDMV/STREAM/00001.m2ts"),
                    _file("f-bd2", "原盘/阿凡达 (2009)/BDMV/STREAM/00002.m2ts"),
                    _file("f-iso", "镜像/Some.Movie.2001.iso"),
                    _file("f-strm", "网盘/占位.strm", 100),
                ],
                "dir_ids": ["d-dune", "d-opp", "d-bd", "d-iso"],
            },
            "d-tv": {"files": [], "dir_ids": []},
        },
        "feed": [],
    }


@pytest.fixture(params=["inline", "process"])
def client(request, tmp_path, monkeypatch):
    import movieclaw_api.services.library.scan as scan_mod
    import movieclaw_api.services.media_discover as discover_mod
    from movieclaw_api.services.auth import reset_auth_state
    from movieclaw_api.services.drives import gateway, sources
    from movieclaw_api.settings import reset_setting_store
    from movieclaw_db.crypto import reset_secret_box

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'drives.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "test-key-not-used")
    tmdb = _fake_tmdb()
    monkeypatch.setattr(discover_mod, "get_tmdb_client", lambda: tmdb)
    monkeypatch.setattr(scan_mod, "get_tmdb_client", lambda: tmdb)
    monkeypatch.setattr(scan_mod, "NEW_FILE_QUIET_SECONDS", 0)
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    gateway.reset_state()
    sources.reset_state()
    state = tmp_path / "drive-state.json"
    state.write_text(json.dumps(_initial_state(), ensure_ascii=False), encoding="utf-8")
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "fake_drive.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            f"""
            - id: fake-drive
              local: true
              module: fake_drive
              runtime: {request.param}
              config: {{state: "{state}"}}
            """
        ),
        encoding="utf-8",
    )
    from movieclaw_api.app import create_app

    with TestClient(create_app()) as test_client:
        assert test_client.post("/api/v1/auth/bootstrap", json=ADMIN).status_code == 200
        login = test_client.post(
            "/api/v1/drives/accounts/cookie", json={"backend": "fake", "cookie": "UID=u1"}
        )
        assert login.status_code == 201, login.text
        test_client.account_id = login.json()["data"]["account"]["id"]  # type: ignore[attr-defined]
        test_client.state_path = state  # type: ignore[attr-defined]
        yield test_client
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    gateway.reset_state()
    sources.reset_state()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    get_settings.cache_clear()


def call(client: TestClient, fn, *args, **kwargs):
    return client.portal.call(partial(fn, *args, **kwargs))  # type: ignore[attr-defined]


def _edit_state(client: TestClient, edit) -> None:
    path: Path = client.state_path  # type: ignore[attr-defined]
    data = json.loads(path.read_text(encoding="utf-8"))
    edit(data)
    path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")


def _wait_idle(client: TestClient, library_id: int, timeout: float = 300.0) -> dict:
    deadline = time.monotonic() + timeout
    while True:
        view = client.get(f"/api/v1/libraries/{library_id}").json()["data"]
        if not view["scanning"]:
            return view
        assert time.monotonic() < deadline, view
        time.sleep(0.1)


def _create_library(client: TestClient, tmp_path: Path, **extra) -> dict:
    staging = tmp_path / "staging"
    staging.mkdir(exist_ok=True)
    payload = {
        "name": "电影",
        "kind": "movie",
        "root_paths": [str(staging)],
        "cloud_folders": [
            {
                "account_id": client.account_id,  # type: ignore[attr-defined]
                "remote_dir_id": "d-movies",
                "display_path": "影视/电影",
                "is_primary": True,
            }
        ],
        **extra,
    }
    created = client.post("/api/v1/libraries", json=payload)
    assert created.status_code == 200, created.text
    return _wait_idle(client, created.json()["data"]["id"])


async def _ledger(library_id: int) -> dict[str, dict]:
    """台账（含副本）：网盘文件 id → 行的要点。"""
    from sqlmodel import select

    from movieclaw_db.engine import get_database
    from movieclaw_db.models import LibraryFile, LibraryFileReplica

    async with get_database().session() as session:
        rows = (
            await session.execute(
                select(LibraryFile, LibraryFileReplica)
                .join(
                    LibraryFileReplica,
                    LibraryFileReplica.library_file_id == LibraryFile.id,
                    isouter=True,
                )
                .where(LibraryFile.library_id == library_id)
            )
        ).all()
    out = {}
    for row, replica in rows:
        key = replica.remote_id if replica is not None else row.file_path
        out[key] = {
            "id": row.id,
            "path": row.file_path,
            "state": str(row.state),
            "local_bytes": row.local_bytes,
            "media_item_id": row.media_item_id,
            "unidentified_code": row.unidentified_code,
            "size": row.size_bytes,
            "video_codec": row.video_codec,
            "replica_state": replica.state if replica else None,
            "remote_path": replica.remote_path if replica else None,
            "folder_id": replica.folder_id if replica else None,
            "sha1": replica.sha1 if replica else None,
        }
    return out


def ledger(client: TestClient, library_id: int) -> dict[str, dict]:
    return call(client, _ledger, library_id)


def _scan(client: TestClient, library_id: int, **kwargs):
    from movieclaw_api.services.library.scan import scan_library

    return call(client, scan_library, library_id, **kwargs)


def test_mounting_a_folder_imports_its_videos_by_name(client, tmp_path):
    from movieclaw_api.services.drives import sources
    from movieclaw_api.services.library.cloud import CLOUD_DIR_NAME

    view = _create_library(client, tmp_path)
    [folder] = view["cloud_folders"]
    assert folder["display_path"] == "影视/电影" and folder["is_primary"]
    assert folder["backend_title"] == "假网盘" and folder["account_name"] == "测试盘"
    report = folder["report"]
    # 视频 3 个（样片、原盘、ISO 不算视频；海报、strm 不是内容）
    assert report["videos"] == 3
    assert report["identified"] == 2 and report["pending"] == 1
    assert report["skipped"] == {"disc": 1, "iso": 1, "extra": 1}
    assert report["calls"] >= 1
    assert folder["file_count"] == 3 and folder["listed_at"]

    rows = ledger(client, view["id"])
    assert set(rows) == {"f-dune", "f-opp", "f-noname"}
    dune = rows["f-dune"]
    staging = tmp_path / "staging"
    assert dune["path"] == str(
        staging
        / CLOUD_DIR_NAME
        / str(client.account_id)
        / "影视"
        / "电影"
        / "沙丘2 (2024)"
        / "Dune.Part.Two.2024.2160p.mkv"
    )
    assert not Path(dune["path"]).exists()
    assert dune["local_bytes"] is False and dune["replica_state"] == "verified"
    assert dune["remote_path"] == "影视/电影/沙丘2 (2024)/Dune.Part.Two.2024.2160p.mkv"
    assert dune["size"] == 4_000_000_000 and dune["sha1"].startswith("F-DUNE")
    assert dune["media_item_id"] is not None and dune["unidentified_code"] is None
    assert rows["f-noname"]["unidentified_code"] is not None
    # 入账即可取流：登记进了读字节入口
    assert sources.cloud_file(dune["path"]) is not None
    # 一个本地文件都没有建（纳管不下载、不在本地落空文件）
    assert not any(p.is_file() for p in staging.rglob("*") if p.suffix == ".mkv")


def test_recheck_follows_deletes_moves_additions_and_restores(client, tmp_path):
    view = _create_library(client, tmp_path)
    library_id = view["id"]
    before = ledger(client, library_id)

    def edit(data):
        files = data["trees"]["d-movies"]["files"]
        files[:] = [f for f in files if f["remote_id"] != "f-opp"]  # 删了
        for f in files:
            if f["remote_id"] == "f-dune":  # 挪了位置、改了名
                f["rel_path"] = "科幻/沙丘2.2024.mkv"
                f["name"] = "沙丘2.2024.mkv"
        files.append(_file("f-inception", "盗梦空间 (2010)/Inception.2010.mkv"))

    _edit_state(client, edit)
    summary = _scan(client, library_id)  # 手动扫描：全部网盘目录重新列一次
    assert not summary.errors, summary.errors
    rows = ledger(client, library_id)
    assert rows["f-opp"]["state"] == "missing" and rows["f-opp"]["replica_state"] == "lost"
    # 挪了位置：认回原行，台账路径（虚拟位置）不变，只更新网盘路径
    assert rows["f-dune"]["id"] == before["f-dune"]["id"]
    assert rows["f-dune"]["path"] == before["f-dune"]["path"]
    assert rows["f-dune"]["remote_path"] == "影视/电影/科幻/沙丘2.2024.mkv"
    assert rows["f-dune"]["state"] == "in_place"
    assert rows["f-inception"]["media_item_id"] is not None
    assert rows["f-inception"]["local_bytes"] is False

    # 用户从网盘回收站还原：下次复查认回来
    _edit_state(
        client,
        lambda d: d["trees"]["d-movies"]["files"].append(
            _file("f-opp", "奥本海默 (2023)/Oppenheimer.2023.1080p.mkv", 3_000_000_000)
        ),
    )
    _scan(client, library_id)
    rows = ledger(client, library_id)
    assert rows["f-opp"]["state"] == "in_place" and rows["f-opp"]["replica_state"] == "verified"
    assert rows["f-opp"]["id"] == before["f-opp"]["id"]


def test_local_scans_leave_cloud_only_rows_alone(client, tmp_path):
    from movieclaw_api.services.drives import gateway

    view = _create_library(client, tmp_path)
    library_id = view["id"]
    before = ledger(client, library_id)
    calls = gateway.usage_today(client.account_id)  # type: ignore[attr-defined]
    # 定期对账：网盘目录刚列过、没到复查时间，不列；本地遍历不把只在网盘上的行标缺失
    summary = _scan(client, library_id, backfill_existing_specs=False)
    assert summary.marked_missing == 0
    assert gateway.usage_today(client.account_id) == calls  # type: ignore[attr-defined]
    assert ledger(client, library_id) == before

    # 重新下载了同一版本（同尺寸）到本地：是新文件，不能把网盘那一行「改名归并」过来
    local = tmp_path / "staging" / "奥本海默 (2023)" / "Oppenheimer.2023.1080p.mkv"
    local.parent.mkdir(parents=True)
    with local.open("wb") as fh:
        fh.truncate(3_000_000_000)
    _scan(client, library_id, backfill_existing_specs=False)
    rows = ledger(client, library_id)
    assert rows["f-opp"] == before["f-opp"]
    assert rows[str(local)]["local_bytes"] is True

    # 复查到期：定期对账顺带列一次
    async def expire():
        from movieclaw_api.services.library.cloud import RECHECK_INTERVAL
        from movieclaw_db.engine import get_database
        from movieclaw_db.models import LibraryCloudFolder
        from movieclaw_db.models.base import utcnow

        async with get_database().session() as session:
            folder = await session.get(LibraryCloudFolder, view["cloud_folders"][0]["id"])
            folder.listed_at = utcnow() - RECHECK_INTERVAL * 2
            session.add(folder)
            await session.commit()

    call(client, expire)
    _scan(client, library_id, backfill_existing_specs=False)
    assert gateway.usage_today(client.account_id) > calls  # type: ignore[attr-defined]


def test_change_feed_marks_deletions_and_relists_only_touched_folders(client, tmp_path):
    from movieclaw_api.services.library import cloud

    view = _create_library(client, tmp_path)
    library_id = view["id"]
    # 第一次拉动态只记起点
    call(client, cloud.poll_drive_changes)

    def edit(data):
        data["trees"]["d-movies"]["files"].append(
            _file("f-inception", "盗梦空间 (2010)/Inception.2010.mkv")
        )
        data["feed"] += [
            {"seq": 1, "kind": "removed", "remote_id": "f-opp", "parent_id": "d-opp"},
            {
                "seq": 2,
                "kind": "dir_created",
                "remote_id": "d-inc",
                "is_dir": True,
                "name": "盗梦空间 (2010)",
                "parent_id": "d-movies",
            },
            {"seq": 3, "kind": "added", "remote_id": "f-inception", "parent_id": "d-inc"},
            # 库外的变化不理
            {"seq": 4, "kind": "added", "remote_id": "f-other", "parent_id": "d-elsewhere"},
        ]

    _edit_state(client, edit)
    call(client, cloud.poll_drive_changes)
    rows = ledger(client, library_id)
    # 删掉的已入账文件：不用列目录，直接标缺失
    assert rows["f-opp"]["state"] == "missing" and rows["f-opp"]["replica_state"] == "lost"
    # 落在库目录里的变化：排了一个只列网盘的扫描，跑完新文件入账
    view = _wait_idle(client, library_id)
    rows = ledger(client, library_id)
    assert rows["f-inception"]["media_item_id"] is not None
    # 再拉一次没有新动态：什么都不做
    assert call(client, cloud.apply_changes, client.account_id, [], []) == set()  # type: ignore[attr-defined]


def test_folder_picker_overlap_guard_account_guard_and_unmount(client, tmp_path):
    account_id = client.account_id  # type: ignore[attr-defined]
    root = client.get(f"/api/v1/drives/accounts/{account_id}/dirs")
    assert root.status_code == 200, root.text
    assert root.json()["data"][0] == {
        "id": "d-media",
        "name": "影视",
        "path": "影视",
        "has_children": True,
        "video_count": None,
        "library_id": None,
        "library_name": None,
    }
    view = _create_library(client, tmp_path)
    children = client.get(
        f"/api/v1/drives/accounts/{account_id}/dirs",
        params={"parent_id": "d-media", "path": "影视"},
    ).json()["data"]
    movies = next(d for d in children if d["id"] == "d-movies")
    assert movies["path"] == "影视/电影" and movies["library_name"] == "电影"
    assert next(d for d in children if d["id"] == "d-tv")["library_id"] is None
    # 上层目录也算重叠：被别的库用着的标出来，提交时拒绝
    assert root.json()["data"][0]["library_id"] is None
    again = client.get(f"/api/v1/drives/accounts/{account_id}/dirs").json()["data"][0]
    assert again["library_name"] == "电影"

    other = tmp_path / "other"
    other.mkdir()
    clash = client.post(
        "/api/v1/libraries",
        json={
            "name": "另一个库",
            "kind": "movie",
            "root_paths": [str(other)],
            "cloud_folders": [
                {"account_id": account_id, "remote_dir_id": "d-media", "display_path": "影视"}
            ],
        },
    )
    assert clash.status_code == 400 and "重叠" in clash.json()["message"]

    # 账号还被库用着：不让删
    blocked = client.delete(f"/api/v1/drives/accounts/{account_id}")
    assert blocked.status_code == 409 and "电影" in blocked.json()["message"]

    # 拿掉网盘目录：只删台账，条目跟着清掉
    current = client.get(f"/api/v1/libraries/{view['id']}").json()["data"]
    payload = {
        "name": current["name"],
        "kind": current["kind"],
        "root_paths": current["root_paths"],
        "cloud_folders": [],
    }
    updated = client.put(f"/api/v1/libraries/{view['id']}", json=payload)
    assert updated.status_code == 200, updated.text
    assert updated.json()["data"]["cloud_folders"] == []
    assert ledger(client, view["id"]) == {}
    assert client.delete(f"/api/v1/drives/accounts/{account_id}").status_code == 200

    # 编辑库时再挂上：只列新挂的目录，立刻纳管
    login = client.post(
        "/api/v1/drives/accounts/cookie", json={"backend": "fake", "cookie": "UID=u1"}
    )
    new_account = login.json()["data"]["account"]["id"]
    payload["cloud_folders"] = [
        {"account_id": new_account, "remote_dir_id": "d-movies", "display_path": "影视/电影"}
    ]
    remounted = client.put(f"/api/v1/libraries/{view['id']}", json=payload)
    assert remounted.status_code == 200, remounted.text
    assert remounted.json()["message"] == "已更新，正在纳管新加的网盘目录"
    _wait_idle(client, view["id"])
    assert set(ledger(client, view["id"])) == {"f-dune", "f-opp", "f-noname"}


def test_cloud_files_get_specs_probed_in_the_background_within_budget(
    client, tmp_path, monkeypatch
):
    from movieclaw_api.services.drives import gateway
    from movieclaw_api.services.drives.sources import SERVER_USER_AGENT
    from movieclaw_api.services.library import cloud
    from movieclaw_api.services.media_probe import MediaSpec
    from movieclaw_api.services.playback import strm_probe

    view = _create_library(client, tmp_path)
    probed: list[tuple[str, tuple[str, ...]]] = []

    def fake_probe(url, *, input_args=()):
        probed.append((url, tuple(input_args)))
        return MediaSpec(
            resolution="2160p",
            video_codec="hevc",
            hdr="hdr10",
            bit_depth=10,
            duration_seconds=9000,
            bit_rate=40_000_000,
        )

    monkeypatch.setattr(strm_probe, "probe_media", fake_probe)
    assert call(client, cloud.probe_cloud_specs) == 3
    # 读的是网盘直链，带着服务器的 UA
    assert {url.rsplit("/", 1)[-1] for url, _a in probed} == {"f-dune", "f-opp", "f-noname"}
    assert all(args[args.index("-user_agent") + 1] == SERVER_USER_AGENT for _u, args in probed)
    # 规格落进台账：之后与本地文件一样按真实编码做播放决策
    assert {r["video_codec"] for r in ledger(client, view["id"]).values()} == {"hevc"}
    # 后台补探只用预算的一小部分：超了就停
    probed.clear()

    async def unprobe():
        from sqlmodel import update

        from movieclaw_db.engine import get_database
        from movieclaw_db.models import LibraryFile

        async with get_database().session() as session:
            await session.execute(update(LibraryFile).values(video_codec=None))
            await session.commit()

    call(client, unprobe)
    monkeypatch.setattr(gateway, "usage_today", lambda _account: 10**9)
    assert call(client, cloud.probe_cloud_specs) == 0 and probed == []


def test_importing_a_large_tree_lists_once_and_counts_everything(client, tmp_path, request):
    from movieclaw_api.services.drives import gateway

    if request.node.callspec.params["client"] != "inline":
        pytest.skip("规模用例只在主进程跑一遍（插件跨进程只多一次列举调用的序列化）")

    def edit(data):
        files = []
        for n in range(1, 601):
            files.append(_file(f"f-d{n}", f"沙丘2 (2024)/版本{n}/Dune.Part.Two.2024.mkv"))
        for n in range(1, 401):
            files.append(_file(f"f-x{n}", f"杂项/clip_{n:04d}.mkv", 10_000_000 + n))
        for n in range(1, 41):
            files.append(_file(f"f-bd{n}", f"原盘/片{n}/BDMV/STREAM/00001.m2ts"))
        data["trees"]["d-movies"]["files"] = files

    _edit_state(client, edit)
    calls = gateway.usage_today(client.account_id)  # type: ignore[attr-defined]
    started = time.monotonic()
    view = _create_library(client, tmp_path)
    elapsed = time.monotonic() - started
    report = view["cloud_folders"][0]["report"]
    assert report["videos"] == 1000
    assert report["identified"] == 600 and report["pending"] == 400
    assert report["skipped"]["disc"] == 40
    # 整棵树一次列完（不逐目录往下列）
    assert gateway.usage_today(client.account_id) - calls == 1  # type: ignore[attr-defined]
    assert elapsed < 300, elapsed

"""主根在网盘的库：本地文件上传到网盘（docs/design/cloud-storage.md §5）。

假网盘插件（主进程与独立进程各跑一遍）把「网盘」放在一个目录里：上传的字节真的写进去，``stat``
按落盘的字节算大小与 SHA1。秒传池里的文件要先回答区间校验（读宿主给的那段字节对哈希）。故障从
状态文件注入。验证：

- 新入库的本地文件自动排上传：秒传命中的不传字节，其余按分片传、目录结构与本地一致，核验后副本
  已核验；
- 任务中途断了（第 2 片网络错误）从断点续传：已传的分片不重传；
- 外网有人在看片时上传让路，让完路接着传；
- 核验对不上、本地文件在传的时候变了：这个文件记失败原因、不算已上传，任务接着传别的；
- 网盘要重新登录：任务停在「需要处理」；
- 复查不会把自己传上去、本地还在的文件当成纳管来的再入一遍账；网盘上没了的重新传。
"""

from __future__ import annotations

import hashlib
import json
import sys
import textwrap
import time
from functools import partial
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import durable_events

ADMIN = {"username": "admin", "password": "s3cret-pass"}
PART = 64 * 1024

PLUGIN = """
import hashlib
import json
from pathlib import Path

from pydantic import BaseModel

from movieclaw_sdk import plugin
from movieclaw_sdk.drives import (
    DRIVE_BACKENDS, AccountInfo, AuthExpired, Capabilities, ChangePage, Conflict, DirectLink,
    DriveBackend, Login, LoginResult, NotFound, RemoteDir, RemoteFile, RemoteTree, Transient,
    UploadStep,
)


class Config(BaseModel):
    root: str


class FakeDrive(DriveBackend):
    type = "fake"
    title = "假网盘"
    capabilities = Capabilities(
        writable=True, rapid_upload_hashes=("sha1",), range_challenge=True, list_hashes=True,
        default_qps=1000.0, default_daily_budget=100000,
    )
    login = Login(cookie_domains=("fake.example",))

    def __init__(self, root):
        self.root = Path(root)
        self.store = self.root / "store"

    def _state(self):
        return json.loads((self.root / "state.json").read_text())

    def _save(self, state):
        (self.root / "state.json").write_text(json.dumps(state, ensure_ascii=False))

    def _parts(self, state):
        return list(self.store.glob(state["upload_id"] + ".*"))

    def _check(self, state):
        if state.get("auth_dead"):
            raise AuthExpired("登录已失效")

    async def login_with_cookie(self, cookie_header):
        return LoginResult(user_id="u1", display_name="测试盘", credentials={"token": "ok"})

    async def account_info(self, account):
        return AccountInfo(display_name="测试盘")

    async def list_dir(self, account, dir_id):
        return [RemoteDir(remote_id="d-root", name="影视")] if not dir_id else []

    async def list_tree(self, account, dir_id):
        state = self._state()
        prefix = state["dirs"][dir_id] + "/"
        files = [
            RemoteFile(remote_id=rid, name=meta["path"].rsplit("/", 1)[-1], size=meta["size"],
                       sha1=meta["sha1"], rel_path=meta["path"][len(prefix):])
            for rid, meta in state["files"].items()
            if meta["path"].startswith(prefix)
        ]
        others = tuple(k for k in state["dirs"] if k != dir_id)
        return RemoteTree(files=tuple(files), dir_ids=others)

    async def changes(self, account, cursor):
        return ChangePage(cursor="c0")

    async def ensure_dir(self, account, parent_id, path):
        state = self._state()
        self._check(state)
        if not path:
            return parent_id
        full = state["dirs"][parent_id] + "/" + path
        for did, p in state["dirs"].items():
            if p == full:
                return did
        did = f"d{len(state['dirs'])}"
        state["dirs"][did] = full
        self._save(state)
        return did

    def _add_file(self, state, dir_id, name, data):
        state["seq"] = state.get("seq", 0) + 1
        rid = f"f{state['seq']}"
        path = state["dirs"][dir_id] + "/" + name
        (self.store / rid).write_bytes(data)
        bad = state.get("bad_sha1")
        sha1 = "0" * 40 if bad else hashlib.sha1(data).hexdigest().upper()
        state["files"][rid] = {"path": path, "size": len(data), "sha1": sha1}
        return RemoteFile(remote_id=rid, name=name, size=len(data), sha1=sha1)

    async def begin_upload(self, account, dir_id, name, fingerprint, state, range_data):
        drive = self._state()
        self._check(drive)
        drive.setdefault("calls", []).append(["begin", name, bool(state), range_data is not None])
        pool = drive.get("pool", {})
        if fingerprint.sha1 in pool and (not state or state.get("rapid")):
            src = Path(pool[fingerprint.sha1])
            if range_data is None:
                self._save(drive)
                return UploadStep(need_range=(10, 1000), state={"rapid": True})
            expected = hashlib.sha1(src.read_bytes()[10:1010]).hexdigest()
            if expected != hashlib.sha1(range_data).hexdigest():
                raise Transient("区间校验对不上")
            remote = self._add_file(drive, dir_id, name, src.read_bytes())
            self._save(drive)
            return UploadStep(file=remote)
        if state and state.get("upload_id"):
            done = {int(p.name.rsplit(".", 1)[-1]) for p in self._parts(state)}
            next_part = 0
            while next_part in done:
                next_part += 1
            self._save(drive)
            return UploadStep(part_size=drive["part_size"], next_part=next_part, state=state)
        upload_id = f"u{len(drive.setdefault('uploads', [])) + 1}"
        drive["uploads"].append(upload_id)
        self._save(drive)
        return UploadStep(
            part_size=drive["part_size"],
            state={"upload_id": upload_id, "dir_id": dir_id, "name": name},
        )

    async def upload_part(self, account, state, index, data):
        drive = self._state()
        self._check(drive)
        drive.setdefault("parts", []).append([state["upload_id"], index])
        fail = drive.get("fail_part")
        if fail is not None and fail == index:
            drive["fail_part"] = None
            self._save(drive)
            raise Transient("网络断了")
        self._save(drive)
        (self.store / f"{state['upload_id']}.{index}").write_bytes(data)
        return {**state, "parts": index + 1}

    async def finish_upload(self, account, state):
        drive = self._state()
        parts = sorted(self._parts(state), key=lambda p: int(p.name.rsplit(".", 1)[-1]))
        data = b"".join(p.read_bytes() for p in parts)
        for p in parts:
            p.unlink()
        remote = self._add_file(drive, state["dir_id"], state["name"], data)
        self._save(drive)
        return remote

    async def stat(self, account, remote_id):
        meta = self._state()["files"].get(remote_id)
        if meta is None:
            raise NotFound("没有这个文件")
        return RemoteFile(remote_id=remote_id, name=meta["path"].rsplit("/", 1)[-1],
                          size=meta["size"], sha1=meta["sha1"])

    async def direct_link(self, account, remote_id, user_agent):
        return DirectLink(url=f"http://127.0.0.1:9/{remote_id}")


@plugin("fake-drive", title="假网盘", config=Config)
async def apply(ctx) -> None:
    ctx.contribute(DRIVE_BACKENDS, "fake", FakeDrive(ctx.config.root))
"""


def _blob(seed: int, size: int) -> bytes:
    out = bytearray()
    counter = 0
    while len(out) < size:
        out += hashlib.sha256(f"{seed}:{counter}".encode()).digest()
        counter += 1
    return bytes(out[:size])


@pytest.fixture(params=["inline", "process"])
def client(request, tmp_path, monkeypatch):
    import movieclaw_api.services.library.scan as scan_mod
    from movieclaw_api.services.auth import reset_auth_state
    from movieclaw_api.services.drives import gateway, sources, uplink
    from movieclaw_api.settings import reset_setting_store
    from movieclaw_db.crypto import reset_secret_box

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'drives.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "")
    monkeypatch.setattr(scan_mod, "NEW_FILE_QUIET_SECONDS", 0)
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    gateway.reset_state()
    sources.reset_state()
    uplink.reset_state()
    drive = tmp_path / "drive"
    (drive / "store").mkdir(parents=True)
    (drive / "state.json").write_text(
        json.dumps({"dirs": {"d-root": "影视"}, "files": {}, "part_size": PART, "pool": {}})
    )
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "fake_drive.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            f"""
            - id: fake-drive
              local: true
              module: fake_drive
              runtime: {request.param}
              config: {{root: "{drive}"}}
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
        test_client.drive = drive  # type: ignore[attr-defined]
        yield test_client
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    gateway.reset_state()
    sources.reset_state()
    uplink.reset_state()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    durable_events.reset_state()
    get_settings.cache_clear()


def call(client: TestClient, fn, *args, **kwargs):
    return client.portal.call(partial(fn, *args, **kwargs))  # type: ignore[attr-defined]


def drive_state(client: TestClient) -> dict:
    return json.loads((client.drive / "state.json").read_text())  # type: ignore[attr-defined]


def edit_drive(client: TestClient, edit) -> None:
    path = client.drive / "state.json"  # type: ignore[attr-defined]
    data = json.loads(path.read_text())
    edit(data)
    path.write_text(json.dumps(data, ensure_ascii=False))


async def _replicas(library_id: int) -> dict[str, dict]:
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
    return {
        Path(row.file_path).name: {
            "id": row.id,
            "local_bytes": row.local_bytes,
            "state": replica.state if replica else None,
            "origin": replica.origin if replica else None,
            "remote_id": replica.remote_id if replica else None,
            "remote_path": replica.remote_path if replica else None,
            "error": replica.error if replica else None,
        }
        for row, replica in rows
    }


def replicas(client: TestClient, library_id: int) -> dict[str, dict]:
    return call(client, _replicas, library_id)


def _library(client: TestClient, tmp_path: Path, files: dict[str, bytes]) -> int:
    staging = tmp_path / "staging"
    for rel, data in files.items():
        target = staging / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    staging.mkdir(exist_ok=True)
    created = client.post(
        "/api/v1/libraries",
        json={
            "name": "其他",
            "kind": "video",
            "root_paths": [str(staging)],
            "cloud_folders": [
                {
                    "account_id": client.account_id,  # type: ignore[attr-defined]
                    "remote_dir_id": "d-root",
                    "display_path": "影视",
                    "is_primary": True,
                }
            ],
        },
    )
    assert created.status_code == 200, created.text
    return created.json()["data"]["id"]


def _wait(predicate, timeout: float = 60.0):
    deadline = time.monotonic() + timeout
    while True:
        value = predicate()
        if value:
            return value
        assert time.monotonic() < deadline, "等待超时"
        time.sleep(0.1)


def _uploads_done(client: TestClient, library_id: int, names: set[str]) -> dict[str, dict]:
    def done():
        rows = replicas(client, library_id)
        if all(rows.get(n, {}).get("state") in ("verified", "failed") for n in names):
            return rows
        return None

    return _wait(done)


def test_new_local_files_upload_rapid_or_in_parts_and_verify(client, tmp_path):
    pooled = _blob(1, 300_000)
    fresh = _blob(2, 200_000)
    # 「网盘的去重池」里已有 pooled：秒传要先回答区间校验
    pool_copy = tmp_path / "pool.bin"
    pool_copy.write_bytes(pooled)
    edit_drive(
        client,
        lambda d: d.update(pool={hashlib.sha1(pooled).hexdigest().upper(): str(pool_copy)}),
    )
    library_id = _library(client, tmp_path, {"旅行/海边.mp4": pooled, "家庭/2024/生日.mkv": fresh})
    rows = _uploads_done(client, library_id, {"海边.mp4", "生日.mkv"})
    assert rows["海边.mp4"]["state"] == "verified" and rows["生日.mkv"]["state"] == "verified"
    assert rows["生日.mkv"]["origin"] == "uploaded"
    assert rows["生日.mkv"]["remote_path"] == "影视/家庭/2024/生日.mkv"
    assert rows["海边.mp4"]["local_bytes"] is True  # 释放本地是下一步的事
    state = drive_state(client)
    # 目录结构与本地一致；字节完整
    by_path = {meta["path"]: rid for rid, meta in state["files"].items()}
    assert set(by_path) == {"影视/旅行/海边.mp4", "影视/家庭/2024/生日.mkv"}
    store = client.drive / "store"  # type: ignore[attr-defined]
    assert (store / by_path["影视/家庭/2024/生日.mkv"]).read_bytes() == fresh
    # 秒传：回答了区间校验，没有传分片；真传：按 64 KB 一片传了 4 片
    assert ["begin", "海边.mp4", True, True] in state["calls"]
    assert sorted(i for u, i in state["parts"]) == [0, 1, 2, 3]

    # 库行：任务跑完不再显示上传进度（副本核验后任务还要再查一轮候选才收尾）
    def finished():
        data = client.get(f"/api/v1/libraries/{library_id}").json()["data"]
        return data if data["cloud_upload"] is None else None

    view = _wait(finished)
    assert view["cloud_folders"][0]["is_primary"] is True


async def _run_job(library_id: int, progress: dict | None = None):
    """直接跑处理器（不经执行器）：拿到它写的进度与抛出的控制异常。"""
    from movieclaw_api.services.drives import uploads

    class Context:
        job_id = "test"

        def __init__(self) -> None:
            self.progress = progress or {}

        def progress_due(self, *, min_interval: float = 1.0) -> bool:
            return True

        async def update_progress(self, **kwargs) -> None:
            self.progress = kwargs

        async def current_progress(self) -> dict:
            return dict(self.progress)

        async def cancel_requested(self) -> bool:
            return False

        async def raise_if_cancelled(self) -> None:
            return None

    context = Context()
    try:
        result = await uploads.run_upload_job(context, {"library_id": library_id})
    except Exception as exc:  # noqa: BLE001 -- 测试要看控制异常
        return context.progress, exc
    return context.progress, result


async def _candidates(library_id: int) -> int:
    from movieclaw_api.services.drives import uploads
    from movieclaw_db.engine import get_database
    from movieclaw_db.models.base import utcnow
    from movieclaw_db.repositories.library_cloud_repo import LibraryCloudRepository

    async with get_database().session() as session:
        rows = await LibraryCloudRepository(session).upload_candidates(
            library_id, retry_failed_before=utcnow() - uploads.RETRY_FAILED_AFTER
        )
    return len(rows)


def _pause_auto_uploads(client: TestClient, monkeypatch) -> None:
    """不让入库事件自动排任务：这几个用例自己按步骤跑处理器。"""
    from movieclaw_api.services.drives import uploads

    async def nothing(*_args, **_kwargs):
        return []

    monkeypatch.setattr(uploads, "enqueue", nothing)


def test_resume_after_a_failed_part_skips_parts_already_sent(client, tmp_path, monkeypatch):
    from movieclaw_sdk.jobs import JobRetry

    _pause_auto_uploads(client, monkeypatch)
    data = _blob(3, 5 * PART + 100)
    library_id = _library(client, tmp_path, {"纪录片.mkv": data})
    _wait(lambda: replicas(client, library_id).get("纪录片.mkv"))
    edit_drive(client, lambda d: d.update(fail_part=2))
    progress, outcome = call(client, _run_job, library_id)
    assert isinstance(outcome, JobRetry), outcome
    checkpoint = progress["details"]["checkpoint"]
    assert checkpoint["next_part"] == 2
    assert replicas(client, library_id)["纪录片.mkv"]["state"] == "uploading"
    # 重启后从断点续：第 0、1 片不重传
    progress, outcome = call(client, _run_job, library_id, progress)
    assert isinstance(outcome, dict) and outcome["uploaded"] == 1, outcome
    sent = [index for _upload, index in drive_state(client)["parts"]]
    assert sent == [0, 1, 2, 2, 3, 4, 5]
    assert replicas(client, library_id)["纪录片.mkv"]["state"] == "verified"
    store = client.drive / "store"  # type: ignore[attr-defined]
    [remote] = drive_state(client)["files"]
    assert (store / remote).read_bytes() == data


def test_uploads_yield_while_someone_outside_is_watching(client, tmp_path, monkeypatch):
    from movieclaw_api.services.drives import uplink, uploads

    _pause_auto_uploads(client, monkeypatch)
    monkeypatch.setattr(uploads, "YIELD_POLL_S", 0.05)
    monkeypatch.setattr(uplink, "QUIET_S", 0.6)
    library_id = _library(client, tmp_path, {"片.mkv": _blob(4, 2 * PART)})
    _wait(lambda: replicas(client, library_id).get("片.mkv"))
    uplink.note("outside")  # 外网设备在取流
    uplink.note("home")  # 家里的不算
    assert uplink.busy()
    started = time.monotonic()
    _progress, outcome = call(client, _run_job, library_id)
    # 等外网那路停了（0.6 秒没有新请求）才开始传分片
    assert time.monotonic() - started >= 0.5
    assert isinstance(outcome, dict) and outcome["uploaded"] == 1


def test_mismatch_and_changed_files_are_recorded_and_skipped(client, tmp_path, monkeypatch):
    from movieclaw_api.services.drives import uploads

    _pause_auto_uploads(client, monkeypatch)
    library_id = _library(client, tmp_path, {"a.mkv": _blob(5, PART), "b.mkv": _blob(6, PART)})
    _wait(lambda: len(replicas(client, library_id)) == 2)
    edit_drive(client, lambda d: d.update(bad_sha1=True))
    _progress, outcome = call(client, _run_job, library_id)
    assert isinstance(outcome, dict) and outcome["failed"] == 2, outcome
    rows = replicas(client, library_id)
    assert rows["a.mkv"]["state"] == "failed" and "对不上" in rows["a.mkv"]["error"]
    # 失败的过一段时间再试，这一轮不再碰
    assert call(client, _candidates, library_id) == 0

    # 本地文件在传的时候变了：这次放弃
    edit_drive(client, lambda d: d.update(bad_sha1=False))
    monkeypatch.setattr(uploads, "RETRY_FAILED_AFTER", uploads.timedelta(seconds=0))
    real_read = uploads.read_range

    def growing(path, offset, length):
        with Path(path).open("ab") as fh:
            fh.write(b"x")
        return real_read(path, offset, length)

    monkeypatch.setattr(uploads, "read_range", growing)
    _progress, outcome = call(client, _run_job, library_id)
    rows = replicas(client, library_id)
    assert rows["a.mkv"]["state"] == "failed" and "变了" in rows["a.mkv"]["error"]


def test_relogin_needed_blocks_the_job(client, tmp_path, monkeypatch):
    from movieclaw_sdk.jobs import JobBlocked

    _pause_auto_uploads(client, monkeypatch)
    library_id = _library(client, tmp_path, {"a.mkv": _blob(7, PART)})
    _wait(lambda: replicas(client, library_id).get("a.mkv"))
    edit_drive(client, lambda d: d.update(auth_dead=True))
    _progress, outcome = call(client, _run_job, library_id)
    assert isinstance(outcome, JobBlocked) and outcome.code == "DRIVE_AUTH_EXPIRED"
    assert outcome.actions[0]["target"] == "drives"


def test_recheck_keeps_uploaded_local_rows_and_reuploads_lost_ones(client, tmp_path, monkeypatch):
    from movieclaw_api.services.library.scan import scan_library

    _pause_auto_uploads(client, monkeypatch)
    library_id = _library(client, tmp_path, {"a.mkv": _blob(8, PART), "b.mkv": _blob(9, PART)})
    _wait(lambda: len(replicas(client, library_id)) == 2)
    # 建库那一轮扫描跑完（不然手动扫描会顺延）
    _wait(lambda: not client.get(f"/api/v1/libraries/{library_id}").json()["data"]["scanning"])
    call(client, _run_job, library_id)
    before = replicas(client, library_id)
    assert {r["state"] for r in before.values()} == {"verified"}
    # 手动扫描：网盘主文件夹里列出自己传的两份，不另外入账
    summary = call(client, scan_library, library_id)
    assert not summary.postponed, summary.errors
    after = replicas(client, library_id)
    assert set(after) == {"a.mkv", "b.mkv"} and after == before
    # 网盘上删了 a：本地还在，副本记丢失、重新排进上传，不标缺失
    gone = before["a.mkv"]["remote_id"]
    edit_drive(client, lambda d: d["files"].pop(gone))
    call(client, scan_library, library_id)
    rows = replicas(client, library_id)
    assert rows["a.mkv"]["state"] == "lost" and rows["a.mkv"]["local_bytes"] is True
    _progress, outcome = call(client, _run_job, library_id)
    assert isinstance(outcome, dict) and outcome["uploaded"] == 1
    rows = replicas(client, library_id)
    assert rows["a.mkv"]["state"] == "verified" and rows["a.mkv"]["remote_id"] != gone


async def _verified_replica(file_id: int, account_id: int) -> None:
    """模拟修复前已经被传上去并核验过的副本。"""
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import LibraryFileReplica
    from movieclaw_db.models.base import utcnow

    async with get_database().session() as session:
        session.add(
            LibraryFileReplica(
                library_file_id=file_id,
                account_id=account_id,
                remote_id="r-strm",
                origin="uploaded",
                state="verified",
                verified_at=utcnow(),
            )
        )
        await session.commit()


def test_strm_placeholders_never_upload_or_release(client, tmp_path, monkeypatch):
    """strm 认路径不认容器列：探过规格后容器列是直链的真实容器、改写后被清空（#921）。"""
    from movieclaw_api.services.drives import release, uploads

    enqueue = uploads.enqueue
    _pause_auto_uploads(client, monkeypatch)
    library_id = _library(
        client,
        tmp_path,
        {"a.mkv": _blob(13, PART), "纪录片/b.strm": b"https://example.com/b.mkv\n"},
    )
    _wait(lambda: len(replicas(client, library_id)) == 2)
    _wait(lambda: not client.get(f"/api/v1/libraries/{library_id}").json()["data"]["scanning"])
    strm_id = replicas(client, library_id)["b.strm"]["id"]
    # 刚入账（容器 strm）、探过规格（容器 mkv）、strm 被改写（规格清空）：都只有 a.mkv 要传
    for container in ("strm", "mkv", None):
        call(client, _set_probed, strm_id, container=container)
        assert call(client, _candidates, library_id) == 1, container
    _progress, outcome = call(client, _run_job, library_id)
    assert isinstance(outcome, dict) and outcome["uploaded"] == 1, outcome
    rows = replicas(client, library_id)
    assert rows["a.mkv"]["state"] == "verified" and rows["b.strm"]["state"] is None
    assert {meta["path"] for meta in drive_state(client)["files"].values()} == {"影视/a.mkv"}
    # 只剩 strm 没传：巡检不再排任务
    assert call(client, enqueue, library_id) == []

    # 修复前已经被传上去的 strm：腾空巡检不挑它，直接腾空也不删本地那份
    call(client, _verified_replica, strm_id, client.account_id)  # type: ignore[attr-defined]
    assert strm_id not in call(client, release.candidates)
    assert call(client, release.try_release, strm_id) == "strm 占位文件不腾空"
    assert (tmp_path / "staging" / "纪录片" / "b.strm").exists()


# ---------------------------------------------------------------------- 腾空本地（§6）


async def _set_probed(file_id: int, **extra) -> None:
    """测试用的字节不是真视频，规格探不出来：直接写上规格（规格闸门）。"""
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import LibraryFile

    async with get_database().session() as session:
        row = await session.get(LibraryFile, file_id)
        row.probe_version = 99
        row.audio_streams = []
        row.video_codec = "h264"
        for key, value in extra.items():
            setattr(row, key, value)
        session.add(row)
        await session.commit()


async def _set_library(library_id: int, **values) -> None:
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import Library

    async with get_database().session() as session:
        row = await session.get(Library, library_id)
        for key, value in values.items():
            setattr(row, key, value)
        session.add(row)
        await session.commit()


def _uploaded(client: TestClient, tmp_path: Path, monkeypatch, files: dict[str, bytes]) -> int:
    _pause_auto_uploads(client, monkeypatch)
    library_id = _library(client, tmp_path, files)
    _wait(lambda: len(replicas(client, library_id)) == len(files))
    _wait(lambda: not client.get(f"/api/v1/libraries/{library_id}").json()["data"]["scanning"])
    _progress, outcome = call(client, _run_job, library_id)
    assert isinstance(outcome, dict) and outcome["uploaded"] == len(files), outcome
    return library_id


def test_release_waits_for_gates_then_frees_local_bytes(client, tmp_path, monkeypatch):
    from movieclaw_api.services.drives import release, sources

    data = _blob(10, 2 * PART)
    library_id = _uploaded(client, tmp_path, monkeypatch, {"电影/a.mkv": data})
    row = replicas(client, library_id)["a.mkv"]
    local = tmp_path / "staging" / "电影" / "a.mkv"
    # 规格还没探出来（字节不是真视频）：上传后没有当场腾空
    assert local.exists() and row["local_bytes"] is True
    assert call(client, release.try_release, row["id"]) == "规格还没探出来"

    call(client, _set_probed, row["id"])
    # 有人在直出看这个本地文件：先不动
    release.note_read(row["id"])
    assert call(client, release.try_release, row["id"]) == "有人正在读这个文件"
    release._reads.clear()
    # 开着「本地也保留一份」：不腾空
    call(client, _set_library, library_id, keep_local=True)
    assert "保留" in call(client, release.try_release, row["id"])
    call(client, _set_library, library_id, keep_local=False)

    assert call(client, release.try_release, row["id"]) is None
    rows = replicas(client, library_id)
    assert rows["a.mkv"]["local_bytes"] is False and not local.exists()
    # 搬空的目录跟着清掉，库根留着
    assert not local.parent.exists() and (tmp_path / "staging").is_dir()
    # 之后读网盘：登记进了读字节入口
    assert sources.cloud_file(str(local)) is not None
    # 实时监控 / 对账看到本地没了：不标缺失
    from movieclaw_api.services.library.scan import scan_library

    summary = call(client, scan_library, library_id, backfill_existing_specs=False)
    assert summary.marked_missing == 0
    assert replicas(client, library_id)["a.mkv"]["local_bytes"] is False

    # 用户把文件拷回原位：字节回到本地，播放读本地
    local.parent.mkdir()
    local.write_bytes(data)
    call(client, scan_library, library_id, backfill_existing_specs=False)
    assert replicas(client, library_id)["a.mkv"]["local_bytes"] is True
    assert sources.cloud_file(str(local)) is None


def test_release_prunes_only_directories_it_empties(client, tmp_path, monkeypatch):
    from movieclaw_api.services.drives import release

    library_id = _uploaded(
        client,
        tmp_path,
        monkeypatch,
        {
            "剧集/Season 01/e1.mkv": _blob(14, PART),
            "剧集/Season 01/e2.mkv": _blob(15, PART),
            "纪录片/Season 01/d1.mkv": _blob(16, PART),
        },
    )
    show = tmp_path / "staging" / "剧集"
    (show / "tvshow.nfo").write_text("<tvshow/>")
    rows = replicas(client, library_id)
    for row in rows.values():
        call(client, _set_probed, row["id"])

    # 同一季还有别的集：季目录留着
    assert call(client, release.try_release, rows["e1.mkv"]["id"]) is None
    assert (show / "Season 01").is_dir()
    # 最后一集腾空：季目录空了清掉，剧目录还有旁车，留着
    assert call(client, release.try_release, rows["e2.mkv"]["id"]) is None
    assert not (show / "Season 01").exists()
    assert (show / "tvshow.nfo").exists()
    # 整棵目录都空了：一路清到库根为止
    assert call(client, release.try_release, rows["d1.mkv"]["id"]) is None
    assert not (tmp_path / "staging" / "纪录片").exists()
    assert (tmp_path / "staging").is_dir()


def test_release_rechecks_local_and_remote_and_times_out_gates(client, tmp_path, monkeypatch):
    from datetime import timedelta

    from movieclaw_api.services.drives import release

    library_id = _uploaded(
        client, tmp_path, monkeypatch, {"a.mkv": _blob(11, PART), "b.mkv": _blob(12, PART)}
    )
    rows = replicas(client, library_id)
    a, b = rows["a.mkv"], rows["b.mkv"]
    # a：本地在指纹之后被改过
    call(client, _set_probed, a["id"])
    with (tmp_path / "staging" / "a.mkv").open("ab") as fh:
        fh.write(b"!")
    assert call(client, release.try_release, a["id"]) == "本地文件在指纹之后变过"
    # b：网盘上那份没了
    call(client, _set_probed, b["id"])
    edit_drive(client, lambda d: d["files"].pop(b["remote_id"]))
    assert call(client, release.try_release, b["id"]).startswith("网盘那份核对不了")
    assert (tmp_path / "staging" / "b.mkv").exists()

    # 派生活等太久：副本核验满 24 小时照常腾空（没做完的以后远程补）
    c_lib = library_id
    edit_drive(client, lambda d: None)

    async def age(file_id: int) -> None:
        from movieclaw_db.engine import get_database
        from movieclaw_db.models import LibraryFile
        from movieclaw_db.models.base import utcnow
        from movieclaw_db.repositories.library_cloud_repo import LibraryCloudRepository

        async with get_database().session() as session:
            replica = await LibraryCloudRepository(session).replica_of(file_id)
            replica.verified_at = utcnow() - release.GATE_TIMEOUT - timedelta(minutes=1)
            session.add(replica)
            row = await session.get(LibraryFile, file_id)
            row.probe_version = None
            session.add(row)
            await session.commit()

    (tmp_path / "staging" / "c.mkv").write_bytes(_blob(13, PART))
    from movieclaw_api.services.library.scan import scan_library

    call(client, scan_library, c_lib, backfill_existing_specs=False)
    _progress, outcome = call(client, _run_job, c_lib)
    c = replicas(client, c_lib)["c.mkv"]
    assert c["state"] == "verified"
    call(client, age, c["id"])
    assert call(client, release.try_release, c["id"]) is None
    assert not (tmp_path / "staging" / "c.mkv").exists()


def test_download_tasks_are_removed_after_release_unless_kept(client, monkeypatch):
    from movieclaw_api.services import download_tasks, remove_source
    from movieclaw_api.services.download_sources import FileTorrent
    from movieclaw_sdk.events import LocalReleased

    def torrent(name: str, **over) -> FileTorrent:
        values = {
            "info_hash": name,
            "downloader_id": 1,
            "downloader_name": "qb",
            "title": name,
            "source": "subscription",
            "owned_by_movieclaw": True,
            "hit_and_run": False,
        }
        values.update(over)
        return FileTorrent(**values)

    torrents = [
        torrent("plain"),
        torrent("hnr", hit_and_run=True),
        torrent("foreign", owned_by_movieclaw=False),
        torrent("pack", other_file_ids=(424242,)),  # 还供着的文件不在库里了（视为已腾空）
    ]

    async def fake_torrents(_session, _ids):
        return torrents

    deleted: list[str] = []

    async def fake_delete(_session, *, downloader_id, info_hash, delete_files, by_user):
        assert delete_files is True
        assert by_user is False  # 系统清理，不说成用户删的
        deleted.append(info_hash)

    unfinished: set[str] = set()

    async def fake_finished(_session, *, downloader_id, info_hash):
        return info_hash not in unfinished

    monkeypatch.setattr(remove_source, "torrents_for_files", fake_torrents)
    monkeypatch.setattr(download_tasks, "delete_download_task", fake_delete)
    monkeypatch.setattr(download_tasks, "download_task_finished", fake_finished)
    event = LocalReleased(library_id=1, file_id=1, bytes=10, hardlinked=True)
    call(client, remove_source.after_local_released, event)
    assert deleted == ["plain", "pack"]

    # 季包还没下完（或名下还有没入库的集）：先保留，等最后一个文件腾空再删（issue #943）
    deleted.clear()
    unfinished.add("pack")
    call(client, remove_source.after_local_released, event)
    assert deleted == ["plain"]

    # 设置里关掉：一个都不删
    deleted.clear()
    saved = client.put("/api/v1/drives/settings", json={"remove_download_tasks": False})
    assert saved.status_code == 200 and saved.json()["data"] == {"remove_download_tasks": False}
    call(client, remove_source.after_local_released, event)
    assert deleted == []

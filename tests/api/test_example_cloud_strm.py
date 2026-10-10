"""网盘上传示例插件端到端（docs/design/plugin-phase2b.md §10 B8，扩展模型 §2.2）。

把示例插件 ``cloud_strm.py`` 当本地受信插件装进临时数据目录，真实应用：入库暂存 → 槽位排出
插件的上传任务 → 执行器跑完上传、写签名 ``.strm`` → 只扫这些目录把 ``.strm`` 记账 → 播放器拿
``.strm`` 里的地址取流（含 Range），改了签名一律 404。
"""

from __future__ import annotations

import importlib
import shutil
import sys
import textwrap
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlmodel import select
from tests.api.test_library_ingest import (
    _FAKE_SPEC,
    _make_item,
    _make_library,
    _stub_identify,
    _stub_unit,
)

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import acquisition_ingest, durable_events
from movieclaw_api.services.library import ingest as ingest_mod
from movieclaw_db.engine import get_database
from movieclaw_db.models import ImportWatch, Job, JobStatus, LibraryFile
from movieclaw_media.models import MediaKind

EXAMPLES = (
    Path(__file__).resolve().parents[2]
    / "src"
    / "movieclaw_agent"
    / "builtin-skills"
    / "movieclaw-plugin-dev"
    / "references"
    / "examples"
)
UPLOAD = "cloud-strm:upload"


@pytest.fixture(params=["inline", "process"])
def app_client(request, tmp_path, monkeypatch):
    """主进程里跑一遍、独立进程里再跑一遍（plugin-phase3.md §0：运行位置对插件透明）。"""
    from movieclaw_api.settings.store import reset_setting_store

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'cloud.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    durable_events.reset_state()
    (tmp_path / "plugins").mkdir()
    shutil.copy(EXAMPLES / "cloud_strm.py", tmp_path / "plugins" / "cloud_strm.py")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            f"""
            - id: cloud-strm
              local: true
              runtime: {request.param}
              config: {{ cloud_dir: "{tmp_path / "cloud"}", chunk_mb: 1 }}
              grants: [library.get, library.scan.start]
              paths:
                - {{ path: "{tmp_path / "cloud"}", mode: rw }}
                - {{ path: staging, mode: rw }}
                - {{ path: library, mode: rw }}
            """
        ),
        encoding="utf-8",
    )
    from movieclaw_api.app import create_app

    app = create_app()
    with TestClient(app) as client:
        yield app, client
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    reset_setting_store()
    durable_events.reset_state()
    get_settings.cache_clear()


def wait_job(client, job_type: str, timeout: float = 60) -> Job:
    async def latest() -> Job | None:
        async with get_database().session() as session:
            return (
                await session.execute(
                    select(Job).where(Job.job_type == job_type).order_by(Job.created_at.desc())
                )
            ).scalar()

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        job = client.portal.call(latest)
        if job is not None and job.status in (
            JobStatus.SUCCEEDED,
            JobStatus.FAILED,
            JobStatus.BLOCKED,
        ):
            return job
        time.sleep(0.1)
    raise AssertionError(f"{job_type} 没有在 {timeout} 秒内结束：{job and job.status}")


def test_staged_files_go_to_the_cloud_and_come_back_as_signed_strm(
    app_client, tmp_path, monkeypatch
) -> None:
    from movieclaw_api.settings import get_setting_store
    from movieclaw_api.settings.app_server import AppServerSetting

    app, client = app_client
    fiber = app.state.kernel.fiber("cloud-strm")
    assert fiber.state.value == "active", fiber.error
    db = get_database()
    tv_root, watch, staging = tmp_path / "tv", tmp_path / "watch", tmp_path / "staging"
    watch.mkdir()
    staging.mkdir()
    episodes = {1: b"episode-1" * 200_000, 2: b"episode-2" * 10}  # 第一集跨好几个 1 MB 分块

    async def seed() -> ImportWatch:
        # TestClient 的地址就是「外部访问地址」：.strm 里的完整链接能直接拿来请求
        await get_setting_store().set(AppServerSetting(external_url="http://testserver"))
        await _make_library(db, kind=MediaKind.TV, root=tv_root)
        item = await _make_item(db, kind=MediaKind.TV, title="上云剧集", year=2026)
        _stub_identify(monkeypatch, item)
        async with db.session() as session:
            rule = ImportWatch(
                source_path=str(watch), strategy="hardlink", kind="tv", target_path=str(staging)
            )
            session.add(rule)
            await session.commit()
            await session.refresh(rule)
            return rule

    rule = client.portal.call(seed)
    # 与入库用例同样的隔离：独立的静默观察表，静默窗口立即落定（两轮巡检即入库）
    for table in ("_stability", "_deferred", "_failed_retry", "_last_swept"):
        monkeypatch.setattr(ingest_mod, table, {})
    monkeypatch.setattr(ingest_mod, "QUIET_SECONDS", 0)
    monkeypatch.setattr(acquisition_ingest, "_briefs_cache", (float("-inf"), None))
    monkeypatch.setattr(ingest_mod, "probe_media", lambda _path: _FAKE_SPEC)
    _stub_unit(monkeypatch, lambda file: (1, int(file.stem.removeprefix("ep"))))
    entry = watch / "上云剧集 S01"
    entry.mkdir()
    for number, content in episodes.items():
        (entry / f"ep{number}.mkv").write_bytes(content)

    # 第一轮登记新条目，第二轮确认文件不再变化后入库（与监听器的稳定性判断一致）
    for _ in range(2):
        client.portal.call(lambda: ingest_mod._sweep_dir(rule, None, execute_inline=True))

    upload = wait_job(client, UPLOAD)
    assert upload.status == JobStatus.SUCCEEDED, upload.error
    assert upload.progress["current"] == upload.progress["total"] == 2
    strms = sorted(Path(p) for p in upload.result["strm"])
    assert len(strms) == 2 and all(p.is_relative_to(tv_root) and p.suffix == ".strm" for p in strms)

    # 网盘上是完整文件（没有 .part 残留），暂存副本已删，做种的源文件不受影响
    cloud_files = sorted(p for p in (tmp_path / "cloud").rglob("*") if p.is_file())
    assert [p.read_bytes() for p in cloud_files] == [episodes[1], episodes[2]]
    assert not any(p.is_file() for p in staging.rglob("*"))
    assert (entry / "ep1.mkv").read_bytes() == episodes[1]

    # 只扫 .strm 所在目录，扫完 .strm 记账
    scan = wait_job(client, "library.scan")
    assert scan.status == JobStatus.SUCCEEDED, scan.error

    async def ledger() -> list[str]:
        async with db.session() as session:
            return sorted((await session.execute(select(LibraryFile.file_path))).scalars())

    assert client.portal.call(ledger) == [str(p) for p in strms]

    # 播放器打开 .strm 里的地址：验签通过取到网盘上的文件，支持 Range
    urls = [p.read_text(encoding="utf-8").strip() for p in strms]
    prefix = "http://testserver/api/v1/plugins/cloud-strm/play/"
    assert all(u.startswith(prefix) for u in urls)
    assert client.get(urls[0]).content == episodes[1]
    partial = client.get(urls[0], headers={"Range": "bytes=0-8"})
    assert partial.status_code == 206 and partial.content == b"episode-1"
    assert client.get(urls[0].replace("sig=", "sig=x")).status_code == 404
    assert client.get(urls[0].split("?")[0]).status_code == 404


def test_copy_resumes_from_the_part_file(tmp_path) -> None:
    sys.path.insert(0, str(EXAMPLES))
    try:
        cloud_strm = importlib.import_module("cloud_strm")
    finally:
        sys.path.remove(str(EXAMPLES))
        sys.modules.pop("cloud_strm", None)
    source = tmp_path / "a.mkv"
    source.write_bytes(bytes(range(256)) * 100)
    target = tmp_path / "cloud" / "a.mkv"
    target.parent.mkdir()
    # 上一次传到一半断了：.part 里有前 1000 字节，从第 1000 字节接着传
    part = target.parent / "a.mkv.part"
    part.write_bytes(source.read_bytes()[:1000])
    cloud_strm.copy_from(source.open("rb"), part.open("ab"), 1000, 4096)
    assert part.read_bytes() == source.read_bytes()
    assert cloud_strm.file_id("剧/S01/e1.mkv") == cloud_strm.file_id("剧/S01/e1.mkv")

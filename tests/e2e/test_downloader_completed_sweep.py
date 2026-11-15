"""issue #1275：下载器报告完成 → 监听巡检 → 入库，本机没有任何文件事件。

下载器跑在另一台主机、监听目录是 CIFS 挂载时，远端写入不产生本机 fs 事件。
这里不启动 watchdog 观察者（等价于收不到任何事件），网络轮询间隔也远长于
用例时长，唯一能叫醒巡检的就是下载巡检看到任务转为完成。使用真实的数据库、
监听消费循环、下载巡检和入库作业；仅下载器边界与媒体探测/识别打桩。
"""

import asyncio
import logging

import pytest
from sqlmodel import select
from tests.api.test_download_health import _seed
from tests.api.test_library_ingest import (
    _FAKE_SPEC,
    _make_item,
    _make_library,
    _make_rule,
    _stub_identify,
    _stub_unit,
    _wait_job_status,
)
from tests.api.test_library_ingest import db as db

from movieclaw_api.services import acquisition_ingest, download_progress, jobs
from movieclaw_api.services.library import ingest as ingest_mod
from movieclaw_api.services.library import mounts
from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    DownloaderClient,
    ImportWatch,
    Job,
    JobStatus,
    Library,
    LibraryFile,
    ManualDownloadIntent,
    MediaItem,
    Subscription,
    SubscriptionDownloadAttempt,
    utcnow,
)
from movieclaw_db.models.site_credential import ConfigStatus
from movieclaw_downloader import TorrentBrief, TorrentStatus
from movieclaw_downloader.models import TorrentFile
from movieclaw_media.models import MediaKind

_REMOTE_SAVE = "/downloads"


@pytest.fixture
async def watcher(db, monkeypatch):
    """只跑消费循环的监听器：没有观察者 → 收不到任何文件事件。"""
    monkeypatch.setattr(ingest_mod, "_EVENT_QUIET_SECONDS", 0.01)
    monkeypatch.setattr(download_progress, "_completion_swept", set())
    instance = ingest_mod.IngestWatcher()
    instance._loop = asyncio.get_running_loop()
    instance._consumer = asyncio.create_task(instance._consume())
    monkeypatch.setattr(ingest_mod, "_watcher", instance)
    yield instance
    await instance.stop()


def _cifs_watch_dir(tmp_path, monkeypatch):
    """监听目录挂在 CIFS 上（远端下载器写入，本机无事件）。"""
    watch = tmp_path / "nas-download"
    watch.mkdir()
    table = mounts.parse_mounts(f"//nas/temp/download {watch} cifs rw 0 0\n/dev/sda1 / ext4 rw 0 0")
    monkeypatch.setattr(mounts, "system_mounts", lambda: table)
    assert mounts.is_network_root(str(watch))
    return watch


async def _add_downloader(db, watch, *, name: str = "qb-remote") -> DownloaderClient:
    async with db.session() as session:
        row = DownloaderClient(
            name=name,
            client_type="qbittorrent",
            url="http://downloader.invalid",
            status=ConfigStatus.ACTIVE,
            path_mappings=[{"local": str(watch), "remote": _REMOTE_SAVE}],
        )
        session.add(row)
        await session.commit()
        await session.refresh(row)
        return row


def _stub_downloader(monkeypatch, downloader, status: TorrentStatus) -> list[str]:
    """下载器边界打桩；返回被查询过的 hash，供断言每轮确实在照看。"""
    queried: list[str] = []

    async def lookup(info_hash, *args, **kwargs):
        queried.append(info_hash.lower())
        if info_hash.lower() != status.info_hash:
            return download_progress._TorrentLookup(match=None, reachable_count=1)
        return download_progress._TorrentLookup(match=(downloader, status), reachable_count=1)

    async def briefs():
        return [
            TorrentBrief(
                name=status.name,
                content_name=status.name,
                info_hash=status.info_hash,
                completed=status.completed,
            )
        ]

    monkeypatch.setattr(download_progress, "_lookup_torrent", lookup)
    monkeypatch.setattr(acquisition_ingest, "downloader_briefs", briefs)
    return queried


def _status(info_hash: str, entry: str, video: str, payload: bytes, *, completed: bool):
    return TorrentStatus(
        name=entry,
        info_hash=info_hash,
        completed=completed,
        progress=1.0 if completed else 0.4,
        save_path=_REMOTE_SAVE,
        size_bytes=len(payload),
        state="completed" if completed else "downloading",
        files=[TorrentFile(path=f"{entry}/{video}", size_bytes=len(payload))],
    )


def _no_assets(monkeypatch):
    async def no_assets(*args, **kwargs):
        return None

    monkeypatch.setattr("movieclaw_api.services.media_scrape.ensure_assets", no_assets)
    monkeypatch.setattr(ingest_mod, "probe_media", lambda _path: _FAKE_SPEC)


async def _wait_ingest_job(timeout: float = 5.0) -> Job:
    deadline = asyncio.get_running_loop().time() + timeout
    while True:
        async with get_database().session() as session:
            rows = list(
                (await session.execute(select(Job).where(Job.job_type == "library.ingest")))
                .scalars()
                .all()
            )
        if rows:
            assert len(rows) == 1
            return await _wait_job_status(rows[0].id, JobStatus.SUCCEEDED, timeout=timeout)
        if asyncio.get_running_loop().time() >= deadline:
            raise AssertionError("下载完成后没有排出入库作业")
        await asyncio.sleep(0.01)


async def _settle(watcher) -> None:
    """等消费循环把已入队的巡检做完（去抖窗口 + 巡检本身）。"""
    for _ in range(100):
        await asyncio.sleep(0.02)
        if watcher._queue.empty() and not watcher._reasons:
            return
    raise AssertionError("监听巡检请求没有被消费")


@pytest.mark.asyncio
async def test_manual_download_completion_triggers_sweep_and_imports(
    db, watcher, tmp_path, monkeypatch, caplog
):
    """手动下载：此前只有打开任务中心才对账，后台不知道它何时完成。"""
    watch = _cifs_watch_dir(tmp_path, monkeypatch)
    root = tmp_path / "movies"
    library_id = await _make_library(db, kind=MediaKind.MOVIE, root=root)
    await _make_rule(db, library_id=library_id, source=watch)
    item = await _make_item(db, kind=MediaKind.MOVIE, title="远端电影", year=2024)
    _stub_identify(monkeypatch, item)
    _no_assets(monkeypatch)
    downloader = await _add_downloader(db, watch)
    info_hash = "b" * 40
    async with db.session() as session:
        session.add(
            ManualDownloadIntent(
                info_hash=info_hash,
                media_item_id=item.id,
                library_id=library_id,
                downloader_id=downloader.id,
            )
        )
        await session.commit()
    await jobs.init_job_dispatcher(max_parallel=1)

    entry = "Remote.Movie.2024"
    payload = b"remote movie bytes"
    status = _status(info_hash, entry, "movie.mkv", payload, completed=False)
    queried = _stub_downloader(monkeypatch, downloader, status)

    # 下载中：远端已写了部分内容，但本机没有事件、下载器也没说完成——不巡检
    (watch / entry).mkdir()
    (watch / entry / "movie.mkv").write_bytes(payload)
    await download_progress.check_download_progress()
    assert queried == [info_hash]
    assert watcher._queue.empty() and not watcher._reasons

    # 下载器报告完成：同一轮请求巡检，原因写进日志，文件入库
    status.completed = True
    status.progress = 1.0
    status.state = "completed"
    with caplog.at_level(logging.INFO, logger=ingest_mod.logger.name):
        await download_progress.check_download_progress()
        assert watcher._reasons == {str(watch): {ingest_mod.SWEEP_REASON_DOWNLOADER_COMPLETED}}
        await _settle(watcher)
        await _wait_ingest_job()
    assert f"巡检监听目录 {watch}（触发原因：downloader-completed）" in caplog.text
    async with db.session() as session:
        [imported] = (await session.execute(select(LibraryFile))).scalars().all()
        assert imported.media_item_id == item.id
        # 手动锚由入库认领后回收
        assert not (await session.execute(select(ManualDownloadIntent))).scalars().all()
    assert imported.file_path.startswith(str(root))
    with open(imported.file_path, "rb") as fh:
        assert fh.read() == payload

    # 已完成的任务后续巡检不再触发
    await download_progress.check_download_progress()
    assert watcher._queue.empty() and not watcher._reasons


@pytest.mark.asyncio
async def test_subscription_download_completion_triggers_sweep_and_imports(
    db, watcher, tmp_path, monkeypatch, caplog
):
    """订阅下载：完成翻转（持久化）即请求巡检，之后的心跳不再重复触发。"""
    watch = _cifs_watch_dir(tmp_path, monkeypatch)
    root = tmp_path / "tv"
    root.mkdir()
    info_hash = "c" * 40
    sub_id, _wanted_id = await _seed(
        db, tmdb_id=7, title="远端剧集", info_hash=info_hash, grabbed_at=utcnow()
    )
    async with db.session() as session:
        sub = await session.get(Subscription, sub_id)
        library = await session.get(Library, sub.library_id)
        library.root_paths = [str(root)]
        session.add(library)
        await session.commit()
        library_id = library.id
        item = await session.get(MediaItem, sub.media_item_id)
    await _make_rule(db, library_id=library_id, source=watch)
    _stub_identify(monkeypatch, item)
    _stub_unit(monkeypatch, lambda _file: (1, 1))
    _no_assets(monkeypatch)
    downloader = await _add_downloader(db, watch)
    await jobs.init_job_dispatcher(max_parallel=1)

    entry = "Remote.Show.S01"
    payload = b"remote episode bytes"
    (watch / entry).mkdir()
    (watch / entry / "Remote.Show.S01E01.mkv").write_bytes(payload)
    status = _status(info_hash, entry, "Remote.Show.S01E01.mkv", payload, completed=True)
    _stub_downloader(monkeypatch, downloader, status)

    with caplog.at_level(logging.INFO, logger=ingest_mod.logger.name):
        await download_progress.check_download_progress()
        assert watcher._reasons == {str(watch): {ingest_mod.SWEEP_REASON_DOWNLOADER_COMPLETED}}
        await _settle(watcher)
        await _wait_ingest_job()
    assert f"巡检监听目录 {watch}（触发原因：downloader-completed）" in caplog.text
    async with db.session() as session:
        attempt = (await session.execute(select(SubscriptionDownloadAttempt))).scalar_one()
        assert attempt.status == "completed"
        [imported] = (await session.execute(select(LibraryFile))).scalars().all()
        assert imported.media_item_id == item.id
    assert imported.file_path.startswith(str(root))
    with open(imported.file_path, "rb") as fh:
        assert fh.read() == payload

    # 进程内去重表清空（模拟重启）也不会重复触发：订阅靠持久化的完成翻转
    download_progress._completion_swept.clear()
    await download_progress.check_download_progress()
    await download_progress.check_download_progress()
    assert watcher._queue.empty() and not watcher._reasons


@pytest.mark.asyncio
async def test_completed_task_triggers_only_once_across_ticks(db, tmp_path, monkeypatch):
    """同一任务完成后反复巡检只触发一次；订阅与手动指向同一种子也只一次；
    任务退回未完成（重新校验/续传）后再次完成，算一次新的完成。"""
    watch = _cifs_watch_dir(tmp_path, monkeypatch)
    monkeypatch.setattr(download_progress, "_completion_swept", set())
    pokes: list[tuple[str, str]] = []

    class _Recorder:
        def poke(self, source_path, *, reason):
            pokes.append((source_path, reason))

    monkeypatch.setattr(ingest_mod, "_watcher", _Recorder())
    info_hash = "d" * 40
    sub_id, _wanted_id = await _seed(
        db, tmdb_id=8, title="共享种子", info_hash=info_hash, grabbed_at=utcnow()
    )
    async with db.session() as session:
        sub = await session.get(Subscription, sub_id)
        library_id, media_item_id = sub.library_id, sub.media_item_id
    await _make_rule(db, library_id=library_id, source=watch)
    downloader = await _add_downloader(db, watch)
    async with db.session() as session:
        session.add(
            ManualDownloadIntent(
                info_hash=info_hash,
                media_item_id=media_item_id,
                library_id=library_id,
                downloader_id=downloader.id,
            )
        )
        await session.commit()
    status = _status(info_hash, "Shared", "Shared.S01E01.mkv", b"x", completed=True)
    _stub_downloader(monkeypatch, downloader, status)
    expected = [(str(watch), ingest_mod.SWEEP_REASON_DOWNLOADER_COMPLETED)]

    for _ in range(3):
        await download_progress.check_download_progress()
    assert pokes == expected

    # 退回未完成再完成：手动锚仍在，重新完成按一次新完成触发
    status.completed = False
    await download_progress.check_download_progress()
    assert pokes == expected
    status.completed = True
    await download_progress.check_download_progress()
    await download_progress.check_download_progress()
    assert pokes == expected * 2


def _count_sweeps(monkeypatch) -> dict[str, int]:
    """数一数监听目录巡检做完了几轮（不论成败），供用例等「这一轮确实跑完」。"""
    done = {"n": 0}
    real = ingest_mod._sweep_dir

    async def counted(*args, **kwargs):
        try:
            return await real(*args, **kwargs)
        finally:
            done["n"] += 1

    monkeypatch.setattr(ingest_mod, "_sweep_dir", counted)
    return done


async def _wait_sweeps(done: dict[str, int], at_least: int, timeout: float = 5.0) -> None:
    deadline = asyncio.get_running_loop().time() + timeout
    while done["n"] < at_least:
        if asyncio.get_running_loop().time() >= deadline:
            raise AssertionError(f"监听巡检只跑了 {done['n']} 轮")
        await asyncio.sleep(0.01)


def _cifs_mount(monkeypatch, *paths) -> None:
    """这些目录都挂在 CIFS 上（目录本身此刻存不存在都行——挂载可能正掉着）。"""
    lines = [f"//nas/share{i} {path} cifs rw 0 0" for i, path in enumerate(paths)]
    table = mounts.parse_mounts("\n".join([*lines, "/dev/sda1 / ext4 rw 0 0"]))
    monkeypatch.setattr(mounts, "system_mounts", lambda: table)


@pytest.mark.asyncio
async def test_network_poll_continues_after_skip_existing_baseline(
    db, watcher, tmp_path, monkeypatch
):
    """「跳过存量」规则的首轮巡检只打基线就收工；之后远端完成的新下载没有
    任何本机事件、也没有下载器完成信号，只能靠网络轮询发现——首轮基线后
    轮询必须照常挂上，新下载按新增入库，存量保持忽略。"""
    watch = _cifs_watch_dir(tmp_path, monkeypatch)
    monkeypatch.setattr(ingest_mod, "NETWORK_POLL_SECONDS", 0.05)
    root = tmp_path / "movies"
    library_id = await _make_library(db, kind=MediaKind.MOVIE, root=root)
    async with db.session() as session:
        session.add(
            ImportWatch(
                source_path=str(watch),
                strategy="hardlink",
                library_id=library_id,
                process_existing=False,
            )
        )
        await session.commit()
    item = await _make_item(db, kind=MediaKind.MOVIE, title="远端新片", year=2024)
    _stub_identify(monkeypatch, item)
    _no_assets(monkeypatch)
    await jobs.init_job_dispatcher(max_parallel=1)
    (watch / "Old.Movie.2001").mkdir()
    (watch / "Old.Movie.2001" / "old.mkv").write_bytes(b"old")

    # 监听建立时的那一次补扫：只打基线
    sweeps = _count_sweeps(monkeypatch)
    ingest_mod.request_sweep(str(watch), reason=ingest_mod.SWEEP_REASON_WATCH_ARMED)
    await _wait_sweeps(sweeps, 1)

    # 远端下载完成：本机无事件、无人 poke
    (watch / "New.Movie.2024").mkdir()
    (watch / "New.Movie.2024" / "movie.mkv").write_bytes(b"fresh bytes")
    await _wait_ingest_job()
    async with db.session() as session:
        [imported] = (await session.execute(select(LibraryFile))).scalars().all()
    assert imported.media_item_id == item.id
    with open(imported.file_path, "rb") as fh:
        assert fh.read() == b"fresh bytes"


@pytest.mark.asyncio
@pytest.mark.parametrize("fault", ["mount-missing", "sweep-raises"])
async def test_network_poll_recovers_after_failed_sweep(db, watcher, tmp_path, monkeypatch, fault):
    """某一轮巡检失败（挂载暂时掉了 / 巡检中途抛异常）后轮询不能就此断掉：
    故障恢复后，远端完成的下载在没有任何本机事件的情况下仍被下一轮轮询接住。"""
    watch = tmp_path / "nas-download"
    _cifs_mount(monkeypatch, watch)
    monkeypatch.setattr(ingest_mod, "NETWORK_POLL_SECONDS", 0.05)
    root = tmp_path / "movies"
    library_id = await _make_library(db, kind=MediaKind.MOVIE, root=root)
    await _make_rule(db, library_id=library_id, source=watch)
    item = await _make_item(db, kind=MediaKind.MOVIE, title="远端电影", year=2024)
    _stub_identify(monkeypatch, item)
    _no_assets(monkeypatch)
    await jobs.init_job_dispatcher(max_parallel=1)

    failures = {"left": 0}
    if fault == "sweep-raises":
        watch.mkdir()
        failures["left"] = 1
        real_briefs = acquisition_ingest.downloader_briefs

        async def flaky_briefs():
            if failures["left"]:
                failures["left"] -= 1
                raise RuntimeError("下载器概览查询异常")
            return await real_briefs()

        monkeypatch.setattr(acquisition_ingest, "downloader_briefs", flaky_briefs)

    # 故障中的那一轮
    sweeps = _count_sweeps(monkeypatch)
    ingest_mod.request_sweep(str(watch), reason=ingest_mod.SWEEP_REASON_WATCH_ARMED)
    await _wait_sweeps(sweeps, 1)
    assert failures["left"] == 0

    # 故障恢复，远端下载完成：本机无事件、无人 poke
    watch.mkdir(exist_ok=True)
    (watch / "Remote.Movie.2024").mkdir()
    (watch / "Remote.Movie.2024" / "movie.mkv").write_bytes(b"remote bytes")
    await _wait_ingest_job()
    async with db.session() as session:
        [imported] = (await session.execute(select(LibraryFile))).scalars().all()
    assert imported.media_item_id == item.id


@pytest.mark.asyncio
@pytest.mark.parametrize("unmounted", ["local", "unknown"])
async def test_network_poll_survives_mount_type_change(
    db, watcher, tmp_path, monkeypatch, unmounted
):
    """CIFS 挂载掉了：挂载表里这个目录一度落回本地盘（local）或整张表读不到
    （unknown）。已确认是网络目录的规则要一直保留恢复检查——之后重新挂上、
    远端完成了下载，即使没有任何本机文件事件也要被轮询接住入库，不能只等
    小时级兜底。"""
    watch = tmp_path / "nas-download"
    watch.mkdir()
    table = {"now": "cifs"}
    reads = {"unmounted": 0}
    tables = {
        "cifs": f"//nas/temp/download {watch} cifs rw 0 0\n/dev/sda1 / ext4 rw 0 0",
        "local": "/dev/sda1 / ext4 rw 0 0",
        "unknown": "",
    }

    def system_mounts():
        if table["now"] != "cifs":
            reads["unmounted"] += 1
        return mounts.parse_mounts(tables[table["now"]])

    monkeypatch.setattr(mounts, "system_mounts", system_mounts)
    assert mounts.is_network_root(str(watch))
    monkeypatch.setattr(ingest_mod, "NETWORK_POLL_SECONDS", 0.05)
    root = tmp_path / "movies"
    library_id = await _make_library(db, kind=MediaKind.MOVIE, root=root)
    await _make_rule(db, library_id=library_id, source=watch)
    item = await _make_item(db, kind=MediaKind.MOVIE, title="远端电影", year=2024)
    _stub_identify(monkeypatch, item)
    _no_assets(monkeypatch)
    await jobs.init_job_dispatcher(max_parallel=1)

    # 挂着 CIFS 时的首轮巡检：确认是网络目录，挂上轮询
    sweeps = _count_sweeps(monkeypatch)
    ingest_mod.request_sweep(str(watch), reason=ingest_mod.SWEEP_REASON_WATCH_ARMED)
    await _wait_sweeps(sweeps, 1)

    # 挂载掉了：等轮询至少醒来一次、看到挂载表已不再是 CIFS
    table["now"] = unmounted
    assert not mounts.is_network_root(str(watch))
    reads["unmounted"] = 0
    deadline = asyncio.get_running_loop().time() + 5.0
    while reads["unmounted"] < 2:
        if asyncio.get_running_loop().time() >= deadline:
            raise AssertionError("挂载掉了之后轮询再没醒来")
        await asyncio.sleep(0.01)

    # 重新挂上，远端下载完成：本机无事件、无人 poke
    table["now"] = "cifs"
    (watch / "Remote.Movie.2024").mkdir()
    (watch / "Remote.Movie.2024" / "movie.mkv").write_bytes(b"remote bytes")
    await _wait_ingest_job()
    async with db.session() as session:
        [imported] = (await session.execute(select(LibraryFile))).scalars().all()
    assert imported.media_item_id == item.id


async def _same_hash_on_two_downloaders(db, tmp_path, monkeypatch):
    """同一个种子同时在两台下载器里：订阅尝试走 A（没记下载器，先查到 A），
    手动锚指明 B；两台各自映射到自己的 CIFS 监听目录，两边都已完成。"""
    watch_a, watch_b = tmp_path / "nas-a", tmp_path / "nas-b"
    watch_a.mkdir()
    watch_b.mkdir()
    _cifs_mount(monkeypatch, watch_a, watch_b)
    monkeypatch.setattr(download_progress, "_completion_swept", set())
    pokes: list[tuple[str, str]] = []

    class _Recorder:
        def poke(self, source_path, *, reason):
            pokes.append((source_path, reason))

    monkeypatch.setattr(ingest_mod, "_watcher", _Recorder())
    info_hash = "e" * 40
    sub_id, _wanted_id = await _seed(
        db, tmdb_id=9, title="两台下载器", info_hash=info_hash, grabbed_at=utcnow()
    )
    async with db.session() as session:
        sub = await session.get(Subscription, sub_id)
        library_id, media_item_id = sub.library_id, sub.media_item_id
    await _make_rule(db, library_id=library_id, source=watch_a)
    await _make_rule(db, library_id=library_id, source=watch_b)
    downloader_a = await _add_downloader(db, watch_a, name="qb-a")
    downloader_b = await _add_downloader(db, watch_b, name="qb-b")
    async with db.session() as session:
        session.add(
            ManualDownloadIntent(
                info_hash=info_hash,
                media_item_id=media_item_id,
                library_id=library_id,
                downloader_id=downloader_b.id,
            )
        )
        await session.commit()
    status_a = _status(info_hash, "Shared", "Shared.S01E01.mkv", b"x", completed=True)
    status_b = _status(info_hash, "Shared", "Shared.S01E01.mkv", b"x", completed=True)

    async def lookup(hash_, *args, preferred_downloader_id=None, **kwargs):
        # 手动锚指明在 B 上；订阅尝试没记下载器，先查到的是 A
        if preferred_downloader_id == downloader_b.id:
            return download_progress._TorrentLookup(
                match=(downloader_b, status_b), reachable_count=2
            )
        return download_progress._TorrentLookup(match=(downloader_a, status_a), reachable_count=2)

    async def briefs():
        return []

    monkeypatch.setattr(download_progress, "_lookup_torrent", lookup)
    monkeypatch.setattr(acquisition_ingest, "downloader_briefs", briefs)
    done = ingest_mod.SWEEP_REASON_DOWNLOADER_COMPLETED

    for _ in range(3):
        await download_progress.check_download_progress()
    assert sorted(pokes) == sorted([(str(watch_a), done), (str(watch_b), done)])
    pokes.clear()
    return pokes, (watch_a, status_a), (watch_b, status_b)


@pytest.mark.asyncio
async def test_same_hash_on_two_downloaders_each_triggers_own_watch_dir(db, tmp_path, monkeypatch):
    """同一个种子同时在两台下载器里（订阅走 A、手动走 B），各自映射到不同的
    监听目录：两边的完成都要请求巡检自己的目录，一边先完成不能吞掉另一边；
    各自仍只触发一次，B 退回未完成后再完成只重新触发 B。"""
    pokes, _a, (watch_b, status_b) = await _same_hash_on_two_downloaders(db, tmp_path, monkeypatch)

    # B 上的任务重新校验（退回未完成）后再次完成：只重新触发 B
    status_b.completed = False
    await download_progress.check_download_progress()
    status_b.completed = True
    await download_progress.check_download_progress()
    await download_progress.check_download_progress()
    assert pokes == [(str(watch_b), ingest_mod.SWEEP_REASON_DOWNLOADER_COMPLETED)]


@pytest.mark.asyncio
async def test_subscription_regression_retriggers_while_manual_anchor_remains(
    db, tmp_path, monkeypatch
):
    """订阅走 A、手动走 B 的同一种子都已完成，B 的手动锚还没回收；A 上的任务
    重新校验（退回未完成）后再次完成，是 A 的一次新完成：必须再请求巡检 A 的
    目录——B 的锚还在不能让 A 的旧完成记录一直占着；B 不受影响。"""
    pokes, (watch_a, status_a), _b = await _same_hash_on_two_downloaders(db, tmp_path, monkeypatch)

    status_a.completed = False
    await download_progress.check_download_progress()
    async with db.session() as session:
        attempt = (await session.execute(select(SubscriptionDownloadAttempt))).scalar_one()
        assert attempt.status != "completed"
        # 前提：B 的手动锚仍在照看
        assert (await session.execute(select(ManualDownloadIntent))).scalars().all()
    status_a.completed = True
    await download_progress.check_download_progress()
    await download_progress.check_download_progress()
    assert pokes == [(str(watch_a), ingest_mod.SWEEP_REASON_DOWNLOADER_COMPLETED)]

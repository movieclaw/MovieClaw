"""内封轨抽取的共享底座（issue #432）。

抽取要通读整个容器，16 GB 的 MKV 是 80 秒级——这条路径上「多起一个 ffmpeg」
不是浪费一点 CPU，而是把最贵的一步整个做第二遍。本文件守的就是这件事：
同一条轨并发只跑一个进程，预检不在请求里等，产物播放器与生成端共用。

真抽取的正确性（ASS 保样式、文本转 SRT、PGS 转 sup）在
``tests/playback/test_embedded_subs.py`` 里，标 integration。
"""

from __future__ import annotations

import asyncio
from pathlib import Path
from types import SimpleNamespace

import pytest

import movieclaw_api.services.media_extract as media_extract
from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import render_value, source_render
from movieclaw_api.services.library.bluray import DISC_PLAYLIST_VERSION
from movieclaw_api.services.playback import iso_source
from movieclaw_api.services.playback.disc_source import DiscClip, DiscSource
from movieclaw_db.models import FileSource, FileState, LibraryFile


@pytest.fixture(autouse=True)
def _no_cue_extraction(monkeypatch):
    """这里的用例测整片通读的单飞、取消与失败记忆，按事件循环的轮次计时；按字幕索引读取
    的快路径要进线程、占真实时间，在这里一律当作「不适用」（它另见 test_subtitle_cues）。"""

    async def not_applicable(_pending) -> bool:
        return False

    monkeypatch.setattr(media_extract, "_run_sparse_extraction", not_applicable)


def make_file(video: Path, codec: str = "subrip") -> LibraryFile:
    return LibraryFile(
        id=7,
        library_id=1,
        media_item_id=1,
        file_path=str(video),
        size_bytes=1,
        source=FileSource.SCANNED,
        state=FileState.IN_PLACE,
        container="mkv",
        subtitle_streams=[{"codec": codec}],
    )


@pytest.fixture
def video(tmp_path: Path, monkeypatch) -> Path:
    """一个假视频 + 独立的抽取缓存目录。"""
    path = tmp_path / "movie.mkv"
    path.write_bytes(b"source")
    monkeypatch.setattr(media_extract, "cache_dir", lambda: tmp_path / "cache")
    return path


def _fresh_product(video: Path, cache: Path, name: str, text: str = "x") -> Path:
    import os

    cache.mkdir(parents=True, exist_ok=True)
    product = cache / name
    product.write_text(text, encoding="utf-8")
    os.utime(product, ns=(video.stat().st_mtime_ns + 10**9,) * 2)
    return product


# ---------------------------------------------------------------------------
# 缓存查询：预检据此判断「这次能不能立刻给出结论」
# ---------------------------------------------------------------------------


def test_cached_track_never_starts_ffmpeg(tmp_path: Path, video: Path, monkeypatch) -> None:
    def never(*_a, **_k):  # pragma: no cover
        raise AssertionError("只查缓存的调用起了 ffmpeg")

    monkeypatch.setattr(media_extract.subprocess, "Popen", never)
    assert media_extract.cached_track(make_file(video), 0) is None

    _fresh_product(video, tmp_path / "cache", "7.s0.srt")
    track = media_extract.cached_track(make_file(video), 0)
    assert track is not None and track.format == "srt"


def test_cache_goes_stale_when_the_video_is_replaced(
    tmp_path: Path, video: Path
) -> None:
    """洗版换片后必须重抽——否则新片配旧字幕，时间轴整体对不上。"""
    import os

    product = _fresh_product(video, tmp_path / "cache", "7.s0.srt")
    assert media_extract.cached_track(make_file(video), 0) is not None

    os.utime(video, ns=(product.stat().st_mtime_ns + 10**9,) * 2)
    assert media_extract.cached_track(make_file(video), 0) is None


def test_unsupported_codec_has_no_cache_identity(video: Path) -> None:
    assert media_extract.cached_track(make_file(video, "dvd_subtitle"), 0) is None


# ---------------------------------------------------------------------------
# 单飞：issue #432 的第二条
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_concurrent_requests_share_one_ffmpeg(video: Path, monkeypatch) -> None:
    """用户等待时拨一下「双语」开关就再发一次预检，不能因此起第二个 ffmpeg。

    日志里那两条 80 秒的请求就是这么来的：前端丢掉了旧响应，后端的活一点
    没省，同一个 16 GB 的文件被同时通读了两遍。
    """
    starts = 0
    release = asyncio.Event()

    class SlowProcess:
        pid = 4321
        returncode: int | None = None

        async def communicate(self):
            await release.wait()
            self.returncode = 0
            return b"", b""

    async def fake_exec(*argv, **_kwargs):
        nonlocal starts
        starts += 1
        # 产物由「ffmpeg」写出：最后一个参数是临时文件路径
        Path(argv[-1]).write_text("1\n00:00:01,000 --> 00:00:02,000\nhi\n\n", encoding="utf-8")
        return SlowProcess()

    monkeypatch.setattr(media_extract.shutil, "which", lambda _n: "/fake/ffmpeg")
    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", fake_exec)

    file = make_file(video)
    waiters = [
        asyncio.create_task(media_extract.extract_track_async(file, 0)) for _ in range(4)
    ]
    await asyncio.sleep(0)  # 让所有等待者都登记到同一个共享任务上
    release.set()
    results = await asyncio.gather(*waiters)

    assert starts == 1, f"同一条轨起了 {starts} 个 ffmpeg"
    assert all(r is not None and r.format == "srt" for r in results)


@pytest.mark.asyncio
async def test_one_caller_leaving_does_not_kill_the_others(video: Path, monkeypatch) -> None:
    """详情页预热与播放器请求会撞在同一条轨上，谁先走都不能把对方的活取消。"""
    release = asyncio.Event()

    class SlowProcess:
        pid = 4321
        returncode: int | None = None

        async def communicate(self):
            await release.wait()
            self.returncode = 0
            return b"", b""

    async def fake_exec(*argv, **_kwargs):
        Path(argv[-1]).write_text("1\n00:00:01,000 --> 00:00:02,000\nhi\n\n", encoding="utf-8")
        return SlowProcess()

    monkeypatch.setattr(media_extract.shutil, "which", lambda _n: "/fake/ffmpeg")
    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", fake_exec)

    file = make_file(video)
    leaving = asyncio.create_task(media_extract.extract_track_async(file, 0))
    staying = asyncio.create_task(media_extract.extract_track_async(file, 0))
    await asyncio.sleep(0)

    leaving.cancel()
    with pytest.raises(asyncio.CancelledError):
        await leaving

    release.set()
    assert (await staying) is not None, "一个调用方离开就把还在等的那个也弄没了"


# ---------------------------------------------------------------------------
# 后台调度：预检不在 HTTP 请求里等 ffmpeg
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_scheduling_is_idempotent_and_finishes_after_the_caller_leaves(
    video: Path, monkeypatch
) -> None:
    """轮询期间反复调度只跑一个进程；用户关掉对话框，抽取仍要做完落缓存。

    那趟昂贵的通读只值得做一次——半路丢掉等于下次从零再来。
    """
    starts = 0
    release = asyncio.Event()

    class SlowProcess:
        pid = 99
        returncode: int | None = None

        async def communicate(self):
            await release.wait()
            self.returncode = 0
            return b"", b""

    async def fake_exec(*argv, **_kwargs):
        nonlocal starts
        starts += 1
        Path(argv[-1]).write_text("1\n00:00:01,000 --> 00:00:02,000\nhi\n\n", encoding="utf-8")
        return SlowProcess()

    monkeypatch.setattr(media_extract.shutil, "which", lambda _n: "/fake/ffmpeg")
    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", fake_exec)

    file = make_file(video)
    # 前端轮询三次 = 三次调度，只应该有一个 ffmpeg
    assert media_extract.schedule_extraction(file, 0) is True
    await asyncio.sleep(0)
    assert media_extract.schedule_extraction(file, 0) is True
    assert media_extract.schedule_extraction(file, 0) is True

    # 调用方全部离开（用户关掉对话框），后台任务继续把产物抽完
    release.set()
    for _ in range(10):
        await asyncio.sleep(0)
        if media_extract.cached_track(file, 0) is not None:
            break

    assert starts == 1, f"轮询把同一条轨抽了 {starts} 遍"
    assert media_extract.cached_track(file, 0) is not None, "后台抽取没有落成缓存"
    # 已有缓存后不再调度：轮询拿到的就是最终结论
    assert media_extract.schedule_extraction(file, 0) is False


@pytest.mark.asyncio
async def test_a_failed_track_is_not_retried_on_every_poll(video: Path, monkeypatch) -> None:
    """一条读不出来的轨，不能让前端轮询每隔两三秒催起一个新的 ffmpeg。

    没有这道闸门，打开对话框放着不管就是一个持续吃满 CPU 的循环。
    """
    starts = 0

    class FailingProcess:
        pid = 1
        returncode: int | None = None

        async def communicate(self):
            self.returncode = 1
            return b"", b"stream not found"

    async def fake_exec(*_argv, **_kwargs):
        nonlocal starts
        starts += 1
        return FailingProcess()  # 不写产物 = 抽取失败

    monkeypatch.setattr(media_extract.shutil, "which", lambda _n: "/fake/ffmpeg")
    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", fake_exec)

    file = make_file(video)
    assert media_extract.schedule_extraction(file, 0) is True
    for _ in range(10):
        await asyncio.sleep(0)
        if media_extract.extraction_failed(file, 0):
            break

    assert media_extract.extraction_failed(file, 0) is True
    # 后续轮询一律被拒，ffmpeg 不再起第二次
    assert media_extract.schedule_extraction(file, 0) is False
    assert media_extract.schedule_extraction(file, 0) is False
    for _ in range(5):
        await asyncio.sleep(0)
    assert starts == 1, f"失败的轨被重抽了 {starts} 次"


@pytest.mark.asyncio
async def test_replacing_the_video_clears_the_failure_verdict(
    video: Path, monkeypatch
) -> None:
    """洗版换片之后值得再试一次——旧片抽不出来不代表新片也不行。"""
    import os

    file = make_file(video)
    spec = media_extract._extraction_spec(file, 0)
    assert spec is not None
    media_extract._FAILED_EXTRACTIONS[media_extract._job_key(spec, 0)] = (
        video.stat().st_mtime_ns
    )
    assert media_extract.extraction_failed(file, 0) is True

    os.utime(video, ns=(video.stat().st_mtime_ns + 10**9,) * 2)
    assert media_extract.extraction_failed(file, 0) is False


@pytest.mark.asyncio
async def test_scheduling_an_unsupported_track_is_refused(video: Path) -> None:
    assert media_extract.schedule_extraction(make_file(video, "dvd_subtitle"), 0) is False


def test_scheduling_without_an_event_loop_is_refused(video: Path) -> None:
    """同步上下文（扫描脚本、CLI）没有事件循环可挂后台任务，如实返回 False。"""
    assert media_extract.schedule_extraction(make_file(video), 0) is False


# ---------------------------------------------------------------------------
# 一个文件只通读一遍、全局串行、超时按体积、失败记住（2026-09 NAS 白读几百 GB）
# ---------------------------------------------------------------------------

_SRT = "1\n00:00:01,000 --> 00:00:02,000\nhi\n\n"


def make_multi_file(video: Path, codecs: list[str], file_id: int = 7) -> LibraryFile:
    file = make_file(video)
    file.id = file_id
    file.subtitle_streams = [{"codec": c} for c in codecs]
    return file


def _outputs(argv) -> list[str]:
    """假 ffmpeg 要写出的产物：多路输出时每条轨一个 .part 临时文件。"""
    return [a for a in argv if ".part." in str(a)]


class _DoneProcess:
    pid = None  # 没有真实进程组；终止路径对 None 按幂等跳过

    def __init__(self, returncode: int = 0) -> None:
        self.returncode: int | None = None
        self._rc = returncode

    async def communicate(self):
        self.returncode = self._rc
        return b"", b"" if self._rc == 0 else b"boom"


@pytest.mark.asyncio
async def test_one_ffmpeg_extracts_every_track_of_the_file(video: Path, monkeypatch) -> None:
    """一部带三条字幕的 Remux，逐轨抽等于从头读三遍；一趟多路输出全部落缓存。"""
    calls = []

    async def fake_exec(*argv, **_kwargs):
        calls.append(argv)
        for out in _outputs(argv):
            Path(out).write_text(_SRT, encoding="utf-8")
        return _DoneProcess()

    monkeypatch.setattr(media_extract.shutil, "which", lambda _n: "/fake/ffmpeg")
    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", fake_exec)

    file = make_multi_file(video, ["subrip", "ass", "hdmv_pgs_subtitle", "dvd_subtitle"])
    track = await media_extract.extract_track_async(file, 1)

    assert track is not None and track.format == "ass"
    assert len(calls) == 1, f"一个文件起了 {len(calls)} 个 ffmpeg"
    assert calls[0].count("-i") == 1 and calls[0].count("-map") == 3  # VobSub 不支持，不抽
    for index, fmt in ((0, "srt"), (2, "sup")):
        cached = media_extract.cached_track(file, index)
        assert cached is not None and cached.format == fmt


@pytest.mark.asyncio
async def test_different_tracks_of_one_file_share_one_ffmpeg(video: Path, monkeypatch) -> None:
    """播放器要轨 0、AI 生成要轨 1，同时到达也只通读一遍。"""
    starts = 0
    release = asyncio.Event()

    class SlowProcess(_DoneProcess):
        async def communicate(self):
            await release.wait()
            return await super().communicate()

    async def fake_exec(*argv, **_kwargs):
        nonlocal starts
        starts += 1
        for out in _outputs(argv):
            Path(out).write_text(_SRT, encoding="utf-8")
        return SlowProcess()

    monkeypatch.setattr(media_extract.shutil, "which", lambda _n: "/fake/ffmpeg")
    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", fake_exec)

    file = make_multi_file(video, ["subrip", "subrip"])
    first = asyncio.create_task(media_extract.extract_track_async(file, 0))
    second = asyncio.create_task(media_extract.extract_track_async(file, 1))
    await asyncio.sleep(0)
    release.set()

    assert all(r is not None for r in await asyncio.gather(first, second))
    assert starts == 1, f"同一个文件被通读了 {starts} 遍"


@pytest.mark.asyncio
async def test_a_timed_out_file_is_not_read_again(video: Path, monkeypatch) -> None:
    """超时白读一遍已经够亏；不记住的话每次打开播放器都再白读一遍。"""
    starts = 0

    class HangingProcess(_DoneProcess):
        async def communicate(self):
            await asyncio.Event().wait()

    async def fake_exec(*_argv, **_kwargs):
        nonlocal starts
        starts += 1
        return HangingProcess()

    monkeypatch.setattr(media_extract.shutil, "which", lambda _n: "/fake/ffmpeg")
    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", fake_exec)
    monkeypatch.setattr(media_extract, "_extract_timeout", lambda _v: 0.01)
    # 超时后会给进程组发 SIGTERM/SIGKILL：假进程的 pid 不能真的拿去 killpg
    monkeypatch.setattr(media_extract, "_signal_process_group", lambda _pid, _sig: None)
    monkeypatch.setattr(media_extract, "_PROCESS_TERM_TIMEOUT", 0.01)
    monkeypatch.setattr(media_extract, "_PROCESS_KILL_TIMEOUT", 0.01)

    file = make_multi_file(video, ["subrip", "ass"])
    assert await media_extract.extract_track_async(file, 0) is None
    assert media_extract.extraction_failed(file, 0) and media_extract.extraction_failed(file, 1)

    assert await media_extract.extract_track_async(file, 1) is None
    assert starts == 1, f"超时过的文件又被读了 {starts - 1} 遍"


@pytest.mark.asyncio
async def test_whole_file_reads_are_serialized_across_files(tmp_path: Path, monkeypatch) -> None:
    """几个 ffmpeg 并发读 NFS 只会平分带宽、一起撞超时；同一时刻只放行一个。"""
    monkeypatch.setattr(media_extract, "cache_dir", lambda: tmp_path / "cache")
    running = 0
    peak = 0

    class CountingProcess(_DoneProcess):
        async def communicate(self):
            nonlocal running, peak
            running += 1
            peak = max(peak, running)
            await asyncio.sleep(0.01)
            running -= 1
            return await super().communicate()

    async def fake_exec(*argv, **_kwargs):
        for out in _outputs(argv):
            Path(out).write_text(_SRT, encoding="utf-8")
        return CountingProcess()

    monkeypatch.setattr(media_extract.shutil, "which", lambda _n: "/fake/ffmpeg")
    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", fake_exec)

    files = []
    for i in range(4):
        path = tmp_path / f"movie{i}.mkv"
        path.write_bytes(b"source")
        files.append(make_multi_file(path, ["subrip"], file_id=100 + i))

    results = await asyncio.gather(
        *(media_extract.extract_track_async(f, 0) for f in files)
    )
    assert all(r is not None for r in results)
    assert peak == 1, f"同时有 {peak} 个整文件通读在跑"


def test_timeout_scales_with_file_size() -> None:
    """固定 120 秒读不完 60 GB 的 Remux；按保守吞吐放宽，封顶一小时。

    体积走替身，**不真造文件**：这个用例原来 ``truncate`` 出 20 GB 与 200 GB 的
    "稀疏文件"，而稀疏与否由文件系统决定——NTFS 等不支持稀疏文件的文件系统上会真写
    出这么多零，把 pytest 临时目录所在的盘写满，之后的用例全部 ENOSPC（连 sqlite 都
    开不了）。判定只读 ``stat().st_size``，喂它一个数就够了。
    """

    class _SizedPath:
        """只回答体积的假 Path：``_extract_timeout`` 只用 ``str()`` 与 ``stat().st_size``。"""

        def __init__(self, name: str, size: int) -> None:
            self._name = name
            self._size = size

        def __str__(self) -> str:
            return self._name

        def stat(self):  # noqa: ANN201 - 与 pathlib.Path.stat 同形的替身
            return SimpleNamespace(st_size=self._size)

    assert (
        media_extract._extract_timeout(_SizedPath("small.mkv", 1))
        == media_extract.EXTRACT_TIMEOUT
    )
    assert media_extract._extract_timeout(
        _SizedPath("remux.mkv", 20 * 1024**3)
    ) == pytest.approx(1024.0)
    assert (
        media_extract._extract_timeout(_SizedPath("huge.mkv", 200 * 1024**3))
        == media_extract._MAX_EXTRACT_TIMEOUT
    )


@pytest.mark.asyncio
async def test_a_bad_track_does_not_sink_the_good_ones(video: Path, monkeypatch) -> None:
    """多轨一趟 ffmpeg 报错时退回逐轨：好轨照常出产物，只有坏轨记失败。"""
    calls = []

    async def fake_exec(*argv, **_kwargs):
        calls.append(argv)
        maps = [argv[i + 1] for i, a in enumerate(argv) if a == "-map"]
        if len(maps) > 1 or maps == ["0:s:1"]:
            return _DoneProcess(returncode=1)  # 坏轨 1 连累整趟
        for out in _outputs(argv):
            Path(out).write_text(_SRT, encoding="utf-8")
        return _DoneProcess()

    monkeypatch.setattr(media_extract.shutil, "which", lambda _n: "/fake/ffmpeg")
    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", fake_exec)

    file = make_multi_file(video, ["subrip", "subrip"])
    assert await media_extract.extract_track_async(file, 0) is not None
    assert len(calls) == 3  # 一趟多路失败 + 逐轨两趟
    assert media_extract.extraction_failed(file, 1) is True
    assert media_extract.extraction_failed(file, 0) is False
    assert not list((video.parent / "cache").glob("*.part*")), "失败留下了半成品"


def test_signalling_never_reaches_pid_one(monkeypatch) -> None:
    """glibc 的 killpg(1) 等于 kill(-1)：会杀光当前用户的所有进程。"""
    sent = []
    monkeypatch.setattr(media_extract.os, "killpg", lambda pid, sig: sent.append(pid))
    for pid in (None, 0, 1):
        media_extract._signal_process_group(pid, media_extract.signal.SIGTERM)
    media_extract._signal_process_group(4321, media_extract.signal.SIGTERM)
    assert sent == [4321]


# ---------------------------------------------------------------------------
# 读取进度与失败原因：AI 字幕任务据此告诉用户「排队中 / 读到哪 / 为什么失败」
# ---------------------------------------------------------------------------


def test_last_position_skips_placeholders(tmp_path: Path) -> None:
    progress = tmp_path / "read.progress"
    progress.write_text(
        "out_time_us=N/A\nprogress=continue\n"
        "out_time_us=1500000\nprogress=continue\n"
        "out_time_us=N/A\nprogress=continue\n",
        encoding="ascii",
    )
    assert media_extract._last_position(progress) == 1.5
    assert media_extract._last_position(tmp_path / "missing.progress") is None


def test_needs_extraction_only_when_there_is_something_to_read(video: Path) -> None:
    file = make_file(video)
    assert media_extract.needs_extraction(file, 0) is True
    _fresh_product(video, video.parent / "cache", "7.s0.srt")
    assert media_extract.needs_extraction(file, 0) is False  # 有缓存
    assert media_extract.needs_extraction(make_file(video, codec="dvd_subtitle"), 0) is False


@pytest.mark.asyncio
async def test_read_progress_follows_the_queue_then_the_position(
    tmp_path: Path, monkeypatch
) -> None:
    """排在别的文件后面时报「排队中」，轮到了报 ffmpeg 已处理到的时间点。"""
    monkeypatch.setattr(media_extract, "cache_dir", lambda: tmp_path / "cache")
    releases: dict[str, asyncio.Event] = {}

    class BlockingProcess(_DoneProcess):
        def __init__(self, key: str) -> None:
            super().__init__()
            self.key = key

        async def communicate(self):
            await releases[self.key].wait()
            return await super().communicate()

    async def fake_exec(*argv, **_kwargs):
        # 真 ffmpeg 会周期性往 -progress 文件里追加 out_time_us
        progress = Path(argv[list(argv).index("-progress") + 1])
        progress.write_text("out_time_us=1800000000\nprogress=continue\n", encoding="ascii")
        for out in _outputs(argv):
            Path(out).write_text(_SRT, encoding="utf-8")
        key = argv[list(argv).index("-i") + 1]
        releases.setdefault(key, asyncio.Event())
        return BlockingProcess(key)

    monkeypatch.setattr(media_extract.shutil, "which", lambda _n: "/fake/ffmpeg")
    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", fake_exec)

    first, second = tmp_path / "a.mkv", tmp_path / "b.mkv"
    for path in (first, second):
        path.write_bytes(b"source")
    file_a = make_multi_file(first, ["subrip"], file_id=201)
    file_b = make_multi_file(second, ["subrip"], file_id=202)

    task_a = asyncio.create_task(media_extract.extract_track_async(file_a, 0))
    for _ in range(200):
        progress_a = media_extract.read_progress(file_a)
        if progress_a is not None and progress_a.position_seconds is not None:
            break
        await asyncio.sleep(0.01)
    task_b = asyncio.create_task(media_extract.extract_track_async(file_b, 0))
    await asyncio.sleep(0.05)

    assert media_extract.read_progress(file_a) == media_extract.ReadProgress(
        queued=False, position_seconds=1800.0
    )
    assert media_extract.read_progress(file_b) == media_extract.ReadProgress(queued=True)

    releases[str(first)].set()
    assert await task_a is not None
    for _ in range(200):
        if str(second) in releases:
            break
        await asyncio.sleep(0.01)
    releases[str(second)].set()
    assert await task_b is not None

    assert media_extract.read_progress(file_a) is None
    assert media_extract.read_progress(file_b) is None
    assert not list((tmp_path / "cache").glob(".read-*.progress")), "进度文件没清掉"


@pytest.mark.asyncio
async def test_failure_reason_tells_timeout_from_ffmpeg_error(
    tmp_path: Path, monkeypatch
) -> None:
    """任务失败时直接告诉用户是读超时还是文件本身有问题，而不是「见服务端日志」。"""
    monkeypatch.setattr(media_extract, "cache_dir", lambda: tmp_path / "cache")
    monkeypatch.setattr(media_extract.shutil, "which", lambda _n: "/fake/ffmpeg")

    class HangingProcess(_DoneProcess):
        async def communicate(self):
            await asyncio.Event().wait()

    slow = tmp_path / "slow.mkv"
    slow.write_bytes(b"source")

    async def hanging_exec(*_argv, **_kwargs):
        return HangingProcess()

    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", hanging_exec)
    monkeypatch.setattr(media_extract, "_extract_timeout", lambda _v: 0.01)
    monkeypatch.setattr(media_extract, "_signal_process_group", lambda _pid, _sig: None)
    monkeypatch.setattr(media_extract, "_PROCESS_TERM_TIMEOUT", 0.01)
    monkeypatch.setattr(media_extract, "_PROCESS_KILL_TIMEOUT", 0.01)
    slow_file = make_multi_file(slow, ["subrip"], file_id=301)
    assert await media_extract.extract_track_async(slow_file, 0) is None
    assert "读取超时" in source_render(media_extract.failure_reason(slow_file, 0))

    broken = tmp_path / "broken.mkv"
    broken.write_bytes(b"source")

    async def failing_exec(*_argv, **_kwargs):
        return _DoneProcess(returncode=1)

    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", failing_exec)
    broken_file = make_multi_file(broken, ["subrip"], file_id=302)
    assert await media_extract.extract_track_async(broken_file, 0) is None
    reason = media_extract.failure_reason(broken_file, 0)
    assert source_render(reason) == "ffmpeg 报错：boom"
    with use_locale("en"):
        assert render_value(reason) == "ffmpeg error: boom"
    assert media_extract.needs_extraction(broken_file, 0) is False, "失败过就不再算「待读取」"

    # 换了片子（mtime 变了）就忘掉旧结论与原因，值得再读一次
    import os

    stat = broken.stat()
    os.utime(broken, ns=(stat.st_atime_ns, stat.st_mtime_ns + 10**9))
    assert media_extract.failure_reason(broken_file, 0) is None
    assert media_extract.needs_extraction(broken_file, 0) is True


# ---------------------------------------------------------------------------
# 原盘：file_path 是目录，按主播放列表的各段读（docs/design/disc-playback.md §8）
# ---------------------------------------------------------------------------

_CLOCK = 45_000


def make_disc_file(disc: Path, clips: list[tuple[str, int, int]], codecs: list[str]) -> LibraryFile:
    """一行原盘台账 + 盘上的 m2ts：剪辑清单是（id, IN 秒, OUT 秒）。"""
    stream_dir = disc / "BDMV" / "STREAM"
    stream_dir.mkdir(parents=True)
    for clip_id, _, _ in clips:
        (stream_dir / f"{clip_id}.m2ts").write_bytes(b"m2ts")
    file = make_multi_file(disc, codecs)
    file.container = "bluray"
    file.disc_playlist = {
        "version": DISC_PLAYLIST_VERSION,
        "name": "00001.mpls",
        "clips": [
            {"id": clip_id, "in": start * _CLOCK, "out": end * _CLOCK}
            for clip_id, start, end in clips
        ],
    }
    return file


@pytest.fixture
def disc_cache(tmp_path: Path, monkeypatch) -> Path:
    cache = tmp_path / "cache"
    monkeypatch.setattr(media_extract, "cache_dir", lambda: cache)
    monkeypatch.setattr(media_extract.shutil, "which", lambda _n: "/fake/ffmpeg")
    return cache


def _capture_exec(monkeypatch, *, body: str = "PG") -> list[dict]:
    """假 ffmpeg：写出产物，并把启动那一刻的命令行与 concat 清单内容记下来。"""
    calls: list[dict] = []

    async def fake_exec(*argv, **_kwargs):
        listing = argv[argv.index("-i") + 1]
        calls.append({"argv": argv, "listing": Path(listing).read_text(encoding="utf-8")})
        for out in _outputs(argv):
            Path(out).write_text(body, encoding="utf-8")
        return _DoneProcess()

    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", fake_exec)
    return calls


@pytest.mark.asyncio
async def test_disc_track_is_read_through_the_main_playlist(
    tmp_path: Path, disc_cache: Path, monkeypatch
) -> None:
    """目录交给 ffmpeg 必然失败：要读主播放列表的各段，只读 IN/OUT 之内，一趟抽出全部轨。"""
    calls = _capture_exec(monkeypatch)
    disc = tmp_path / "盘's"
    file = make_disc_file(
        disc,
        [("00001", 100, 120), ("00002", 505, 525)],
        ["hdmv_pgs_subtitle", "hdmv_pgs_subtitle"],
    )

    track = await media_extract.extract_track_async(file, 1)

    assert track is not None and track.format == "sup"
    assert len(calls) == 1, "原盘也只该通读一遍"
    argv, listing = calls[0]["argv"], calls[0]["listing"]
    assert argv[argv.index("-f") + 1] == "concat"
    assert argv[argv.index("-safe") + 1] == "0"
    assert str(disc) not in argv, "目录不能当输入"
    assert argv.count("-map") == 2 and "0:s:0" in argv and "0:s:1" in argv
    escaped = str(disc).replace("'", "'\\''")
    assert f"file '{escaped}/BDMV/STREAM/00001.m2ts'" in listing
    assert f"file '{escaped}/BDMV/STREAM/00002.m2ts'" in listing
    assert "inpoint 505.000000" in listing and "outpoint 525.000000" in listing
    assert "duration 20.000000" in listing
    assert media_extract.cached_track(file, 0) is not None
    # 进度文件与清单都只活这一趟
    assert [p.name for p in disc_cache.glob(".read-*")] == []


@pytest.mark.asyncio
async def test_disc_does_not_try_the_matroska_cue_path(
    tmp_path: Path, disc_cache: Path, monkeypatch
) -> None:
    """光盘没有字幕索引：按索引读会对着目录报错，还多绕一趟线程。"""

    async def must_not_run(_pending) -> bool:
        raise AssertionError("原盘不该走按字幕索引读取")

    monkeypatch.setattr(media_extract, "_run_sparse_extraction", must_not_run)
    _capture_exec(monkeypatch)
    file = make_disc_file(tmp_path / "disc", [("00001", 0, 60)], ["hdmv_pgs_subtitle"])
    assert await media_extract.extract_track_async(file, 0) is not None


@pytest.mark.asyncio
async def test_disc_with_a_missing_clip_starts_nothing_and_stays_retryable(
    tmp_path: Path, disc_cache: Path, monkeypatch
) -> None:
    """挂载卸了、盘还没拷完：不起 ffmpeg，也不记失败——片子回来了要能接着抽。"""
    calls = _capture_exec(monkeypatch)
    disc = tmp_path / "disc"
    file = make_disc_file(disc, [("00001", 0, 60), ("00002", 0, 60)], ["hdmv_pgs_subtitle"])
    second = disc / "BDMV" / "STREAM" / "00002.m2ts"
    second.unlink()

    assert await media_extract.extract_track_async(file, 0) is None
    assert calls == []
    assert media_extract.extraction_failed(file, 0) is False

    second.write_bytes(b"m2ts")
    assert await media_extract.extract_track_async(file, 0) is not None
    assert len(calls) == 1


@pytest.mark.asyncio
async def test_disc_failure_is_remembered_like_any_other_file(
    tmp_path: Path, disc_cache: Path, monkeypatch
) -> None:
    """通读一张盘要几分钟，读不出来就记住，别每次打开播放器再读一遍。"""
    starts = 0

    async def fake_exec(*_argv, **_kwargs):
        nonlocal starts
        starts += 1
        return _DoneProcess(returncode=1)

    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", fake_exec)
    file = make_disc_file(tmp_path / "disc", [("00001", 0, 60)], ["hdmv_pgs_subtitle"])

    assert await media_extract.extract_track_async(file, 0) is None
    assert await media_extract.extract_track_async(file, 0) is None
    assert starts == 1
    assert media_extract.extraction_failed(file, 0) is True


@pytest.mark.asyncio
async def test_disc_without_a_playable_source_has_nothing_to_extract(
    tmp_path: Path, disc_cache: Path, monkeypatch
) -> None:
    """读不出盘内结构的镜像：对着整个镜像跑 ffmpeg 认不出流，白读一遍。"""
    calls = _capture_exec(monkeypatch)
    image = tmp_path / "broken.iso"
    image.write_bytes(b"not an image")
    file = make_multi_file(image, ["hdmv_pgs_subtitle"])
    file.container = "iso"

    assert await media_extract.extract_track_async(file, 0) is None
    assert media_extract.schedule_extraction(file, 0) is False
    assert calls == []


@pytest.mark.asyncio
async def test_bluray_image_reads_the_clips_inside_the_image(
    tmp_path: Path, disc_cache: Path, monkeypatch
) -> None:
    """蓝光镜像的台账也有 PGS 轨（探测读的是盘内主片）：清单里是镜像上的 subfile 区间。"""
    calls = _capture_exec(monkeypatch)
    image = tmp_path / "movie.iso"
    image.write_bytes(b"image")
    source = DiscSource(
        disc_dir=image,
        playlist_name="00800.mpls",
        clips=(DiscClip("00001", image, 0, 60 * _CLOCK, byte_ranges=((2048, 4096),)),),
        image="bluray",
    )
    monkeypatch.setattr(iso_source, "iso_disc_source", lambda _path: source)
    file = make_multi_file(image, ["hdmv_pgs_subtitle"])
    file.container = "iso"

    assert await media_extract.extract_track_async(file, 0) is not None
    argv, listing = calls[0]["argv"], calls[0]["listing"]
    assert argv[argv.index("-protocol_whitelist") + 1] == "file,subfile,concat"
    assert f"file 'subfile,,start,2048,end,4096,,:{image}'" in listing


def test_disc_timeout_counts_the_clips_not_the_directory(tmp_path: Path) -> None:
    """目录自己只有几 KB，按它估就是固定 120 秒，读不完任何一张盘，超时还会被记成失败。"""

    def spec(*sizes: int) -> media_extract._ExtractionSpec:
        image = tmp_path / "disc.iso"
        clips = tuple(
            DiscClip(f"{i:05d}", image, 0, _CLOCK, byte_ranges=((0, size),))
            for i, size in enumerate(sizes)
        )
        return media_extract._ExtractionSpec(
            fmt="sup",
            video=tmp_path,
            out_path=tmp_path / "x.sup",
            disc=DiscSource(disc_dir=tmp_path, playlist_name="1.mpls", clips=clips),
        )

    gib = 1024**3
    assert media_extract._spec_timeout(spec(1024)) == media_extract.EXTRACT_TIMEOUT
    # 两段各 20 GB：按 20 MB/s 估 2048 秒，只算一段或只看目录都不够
    assert media_extract._spec_timeout(spec(20 * gib, 20 * gib)) == pytest.approx(2048)
    assert media_extract._spec_timeout(spec(200 * gib)) == media_extract._MAX_EXTRACT_TIMEOUT


def test_disc_clip_size_reads_the_file(tmp_path: Path) -> None:
    clip = tmp_path / "00001.m2ts"
    clip.write_bytes(b"x" * 188)
    assert DiscClip("00001", clip, 0, 1).size_bytes == 188
    assert DiscClip("00002", tmp_path / "gone.m2ts", 0, 1).size_bytes == 0


def test_open_pgs_at_a_clip_boundary_gets_an_empty_display_set() -> None:
    """清屏包在 OUT 之后：切点上还显示着的字幕要补一个 0 对象的合成段。"""
    from disc_fixture import sup_events
    from pgs_sup import make_sup

    raw = make_sup(start_s=5, end_s=8) + make_sup(start_s=14, end_s=16)
    closed = media_extract._close_trimmed_pgs(raw, [6 * 90_000, 20 * 90_000])

    assert sup_events(closed) == [(5.0, 1), (6.0, 0), (8.0, 0), (14.0, 1), (16.0, 0)]
    # 再走一遍不能再补一个：边界上已经有清屏
    assert media_extract._close_trimmed_pgs(closed, [6 * 90_000, 20 * 90_000]) == closed


def test_pgs_already_clear_at_the_boundary_is_left_alone() -> None:
    from disc_fixture import sup_events
    from pgs_sup import make_sup

    inside = make_sup(start_s=1, end_s=2)
    exact = make_sup(start_s=1, end_s=6)
    boundary = [6 * 90_000]
    assert media_extract._close_trimmed_pgs(inside, boundary) is inside
    assert media_extract._close_trimmed_pgs(exact, boundary) is exact
    assert media_extract._close_trimmed_pgs(b"not a sup", boundary) == b"not a sup"

    still_up = make_sup(start_s=5, end_s=30)
    assert sup_events(media_extract._close_trimmed_pgs(still_up, [20 * 90_000])) == [
        (5.0, 1),
        (20.0, 0),
        (30.0, 0),
    ]


@pytest.mark.asyncio
async def test_disc_extraction_closes_pgs_at_the_playlist_trim(
    tmp_path: Path, disc_cache: Path, monkeypatch
) -> None:
    """假 ffmpeg 交出的是裁完的流：钩子按播放列表的切点补清屏，不按盘根。"""
    from disc_fixture import sup_events
    from pgs_sup import make_sup

    async def fake_exec(*argv, **_kwargs):
        for out in _outputs(argv):
            Path(out).write_bytes(make_sup(start_s=5, end_s=8))
        return _DoneProcess()

    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", fake_exec)
    file = make_disc_file(
        tmp_path / "disc", [("00001", 0, 6), ("00002", 0, 10)], ["hdmv_pgs_subtitle"]
    )

    track = await media_extract.extract_track_async(file, 0)

    assert track is not None
    # 6 秒是第一段的 OUT；8 秒的原清屏还在。第二段结束于 16 秒，那时画面已经清了。
    assert sup_events(track.path.read_bytes()) == [(5.0, 1), (6.0, 0), (8.0, 0)]


def test_directory_disc_stamp_follows_clips_and_playlist_not_the_root(tmp_path: Path) -> None:
    """替换深层剪辑、改 IN/OUT，指纹都要变；只动盘根目录则不变。"""
    import os

    disc = tmp_path / "disc"
    file = make_disc_file(disc, [("00001", 0, 60), ("00002", 0, 60)], ["hdmv_pgs_subtitle"])
    clip = disc / "BDMV" / "STREAM" / "00001.m2ts"
    spec = media_extract._lookup_spec(file, 0)
    assert spec is not None and spec.disc is not None
    original = media_extract._source_stamp(spec)

    os.utime(disc, ns=(disc.stat().st_mtime_ns + 10**9,) * 2)
    assert media_extract._source_stamp(spec) == original

    stat = clip.stat()
    clip.write_bytes(b"m2ts-replaced")
    os.utime(clip, ns=(stat.st_atime_ns, stat.st_mtime_ns))
    assert media_extract._source_stamp(spec) != original

    os.utime(clip, ns=(stat.st_atime_ns, stat.st_mtime_ns))
    clip.write_bytes(b"m2ts")
    os.utime(clip, ns=(stat.st_atime_ns, stat.st_mtime_ns))
    assert media_extract._source_stamp(spec) == original

    playlist = file.disc_playlist
    assert isinstance(playlist, dict)
    clips = [dict(item) for item in playlist["clips"]]
    clips[0]["out"] = 30 * _CLOCK
    file.disc_playlist = {**playlist, "clips": clips}
    shifted = media_extract._lookup_spec(file, 0)
    assert shifted is not None
    assert media_extract._source_stamp(shifted) != original


@pytest.mark.asyncio
async def test_disc_cache_and_failure_share_the_clip_stamp(
    tmp_path: Path, disc_cache: Path, monkeypatch
) -> None:
    """成功缓存认剪辑指纹：剪辑变了重抽，只把盘根目录改新则留着。"""
    import os

    calls = _capture_exec(monkeypatch)
    disc = tmp_path / "disc"
    file = make_disc_file(disc, [("00001", 0, 60), ("00002", 0, 60)], ["hdmv_pgs_subtitle"])
    clip = disc / "BDMV" / "STREAM" / "00001.m2ts"
    root_ns = disc.stat().st_mtime_ns

    assert await media_extract.extract_track_async(file, 0) is not None
    assert len(calls) == 1
    sidecar = disc_cache / "7.s0.sup.src"
    spec = media_extract._lookup_spec(file, 0)
    assert spec is not None
    assert sidecar.read_text(encoding="ascii").strip() == str(media_extract._source_stamp(spec))

    cached = media_extract.cached_track(file, 0)
    assert cached is not None
    # 根目录比产物还新：旧逻辑按 mtime 会判失效。剪辑没变，缓存得留着。
    os.utime(disc, ns=(cached.path.stat().st_mtime_ns + 10**9,) * 2)
    assert media_extract.cached_track(file, 0) is not None
    assert await media_extract.extract_track_async(file, 0) is not None
    assert len(calls) == 1, "盘根目录更新不该让字幕缓存失效"

    os.utime(clip, ns=(clip.stat().st_mtime_ns + 10**9,) * 2)
    os.utime(disc, ns=(root_ns,) * 2)
    assert media_extract.cached_track(file, 0) is None
    assert await media_extract.extract_track_async(file, 0) is not None
    assert len(calls) == 2


@pytest.mark.asyncio
async def test_disc_failure_clears_when_a_clip_changes_not_when_the_root_does(
    tmp_path: Path, disc_cache: Path, monkeypatch
) -> None:
    import os

    starts = 0

    async def fake_exec(*_argv, **_kwargs):
        nonlocal starts
        starts += 1
        return _DoneProcess(returncode=1)

    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", fake_exec)
    disc = tmp_path / "disc"
    file = make_disc_file(disc, [("00001", 0, 60)], ["hdmv_pgs_subtitle"])
    clip = disc / "BDMV" / "STREAM" / "00001.m2ts"

    assert await media_extract.extract_track_async(file, 0) is None
    assert media_extract.extraction_failed(file, 0) is True
    assert await media_extract.extract_track_async(file, 0) is None
    assert starts == 1

    os.utime(disc, ns=(disc.stat().st_mtime_ns + 10**9,) * 2)
    assert media_extract.extraction_failed(file, 0) is True
    assert await media_extract.extract_track_async(file, 0) is None
    assert starts == 1, "盘根目录更新不该让失败结论作废"

    os.utime(clip, ns=(clip.stat().st_mtime_ns + 10**9,) * 2)
    assert media_extract.extraction_failed(file, 0) is False
    assert media_extract.needs_extraction(file, 0) is True
    assert await media_extract.extract_track_async(file, 0) is None
    assert starts == 2

    playlist = file.disc_playlist
    assert isinstance(playlist, dict)
    clips = [dict(item) for item in playlist["clips"]]
    clips[0]["out"] = 30 * _CLOCK
    file.disc_playlist = {**playlist, "clips": clips}
    assert media_extract.extraction_failed(file, 0) is False
    assert await media_extract.extract_track_async(file, 0) is None
    assert starts == 3


@pytest.mark.asyncio
async def test_bluray_image_cache_follows_the_image_file(
    tmp_path: Path, disc_cache: Path, monkeypatch
) -> None:
    """ISO 的指纹仍是镜像文件本身，不另写一份播放列表指纹。"""
    import os

    calls = _capture_exec(monkeypatch)
    image = tmp_path / "movie.iso"
    image.write_bytes(b"image")
    # 产物和镜像落在同一个时间戳上时，按 mtime 会把刚抽完的结果判失效。先把镜像拨回过去。
    os.utime(image, ns=(1_000_000_000_000_000_000,) * 2)
    source = DiscSource(
        disc_dir=image,
        playlist_name="00800.mpls",
        clips=(DiscClip("00001", image, 0, 60 * _CLOCK, byte_ranges=((0, 4),)),),
        image="bluray",
    )
    monkeypatch.setattr(iso_source, "iso_disc_source", lambda _path: source)
    file = make_multi_file(image, ["hdmv_pgs_subtitle"])
    file.container = "iso"

    assert await media_extract.extract_track_async(file, 0) is not None
    assert list(disc_cache.glob("*.src")) == []
    cached = media_extract.cached_track(file, 0)
    assert cached is not None
    assert len(calls) == 1
    spec = media_extract._ExtractionSpec(fmt="sup", video=image, out_path=cached.path, disc=source)
    assert media_extract._source_stamp(spec) == image.stat().st_mtime_ns

    os.utime(image, ns=(cached.path.stat().st_mtime_ns + 10**9,) * 2)
    assert media_extract.cached_track(file, 0) is None
    assert media_extract._source_stamp(spec) == image.stat().st_mtime_ns



# ---------------------------------------------------------------------------
# 等待者都走了也不当场取消：通读比一个请求活得久（Safari 60 秒、反代 60～100 秒）
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_a_returning_waiter_picks_up_the_same_read(video: Path, monkeypatch) -> None:
    """浏览器或反代掐断请求后，播放器接着再问：还是那一趟 ffmpeg，进度不丢。"""
    starts = 0
    terminated = []
    release = asyncio.Event()

    class SlowProcess(_DoneProcess):
        async def communicate(self):
            await release.wait()
            return await super().communicate()

    async def fake_exec(*argv, **_kwargs):
        nonlocal starts
        starts += 1
        for out in _outputs(argv):
            Path(out).write_text(_SRT, encoding="utf-8")
        return SlowProcess()

    monkeypatch.setattr(media_extract.shutil, "which", lambda _n: "/fake/ffmpeg")
    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", fake_exec)
    monkeypatch.setattr(media_extract, "_signal_process_group", lambda *_a: terminated.append(_a))
    monkeypatch.setattr(media_extract, "_ABANDON_GRACE_SECONDS", 0.05)

    file = make_multi_file(video, ["hdmv_pgs_subtitle"])
    first = asyncio.create_task(media_extract.extract_track_async(file, 0))
    while starts == 0:
        await asyncio.sleep(0)
    first.cancel()
    with pytest.raises(asyncio.CancelledError):
        await first
    timer = media_extract._EXTRACTION_JOBS[str(video)].abandon_timer
    assert timer is not None

    second = asyncio.create_task(media_extract.extract_track_async(file, 0))
    await asyncio.sleep(0)
    # 定时要撤掉，不能只在到点时看「此刻有没有人」：下一个请求的间隙里到点，读取一样被杀
    assert timer.cancelled()
    await asyncio.sleep(0.1)  # 宽限早过了：第二个等待者在，不算没人要
    assert terminated == [], "还有人在等，通读却被取消了"

    release.set()
    assert (await second) is not None
    assert starts == 1, f"接着等的请求又从头读了一遍（起了 {starts} 个 ffmpeg）"


@pytest.mark.asyncio
async def test_nobody_returning_cancels_the_read_after_the_grace(video: Path, monkeypatch) -> None:
    """用户真的走了：一张盘几十 GB 不能白读完。宽限期过后回收进程和临时文件。"""
    killed = asyncio.Event()
    started = asyncio.Event()

    class HangingProcess(_DoneProcess):
        pid = 4321

        async def communicate(self):
            started.set()
            await killed.wait()
            return await super().communicate()

    async def fake_exec(*argv, **_kwargs):
        for out in _outputs(argv):
            Path(out).write_text(_SRT, encoding="utf-8")
        return HangingProcess()

    monkeypatch.setattr(media_extract.shutil, "which", lambda _n: "/fake/ffmpeg")
    monkeypatch.setattr(media_extract.asyncio, "create_subprocess_exec", fake_exec)
    monkeypatch.setattr(media_extract, "_signal_process_group", lambda *_a: killed.set())
    monkeypatch.setattr(media_extract, "_ABANDON_GRACE_SECONDS", 0.5)

    file = make_multi_file(video, ["hdmv_pgs_subtitle"])
    waiter = asyncio.create_task(media_extract.extract_track_async(file, 0))
    await started.wait()
    waiter.cancel()
    with pytest.raises(asyncio.CancelledError):
        await waiter
    assert not killed.is_set(), "最后一个等待者一走就取消了，没有宽限"

    await asyncio.wait_for(killed.wait(), timeout=10)
    # 让 ffmpeg 协程跑完收尾：不留半成品，也不记失败（下次打开要能重新读）
    while media_extract._EXTRACTION_JOBS:
        await asyncio.sleep(0.01)
    assert list((video.parent / "cache").glob("*.part*")) == []
    assert media_extract.extraction_failed(file, 0) is False

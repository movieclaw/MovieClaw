"""库封面拼贴的并发去重回归测试。"""

from __future__ import annotations

import asyncio
from pathlib import Path

import pytest

from movieclaw_api.services.library import cover

#: 库内容版本（替代 library.stats_refreshed_at）；用例改它模拟「库内容变了」
CONTENT = {"version": 1}


@pytest.fixture(autouse=True)
def _content_version(monkeypatch: pytest.MonkeyPatch) -> None:
    """这些用例不建库：内容版本由 CONTENT 给，不查数据库。"""
    CONTENT["version"] = 1

    async def version(_library_id: int) -> object:
        return CONTENT["version"]

    monkeypatch.setattr(cover, "library_content_version", version)


async def test_concurrent_cover_requests_share_selection_and_render(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """同一库的并发请求只能执行一次素材选择和拼贴渲染。"""
    selected = 0
    rendered = 0
    selecting = asyncio.Event()
    release = asyncio.Event()
    poster = tmp_path / "poster.jpg"
    poster.write_bytes(b"poster")

    async def select_once(_library_id: int, cutoff=None) -> list[Path]:
        nonlocal selected
        selected += 1
        selecting.set()
        await release.wait()
        return [poster]

    def render_once(_posters: list[Path], output: Path) -> None:
        nonlocal rendered
        rendered += 1
        output.write_bytes(b"cover")

    monkeypatch.setattr(cover, "select_cover_posters", select_once)
    monkeypatch.setattr(cover, "_cover_key", lambda _paths: "cover-key")
    monkeypatch.setattr(cover, "covers_dir", lambda: tmp_path / "covers")
    monkeypatch.setattr(cover, "render_shelf_collage", render_once)

    tasks = [asyncio.create_task(cover.ensure_library_cover(42)) for _ in range(5)]
    await asyncio.wait_for(selecting.wait(), timeout=1)
    assert selected == 1
    release.set()

    results = await asyncio.gather(*tasks)
    assert results == [(tmp_path / "covers" / "42-cover-key.jpg", "cover-key")] * 5
    assert rendered == 1
    await asyncio.sleep(0)
    assert 42 not in cover._cover_tasks


async def test_no_poster_result_does_not_leave_cover_task(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """无可用海报时任务会清理，之后的调用能够重新选择素材。"""
    selected = 0

    async def no_posters(_library_id: int, cutoff=None) -> list[Path]:
        nonlocal selected
        selected += 1
        return []

    monkeypatch.setattr(cover, "select_cover_posters", no_posters)

    assert await cover.ensure_library_cover(43) is None
    await asyncio.sleep(0)
    assert 43 not in cover._cover_tasks
    assert await cover.ensure_library_cover(43) is None
    assert selected == 2


async def test_selection_error_does_not_leave_cover_task(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """选择素材异常仍会回收任务，避免该库后续请求永久复用失败任务。"""
    calls = 0

    async def fail_selection(_library_id: int, cutoff=None) -> list[Path]:
        nonlocal calls
        calls += 1
        raise RuntimeError("database unavailable")

    monkeypatch.setattr(cover, "select_cover_posters", fail_selection)

    with pytest.raises(RuntimeError, match="database unavailable"):
        await cover.ensure_library_cover(44)
    await asyncio.sleep(0)
    assert 44 not in cover._cover_tasks

    with pytest.raises(RuntimeError, match="database unavailable"):
        await cover.ensure_library_cover(44)
    assert calls == 2


# ---------------------------------------------------------------------------
# 自定义封面（issue #427）：上传图归一化、优先级与回落
# ---------------------------------------------------------------------------


def _png(width: int, height: int, *, alpha: bool = False) -> bytes:
    """造一张噪声图——纯色图压出来只有几百字节，压不出体积差异。"""
    import random
    from io import BytesIO

    from PIL import Image

    rng = random.Random(7)
    mode = "RGBA" if alpha else "RGB"
    img = Image.new(mode, (width, height))
    img.putdata(
        [
            (rng.randrange(256), rng.randrange(256), rng.randrange(256))
            + ((rng.randrange(256),) if alpha else ())
            for _ in range(width * height)
        ]
    )
    buffer = BytesIO()
    img.save(buffer, "PNG")
    return buffer.getvalue()


def test_normalize_shrinks_long_edge_and_outputs_jpeg() -> None:
    """超大图被压到长边 1600、输出 JPEG，且体积显著变小。"""
    from io import BytesIO

    from PIL import Image

    source = _png(2400, 1200)
    out = cover.normalize_cover_image(source)

    img = Image.open(BytesIO(out))
    assert img.format == "JPEG"
    assert max(img.size) == cover.CUSTOM_MAX_EDGE
    # 不裁剪：比例原样保留（2:1）
    assert img.size == (1600, 800)
    assert len(out) < len(source)


def test_normalize_keeps_small_image_unscaled() -> None:
    """小图只重编码不放大——放大只会糊，且白占体积。"""
    from io import BytesIO

    from PIL import Image

    out = cover.normalize_cover_image(_png(640, 360))
    assert Image.open(BytesIO(out)).size == (640, 360)


def test_normalize_flattens_alpha() -> None:
    """带透明通道的 PNG 能落成 JPEG（JPEG 没有 alpha，必须先填底）。"""
    from io import BytesIO

    from PIL import Image

    img = Image.open(BytesIO(cover.normalize_cover_image(_png(320, 200, alpha=True))))
    assert img.format == "JPEG"
    assert img.mode == "RGB"


def test_normalize_rejects_non_image() -> None:
    """不是图片的文件给出中文提示，而不是抛 500。"""
    with pytest.raises(ValueError, match="无法识别"):
        cover.normalize_cover_image(b"<svg xmlns='http://www.w3.org/2000/svg'/>")


def test_normalize_rejects_pixel_bomb(monkeypatch: pytest.MonkeyPatch) -> None:
    """像素数超限在解码前就被拒，不给解压炸弹撑爆内存的机会。"""
    monkeypatch.setattr(cover, "MAX_UPLOAD_PIXELS", 1000)
    with pytest.raises(ValueError, match="尺寸过大"):
        cover.normalize_cover_image(_png(200, 200))


async def test_custom_cover_takes_priority_and_falls_back(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """有自定义封面时不碰拼贴；删掉后自动回落到拼贴。"""
    selected = 0

    async def select_once(_library_id: int, cutoff=None) -> list[Path]:
        nonlocal selected
        selected += 1
        poster = tmp_path / "poster.jpg"
        poster.write_bytes(b"poster")
        return [poster]

    monkeypatch.setattr(cover, "select_cover_posters", select_once)
    monkeypatch.setattr(cover, "_cover_key", lambda _paths: "collage-key")
    monkeypatch.setattr(cover, "covers_dir", lambda: tmp_path / "covers")
    monkeypatch.setattr(cover, "render_shelf_collage", lambda _p, out: out.write_bytes(b"c"))
    monkeypatch.setattr(cover, "custom_covers_dir", lambda: tmp_path / "custom")

    version = cover.save_custom_cover(51, cover.normalize_cover_image(_png(300, 200)))
    assert cover.has_custom_cover(51)

    path, key = await cover.ensure_library_cover(51)  # type: ignore[misc]
    assert path == cover.custom_cover_path(51)
    assert key == version
    assert selected == 0  # 连候选素材都没扫

    assert cover.remove_custom_cover(51) is True
    assert cover.remove_custom_cover(51) is False
    result = await cover.ensure_library_cover(51)
    assert result is not None and result[1] == "collage-key"
    assert selected == 1


def test_save_custom_cover_drops_stale_collage(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """设了自定义封面后，该库的拼贴产物再没人读，顺手清掉。"""
    collages = tmp_path / "covers"
    collages.mkdir()
    (collages / "52-old.jpg").write_bytes(b"stale")
    (collages / "53-other.jpg").write_bytes(b"keep")
    monkeypatch.setattr(cover, "covers_dir", lambda: collages)
    monkeypatch.setattr(cover, "custom_covers_dir", lambda: tmp_path / "custom")

    cover.save_custom_cover(52, cover.normalize_cover_image(_png(120, 80)))
    assert not (collages / "52-old.jpg").exists()
    assert (collages / "53-other.jpg").exists()  # 别的库的不许碰


# ---------------------------------------------------------------------------
# 一天最多换一次图：按天登记、先给旧图后台重渲、素材以零点为界
# ---------------------------------------------------------------------------


class _Clock:
    """可拨的钟（带时区），替换 cover._now。"""

    def __init__(self) -> None:
        from datetime import datetime
        from zoneinfo import ZoneInfo

        self.now = datetime(2026, 10, 5, 15, 0, tzinfo=ZoneInfo("Asia/Shanghai"))

    def __call__(self):  # type: ignore[no-untyped-def]
        return self.now

    def next_day(self) -> None:
        from datetime import timedelta

        self.now += timedelta(days=1)


def _fake_collage(tmp_path: Path, monkeypatch: pytest.MonkeyPatch, picks: list[list[Path]]):
    """打桩选素材/渲染：每次选素材按 picks 依次给；返回计数器。"""
    calls = {"select": 0, "render": 0}
    gate = asyncio.Event()
    gate.set()

    async def select(_library_id: int, cutoff=None) -> list[Path]:
        calls["select"] += 1
        return picks[min(calls["select"], len(picks)) - 1]

    def render(_posters: list[Path], out: Path) -> None:
        calls["render"] += 1
        out.write_bytes(b"cover")

    monkeypatch.setattr(cover, "select_cover_posters", select)
    monkeypatch.setattr(cover, "_cover_key", lambda paths: "-".join(p.stem for p in paths))
    monkeypatch.setattr(cover, "covers_dir", lambda: tmp_path / "covers")
    monkeypatch.setattr(cover, "render_shelf_collage", render)
    return calls


def _posters(tmp_path: Path, *names: str) -> list[Path]:
    out = []
    for name in names:
        p = tmp_path / f"{name}.jpg"
        p.write_bytes(name.encode())
        out.append(p)
    return out


async def _settle() -> None:
    """让后台刷新任务跑完（渲染走线程池，多让几轮）。"""
    for _ in range(50):
        if not cover._cover_tasks and not cover._render_tasks:
            return
        await asyncio.sleep(0.01)


async def test_same_day_requests_skip_selection(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """当天登记过就不再选素材、不再渲染：请求只剩一次字典查找。"""
    monkeypatch.setattr(cover, "_now", _Clock())
    calls = _fake_collage(tmp_path, monkeypatch, [_posters(tmp_path, "a", "b", "c", "d")])

    first = await cover.ensure_library_cover(60)
    for _ in range(5):
        assert await cover.ensure_library_cover(60) == first
    assert calls == {"select": 1, "render": 1}


async def test_next_day_serves_old_cover_while_rendering(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """过了零点：先给昨天的图（请求不等渲染），后台渲完后换新图、删旧图。"""
    clock = _Clock()
    monkeypatch.setattr(cover, "_now", clock)
    old_set = _posters(tmp_path, "a", "b", "c", "d")
    new_set = _posters(tmp_path, "e", "b", "c", "d")
    calls = _fake_collage(tmp_path, monkeypatch, [old_set, new_set])

    old = await cover.ensure_library_cover(61)
    assert old is not None
    clock.next_day()
    assert await cover.ensure_library_cover(61) == old  # 没等渲染
    await _settle()
    new = await cover.ensure_library_cover(61)
    assert new is not None and new != old
    assert new[1] == "e-b-c-d"
    assert not old[0].exists()
    assert calls == {"select": 2, "render": 2}


async def test_unchanged_selection_next_day_does_not_rerender(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """过了零点素材没变：只重选一次，不重渲。"""
    clock = _Clock()
    monkeypatch.setattr(cover, "_now", clock)
    calls = _fake_collage(tmp_path, monkeypatch, [_posters(tmp_path, "a", "b", "c", "d")])

    first = await cover.ensure_library_cover(62)
    clock.next_day()
    await cover.ensure_library_cover(62)
    await _settle()
    assert await cover.ensure_library_cover(62) == first
    assert calls == {"select": 2, "render": 1}


async def test_restart_serves_collage_on_disk_first(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """进程重启后内存登记没了：盘上有上一版就先给，后台再核对。"""
    monkeypatch.setattr(cover, "_now", _Clock())
    calls = _fake_collage(tmp_path, monkeypatch, [_posters(tmp_path, "a", "b", "c", "d")])
    covers = tmp_path / "covers"
    covers.mkdir()
    (covers / "63-previous.jpg").write_bytes(b"old")

    assert await cover.ensure_library_cover(63) == (covers / "63-previous.jpg", "previous")
    await _settle()
    assert await cover.ensure_library_cover(63) == (covers / "63-a-b-c-d.jpg", "a-b-c-d")
    assert not (covers / "63-previous.jpg").exists()
    assert calls["render"] == 1


async def test_render_failure_keeps_old_cover_for_the_day(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """重渲失败：接着用上一版到明天，不让每个请求都重试一次渲染。"""
    clock = _Clock()
    monkeypatch.setattr(cover, "_now", clock)
    calls = _fake_collage(
        tmp_path,
        monkeypatch,
        [_posters(tmp_path, "a", "b", "c", "d"), _posters(tmp_path, "e", "b", "c", "d")],
    )
    old = await cover.ensure_library_cover(64)

    def broken(_posters: list[Path], _out: Path) -> None:
        calls["render"] += 1
        raise OSError("坏图")

    monkeypatch.setattr(cover, "render_shelf_collage", broken)
    clock.next_day()
    for _ in range(3):
        assert await cover.ensure_library_cover(64) == old
        await _settle()
    assert calls["render"] == 2  # 首次 1 次 + 失败 1 次，没有反复重试


async def test_partial_shelf_updates_immediately(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """空库、不满一架的新库不冻结：新片入库后的**第一次请求**就是新封面，不等到明天，
    也不先给旧图（客户端缓存了旧 tag，新片就迟迟上不了封面）。"""
    monkeypatch.setattr(cover, "_now", _Clock())
    calls = _fake_collage(
        tmp_path,
        monkeypatch,
        [
            [],  # 空库：还没有封面
            _posters(tmp_path, "a"),
            _posters(tmp_path, "b", "a"),
            _posters(tmp_path, "c", "b", "a"),
            _posters(tmp_path, "d", "c", "b", "a"),  # 满一架
            _posters(tmp_path, "e", "d", "c", "b"),  # 满了之后当天再进片：不再重选
        ],
    )
    assert await cover.ensure_library_cover(66) is None
    for expected in ("a", "b-a", "c-b-a", "d-c-b-a"):
        result = await cover.ensure_library_cover(66)
        assert result is not None and result[1] == expected
    full = result
    for _ in range(3):
        assert await cover.ensure_library_cover(66) == full
    assert calls["select"] == 5  # 满一架之后当天不再选素材
    assert sorted(p.name for p in (tmp_path / "covers").iterdir()) == ["66-d-c-b-a.jpg"]


async def test_selection_prefers_items_added_before_today(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """真实 SQLite：今天零点前入库的优先、今天入库的只补位；同一入库时间按 id 定序。"""
    from datetime import datetime

    from movieclaw_api.core.config import get_settings
    from movieclaw_db.engine import dispose_db, get_database, init_db
    from movieclaw_db.migrations import run_migrations
    from movieclaw_db.models import FileSource, Library, LibraryFile, MediaItem, MediaMetadata

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'cover.db'}")
    monkeypatch.setenv("METADATA_DIR", str(tmp_path / "metadata"))
    get_settings.cache_clear()
    monkeypatch.setattr(cover, "_now", _Clock())  # 2026-10-05 15:00 上海 → 零点 = 10-04 16:00 UTC
    init_db(get_settings().database_url, echo=False)
    await run_migrations()

    # (名字, 入库时间 naive UTC)：old* 在零点前，today* 在零点后；tie_lo/tie_hi 同一时刻
    seeds = [
        ("old1", datetime(2026, 10, 4, 10)),
        ("today1", datetime(2026, 10, 5, 1)),
        ("tie_lo", datetime(2026, 10, 3, 8)),
        ("tie_hi", datetime(2026, 10, 3, 8)),
        ("today2", datetime(2026, 10, 5, 2)),
    ]
    ids: dict[str, int] = {}
    try:
        async with get_database().session() as session:
            lib = Library(name="电影", kind="movie", root_paths=[str(tmp_path)])
            session.add(lib)
            await session.flush()
            for n, (name, created) in enumerate(seeds):
                item = MediaItem(kind="movie", tmdb_id=9000 + n, title=name, original_title=name)
                session.add(item)
                await session.flush()
                ids[name] = item.id
                rel = f"{item.id}/poster.jpg"
                poster = tmp_path / "metadata" / "images" / rel
                poster.parent.mkdir(parents=True)
                poster.write_bytes(b"p")
                session.add(MediaMetadata(media_item_id=item.id, poster_file=rel))
                session.add(
                    LibraryFile(
                        library_id=lib.id,
                        media_item_id=item.id,
                        file_path=str(tmp_path / f"{name}.mkv"),
                        size_bytes=1,
                        source=FileSource.SCANNED,
                        created_at=created,
                    )
                )
            await session.commit()
            library_id = lib.id

        picked = [p.parent.name for p in await cover.select_cover_posters(library_id)]
        # 零点前的三部按时间倒序（并列时 id 大的在前），再拿今天**最早**入库的一部补满
        # ——补位先到先占，今天后进的片不会把它挤掉
        assert picked == [str(ids[n]) for n in ("old1", "tie_hi", "tie_lo", "today1")]
    finally:
        await dispose_db()
        get_settings.cache_clear()


# ---------------------------------------------------------------------------
# 审查补漏：清空的库、删库后 id 复用、跨零点竞态
# ---------------------------------------------------------------------------


async def test_emptied_library_drops_old_cover(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """库里的片全被移走：封面要消失，不能拿盘上的旧图一直顶着（重启后同样）。"""
    clock = _Clock()
    monkeypatch.setattr(cover, "_now", clock)
    calls = _fake_collage(tmp_path, monkeypatch, [_posters(tmp_path, "a", "b", "c", "d"), []])
    assert await cover.ensure_library_cover(67) is not None
    clock.next_day()
    await cover.ensure_library_cover(67)  # 过零点：先给旧图，后台发现库空了
    await _settle()
    assert await cover.ensure_library_cover(67) is None
    monkeypatch.setattr(cover, "_memos", {})  # 模拟重启
    assert await cover.ensure_library_cover(67) is None
    assert not list((tmp_path / "covers").glob("67-*.jpg"))
    assert calls["select"] >= 2


async def test_forget_library_cover_on_delete(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """删库要把拼贴和当天登记一起带走：SQLite 会把被删的最大 id 复用给新库，
    留着的话新建的空库会顶着旧库的封面。"""
    monkeypatch.setattr(cover, "_now", _Clock())
    _fake_collage(tmp_path, monkeypatch, [_posters(tmp_path, "a", "b", "c", "d"), []])
    monkeypatch.setattr(cover, "custom_covers_dir", lambda: tmp_path / "custom")
    assert await cover.ensure_library_cover(68) is not None

    cover.forget_library_cover(68)
    assert not list((tmp_path / "covers").glob("68-*.jpg"))
    assert await cover.ensure_library_cover(68) is None  # 同 id 的新库：没有封面


async def test_cutoff_is_stamped_from_the_selection(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """选素材时跨过了零点：登记要盖选素材那一刻的日期，不能把昨天口径的结果冻结一整天。"""
    clock = _Clock()
    monkeypatch.setattr(cover, "_now", clock)
    first = _posters(tmp_path, "a", "b", "c", "d")
    second = _posters(tmp_path, "e", "b", "c", "d")
    picks = iter([first, second])

    async def select_across_midnight(_library_id: int, cutoff=None) -> list[Path]:
        posters = next(picks)
        if posters is first:
            clock.next_day()  # 查询期间过了零点
        return posters

    _fake_collage(tmp_path, monkeypatch, [first])
    monkeypatch.setattr(cover, "select_cover_posters", select_across_midnight)
    await cover.ensure_library_cover(69)
    result = await cover.ensure_library_cover(69)  # 新的一天：要按今天口径重选
    await _settle()
    result = await cover.ensure_library_cover(69)
    assert result is not None and result[1] == "e-b-c-d"


def test_view_cover_sweep_keeps_recent_and_in_use(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """「合集」视图旧图：宽限期内的、还有观看范围在用的都留着，只清又旧又没人用的。"""
    import os
    import time

    covers = tmp_path / "covers"
    covers.mkdir()
    monkeypatch.setattr(cover, "covers_dir", lambda: covers)
    old = time.time() - cover._VIEW_COVER_GRACE_SECONDS - 60
    stale, in_use, recent = (covers / f"collections-{c * 32}.jpg" for c in "abc")
    other = covers / "7-old.jpg"
    for path in (stale, in_use, recent, other):
        path.write_bytes(b"x")
    for path in (stale, in_use, other):
        os.utime(path, (old, old))
    cover._memo_put(("collections-view", 0), (in_use, "b" * 32), 4)

    cover._sweep_view_covers()
    assert not stale.exists()
    assert in_use.exists() and recent.exists()
    assert other.exists()  # 库封面不归它管


async def test_content_change_rechecks_full_shelf_without_rerender(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """满一架的库进了今天的新片（内容版本变了）：重选一次，素材没变就不重渲。"""
    monkeypatch.setattr(cover, "_now", _Clock())
    shelf = _posters(tmp_path, "a", "b", "c", "d")
    calls = _fake_collage(tmp_path, monkeypatch, [shelf, shelf])
    first = await cover.ensure_library_cover(70)
    CONTENT["version"] = 2
    assert await cover.ensure_library_cover(70) == first
    assert await cover.ensure_library_cover(70) == first
    assert calls == {"select": 2, "render": 1}


async def test_removed_cover_item_updates_on_first_request(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """选中的片被移走：第一次请求就是新封面，不先给还挂着已移走片子的旧图。"""
    monkeypatch.setattr(cover, "_now", _Clock())
    _fake_collage(
        tmp_path,
        monkeypatch,
        [_posters(tmp_path, "a", "b", "c", "d"), _posters(tmp_path, "b", "c", "d", "e")],
    )
    await cover.ensure_library_cover(71)
    CONTENT["version"] = 2
    result = await cover.ensure_library_cover(71)
    assert result is not None and result[1] == "b-c-d-e"


async def test_emptied_full_library_loses_cover_on_first_request(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """满一架的库被清空：第一次请求就没有封面，盘上旧图一并清掉。"""
    monkeypatch.setattr(cover, "_now", _Clock())
    _fake_collage(tmp_path, monkeypatch, [_posters(tmp_path, "a", "b", "c", "d"), []])
    await cover.ensure_library_cover(72)
    CONTENT["version"] = 2
    assert await cover.ensure_library_cover(72) is None
    assert not list((tmp_path / "covers").glob("72-*.jpg"))

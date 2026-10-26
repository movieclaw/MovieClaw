"""拼音记忆（services/library/pinyin.py）：主进程不导入 pypinyin，结果与原实现一致。

pypinyin 词组词库常驻约 50MB。海报墙排序、A-Z 索引、搜索匹配都改为先 prepare 再查字典，
没见过的名字交子进程算；这里钉住三件事：请求路径上从不在主进程内现算、补算落表后新进程
直接查表、装配应用不导入 pypinyin。
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from textwrap import dedent

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from movieclaw_api.api.routes.libraries import list_library_item_index, list_library_items
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import Principal
from movieclaw_api.services.library import pinyin, pinyin_worker, sort_key
from movieclaw_api.services.library import search_matching as matching
from movieclaw_api.services.library.search_index import refresh_index_batch
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import LibraryFile, MediaItem
from movieclaw_db.models.library_file import FileSource
from movieclaw_db.repositories import LibraryRepository

_ADMIN = Principal(kind="admin", name="tester")
_TITLES = ["三体", "漫长的季节", "爱很美味", "重庆森林", "9号秘事", "长安十二时辰"]


def _forget() -> None:
    pinyin._sort.clear()
    pinyin._syllables.clear()
    sort_key.title_sort_key.cache_clear()
    matching.name_forms.cache_clear()


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'pinyin.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    get_settings.cache_clear()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    async with get_database().session() as session:
        library = await LibraryRepository(session).create(
            name="剧集库", kind="tv", root_paths=["/tv"]
        )
        for index, title in enumerate(_TITLES):
            item = MediaItem(kind="tv", tmdb_id=700 + index, title=title, original_title=title)
            session.add(item)
            await session.flush()
            session.add(
                LibraryFile(
                    library_id=library.id,
                    media_item_id=item.id,
                    file_path=f"/tv/{item.id}/S01E01.mkv",
                    size_bytes=1,
                    source=FileSource.SCANNED,
                )
            )
        await session.commit()
    _forget()
    yield library.id
    _forget()
    await dispose_db()
    get_settings.cache_clear()


@pytest.fixture
def no_in_process(monkeypatch):
    """主进程里一行拼音都不许算：结果只能来自表或子进程（子进程是另一个解释器，不受影响）。

    兜底路径（漏 prepare、子进程起不来）都会调到这几个函数，所以子进程一旦失败也会在这里现形。
    """

    def forbidden(*args, **kwargs):  # type: ignore[no-untyped-def]
        raise AssertionError(f"主进程内算了拼音：{args!r}")

    for name in ("compute", "sort_pinyin", "syllables"):
        monkeypatch.setattr(pinyin_worker, name, forbidden)


async def _search(query: str) -> list[str]:
    from movieclaw_api.api.deps import require_login
    from movieclaw_api.app import create_app

    app = create_app()
    app.dependency_overrides[require_login] = lambda: _ADMIN
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as client:
        resp = await client.get("/api/v1/search/library", params={"q": query})
    assert resp.status_code == 200, resp.text
    return [hit["item"]["title"] for hit in resp.json()["data"]["items"]]


@pytest.mark.parametrize("indexed", [False, True])
async def test_walls_index_and_search_never_compute_in_process(db, no_in_process, indexed):
    library_id = db
    if indexed:
        while await refresh_index_batch():
            pass
    async with get_database().session() as session:
        rows = await list_library_items(library_id, session=session, principal=_ADMIN)
        index = await list_library_item_index(library_id, session=session, principal=_ADMIN)
    # 与改造前同一套顺序：多音字「重庆」「长安」按 chong / chang 排
    assert [r.title for r in rows.data] == [
        "爱很美味",
        "长安十二时辰",
        "重庆森林",
        "漫长的季节",
        "三体",
        "9号秘事",
    ]
    assert [(e.initial, e.count) for e in index.data] == [
        ("A", 1),
        ("C", 2),
        ("M", 1),
        ("S", 1),
        ("#", 1),
    ]
    # 首字母、全拼、混输（逐字读音）都要命中
    for query in ("cqsl", "chongqing", "重庆sl", "casesc", "changan", "长安sesc"):
        assert (await _search(query))[0] in ("重庆森林", "长安十二时辰"), query


async def test_backfill_persists_and_a_fresh_process_reads_the_table(db, monkeypatch):
    while await refresh_index_batch():
        pass
    await pinyin.backfill()
    expected_sort = {t: pinyin_worker.sort_pinyin(t) for t in _TITLES}
    names = [matching.compact(t) for t in _TITLES]
    expected_syllables = {n: tuple(pinyin_worker.syllables(n)) for n in names}

    # 「新进程」：进程内记忆清空，子进程与现算都不许用，只能从表里取
    _forget()

    async def no_worker(*args, **kwargs):  # type: ignore[no-untyped-def]
        raise AssertionError("表里已有的不该再起子进程")

    monkeypatch.setattr(pinyin, "_compute", no_worker)
    monkeypatch.setattr(pinyin, "_fallback", no_worker)
    await pinyin.prepare(sort=_TITLES, syllables=names)
    assert {t: pinyin.sort_pinyin(t) for t in _TITLES} == expected_sort
    assert {n: pinyin.syllables(n) for n in names} == expected_syllables


async def test_worker_matches_in_process_results(db, monkeypatch):
    """子进程与进程内实现同一份代码，结果逐字一致（含非中文片段与空白）。"""
    texts = [*_TITLES, "Dune 沙丘2", "  银河护卫队 Vol.3 ", "ｌｏｎｇ季节"]
    expected_sort = [pinyin_worker.sort_pinyin(t) for t in texts]
    expected_syllables = [pinyin_worker.syllables(t) for t in texts]

    def forbidden(*args, **kwargs):  # type: ignore[no-untyped-def]
        raise AssertionError("子进程失败、退回了进程内计算")

    monkeypatch.setattr(pinyin_worker, "compute", forbidden)
    result = await pinyin._compute(texts, texts)
    assert result["sort"] == expected_sort
    assert result["syllables"] == expected_syllables


def test_app_does_not_import_pypinyin():
    script = dedent("""
        import sys
        from movieclaw_api.app import create_app
        from movieclaw_api.services.library import items, search, search_index  # noqa: F401
        create_app()
        print(sys.modules.get("pypinyin") is None)
    """)
    result = subprocess.run(
        [sys.executable, "-c", script],
        cwd=Path(__file__).resolve().parents[2],
        env={"PATH": "/usr/bin:/bin", "PYTHONPATH": "src", "TMDB_API_KEY": "x"},
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout.strip().splitlines()[-1].lower()) is True

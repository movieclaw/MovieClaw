"""issue #587：库顺序、「合集」视图封面、图片 MIME 与内容一致。

三处都只影响协议兼容层（Web 端早已正确），全部走 HTTP 断言。
"""

from __future__ import annotations

import io
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from PIL import Image
from tests.jellyfin.helpers import AUTH_HEADER, jf_login

from movieclaw_jellyfin.ids import (
    collection_guid,
    collection_view_guid,
    collections_view_guid,
    item_guid,
    library_guid,
)

ALL_ITEMS = [{"field": "genres", "op": "any_of", "values": []}]


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f'{AUTH_HEADER}, Token="{token}"'}


@pytest.fixture
def token(client: TestClient) -> str:
    return jf_login(client)


def _views(client: TestClient, token: str) -> list[dict]:
    resp = client.get("/UserViews", headers=_headers(token))
    assert resp.status_code == 200, resp.text
    return resp.json()["Items"]


def _write_webp_poster(tmp_path: Path) -> None:
    """把电影的海报资产换成「扩展名 .jpg、内容 WebP」——旧版本从图床落下的样子。"""
    Image.new("RGB", (100, 150), "#a54a4a").save(
        tmp_path / "metadata" / "images" / "1" / "poster.jpg", "WEBP"
    )


# ---------------------------------------------------------------------------
# 问题 1：/UserViews 按控制台拖好的 sort_order 下发
# ---------------------------------------------------------------------------


def test_user_views_follow_display_order(client: TestClient, token: str, seeded: dict) -> None:
    movie, tv = seeded["movie_lib"], seeded["tv_lib"]
    # 建库顺序是 电影 → 剧集；控制台把剧集拖到前面
    resp = client.put("/api/v1/libraries/display-order", json={"ordered_ids": [tv, movie]})
    assert resp.status_code == 200, resp.text

    ids = [v["Id"] for v in _views(client, token)]
    assert ids[:2] == [library_guid(tv), library_guid(movie)]

    # 其余列库的入口与 /UserViews 同序（VirtualFolders 是播放器设置页的库列表）
    folders = client.get("/Library/VirtualFolders", headers=_headers(token)).json()
    assert [f["ItemId"] for f in folders][:2] == [library_guid(tv), library_guid(movie)]


# ---------------------------------------------------------------------------
# 问题 2：「合集」聚合视图要有封面
# ---------------------------------------------------------------------------


def _add_collection(client: TestClient, *, name: str, library_id: int) -> int:
    resp = client.post(
        "/api/v1/collections", json={"name": name, "library_id": library_id, "rules": ALL_ITEMS}
    )
    assert resp.status_code == 200, resp.text
    return int(resp.json()["data"]["id"])


def test_collections_view_has_cover(client: TestClient, token: str, seeded: dict) -> None:
    _add_collection(client, name="诺兰", library_id=seeded["movie_lib"])
    view = next(v for v in _views(client, token) if v["Id"] == collections_view_guid())
    tag = view["ImageTags"].get("Primary")
    assert tag, "「合集」视图要声明 Primary 图，客户端才会去拿"

    resp = client.get(f"/Items/{collections_view_guid()}/Images/Primary?tag={tag}")
    assert resp.status_code == 200, resp.text
    assert resp.headers["content-type"] == "image/jpeg"
    img = Image.open(io.BytesIO(resp.content))
    assert img.format == "JPEG"
    # 与库封面同一种货架拼贴（21:10 横版），不是单张竖版海报
    assert img.width > img.height

    # 单条目接口（客户端点进视图前会拉一次）给的是同一个 tag
    single = client.get(f"/Items/{collections_view_guid()}", headers=_headers(token)).json()
    assert single["ImageTags"].get("Primary") == tag


def test_collections_view_cover_bad_tag_is_404(client: TestClient) -> None:
    for tag in ("", "../../etc/passwd", "0" * 32):
        resp = client.get(f"/Items/{collections_view_guid()}/Images/Primary?tag={tag}")
        assert resp.status_code == 404


# ---------------------------------------------------------------------------
# 问题 3：图片 Content-Type 按真实内容声明
# ---------------------------------------------------------------------------


def test_webp_poster_named_jpg_is_served_as_jpeg(
    client: TestClient, tmp_path: Path, seeded: dict
) -> None:
    """扩展名 .jpg、内容 WebP 的海报：声明类型必须与字节一致。

    转成真 JPEG 而不是改报 image/webp：第三方播放器对 WebP 的支持参差，
    原图直出的路径上兼容性优先。"""
    _write_webp_poster(tmp_path)
    for url in (
        f"/Items/{item_guid(seeded['movie'])}/Images/Primary",
        f"/Items/{item_guid(seeded['movie'])}/Images/Primary?maxWidth=80",
    ):
        resp = client.get(url)
        assert resp.status_code == 200, resp.text
        assert resp.headers["content-type"] == "image/jpeg"
        assert resp.content[:3] == b"\xff\xd8\xff", url


def test_collection_cover_borrowing_webp_poster(
    client: TestClient, token: str, tmp_path: Path, seeded: dict
) -> None:
    """合集（BoxSet / 钉首页的虚拟库）借首个成员的海报——首成员恰为 WebP 的那一格。"""
    _write_webp_poster(tmp_path)
    cid = _add_collection(client, name="诺兰", library_id=seeded["movie_lib"])
    for guid in (collection_guid(cid), collection_view_guid(cid)):
        resp = client.get(f"/Items/{guid}/Images/Primary")
        assert resp.status_code == 200, resp.text
        assert resp.headers["content-type"] == "image/jpeg"
        assert resp.content[:3] == b"\xff\xd8\xff"


def test_true_jpeg_poster_is_served_untouched(
    client: TestClient, tmp_path: Path, seeded: dict
) -> None:
    """真 JPEG 原图直出，不白白重编码一遍。"""
    raw = (tmp_path / "metadata" / "images" / "1" / "poster.jpg").read_bytes()
    resp = client.get(f"/Items/{item_guid(seeded['movie'])}/Images/Primary")
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "image/jpeg"
    assert resp.content == raw


def test_collections_view_cover_follows_viewer_scope(
    client: TestClient, token: str, tmp_path: Path, seeded: dict
) -> None:
    """封面素材按观看者可见范围选：看不见的库里的海报不能拼进他的封面。

    取图请求不带凭据，所以这一层只能在 /UserViews 里把关——这里直接验 tag
    对应的素材集合。"""
    import sqlite3

    from movieclaw_api.core.config import get_settings
    from movieclaw_api.services.library.cover import _cover_key

    images = tmp_path / "metadata" / "images"
    (images / "2").mkdir()
    Image.new("RGB", (100, 150), "#3c8a5a").save(images / "2" / "poster.jpg", "JPEG")
    db = get_settings().database_url.removeprefix("sqlite+aiosqlite:///")
    with sqlite3.connect(db) as conn:
        conn.execute(
            "UPDATE media_metadata SET poster_file = '2/poster.jpg' WHERE media_item_id = ?",
            (seeded["show"],),
        )
    _add_collection(client, name="电影合集", library_id=seeded["movie_lib"])
    _add_collection(client, name="剧集合集", library_id=seeded["tv_lib"])

    def cover_tag() -> str:
        view = next(v for v in _views(client, token) if v["Id"] == collections_view_guid())
        return view["ImageTags"]["Primary"]

    full = cover_tag()
    with sqlite3.connect(db) as conn:
        conn.execute(
            "UPDATE library SET access_mode = 'selected', admin_visible = 0 WHERE id = ?",
            (seeded["movie_lib"],),
        )
    scoped = cover_tag()
    assert scoped != full
    assert scoped == _cover_key([(images / "2" / "poster.jpg").resolve()])
    resp = client.get(f"/Items/{collections_view_guid()}/Images/Primary?tag={scoped}")
    assert resp.status_code == 200


def _seed_movies_with_posters(tmp_path: Path, library_id: int, count: int) -> list[int]:
    """往电影库直接塞几部带本地海报的作品（夹具里只有两部有海报，凑不满一架）。"""
    import sqlite3

    from movieclaw_api.core.config import get_settings

    db = get_settings().database_url.removeprefix("sqlite+aiosqlite:///")
    now = "2026-01-01 00:00:00"
    ids: list[int] = []
    with sqlite3.connect(db) as conn:
        for n in range(count):
            cur = conn.execute(
                "INSERT INTO media_item (created_at, updated_at, kind, source, external_id,"
                " tmdb_id, title, original_title, aliases)"
                " VALUES (?, ?, 'movie', 'tmdb', ?, ?, ?, ?, '[]')",
                (now, now, f"tmdb:{8800 + n}", 8800 + n, f"片{n}", f"Film {n}"),
            )
            item_id = int(cur.lastrowid or 0)
            rel = f"{item_id}/poster.jpg"
            poster = tmp_path / "metadata" / "images" / rel
            poster.parent.mkdir(parents=True, exist_ok=True)
            Image.new("RGB", (100, 150), (40 * n, 90, 160)).save(poster, "JPEG")
            conn.execute(
                "INSERT INTO media_metadata (created_at, updated_at, media_item_id, genres,"
                ' origin_countries, studios, directors, "cast", scrape_language, poster_file)'
                " VALUES (?, ?, ?, '[]', '[]', '[]', '[]', '[]', 'zh-CN', ?)",
                (now, now, item_id, rel),
            )
            conn.execute(
                "INSERT INTO library_file (created_at, updated_at, library_id, media_item_id,"
                " season_number, episode_number, file_path, size_bytes, source)"
                " VALUES (?, ?, ?, ?, 0, 0, ?, 1, 'scanned')",
                (now, now, library_id, item_id, str(tmp_path / f"film{n}.mkv")),
            )
            ids.append(item_id)
    return ids


def test_collections_view_cover_partial_then_frozen(
    client: TestClient, token: str, tmp_path: Path, seeded: dict, monkeypatch
) -> None:
    """「合集」视图封面：不满一架时新合集当场补进去；满一架后当天不再换，过零点才换。"""
    import time
    from datetime import datetime, timedelta
    from zoneinfo import ZoneInfo

    from movieclaw_api.services.library import cover

    now = [datetime(2026, 10, 5, 15, tzinfo=ZoneInfo("Asia/Shanghai"))]
    monkeypatch.setattr(cover, "_now", lambda: now[0])
    films = _seed_movies_with_posters(tmp_path, seeded["movie_lib"], 5)

    def settled_tag() -> str:
        """取一次（可能先拿到旧图），等后台渲完，再取一次。"""
        for _ in range(2):
            view = next(v for v in _views(client, token) if v["Id"] == collections_view_guid())
            for _ in range(100):
                if not cover._render_tasks:
                    break
                time.sleep(0.02)
        return view["ImageTags"]["Primary"]

    def add(n: int) -> int:
        resp = client.post(
            "/api/v1/collections",
            json={"name": f"片单{n}", "library_id": seeded["movie_lib"], "item_ids": [films[n]]},
        )
        assert resp.status_code == 200, resp.text
        return int(resp.json()["data"]["id"])

    def tag_now() -> str:
        view = next(v for v in _views(client, token) if v["Id"] == collections_view_guid())
        return view["ImageTags"]["Primary"]

    first = add(0)
    tags = [tag_now()]
    for n in (1, 2, 3):
        add(n)
        tags.append(tag_now())  # 建好后的第一次请求就是新封面
    # 不满一架时每建一个合集都当场补进封面
    assert len(set(tags)) == 4
    for tag in tags:  # 换下来的旧图留着：缓存了旧 /UserViews 的客户端还会拿旧 tag 来取
        resp = client.get(f"/Items/{collections_view_guid()}/Images/Primary?tag={tag}")
        assert resp.status_code == 200
    full = tags[-1]

    # 满一架后当天：再建的合集排在后面，封面不变（当天登记直接命中）
    add(4)
    assert tag_now() == full

    # 封面里的合集被删掉：第一次请求就换，不让删掉的合集挂到零点
    assert client.delete(f"/api/v1/collections/{first}").status_code == 200
    replaced = tag_now()
    assert replaced != full
    for tag in (replaced, full):  # 换下来的旧图仍在宽限期内可取
        got = client.get(f"/Items/{collections_view_guid()}/Images/Primary?tag={tag}")
        assert got.status_code == 200

    # 过了零点构成没变：沿用同一张，不重渲
    now[0] += timedelta(days=1)
    assert settled_tag() == replaced


def test_old_collections_view_tag_stays_fetchable(
    client: TestClient, token: str, tmp_path: Path, seeded: dict, monkeypatch
) -> None:
    """客户端会缓存 /UserViews：封面换了之后，拿着旧 tag 来取图也不能 404（#587 的空白格子）。"""
    from datetime import datetime
    from zoneinfo import ZoneInfo

    from movieclaw_api.services.library import cover

    now = [datetime(2026, 10, 5, 15, tzinfo=ZoneInfo("Asia/Shanghai"))]
    monkeypatch.setattr(cover, "_now", lambda: now[0])
    films = _seed_movies_with_posters(tmp_path, seeded["movie_lib"], 2)

    def tag_now() -> str:
        view = next(v for v in _views(client, token) if v["Id"] == collections_view_guid())
        return view["ImageTags"]["Primary"]

    resp = client.post(
        "/api/v1/collections",
        json={"name": "片单", "library_id": seeded["movie_lib"], "item_ids": [films[0]]},
    )
    assert resp.status_code == 200
    old = tag_now()
    resp = client.post(
        "/api/v1/collections",
        json={"name": "片单2", "library_id": seeded["movie_lib"], "item_ids": [films[1]]},
    )
    assert resp.status_code == 200
    new = tag_now()
    assert new != old
    for tag in (old, new):
        got = client.get(f"/Items/{collections_view_guid()}/Images/Primary?tag={tag}")
        assert got.status_code == 200, tag


async def test_collections_view_cover_probe_budget(monkeypatch) -> None:
    """找到第一个非空合集之后，凑封面只再探有限几个（分级受限的观看者可能只看得见一两个）。"""
    from types import SimpleNamespace

    from movieclaw_api.services.library.access import NO_CONTENT_LIMIT
    from movieclaw_jellyfin.routes import library as routes

    rows = [SimpleNamespace(id=i) for i in range(300)]
    probed: list[int] = []

    async def fake_visible(_session, **_kw):
        return rows

    async def fake_cover(_session, row, _scope):
        probed.append(row.id)
        return 1000 if row.id == 5 else None  # 300 个里只有一个非空

    monkeypatch.setattr(routes, "visible_collections", fake_visible)
    monkeypatch.setattr(routes, "_visible_cover_item", fake_cover)

    class _NoFiles:
        async def execute(self, _query):
            return SimpleNamespace(all=lambda: [])

    scope = routes.ViewerScope(3, {1}, NO_CONTENT_LIMIT)
    has, tag = await routes._collections_view(_NoFiles(), scope)  # type: ignore[arg-type]
    assert has is True and tag is None
    assert len(probed) == 6 + routes._COVER_EXTRA_PROBES

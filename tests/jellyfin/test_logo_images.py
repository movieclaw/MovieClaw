"""Jellyfin 协议下发片名 Logo（issue #472，docs/design/jellyfin-compat.md 5.6）。

Logo 与 Primary/Backdrop 同一套三层解析：条目目录美术图（clearlogo.png /
logo.png）> 刮削资产（logo_file）> TMDB 图床兜底（logo_path）。透明底 PNG
全程保持 PNG——缩放变体转 JPEG 会把透明区压成黑底。季/集经 Parent* 字段
指向剧集的 Logo。
"""

from __future__ import annotations

import io
import os
import sqlite3
from pathlib import Path
from types import SimpleNamespace

from fastapi.testclient import TestClient
from PIL import Image

from jellyfin.helpers import jf_login
from movieclaw_jellyfin.ids import item_guid, library_guid, season_guid


def _write_logo(path: Path, rgb: tuple[int, int, int] = (230, 180, 40)) -> None:
    """80×30 透明底 PNG，中间一块不透明色条（模拟片名字标）。"""
    path.parent.mkdir(parents=True, exist_ok=True)
    image = Image.new("RGBA", (80, 30), (0, 0, 0, 0))
    for x in range(10, 70):
        for y in range(8, 22):
            image.putpixel((x, y), (*rgb, 255))
    image.save(path, "PNG")


def _sql(statement: str, params: tuple) -> None:
    conn = sqlite3.connect(os.environ["DATABASE_URL"].split("///", 1)[1])
    conn.execute(statement, params)
    conn.commit()
    conn.close()


def _decode(body: bytes) -> Image.Image:
    image = Image.open(io.BytesIO(body))
    image.load()
    return image


def test_logo_asset_listed_and_served_as_transparent_png(
    client: TestClient, seeded: dict, tmp_path: Path
) -> None:
    token = jf_login(client)
    auth = {"ApiKey": token}
    movie = seeded["movie"]
    _write_logo(tmp_path / "metadata" / "images" / str(movie) / "logo.png")
    _sql(
        "update media_metadata set logo_file = ? where media_item_id = ?",
        (f"{movie}/logo.png", movie),
    )

    # 列表路径只装白名单列（load_only）：Logo 两列不在白名单里，这里就是
    # session 关闭后的惰性加载 → 整条列表 500
    listing = client.get(
        "/Items",
        params={
            **auth,
            "parentId": library_guid(seeded["movie_lib"]),
            "includeItemTypes": "Movie",
            "fields": "Overview",
        },
    )
    assert listing.status_code == 200, listing.text
    assert listing.json()["Items"][0]["ImageTags"].get("Logo")
    detail = client.get(f"/Items/{item_guid(movie)}", params=auth).json()
    tag = detail["ImageTags"]["Logo"]

    original = client.get(f"/Items/{item_guid(movie)}/Images/Logo", params={**auth, "tag": tag})
    assert original.status_code == 200
    assert original.headers["content-type"] == "image/png"
    assert original.headers["ETag"] == f'"{tag}"'
    image = _decode(original.content)
    assert image.convert("RGBA").getpixel((0, 0))[3] == 0

    # 客户端几乎总带 maxWidth：缩放变体必须仍是透明底 PNG，而不是黑底 JPEG
    scaled = client.get(f"/Items/{item_guid(movie)}/Images/Logo", params={**auth, "maxWidth": 40})
    assert scaled.status_code == 200
    assert scaled.headers["content-type"] == "image/png"
    image = _decode(scaled.content)
    assert image.width == 40
    rgba = image.convert("RGBA")
    assert rgba.getpixel((0, 0))[3] == 0
    assert rgba.getpixel((20, 7))[3] == 255

    # 不透明的海报照旧缩成 JPEG（体积小）
    poster = client.get(
        f"/Items/{item_guid(movie)}/Images/Primary", params={**auth, "maxWidth": 40}
    )
    assert poster.headers["content-type"] == "image/jpeg"


def test_pascal_case_scale_params_are_honored(
    client: TestClient, seeded: dict, tmp_path: Path
) -> None:
    """Infuse 这类客户端发 PascalCase 的 MaxWidth / FillWidth：照样出缩放图，不能回原图。"""
    token = jf_login(client)
    movie = seeded["movie"]
    _write_logo(tmp_path / "metadata" / "images" / str(movie) / "logo.png")
    _sql(
        "update media_metadata set logo_file = ? where media_item_id = ?",
        (f"{movie}/logo.png", movie),
    )

    for param in ("MaxWidth", "FillWidth"):
        resp = client.get(
            f"/Items/{item_guid(movie)}/Images/Logo", params={"ApiKey": token, param: 40}
        )
        assert resp.status_code == 200
        assert _decode(resp.content).width == 40, param


def test_palette_png_logo_keeps_transparency_when_scaled(
    client: TestClient, seeded: dict, tmp_path: Path
) -> None:
    """调色板 PNG（P 模式 + tRNS 透明色）同样保持透明，且不按最近邻缩出锯齿。"""
    token = jf_login(client)
    movie = seeded["movie"]
    path = tmp_path / "metadata" / "images" / str(movie) / "logo.png"
    _write_logo(path)
    Image.open(path).convert("RGBA").quantize(colors=16).save(path, "PNG")
    assert Image.open(path).mode == "P"
    _sql(
        "update media_metadata set logo_file = ? where media_item_id = ?",
        (f"{movie}/logo.png", movie),
    )

    scaled = client.get(
        f"/Items/{item_guid(movie)}/Images/Logo", params={"ApiKey": token, "maxWidth": 40}
    )
    assert scaled.headers["content-type"] == "image/png"
    assert _decode(scaled.content).convert("RGBA").getpixel((0, 0))[3] == 0


def test_series_logo_falls_back_to_tmdb_and_parents_point_at_it(
    client: TestClient, seeded: dict, tmp_path: Path, monkeypatch
) -> None:
    """资产未落地：DTO 仍按 TMDB 路径给出 Logo tag，图片走图床兜底（原图档）；
    季/集用 ParentLogoItemId/ParentLogoImageTag 指向剧集。"""
    token = jf_login(client)
    auth = {"ApiKey": token}
    show = seeded["show"]
    _sql("update media_item set logo_path = '/show-logo.png' where id = ?", (show,))

    fake = tmp_path / "fake-logo.png"
    _write_logo(fake, (40, 90, 220))
    requested: list[str] = []

    class _FakeCache:
        async def get_or_fetch(self, url: str):
            requested.append(url)
            return SimpleNamespace(path=fake, content_type="image/png", version="v1")

    from movieclaw_api.services import image_cache as image_cache_module

    monkeypatch.setattr(image_cache_module, "get_image_cache", lambda: _FakeCache())

    show_guid = item_guid(show)
    series = client.get(f"/Items/{show_guid}", params=auth).json()
    tag = series["ImageTags"]["Logo"]
    resp = client.get(f"/Items/{show_guid}/Images/Logo", params=auth)
    assert resp.status_code == 200
    assert resp.headers["content-type"] == "image/png"
    assert requested and requested[-1].endswith("/original/show-logo.png")
    # 兜底层绝不能拿成背景图：非 primary 一律当 backdrop 的写法会走到 backdrop_path
    assert "backdrop" not in requested[-1]

    seasons = client.get(f"/Shows/{show_guid}/Seasons", params=auth).json()["Items"]
    assert {(s["ParentLogoItemId"], s["ParentLogoImageTag"]) for s in seasons} == {(show_guid, tag)}
    episodes = client.get(
        f"/Shows/{show_guid}/Episodes",
        params={**auth, "seasonId": season_guid(show, 1)},
    ).json()["Items"]
    assert episodes and all(e["ParentLogoItemId"] == show_guid for e in episodes)
    assert all(e["ParentLogoImageTag"] == tag for e in episodes)
    assert all("Logo" not in e["ImageTags"] for e in episodes)


def test_dir_clearlogo_wins_and_empty_path_means_none(
    client: TestClient, seeded: dict, media_root: Path
) -> None:
    """条目目录里用户/第三方刮削器放的 clearlogo.png 最优先（与海报同规则）；
    logo_path 空串（TMDB 确认没有）且无资产 → 不给 tag、图片 404。"""
    token = jf_login(client)
    auth = {"ApiKey": token}
    show = seeded["show"]
    show_guid = item_guid(show)

    _sql("update media_item set logo_path = '' where id = ?", (show,))
    body = client.get(f"/Items/{show_guid}", params=auth).json()
    assert "Logo" not in body["ImageTags"]
    assert client.get(f"/Items/{show_guid}/Images/Logo", params=auth).status_code == 404

    _write_logo(media_root / "Breaking (2008)" / "clearlogo.png", (10, 200, 10))
    resp = client.get(f"/Items/{show_guid}/Images/Logo", params=auth)
    assert resp.status_code == 200
    assert resp.headers["Cache-Control"] == "private, max-age=3600"
    assert _decode(resp.content).convert("RGBA").getpixel((40, 15)) == (10, 200, 10, 255)

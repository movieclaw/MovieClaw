"""Issue #602：真实 HTTP 验证剧集海报归属（季目录与平铺分集）。"""

from __future__ import annotations

import io
import os
import socket
import sqlite3
import threading
import time
from pathlib import Path

import httpx
import pytest
import uvicorn
from PIL import Image

from jellyfin.helpers import ADMIN, jf_login
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_jellyfin.ids import episode_guid, item_guid


@pytest.fixture
def client(seeded, tmp_path, monkeypatch):
    """复用真实数据库播种，应用按生产生命周期启动，客户端走 TCP。"""
    from movieclaw_api.app import create_app

    monkeypatch.setenv("IMAGE_CACHE_DIR", str(tmp_path / "image-cache"))
    get_settings.cache_clear()
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(create_app(), log_config=None, access_log=False))
    thread = threading.Thread(target=server.run, kwargs={"sockets": [sock]}, daemon=True)
    thread.start()
    try:
        deadline = time.monotonic() + 20
        while not server.started:
            assert thread.is_alive() and time.monotonic() < deadline, "服务启动超时"
            time.sleep(0.02)
        with httpx.Client(base_url=f"http://127.0.0.1:{port}", trust_env=False) as c:
            response = c.post("/api/v1/auth/bootstrap", json=ADMIN)
            assert response.status_code == 200, response.text
            yield c
    finally:
        server.should_exit = True
        thread.join(timeout=20)
        sock.close()
        reset_setting_store()
        reset_secret_box()
        reset_auth_state()
        get_settings.cache_clear()
        assert not thread.is_alive(), "服务未退出"


def _image(path: Path, size: tuple[int, int], color: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", size, color).save(path, "JPEG")
    return path


def _sql(statement: str, params: tuple) -> None:
    with sqlite3.connect(os.environ["DATABASE_URL"].split("///", 1)[1]) as connection:
        connection.execute(statement, params)


def _video(media_root: Path, show_id: int, *, flat: bool) -> Path:
    old = media_root / "Breaking (2008)" / "Season 01" / "S01E01.mkv"
    if not flat:
        return old
    video = old.parent.parent / old.name
    old.rename(video)
    _sql(
        "update library_file set file_path = ? where media_item_id = ? "
        "and season_number = 1 and episode_number = 1",
        (str(video), show_id),
    )
    return video


def _poster_asset(tmp_path: Path, show_id: int) -> Path:
    path = _image(
        tmp_path / "metadata" / "images" / str(show_id) / "poster.jpg", (300, 450), "yellow"
    )
    _sql(
        "update media_metadata set poster_file = ?, poster_width = ?, poster_height = ? "
        "where media_item_id = ?",
        (f"{show_id}/poster.jpg", 300, 450, show_id),
    )
    return path


def _assert_image(response: httpx.Response, expected: Path) -> None:
    assert response.status_code == 200, response.text
    assert response.headers["content-type"] == "image/jpeg"
    assert response.content == expected.read_bytes()


@pytest.mark.parametrize("flat", [False, True], ids=["season-dir", "flat"])
@pytest.mark.parametrize("suffix", ["", "-poster"], ids=["same-name", "poster-sidecar"])
def test_series_poster_ignores_episode_images(
    client, seeded, media_root, tmp_path, flat, suffix
) -> None:
    show_id = seeded["show"]
    video = _video(media_root, show_id, flat=flat)
    _image(video.with_name(f"{video.stem}{suffix}.jpg"), (1248, 702), "red")
    poster = _image(media_root / "Breaking (2008)" / "poster.jpg", (780, 1170), "blue")
    _poster_asset(tmp_path, show_id)
    auth = {"ApiKey": jf_login(client)}
    guid = item_guid(show_id)

    # 模拟 Infuse：先浏览/取详情，再依据 ImageTags 请求主图与缩放变体。
    listing = client.get("/Items", params={**auth, "IncludeItemTypes": "Series"})
    assert listing.status_code == 200, listing.text
    assert any(item["Id"] == guid for item in listing.json()["Items"])
    detail = client.get(f"/Items/{guid}", params=auth)
    assert detail.status_code == 200, detail.text
    assert detail.json()["ImageTags"]["Primary"]
    assert detail.json()["PrimaryImageAspectRatio"] == pytest.approx(0.6667)
    _assert_image(client.get(f"/Items/{guid}/Images/Primary", params=auth), poster)
    scaled = client.get(f"/Items/{guid}/Images/Primary", params={**auth, "MaxWidth": 200})
    assert scaled.status_code == 200, scaled.text
    assert Image.open(io.BytesIO(scaled.content)).size == (200, 300)

    # Web/Mac：详情下发的地址与直接 artwork 接口都必须拿到同一张剧集海报。
    base = f"/api/v1/libraries/{seeded['tv_lib']}/items/{show_id}"
    detail = client.get(base)
    assert detail.status_code == 200, detail.text
    poster_url = detail.json()["data"]["poster_url"]
    assert poster_url.startswith(base.removeprefix("/api/v1") + "/artwork?")
    _assert_image(client.get("/api/v1" + poster_url), poster)
    _assert_image(client.get(base + "/artwork", params={"kind": "poster"}), poster)


@pytest.mark.parametrize("flat", [False, True], ids=["season-dir", "flat"])
@pytest.mark.parametrize("cached", [False, True], ids=["no-art", "scraped-asset"])
def test_series_without_local_poster_does_not_use_episode_image(
    client, seeded, media_root, tmp_path, flat, cached
) -> None:
    show_id = seeded["show"]
    video = _video(media_root, show_id, flat=flat)
    _image(video.with_suffix(".jpg"), (1248, 702), "red")
    _image(video.with_name(video.stem + "-poster.jpg"), (1248, 702), "red")
    poster = _poster_asset(tmp_path, show_id) if cached else None
    auth = {"ApiKey": jf_login(client)}
    response = client.get(f"/Items/{item_guid(show_id)}/Images/Primary", params=auth)
    if poster is None:
        assert response.status_code == 404, response.text
    else:
        _assert_image(response, poster)
    base = f"/api/v1/libraries/{seeded['tv_lib']}/items/{show_id}"
    response = client.get(base + "/artwork", params={"kind": "poster"})
    assert response.status_code == 404, response.text
    detail = client.get(base)
    assert detail.status_code == 200, detail.text
    poster_url = detail.json()["data"]["poster_url"]
    if poster is None:
        assert poster_url is None
    else:
        assert poster_url.startswith("/images/assets/")
        _assert_image(client.get("/api/v1" + poster_url), poster)


@pytest.mark.parametrize("nested", [False, True], ids=["movie-dir", "version-dir"])
def test_movie_same_name_poster_keeps_priority(client, seeded, media_root, nested) -> None:
    folder = media_root / "Inception (2010)"
    video = folder / "Inception.2010.2160p.mkv"
    if nested:
        old = video
        video = folder / "2160p" / old.name
        video.parent.mkdir()
        old.rename(video)
        _sql("update library_file set file_path = ? where file_path = ?", (str(video), str(old)))
    poster = _image(video.with_suffix(".jpg"), (400, 600), "green")
    _image(video.parent / "poster.jpg", (780, 1170), "blue")
    auth = {"ApiKey": jf_login(client)}
    _assert_image(
        client.get(f"/Items/{item_guid(seeded['movie'])}/Images/Primary", params=auth), poster
    )
    _assert_image(
        client.get(
            f"/api/v1/libraries/{seeded['movie_lib']}/items/{seeded['movie']}/artwork",
            params={"kind": "poster"},
        ),
        poster,
    )


def test_episode_primary_still_is_independent(client, seeded, media_root, tmp_path) -> None:
    show_id = seeded["show"]
    _image(media_root / "Breaking (2008)" / "poster.jpg", (780, 1170), "blue")
    still = _image(
        tmp_path / "metadata" / "images" / str(show_id) / "s01e01.jpg", (1248, 702), "red"
    )
    _sql(
        "update media_episode set still_file = ? where media_item_id = ? "
        "and season_number = 1 and episode_number = 1",
        (f"{show_id}/s01e01.jpg", show_id),
    )
    auth = {"ApiKey": jf_login(client)}
    _assert_image(
        client.get(f"/Items/{episode_guid(show_id, 1, 1)}/Images/Primary", params=auth), still
    )

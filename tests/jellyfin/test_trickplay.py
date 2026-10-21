"""Jellyfin 兼容层的进度条预览图（#955）。

- 条目上的 ``Trickplay`` 受 fields 门控，单条目全字段带出；外层键是媒体源 id、
  内层键是单格像素宽度；还没生成索引的版本不出现；
- ``/Videos/{id}/Trickplay/{width}/{index}.jpg`` 用设备 token 鉴权，按
  ``MediaSourceId`` 选版本（缺省取第一个），宽度不符、越界一律 404；
- 直连取流像自家播放器开会话一样在后台补生成（HLS 转码入口见 test_transcode）。
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from jellyfin.helpers import jf_login
from movieclaw_api.core.config import get_settings
from movieclaw_api.services.playback import trickplay
from movieclaw_jellyfin.ids import decode_guid, item_guid


@pytest.fixture
def trickplay_root(seeded, tmp_path: Path, monkeypatch) -> Path:
    root = tmp_path / "trickplay"
    monkeypatch.setenv("MOVIECLAW_TRICKPLAY_CACHE_DIR", str(root))
    get_settings.cache_clear()
    return root


def _write_index(root: Path, file_id: int, *, sheets: int = 2, count: int = 150) -> None:
    """按生成器的产物形状落一份索引：两张 10×10 雪碧图、单格 320×180、150 格。"""
    directory = root / str(file_id)
    directory.mkdir(parents=True)
    names = [f"sprite_{i + 1:03d}.jpg" for i in range(sheets)]
    for i, name in enumerate(names):
        (directory / name).write_bytes(b"\xff\xd8" + bytes([i]) * 10_000 + b"\xff\xd9")
    index = {
        "interval_ms": 10_000,
        "tile_width": 320,
        "tile_height": 180,
        "columns": 10,
        "rows": 10,
        "sheets": names,
        "count": count,
    }
    (directory / "index.json").write_text(json.dumps(index), encoding="utf-8")


def _sources(client: TestClient, item: str, token: str) -> list[str]:
    body = client.get(f"/Items/{item}", params={"ApiKey": token}).json()
    return [s["Id"] for s in body["MediaSources"]]


def test_trickplay_field_shape_and_gating(
    trickplay_root: Path, client: TestClient, seeded: dict
) -> None:
    token = jf_login(client)
    item = item_guid(seeded["movie"])
    local_source, strm_source = _sources(client, item, token)
    _write_index(trickplay_root, decode_guid(local_source).entity_id)

    single = client.get(f"/Items/{item}", params={"ApiKey": token}).json()
    # 只有生成好的版本出现；strm 版本还没有索引，不出
    assert single["Trickplay"] == {
        local_source: {
            "320": {
                "Width": 320,
                "Height": 180,
                "TileWidth": 10,
                "TileHeight": 10,
                "ThumbnailCount": 150,
                "Interval": 10_000,
                "Bandwidth": single["Trickplay"][local_source]["320"]["Bandwidth"],
            }
        }
    }
    assert single["Trickplay"][local_source]["320"]["Bandwidth"] > 0
    assert "Trickplay" not in single["MediaSources"][0]

    users = client.get("/Users/Me", params={"ApiKey": token}).json()
    url = f"/Users/{users['Id']}/Items"
    lib = {"ApiKey": token, "IncludeItemTypes": "Movie", "Recursive": "true"}
    plain = client.get(url, params=lib).json()["Items"]
    assert plain and all("Trickplay" not in i for i in plain)
    gated = client.get(url, params={**lib, "Fields": "Trickplay"}).json()["Items"]
    movie = next(i for i in gated if i["Id"] == item)
    assert list(movie["Trickplay"]) == [local_source]


def test_trickplay_absent_until_generated(
    trickplay_root: Path, client: TestClient, seeded: dict
) -> None:
    token = jf_login(client)
    single = client.get(f"/Items/{item_guid(seeded['movie'])}", params={"ApiKey": token}).json()
    # 没生成就是空字典（真 Jellyfin 同款），客户端只显示时间
    assert single["Trickplay"] == {}


def test_trickplay_image_route(trickplay_root: Path, client: TestClient, seeded: dict) -> None:
    token = jf_login(client)
    item = item_guid(seeded["movie"])
    local_source, strm_source = _sources(client, item, token)
    file_id = decode_guid(local_source).entity_id
    _write_index(trickplay_root, file_id)
    sheet = (trickplay_root / str(file_id) / "sprite_002.jpg").read_bytes()

    ok = client.get(
        f"/Videos/{item}/Trickplay/320/1.jpg",
        params={"ApiKey": token, "MediaSourceId": local_source},
    )
    assert ok.status_code == 200
    assert ok.headers["content-type"] == "image/jpeg"
    assert ok.content == sheet
    # Jellyfin 路由与参数大小写不敏感
    lower = client.get(
        f"/videos/{item}/trickplay/320/1.jpg",
        params={"api_key": token, "mediasourceid": local_source},
    )
    assert lower.status_code == 200 and lower.content == sheet
    # 不传 MediaSourceId 用第一个版本
    default = client.get(f"/Videos/{item}/Trickplay/320/0.jpg", params={"ApiKey": token})
    assert default.status_code == 200

    missing = [
        ("320/2.jpg", {"MediaSourceId": local_source}),  # 越界
        ("480/0.jpg", {"MediaSourceId": local_source}),  # 没有这个宽度
        ("320/0.jpg", {"MediaSourceId": strm_source}),  # 这个版本没生成
    ]
    for tail, extra in missing:
        resp = client.get(f"/Videos/{item}/Trickplay/{tail}", params={"ApiKey": token, **extra})
        assert resp.status_code == 404, tail
    # 设备鉴权
    assert client.get(f"/Videos/{item}/Trickplay/320/0.jpg").status_code == 401


def test_direct_stream_schedules_generation(
    trickplay_root: Path, client: TestClient, seeded: dict, monkeypatch
) -> None:
    scheduled: list[int] = []
    monkeypatch.setattr(trickplay, "schedule", lambda f, *, delay_s=0: scheduled.append(f.id))
    token = jf_login(client)
    item = item_guid(seeded["movie"])
    local_source, _ = _sources(client, item, token)

    head = client.head(
        f"/Videos/{item}/stream",
        params={"ApiKey": token, "static": "true", "MediaSourceId": local_source},
    )
    assert head.status_code == 200
    assert scheduled == []  # HEAD 只是探测
    resp = client.get(
        f"/Videos/{item}/stream",
        params={"ApiKey": token, "static": "true", "MediaSourceId": local_source},
    )
    assert resp.status_code == 200
    assert scheduled == [decode_guid(local_source).entity_id]

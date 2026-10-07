"""Issue #613：真实媒体下，成员能播放的文件通过分享也应能起播。"""

from functools import partial

import pytest
from tests.api.test_playback_e2e import CHROME, _seed, make_media

from movieclaw_db.engine import get_database
from movieclaw_db.models import LibraryFile

pytestmark = pytest.mark.integration
pytest_plugins = ("tests.api.test_playback_e2e",)


@pytest.mark.parametrize(
    ("container", "by_file", "password"),
    [("mp4", False, None), ("mp4", True, "k7pw2m"), ("mkv", False, None), ("mkv", True, "k7pw2m")],
)
def test_shared_start_session_matches_member(client, tmp_path, container, by_file, password):
    path = make_media(tmp_path / "m", "shared", codec="h264", container=container)
    file_id = client.portal.call(partial(_seed, path, codec="h264", container=container))

    async def identity():
        async with get_database().session() as session:
            row = await session.get(LibraryFile, file_id)
            return row.library_id, row.media_item_id

    library_id, item_id = client.portal.call(identity)
    payload = {"file_id": file_id, "capability": CHROME}
    member = client.post("/api/v1/playback/sessions", json=payload)
    assert member.status_code == 200, member.text
    assert member.json()["data"]["stream_url"]
    session_id = member.json()["data"]["session_id"]
    if session_id:
        assert client.delete(f"/api/v1/playback/sessions/{session_id}").status_code == 200

    created = client.post(
        f"/api/v1/libraries/{library_id}/items/{item_id}/share",
        json={"password": password},
    )
    assert created.status_code == 200, created.text
    slug = created.json()["data"]["slug"]
    base = f"/api/v1/share/{slug}"
    client.cookies.clear()
    if password:
        unlocked = client.post(f"{base}/unlock", json={"password": password})
        assert unlocked.status_code == 200, unlocked.text
    if not by_file:
        payload = {"media_item_id": item_id, "capability": CHROME}
    assert client.get(f"{base}/item").status_code == 200
    decision = client.post(f"{base}/playback/decide", json=payload)
    assert decision.status_code == 200, decision.text
    assert decision.json()["data"]["tier"] == (0 if container == "mp4" else 1)

    shared = client.post(f"{base}/playback/sessions", json=payload)
    assert shared.status_code == 200, shared.text
    assert shared.json()["data"]["decision"]["tier"] == (0 if container == "mp4" else 1)
    assert "total;dur=" in shared.headers["Server-Timing"]
    stream = client.get(shared.json()["data"]["stream_url"])
    assert stream.status_code == 200, stream.text
    if container == "mp4":
        assert stream.content == path.read_bytes()
    else:
        assert "#EXTM3U" in stream.text

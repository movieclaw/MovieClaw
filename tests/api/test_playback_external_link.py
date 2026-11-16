"""外部播放器链接（docs/design/external-player.md）。

端到端地走一遍用户真实会做的事：网页登录 → 要链接 → 把返回的**绝对地址**原样交给
「外部播放器」（这里是测试客户端按 Range 取字节 / 拉字幕）。再覆盖授权边界：token 只认
那一个文件、会过期、带外部标记；成员看不到的片 404；分享访客 403；原盘目录拒绝、ISO 放行；
以及调一次接口不在播放会话、观看状态、播放记录、活动页里留下任何痕迹。
"""

from __future__ import annotations

import asyncio
import itertools
import time
from datetime import UTC, date, datetime
from functools import partial
from pathlib import Path
from urllib.parse import parse_qs, quote, urlsplit

import pytest
from fastapi.testclient import TestClient
from sqlmodel import func, select

from movieclaw_api.api.routes import playback as routes_playback
from movieclaw_api.core.config import get_settings
from movieclaw_api.exceptions import ForbiddenException
from movieclaw_api.schemas.playback import PlaybackExternalLinkRequest
from movieclaw_api.services.auth import Principal, ShareGrant, reset_auth_state
from movieclaw_api.services.playback import signing
from movieclaw_api.services.playback.session import get_session_manager, reset_session_manager
from movieclaw_api.services.playback.signing import issue_stream_token, verify_stream_token
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_db.engine import get_database
from movieclaw_db.models import (
    FileSource,
    FileState,
    LibraryFile,
    MediaItem,
    MediaMetadata,
    PlaybackLog,
    PlaybackMetric,
    PlaybackState,
)
from movieclaw_db.models.base import utcnow
from movieclaw_db.repositories.library_repo import LibraryRepository
from movieclaw_playback import activity

_API = "/api/v1"
_PB = f"{_API}/playback"
_ADMIN = {"username": "admin", "password": "Sup3rSecret!"}
_MEMBER = {"username": "family", "password": "family-pass-1"}
_DATA = bytes(range(256)) * 64  # 16 KiB，每个偏移的字节都不同，Range 取错一眼看得出
_SRT = "1\n00:00:01,000 --> 00:00:02,000\n你好\n"


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'test.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("MEDIA_DIR", str(tmp_path / "media"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path / "data"))
    monkeypatch.setenv("METADATA_DIR", str(tmp_path / "metadata"))
    monkeypatch.setenv("MOVIECLAW_TRANSCODE_DIR", str(tmp_path / "transcodes"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("TMDB_API_KEY", "test-key-not-used")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    reset_session_manager()

    from movieclaw_api.app import create_app

    with TestClient(create_app(), headers={"Accept-Language": "zh-Hans"}) as c:
        c.post(f"{_API}/auth/bootstrap", json=_ADMIN)
        yield c

    asyncio.get_event_loop_policy().new_event_loop().run_until_complete(
        get_session_manager().shutdown()
    )
    reset_session_manager()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


_counter = itertools.count(1)


async def _seed(
    tmp_path: Path,
    *,
    kind: str = "movie",
    versions: tuple[dict, ...] = ({},),
    year: int | None = 2024,
    content_rating: str | None = None,
) -> dict:
    """建库 + 条目 + 若干在位文件（每个 dict 是一个版本的台账字段覆盖），返回各 id。"""
    n = next(_counter)
    root = tmp_path / f"lib{n}"
    root.mkdir()
    async with get_database().session() as session:
        library = await LibraryRepository(session).create(
            name=f"库{n}", kind=kind, root_paths=[str(root)]
        )
        item = MediaItem(
            kind=kind, tmdb_id=n, title=f"示例{n}", original_title=f"Example{n}", year=year
        )
        session.add(item)
        await session.flush()
        if content_rating is not None:
            session.add(
                MediaMetadata(
                    media_item_id=item.id,
                    release_date=date(2024, 1, 1),
                    content_rating=content_rating,
                    scraped_at=utcnow(),
                )
            )
        file_ids = []
        for index, overrides in enumerate(versions):
            fields = {
                "name": f"Example{n}.v{index}.mkv",
                "container": "mkv",
                "resolution": "1080p",
                "season_number": 0,
                "episode_number": 0,
                **overrides,
            }
            path = root / fields.pop("name")
            if fields.pop("directory", False):
                (path / "BDMV").mkdir(parents=True)
            elif "text" in fields:
                path.write_text(fields.pop("text"))
            else:
                path.write_bytes(_DATA)
            for entry in fields.get("external_subtitles") or []:
                (root / entry["filename"]).write_text(_SRT, encoding="utf-8")
            row = LibraryFile(
                library_id=library.id,
                media_item_id=item.id,
                file_path=str(path),
                size_bytes=path.stat().st_size if path.is_file() else 0,
                source=FileSource.SCANNED,
                state=FileState.IN_PLACE,
                video_codec="h264",
                duration_seconds=600,
                audio_streams=[{"codec": "aac", "channels": 2, "default": True}],
                **fields,
            )
            session.add(row)
            await session.flush()
            file_ids.append(row.id)
        await session.commit()
        return {
            "library_id": library.id,
            "item_id": item.id,
            "file_ids": file_ids,
            "title": item.title,
        }


def seed(client: TestClient, tmp_path: Path, **kwargs) -> dict:
    return client.portal.call(partial(_seed, tmp_path, **kwargs))  # type: ignore[attr-defined]


def link(client: TestClient, item_id: int, **extra):
    return client.post(f"{_PB}/external-link", json={"media_item_id": item_id, **extra})


def ok_link(client: TestClient, item_id: int, **extra) -> dict:
    resp = link(client, item_id, **extra)
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def token_of(url: str) -> str:
    return parse_qs(urlsplit(url).query)["token"][0]


def relative(url: str) -> str:
    """测试客户端的基址就是 http://testserver：绝对地址去掉源，直接再请求一次。"""
    parts = urlsplit(url)
    assert f"{parts.scheme}://{parts.netloc}" == "http://testserver"
    return parts.path + (f"?{parts.query}" if parts.query else "")


def _login_member(client: TestClient, **caps) -> None:
    created = client.post(f"{_API}/members", json=_MEMBER)
    assert created.status_code == 200, created.text
    if caps:
        resp = client.put(f"{_API}/members/{created.json()['data']['id']}", json=caps)
        assert resp.status_code == 200, resp.text
    client.cookies.clear()
    assert client.post(f"{_API}/auth/login", json=_MEMBER).status_code == 200


# ---------------------------------------------------------------------------
# 主路径：电影
# ---------------------------------------------------------------------------


def test_movie_link_is_absolute_signed_for_that_file_and_streams_end_to_end(client, tmp_path):
    ids = seed(client, tmp_path)
    file_id = ids["file_ids"][0]
    before = time.time()
    data = ok_link(client, ids["item_id"])

    assert data["file_id"] == file_id
    assert data["title"] == f"{ids['title']} (2024)"
    assert data["container"] == "mkv"
    assert data["start_ms"] == 0
    assert data["duration_ms"] == 600_000
    url = data["stream_url"]
    name = data["file_name"]
    assert name.endswith(".v0.mkv")
    assert urlsplit(url).path == f"{_PB}/files/{file_id}/stream/{quote(name, safe='')}"
    assert url.startswith("http://testserver/")

    grant = client.portal.call(partial(verify_stream_token, token_of(url), file_id=file_id))
    assert grant is not None
    assert grant.external is True
    assert grant.device_id is None  # 不登记成网页实时会话
    assert grant.share_id is None and grant.session_id is None
    assert abs(grant.expires_at - (before + signing.STREAM_TOKEN_TTL_S)) < 5
    expires = datetime.fromisoformat(data["expires_at"].replace("Z", "+00:00"))
    assert expires == datetime.fromtimestamp(grant.expires_at, UTC)

    # 外部播放器拿到的就是这个地址：整取、Range 续拉都是原文件的字节
    client.cookies.clear()  # 播放器没有浏览器的登录 Cookie
    full = client.get(relative(url))
    assert full.status_code == 200
    assert full.content == _DATA
    ranged = client.get(relative(url), headers={"Range": "bytes=1000-1999"})
    assert ranged.status_code == 206
    assert ranged.content == _DATA[1000:2000]
    # HEAD 与不带文件名的老地址行为一致（直出端点本来就只认 GET）
    plain = f"{_PB}/files/{file_id}/stream?token={token_of(url)}"
    assert client.head(relative(url)).status_code == client.head(plain).status_code


@pytest.mark.parametrize(
    "segment",
    ["whatever.mp4", "%E4%B8%AD%E6%96%87%20name.mkv", "..%2F..%2Fetc%2Fpasswd", "..", "%2e%2e"],
)
def test_filename_segment_never_addresses_another_path(client, tmp_path, segment):
    """文件名段只做显示：随便写、写成穿越的样子，要么还是这个文件的字节，要么 404。"""
    ids = seed(client, tmp_path)
    token = token_of(ok_link(client, ids["item_id"])["stream_url"])
    resp = client.get(f"{_PB}/files/{ids['file_ids'][0]}/stream/{segment}?token={token}")
    assert resp.status_code in (200, 404), resp.status_code
    if resp.status_code == 200:
        assert resp.content == _DATA


def test_token_is_scoped_to_one_file_and_expires(client, tmp_path, monkeypatch):
    ids = seed(client, tmp_path, versions=({}, {"resolution": "720p"}))
    first, second = ids["file_ids"]
    token = token_of(ok_link(client, ids["item_id"])["stream_url"])
    assert client.get(f"{_PB}/files/{first}/stream/a.mkv?token={token}").status_code == 200
    # 同一部片的另一个版本也不行：授权范围是文件，不是条目
    assert client.get(f"{_PB}/files/{second}/stream/a.mkv?token={token}").status_code == 404
    assert client.get(f"{_PB}/files/{second}/stream?token={token}").status_code == 404
    assert client.get(f"{_PB}/files/{first}/stream/a.mkv?token={token}x").status_code == 404

    real_time = time.time
    monkeypatch.setattr(signing.time, "time", lambda: real_time() + signing.STREAM_TOKEN_TTL_S + 1)
    assert client.get(f"{_PB}/files/{first}/stream/a.mkv?token={token}").status_code == 404


def test_tokens_without_the_external_marker_still_verify(client, tmp_path):
    """升级前签出的 token（没有 "x"）照常可用，外部标记缺省为 False。"""
    ids = seed(client, tmp_path)
    file_id = ids["file_ids"][0]
    token = client.portal.call(partial(issue_stream_token, member_id=0, file_id=file_id))
    grant = client.portal.call(partial(verify_stream_token, token, file_id=file_id))
    assert grant is not None and grant.external is False
    assert client.get(f"{_PB}/files/{file_id}/stream/x.mkv?token={token}").status_code == 200


def test_origin_follows_the_address_the_browser_used(client, tmp_path):
    """容器内 nginx 带着浏览器访问的主机与协议转发；地址按它拼，外部播放器才连得回来。"""
    ids = seed(client, tmp_path)
    resp = client.post(
        f"{_PB}/external-link",
        json={"media_item_id": ids["item_id"]},
        headers={"X-Forwarded-Host": "nas.example.com:8443", "X-Forwarded-Proto": "https"},
    )
    data = resp.json()["data"]
    assert data["stream_url"].startswith("https://nas.example.com:8443/api/v1/playback/files/")
    # 主机头写坏了就退回本层看到的地址，不拼出一个畸形的 URL
    bad = client.post(
        f"{_PB}/external-link",
        json={"media_item_id": ids["item_id"]},
        headers={"X-Forwarded-Host": "evil host/x", "X-Forwarded-Proto": "javascript"},
    )
    assert bad.json()["data"]["stream_url"].startswith("http://testserver/")


def test_file_name_segment_is_sanitized():
    def name(path: str, container: str | None = "mkv") -> str:
        return routes_playback._link_file_name(LibraryFile(file_path=path, container=container))

    assert name("/m/Movie (2024).mkv") == "Movie (2024).mkv"
    assert name("/m/a\x00b\x1f..c.mkv") == "ab.c.mkv"
    assert name("/m/Show.S01E02.strm", "mp4") == "Show.S01E02.mp4"
    assert name("/m/...", "mp4") == "video.mp4"
    assert name("/m/..", None) == "video"


# ---------------------------------------------------------------------------
# 剧集、版本、续播
# ---------------------------------------------------------------------------


def test_episode_link_and_explicit_version(client, tmp_path):
    ids = seed(
        client,
        tmp_path,
        kind="tv",
        versions=(
            {"season_number": 1, "episode_number": 2, "resolution": "1080p"},
            {"season_number": 1, "episode_number": 2, "resolution": "2160p"},
            {"season_number": 1, "episode_number": 3},
        ),
    )
    hd, uhd, next_episode = ids["file_ids"]
    item_id = ids["item_id"]
    data = ok_link(client, item_id, season_number=1, episode_number=2)
    # 默认版本：同档取分辨率最高的（与全解码客户端开会话一致）
    assert data["file_id"] == uhd
    assert data["title"] == f"{ids['title']} S01E02"
    chosen = ok_link(client, item_id, season_number=1, episode_number=2, file_id=hd)
    assert chosen["file_id"] == hd
    assert client.get(relative(chosen["stream_url"])).content == _DATA
    # 别的集的文件不属于这个单元
    assert (
        link(client, item_id, season_number=1, episode_number=2, file_id=next_episode).status_code
        == 404
    )
    other = seed(client, tmp_path)
    assert (
        link(
            client, item_id, season_number=1, episode_number=2, file_id=other["file_ids"][0]
        ).status_code
        == 404
    )
    assert link(client, item_id, season_number=9, episode_number=9).status_code == 404


def test_resume_point_comes_from_the_watch_state(client, tmp_path):
    ids = seed(client, tmp_path)
    item_id = ids["item_id"]
    resp = client.post(
        f"{_PB}/progress",
        json={"media_item_id": item_id, "event": "stop", "position_ms": 123_000},
    )
    assert resp.status_code == 200, resp.text
    assert ok_link(client, item_id)["start_ms"] == 123_000


# ---------------------------------------------------------------------------
# 字幕
# ---------------------------------------------------------------------------


def test_text_subtitles_are_listed_with_working_urls_and_image_tracks_are_not(client, tmp_path):
    ids = seed(
        client,
        tmp_path,
        versions=(
            {
                "name": "Movie.mkv",
                "external_subtitles": [
                    {
                        "filename": "Movie.chs.srt",
                        "format": "srt",
                        "language": "chi",
                        "title": "简体",
                    },
                ],
                "subtitle_streams": [{"codec": "hdmv_pgs_subtitle", "language": "eng"}],
            },
        ),
    )
    data = ok_link(client, ids["item_id"])
    assert [(s["track"], s["format"], s["label"], s["language"]) for s in data["subtitles"]] == [
        ("external:Movie.chs.srt", "srt", "简体", "chi")
    ]
    url = data["subtitles"][0]["url"]
    assert url.startswith(f"http://testserver{_PB}/files/{ids['file_ids'][0]}/subtitles?")
    client.cookies.clear()
    resp = client.get(relative(url))
    assert resp.status_code == 200, resp.text
    assert "你好" in resp.text
    assert "-->" in resp.text and "," in resp.text.split("-->")[0]  # SRT 的毫秒逗号，不是 VTT


# ---------------------------------------------------------------------------
# 拒绝与放行
# ---------------------------------------------------------------------------


def test_disc_folder_is_refused_and_iso_is_allowed(client, tmp_path):
    folder = seed(
        client, tmp_path, versions=({"name": "Disc", "directory": True, "container": "bluray"},)
    )
    resp = link(client, folder["item_id"])
    assert resp.status_code == 409
    assert (
        resp.json()["message"]
        == "原盘目录（BDMV / VIDEO_TS）没有单个文件，外部播放器打不开，请用网页或 App 播放"
    )

    iso = seed(client, tmp_path, versions=({"name": "Disc.iso", "container": "iso"},))
    data = ok_link(client, iso["item_id"])
    assert data["file_name"] == "Disc.iso"
    assert client.get(relative(data["stream_url"])).content == _DATA


def test_default_version_skips_a_disc_folder_when_a_file_exists(client, tmp_path):
    ids = seed(
        client,
        tmp_path,
        versions=(
            {"name": "Disc", "directory": True, "container": "bluray", "resolution": "2160p"},
            {"name": "Movie.mkv", "resolution": "1080p"},
        ),
    )
    assert ok_link(client, ids["item_id"])["file_id"] == ids["file_ids"][1]
    assert link(client, ids["item_id"], file_id=ids["file_ids"][0]).status_code == 409


def test_broken_strm_is_refused_and_working_strm_is_linked(client, tmp_path):
    broken = seed(client, tmp_path, versions=({"name": "a.strm", "text": "# nothing here\n"},))
    resp = link(client, broken["item_id"])
    assert resp.status_code == 404
    assert resp.json()["message"].startswith("strm 用不了")

    good = seed(
        client, tmp_path, versions=({"name": "b.strm", "text": "https://pan.example.com/b.mkv\n"},)
    )
    data = ok_link(client, good["item_id"])
    assert data["file_name"] == "b.mkv"
    resp = client.get(relative(data["stream_url"]), follow_redirects=False)
    assert resp.status_code == 302
    assert resp.headers["location"] == "https://pan.example.com/b.mkv"


# ---------------------------------------------------------------------------
# 权限
# ---------------------------------------------------------------------------


def test_requires_login(client, tmp_path):
    ids = seed(client, tmp_path)
    client.cookies.clear()
    assert link(client, ids["item_id"]).status_code == 401


def test_member_without_library_access_gets_404(client, tmp_path):
    hidden = seed(client, tmp_path)
    shown = seed(client, tmp_path)
    _login_member(client, all_libraries=False, library_ids=[shown["library_id"]])
    assert link(client, hidden["item_id"]).status_code == 404
    data = ok_link(client, shown["item_id"])
    grant = client.portal.call(partial(verify_stream_token, token_of(data["stream_url"])))
    assert grant is not None and grant.member_id != 0


def test_member_age_limit_applies(client, tmp_path):
    adult = seed(client, tmp_path, content_rating="R")
    _login_member(client, content_age_limit=7)
    assert link(client, adult["item_id"]).status_code == 404


def test_share_guest_is_forbidden(client, tmp_path):
    """分享访客的主体进不了 require_login（路由层就是 401）；处理函数自身也拒绝分享主体，
    以免将来有人把它挂到分享路由下。"""
    ids = seed(client, tmp_path)
    principal = Principal(
        kind="share",
        name="share:x",
        is_admin=False,
        share=ShareGrant(
            share_id=1,
            slug="x",
            media_item_id=ids["item_id"],
            library_id=ids["library_id"],
            expires_at=utcnow(),
        ),
    )

    async def call():
        async with get_database().session() as session:
            await routes_playback.create_external_link(
                PlaybackExternalLinkRequest(media_item_id=ids["item_id"]),
                request=None,  # type: ignore[arg-type] -- 在用到之前就拒绝
                principal=principal,
                session=session,
            )

    with pytest.raises(ForbiddenException) as exc:
        client.portal.call(call)
    assert exc.value.status_code == 403


# ---------------------------------------------------------------------------
# 不留痕迹
# ---------------------------------------------------------------------------


def test_link_and_stream_leave_no_session_state_or_activity(client, tmp_path):
    activity.reset()  # 实时会话表是进程级的：同一进程里别的用例留下的不算
    ids = seed(client, tmp_path)
    data = ok_link(client, ids["item_id"])
    with client.stream(
        "GET", relative(data["stream_url"]), headers={"Range": "bytes=0-99"}
    ) as resp:
        assert resp.status_code == 206
        # 取流进行中：活动页上也没有这一路（不登记成网页播放）
        sessions, meters = activity.snapshot()
        assert not sessions and not meters
        resp.read()

    async def counts():
        async with get_database().session() as session:
            return [
                (await session.execute(select(func.count()).select_from(model))).scalar_one()
                for model in (PlaybackState, PlaybackLog, PlaybackMetric)
            ]

    assert client.portal.call(counts) == [0, 0, 0]
    assert not get_session_manager()._sessions

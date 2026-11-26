"""Jellyfin 兼容层个人评分测试（PR 5 / issue #1292 §7）。

覆盖：
- UserData 输出 Rating（1–10 原值）与 Likes（>= 6.5 为 true，未评分缺省/null）的数值边界；
- POST /UserItems/{id}/Rating（likes=true→10 / likes=false→1 / 大小写参数 / 省略清除 / 非法 400）；
- DELETE /UserItems/{id}/Rating（及 /Users/{userId}/Items/{id}/Rating、/emby 前缀别名）；
- 未登录 401、无权访问隐藏库 404、成员隔离；
- 评分后 UserData 立刻可读且不写播放进度；
- 经 Jellyfin 路径评分触发 library.item.rated / unrated 事件并映射为 UserDataSaved webhook。
"""

from __future__ import annotations

import inspect
import json
from datetime import UTC, datetime

from fastapi.testclient import TestClient
from sqlalchemy import select

from jellyfin.helpers import AUTH_HEADER, jf_login
from movieclaw_api import events
from movieclaw_api.services.auth import hash_password
from movieclaw_api.services.playback import marks as playback_marks
from movieclaw_api.services.webhook import jellyfin_formatter
from movieclaw_db.engine import get_database
from movieclaw_db.models import Member, PlaybackState
from movieclaw_jellyfin.catalog import JELLYFIN_LIKES_THRESHOLD, rating_to_likes
from movieclaw_jellyfin.ids import item_guid, library_guid
from movieclaw_kernel import DeliveryInfo, Origin
from movieclaw_playback.events import ClientInfo


def _auth(client: TestClient) -> dict[str, str]:
    return {"ApiKey": jf_login(client)}


def _create_member_and_login(
    client: TestClient, *, username: str, all_libraries: bool, allowed_libs: list[int] | None = None
) -> tuple[int, str]:
    async def _seed_member() -> int:
        async with get_database().session() as session:
            member = Member(
                username=username,
                display_name=username,
                password_hash=hash_password("member-pass"),
                all_libraries=all_libraries,
                allowed_library_ids=allowed_libs or [],
            )
            session.add(member)
            await session.commit()
            assert member.id is not None
            return member.id

    member_id = client.portal.call(_seed_member)
    resp = client.post(
        "/Users/AuthenticateByName",
        json={"Username": username, "Pw": "member-pass"},
        headers={"Authorization": AUTH_HEADER.replace("test-device-1", f"dev-{username}")},
    )
    assert resp.status_code == 200, resp.text
    return member_id, resp.json()["AccessToken"]


def test_rating_to_likes_threshold_boundary() -> None:
    """Likes 阈值按 Jellyfin 语义：>= 6.5 为 True，< 6.5 为 False，未评分为 None。"""
    assert JELLYFIN_LIKES_THRESHOLD == 6.5
    assert rating_to_likes(None) is None
    assert rating_to_likes(1) is False
    assert rating_to_likes(5) is False
    assert rating_to_likes(6) is False
    assert rating_to_likes(6.4) is False
    assert rating_to_likes(6.5) is True
    assert rating_to_likes(6.6) is True
    assert rating_to_likes(7) is True
    assert rating_to_likes(10) is True


def test_get_userdata_rating_and_likes_boundaries(client: TestClient, seeded: dict) -> None:
    """GET /Items/{id} 的 UserData 正确反映未评分、5、6、7、10 边界值（含电影与整剧）。"""
    auth = _auth(client)
    movie_id = seeded["movie"]
    show_id = seeded["show"]
    movie_gid = item_guid(movie_id)
    show_gid = item_guid(show_id)

    # 未评分：Rating / Likes 均为空（遵循本层 WhenWritingNull 省略约定）
    for gid in (movie_gid, show_gid):
        ud = client.get(f"/Items/{gid}", params=auth).json()["UserData"]
        assert ud.get("Rating") is None
        assert ud.get("Likes") is None
        assert "Rating" not in ud and "Likes" not in ud

    async def _set(media_id: int, value: int | None) -> None:
        async with get_database().session() as session:
            await playback_marks.set_rating(
                session,
                playback_marks.MarkTarget(media_id),
                member_id=0,
                client=ClientInfo(name="web"),
                rating=value,
            )

    # 数值边界：5 (<6.5→False), 6 (<6.5→False), 7 (>=6.5→True), 10 (>=6.5→True)
    for score, expected_likes in ((5, False), (6, False), (7, True), (10, True)):
        client.portal.call(_set, movie_id, score)
        ud = client.get(f"/Items/{movie_gid}", params=auth).json()["UserData"]
        assert ud["Rating"] == score
        assert ud["Likes"] is expected_likes

    # 整剧哨兵 (-1,-1) 同步投影到 Series.UserData
    client.portal.call(_set, show_id, 7)
    show_ud = client.get(f"/Items/{show_gid}", params=auth).json()["UserData"]
    assert show_ud["Rating"] == 7 and show_ud["Likes"] is True

    client.portal.call(_set, show_id, 5)
    show_ud = client.get(f"/Items/{show_gid}", params=auth).json()["UserData"]
    assert show_ud["Rating"] == 5 and show_ud["Likes"] is False

    # 清除后回到未评分
    client.portal.call(_set, movie_id, None)
    cleared = client.get(f"/Items/{movie_gid}", params=auth).json()["UserData"]
    assert cleared.get("Rating") is None and cleared.get("Likes") is None


def test_post_and_delete_rating_routes_without_writing_progress(
    client: TestClient, seeded: dict
) -> None:
    """POST likes=true/false、DELETE 清除、legacy 与 /emby 别名均可立即读回，且绝不写播放进度。"""
    auth = _auth(client)
    movie_id = seeded["movie"]
    show_id = seeded["show"]
    movie_gid = item_guid(movie_id)
    show_gid = item_guid(show_id)

    # POST likes=true → 10 / Likes=True
    resp = client.post(f"/UserItems/{movie_gid}/Rating", params={**auth, "likes": "true"})
    assert resp.status_code == 200, resp.text
    dto = resp.json()
    assert dto["Rating"] == 10 and dto["Likes"] is True
    assert dto["Played"] is False and dto["PlaybackPositionTicks"] == 0 and dto["PlayCount"] == 0

    # 立刻从 GET /Items/{id} 读到
    ud = client.get(f"/Items/{movie_gid}", params=auth).json()["UserData"]
    assert ud["Rating"] == 10 and ud["Likes"] is True

    # PascalCase ?Likes=false → 1 / Likes=False
    resp = client.post(f"/UserItems/{movie_gid}/Rating", params={**auth, "Likes": "false"})
    assert resp.status_code == 200, resp.text
    dto = resp.json()
    assert dto["Rating"] == 1 and dto["Likes"] is False
    ud = client.get(f"/Items/{movie_gid}", params=auth).json()["UserData"]
    assert ud["Rating"] == 1 and ud["Likes"] is False

    # 核验数据库 playback_state 行：未写任何播放进度
    async def _db_state(media_id: int) -> PlaybackState | None:
        async with get_database().session() as session:
            return (
                await session.execute(
                    select(PlaybackState).where(
                        PlaybackState.member_id == 0,
                        PlaybackState.media_item_id == media_id,
                    )
                )
            ).scalar_one_or_none()

    row = client.portal.call(_db_state, movie_id)
    assert row is not None
    assert row.user_rating == 1 and row.rated_at is not None
    assert (row.played, row.position_ms, row.play_count, row.last_played_at) == (False, 0, 0, None)

    # DELETE 清除评分
    resp = client.delete(f"/UserItems/{movie_gid}/Rating", params=auth)
    assert resp.status_code == 200, resp.text
    dto = resp.json()
    assert dto.get("Rating") is None and dto.get("Likes") is None
    ud = client.get(f"/Items/{movie_gid}", params=auth).json()["UserData"]
    assert ud.get("Rating") is None and ud.get("Likes") is None

    # Legacy 路径 + /emby 前缀别名（作用于整剧）
    uid = "0" * 32
    resp = client.post(f"/Users/{uid}/Items/{show_gid}/Rating", params={**auth, "likes": "true"})
    assert resp.status_code == 200 and resp.json()["Rating"] == 10
    resp = client.delete(f"/emby/UserItems/{show_gid}/Rating", params=auth)
    assert resp.status_code == 200 and resp.json().get("Rating") is None

    # 非法 likes 值返回 400；非条目 GUID（如库 GUID）返回 404
    assert (
        client.post(f"/UserItems/{movie_gid}/Rating", params={**auth, "likes": "maybe"}).status_code
        == 400
    )
    lib_gid = library_guid(seeded["movie_lib"])
    assert (
        client.post(f"/UserItems/{lib_gid}/Rating", params={**auth, "likes": "true"}).status_code
        == 404
    )
    assert client.delete(f"/UserItems/{lib_gid}/Rating", params=auth).status_code == 404


def test_rating_auth_and_library_permission_isolation(client: TestClient, seeded: dict) -> None:
    """未登录 401；成员对不可见库条目评分/删除 404 且不落库；成员间评分隔离。"""
    movie_id = seeded["movie"]
    movie_gid = item_guid(movie_id)

    # 1. 未登录 → 401
    assert (
        client.post(f"/UserItems/{movie_gid}/Rating", params={"likes": "true"}).status_code == 401
    )
    assert client.delete(f"/UserItems/{movie_gid}/Rating").status_code == 401

    # 2. 只授权剧集库的受限成员 → 对电影库条目无权限（404 且不落库）
    restricted_id, restricted_token = _create_member_and_login(
        client, username="restricted", all_libraries=False, allowed_libs=[seeded["tv_lib"]]
    )
    r_headers = {"X-Emby-Token": restricted_token}
    assert (
        client.post(
            f"/UserItems/{movie_gid}/Rating", params={"likes": "true"}, headers=r_headers
        ).status_code
        == 404
    )
    assert client.delete(f"/UserItems/{movie_gid}/Rating", headers=r_headers).status_code == 404

    async def _member_rows(member_id: int) -> list[PlaybackState]:
        async with get_database().session() as session:
            return list(
                (
                    await session.execute(
                        select(PlaybackState).where(PlaybackState.member_id == member_id)
                    )
                ).scalars()
            )

    assert client.portal.call(_member_rows, restricted_id) == []

    # 3. 成员隔离：全库成员评 1 分，超管评 10 分，各自 UserData 互不干扰
    _, bob_token = _create_member_and_login(client, username="bob", all_libraries=True)
    admin_headers = {"X-Emby-Token": jf_login(client)}
    bob_headers = {"X-Emby-Token": bob_token}

    assert (
        client.post(
            f"/UserItems/{movie_gid}/Rating", params={"likes": "true"}, headers=admin_headers
        ).status_code
        == 200
    )
    assert (
        client.post(
            f"/UserItems/{movie_gid}/Rating", params={"likes": "false"}, headers=bob_headers
        ).status_code
        == 200
    )
    admin_ud = client.get(f"/Items/{movie_gid}", headers=admin_headers).json()["UserData"]
    bob_ud = client.get(f"/Items/{movie_gid}", headers=bob_headers).json()["UserData"]
    assert (admin_ud["Rating"], admin_ud["Likes"]) == (10, True)
    assert (bob_ud["Rating"], bob_ud["Likes"]) == (1, False)


def test_jellyfin_rating_triggers_userdata_saved_webhook(
    client: TestClient, seeded: dict, monkeypatch
) -> None:
    """经 Jellyfin 路径评分与清除触发 rated/unrated 事件并渲染为 UserDataSaved webhook。"""
    captured: list[tuple[str, dict]] = []

    async def _capture(session, event, build, *, occurred_at=None):  # type: ignore[no-untyped-def]
        if event.name not in ("library.item.rated", "library.item.unrated"):
            return
        payload = build()
        if inspect.isawaitable(payload):
            payload = await payload
        if payload is not None:
            captured.append((event.name, payload.model_dump(mode="json")))

    monkeypatch.setattr(events, "publish", _capture)
    auth = _auth(client)
    movie_gid = item_guid(seeded["movie"])

    assert (
        client.post(f"/UserItems/{movie_gid}/Rating", params={**auth, "likes": "true"}).status_code
        == 200
    )
    assert client.delete(f"/UserItems/{movie_gid}/Rating", params=auth).status_code == 200

    assert [name for name, _ in captured] == ["library.item.rated", "library.item.unrated"]
    rated_data, unrated_data = captured[0][1], captured[1][1]
    assert rated_data["rating"] == 10 and rated_data["previous_rating"] is None
    assert rated_data["client"]["name"] == "Infuse"
    assert unrated_data["rating"] is None and unrated_data["previous_rating"] == 10

    # 通过真实 Jellyfin webhook 格式化器渲染，验证端到端输出 UserDataSaved
    template = (
        '{"NotificationType":"{{NotificationType}}","ItemId":"{{ItemId}}",'
        '"ItemType":"{{ItemType}}","ClientName":"{{ClientName}}"}'
    )
    server = {"id": "srv-1", "name": "MovieClaw", "version": "1.0", "url": "", "username": "admin"}

    async def _render_all():
        out = []
        for idx, (event_name, data) in enumerate(captured, start=1):
            info = DeliveryInfo(
                event_id=f"evt-{idx}",
                name=event_name,
                occurred_at=datetime.now(UTC).isoformat(),
                origin=Origin(kind="host"),
            )
            rendered = await jellyfin_formatter.render(info, data, server, template)
            assert len(rendered) == 1
            out.append(json.loads(rendered[0][0].decode("utf-8")))
        return out

    webhooks = client.portal.call(_render_all)
    assert webhooks == [
        {
            "NotificationType": "UserDataSaved",
            "ItemId": movie_gid,
            "ItemType": "Movie",
            "ClientName": "Infuse",
        },
        {
            "NotificationType": "UserDataSaved",
            "ItemId": movie_gid,
            "ItemType": "Movie",
            "ClientName": "Infuse",
        },
    ]

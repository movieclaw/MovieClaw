"""自托管实时通知（cloud-push.md §4.1）的端到端测试。

不连 MovieClaw Cloud、不配任何中继：Android App 登记成实时通知设备，推送写进它的发件箱，
从 ``GET /push/me/stream`` 补发 + 实时送出，``POST /push/me/ack`` 之后不再补发。

TestClient 会等响应体结束才返回，所以把单条连接的最长时间缩到一两秒：连接到点正常结束，
正好验证「补发 → 实时 → 心跳 → 收尾」整条链路。
"""

from __future__ import annotations

import json
import threading
import time
from collections.abc import Callable
from datetime import timedelta

import httpx
import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box

_AUTH = "/api/v1/auth"
_ADMIN = {"username": "admin", "password": "s3cret-pass"}
_MEMBER = {"username": "family", "password": "family-pass-1"}
_STREAM = "/api/v1/push/me/stream"


@pytest.fixture
def client(tmp_path, monkeypatch):  # type: ignore[no-untyped-def]
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'push.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    from movieclaw_api.services.push import channels, engine, me, outbox

    channels.reset_runtime()
    me.reset_state()
    engine.reset_state()
    monkeypatch.setattr(outbox, "MAX_CONNECTION_S", 1.5)
    monkeypatch.setattr(outbox, "HEARTBEAT_S", 0.4)
    monkeypatch.setattr(outbox, "POLL_S", 0.1)
    from movieclaw_api.app import create_app

    with TestClient(create_app()) as c:
        c.post(f"{_AUTH}/bootstrap", json=_ADMIN)
        c.post(f"{_AUTH}/login", json=_ADMIN)
        yield c
    engine.reset_state()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


def _data(resp: httpx.Response) -> dict:
    assert resp.status_code == 200, resp.text
    return resp.json()["data"]


def _as_app(client: TestClient, bearer: str, method: str, url: str, **kwargs) -> httpx.Response:  # type: ignore[no-untyped-def]
    """以 App 的身份请求：只带设备令牌，不带浏览器的会话 Cookie。"""
    saved = dict(client.cookies)
    client.cookies.clear()
    headers = {**kwargs.pop("headers", {}), "Authorization": f"Bearer {bearer}"}
    try:
        return client.request(method, url, headers=headers, **kwargs)
    finally:
        for name, value in saved.items():
            client.cookies.set(name, value)


def _app_login(
    client: TestClient, who: dict, *, installation: str, name: str, kind: str = "android"
) -> str:
    saved = dict(client.cookies)
    client.cookies.clear()
    try:
        resp = client.post(
            f"{_AUTH}/device/login",
            json={**who, "client": {"kind": kind, "installation_id": installation, "name": name}},
        )
    finally:
        for cookie, value in saved.items():
            client.cookies.set(cookie, value)
    return _data(resp)["token"]


def _enable_stream(client: TestClient, bearer: str, *, on: bool = True) -> dict:
    return _data(
        _as_app(
            client,
            bearer,
            "PUT",
            "/api/v1/push/me/registration",
            json={"permission": "authorized", "stream": on},
        )
    )


def _call(client: TestClient, fn):  # type: ignore[no-untyped-def]
    assert client.portal is not None
    return client.portal.call(fn)


def _notify(
    client: TestClient, members: set[int], title: str, event: str = "subscription.fulfilled"
) -> None:
    """在应用的事件循环里推一条（和业务代码一样走 notify）。"""
    from movieclaw_api.services.push.notify import AlertContent, notify

    async def build(_session, _member_id: int) -> AlertContent:  # type: ignore[no-untyped-def]
        return AlertContent(
            title=title, body="正文", open="/library/1/item/2", thread="t", level="passive"
        )

    async def run() -> None:
        notify(event, set(members), build, collapse=("item", title))

    _call(client, run)


def _rows(client: TestClient) -> list:
    from sqlmodel import select

    from movieclaw_db.engine import get_database
    from movieclaw_db.models import PushOutbox

    async def go() -> list:
        async with get_database().session() as session:
            return list(
                (await session.execute(select(PushOutbox).order_by(PushOutbox.id))).scalars()
            )

    return _call(client, go)


def _wait(predicate: Callable[[], bool], timeout: float = 8.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("等待超时")


def _parse(body: str) -> list[dict]:
    """把 SSE 文本拆成帧：注释行记成 ``{"comment": ...}``。"""
    frames: list[dict] = []
    for block in body.split("\n\n"):
        if not block.strip():
            continue
        frame: dict = {}
        for line in block.split("\n"):
            if line.startswith(":"):
                frame["comment"] = line[1:].strip()
            else:
                key, _, value = line.partition(": ")
                frame[key] = value
        frames.append(frame)
    return frames


def _notifications(frames: list[dict]) -> list[dict]:
    return [json.loads(f["data"]) for f in frames if f.get("event") == "notification"]


# ----------------------------------------------------------------------
# 登记
# ----------------------------------------------------------------------


def test_stream_registration_and_status(client: TestClient) -> None:
    bearer = _app_login(client, _ADMIN, installation="inst-vivo-1", name="vivo X200")
    # 没登记就连：409，App 据此先登记
    assert _as_app(client, bearer, "GET", _STREAM).status_code == 409
    view = _enable_stream(client, bearer)
    assert view == {
        "registered": True,
        "status": "ok",
        "status_text": "能收到",
        "channel_name": "实时连接",
    }
    # 服务器没连云、没有中继也算能收到通知
    mine = _data(client.get("/api/v1/push/me"))
    assert mine["instance_ready"] is True and mine["ready_devices"] == 1
    listed = _data(client.get(f"{_AUTH}/devices"))
    phone = next(d for d in listed if d["name"] == "vivo X200")
    assert phone["push"] == {"status": "ok", "status_text": "能收到"}

    # iOS 有 APNs，不能开实时通知；网页会话不能登记
    ios = _app_login(client, _ADMIN, installation="inst-iphone-1", name="iPhone", kind="ios")
    resp = _as_app(
        client,
        ios,
        "PUT",
        "/api/v1/push/me/registration",
        json={"permission": "authorized", "stream": True},
    )
    assert resp.status_code == 400
    assert _as_app(client, ios, "GET", _STREAM).status_code == 404
    resp = client.put(
        "/api/v1/push/me/registration", json={"permission": "authorized", "stream": True}
    )
    assert resp.status_code == 403
    # 带令牌又要实时通知：说不通
    resp = _as_app(
        client,
        bearer,
        "PUT",
        "/api/v1/push/me/registration",
        json={"permission": "authorized", "stream": True, "token": "ab" * 32},
    )
    assert resp.status_code == 400

    # 系统通知权限关了：显示出来、不再写发件箱
    resp = _as_app(
        client,
        bearer,
        "PUT",
        "/api/v1/push/me/registration",
        json={"permission": "denied", "stream": True},
    )
    assert _data(resp)["status"] == "permission_denied"
    _notify(client, {0}, "关了权限")
    time.sleep(0.3)
    assert all(r.payload["title"] != "关了权限" for r in _rows(client))

    # 关掉实时通知：不再算能收到
    _enable_stream(client, bearer, on=False)
    mine = _data(client.get("/api/v1/push/me"))
    assert mine["ready_devices"] == 0 and mine["instance_ready"] is False
    assert _as_app(client, bearer, "GET", _STREAM).status_code == 409


def test_unauthenticated_stream_rejected(client: TestClient) -> None:
    client.cookies.clear()
    assert client.get(_STREAM).status_code == 401
    assert client.post("/api/v1/push/me/ack", json={"up_to": 1}).status_code == 401


# ----------------------------------------------------------------------
# 写发件箱：只给实时通知设备，遵守偏好
# ----------------------------------------------------------------------


def test_outbox_only_for_stream_devices_and_respects_preferences(client: TestClient) -> None:
    stream_bearer = _app_login(client, _ADMIN, installation="inst-vivo-1", name="vivo")
    _app_login(client, _ADMIN, installation="inst-pixel-1", name="Pixel（没开实时通知）")
    _enable_stream(client, stream_bearer)
    _notify(client, {0}, "沙丘")
    _wait(lambda: len(_rows(client)) == 1)
    rows = _rows(client)
    device_ids = {r.login_device_id for r in rows}
    assert len(device_ids) == 1
    payload = rows[0].payload
    assert payload["title"] == "沙丘" and payload["body"] == "正文"
    assert payload["event"] == "subscription.fulfilled"
    assert payload["deeplink"] == "/library/1/item/2"
    assert payload["priority"] == "passive" and payload["thread"] == "t"
    assert len(payload["collapse"]) == 16  # 和中继同一个 collapse_id
    assert payload["account"]["id"] == "0" and payload["server"]["name"]

    # 关掉「入库完成」：不再写
    off = {"events": {"subscription.fulfilled": False}}
    _data(client.put("/api/v1/push/me/preferences", json=off))
    _notify(client, {0}, "奥本海默")
    time.sleep(0.4)
    assert len(_rows(client)) == 1
    # 别人的事件不写到我的设备
    on = {"events": {"subscription.fulfilled": True}}
    _data(client.put("/api/v1/push/me/preferences", json=on))
    _notify(client, {12345}, "不是我的")
    time.sleep(0.4)
    assert len(_rows(client)) == 1


# ----------------------------------------------------------------------
# 实时连接：补发 → 实时 → 心跳；确认后不再补发
# ----------------------------------------------------------------------


def test_stream_replays_then_streams_live_with_heartbeat(client: TestClient) -> None:
    bearer = _app_login(client, _ADMIN, installation="inst-vivo-1", name="vivo")
    _enable_stream(client, bearer)
    _notify(client, {0}, "第一条")
    _wait(lambda: len(_rows(client)) == 1)
    _notify(client, {0}, "第二条")
    _wait(lambda: len(_rows(client)) == 2)
    first, second = (r.id for r in _rows(client))

    # 连着的时候再来一条：应该实时送到
    timer = threading.Timer(0.6, lambda: _notify(client, {0}, "实时的"))
    timer.start()
    started = time.time()
    resp = _as_app(client, bearer, "GET", _STREAM, params={"since": 0})
    timer.join()
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("text/event-stream")
    assert time.time() - started >= 1.4  # 到连接时长上限才正常结束
    frames = _parse(resp.text)
    assert frames[0] == {"comment": "connected"}
    items = _notifications(frames)
    assert [i["title"] for i in items] == ["第一条", "第二条", "实时的"]
    assert [i["id"] for i in items[:2]] == [first, second]
    ids = [f["id"] for f in frames if f.get("event") == "notification"]
    assert ids == [str(i["id"]) for i in items]
    assert any(f.get("comment") == "heartbeat" for f in frames)

    # 游标：since 之后的才补发；Last-Event-ID 同义（取两者较大的）
    resp = _as_app(client, bearer, "GET", _STREAM, params={"since": first})
    assert [i["title"] for i in _notifications(_parse(resp.text))] == ["第二条", "实时的"]
    resp = _as_app(client, bearer, "GET", _STREAM, headers={"Last-Event-ID": str(items[-1]["id"])})
    assert _notifications(_parse(resp.text)) == []

    # 确认到第二条：之后从头连也只补发没确认的
    ack = _as_app(client, bearer, "POST", "/api/v1/push/me/ack", json={"up_to": second})
    assert _data(ack) == {"acked": 2}
    resp = _as_app(client, bearer, "GET", _STREAM)
    assert [i["title"] for i in _notifications(_parse(resp.text))] == ["实时的"]


def test_other_accounts_cannot_read_or_ack(client: TestClient) -> None:
    resp = client.post("/api/v1/members", json={**_MEMBER, "nickname": "家人"})
    assert resp.status_code in (200, 201), resp.text
    member_id = resp.json()["data"]["id"]
    mine = _app_login(client, _ADMIN, installation="inst-vivo-admin", name="管理员的 vivo")
    theirs = _app_login(client, _MEMBER, installation="inst-vivo-family", name="家人的 vivo")
    _enable_stream(client, mine)
    _enable_stream(client, theirs)
    _notify(client, {0}, "给管理员的")
    _wait(lambda: len(_rows(client)) == 1)
    admin_row = _rows(client)[0].id
    # 家人的连接看不到，确认管理员的 id 也动不了管理员的发件箱
    resp = _as_app(client, theirs, "GET", _STREAM)
    assert _notifications(_parse(resp.text)) == []
    assert (
        _data(_as_app(client, theirs, "POST", "/api/v1/push/me/ack", json={"up_to": admin_row}))[
            "acked"
        ]
        == 0
    )
    resp = _as_app(client, mine, "GET", _STREAM)
    assert [i["title"] for i in _notifications(_parse(resp.text))] == ["给管理员的"]
    # 家人自己的
    _notify(client, {member_id}, "给家人的")
    _wait(lambda: len(_rows(client)) == 2)
    resp = _as_app(client, theirs, "GET", _STREAM)
    assert [i["title"] for i in _notifications(_parse(resp.text))] == ["给家人的"]


def test_test_push_goes_through_outbox(client: TestClient) -> None:
    bearer = _app_login(client, _ADMIN, installation="inst-vivo-1", name="vivo")
    _enable_stream(client, bearer)
    result = _data(_as_app(client, bearer, "POST", "/api/v1/push/me/test"))
    # 手机没连着：已进发件箱，连上后补发
    assert result["sent"] == 1
    assert result["results"][0]["result"] == "queued"
    resp = _as_app(client, bearer, "GET", _STREAM)
    items = _notifications(_parse(resp.text))
    assert items[0]["title"] == "测试通知" and items[0]["event"] == "test"
    assert items[0]["deeplink"] == "/settings/notifications"


# ----------------------------------------------------------------------
# 清理
# ----------------------------------------------------------------------


def test_pruning_and_clear_on_disable(client: TestClient, monkeypatch) -> None:  # type: ignore[no-untyped-def]
    from movieclaw_api.services.push import outbox
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import PushOutbox, utcnow

    monkeypatch.setattr(outbox, "MAX_PENDING", 3)
    bearer = _app_login(client, _ADMIN, installation="inst-vivo-1", name="vivo")
    _enable_stream(client, bearer)
    device_id = int(
        next(d["id"] for d in _data(client.get(f"{_AUTH}/devices")) if d["name"] == "vivo")[3:]
    )

    async def write(n: int, *, age: timedelta | None = None, delivered: bool = False) -> None:
        async with get_database().session() as session:
            for i in range(n):
                row_id = await outbox.enqueue(session, device_id, {"title": f"#{i}"})
                if age is not None or delivered:
                    row = await session.get(PushOutbox, row_id)
                    assert row is not None
                    if age is not None:
                        row.created_at = utcnow() - age
                    if delivered:
                        row.delivered_at = utcnow()
            await session.commit()

    # 未送达的最多留 3 条：丢最旧的
    _call(client, lambda: write(5))
    assert [r.payload["title"] for r in _rows(client)] == ["#2", "#3", "#4"]
    last = _rows(client)[-1].id
    # 过期的、已送达的在下一次写入时清掉；id 不回退
    _call(client, lambda: write(1, age=timedelta(days=8)))
    assert len(_rows(client)) == 3
    _call(client, lambda: write(1, delivered=True))
    _call(client, lambda: write(1))
    rows = _rows(client)
    assert all(r.delivered_at is None for r in rows)
    assert all(r.created_at > utcnow() - timedelta(days=1) for r in rows)
    assert rows[-1].id > last
    # 关掉实时通知：发件箱清空
    _enable_stream(client, bearer, on=False)
    assert _rows(client) == []
    # 注销设备：随行删除（外键级联）
    _enable_stream(client, bearer)
    _call(client, lambda: write(2))
    assert len(_rows(client)) == 2
    resp = client.delete(f"{_AUTH}/devices/ld-{device_id}")
    assert resp.status_code == 200, resp.text
    assert _rows(client) == []


# ----------------------------------------------------------------------
# 状态快照（event: status，Android 常驻通知）
# ----------------------------------------------------------------------


def _task(
    title: str,
    state: str,
    *,
    progress: float,
    size: int,
    speed: int,
    eta=None,
    episodes=(),
    source="subscription",
) -> dict:  # type: ignore[no-untyped-def]
    return {
        "name": f"{title}.torrent",
        "media_title": title,
        "state": state,
        "source": source,
        "progress": progress,
        "size_bytes": size,
        "dlspeed_bytes": speed,
        "eta_seconds": eta,
        "subscriptions": [{"units": [{"season_number": 1, "episode_number": e} for e in episodes]}]
        if episodes
        else [],
    }


def _statuses(frames: list[dict]) -> list[dict]:
    return [json.loads(f["data"]) for f in frames if f.get("event") == "status"]


def _fake_downloads(monkeypatch, items: list[dict]) -> list[int]:  # type: ignore[no-untyped-def]
    """下载器读数换成固定的；返回调用计数（读了几次下载器）。"""
    from movieclaw_api.services import download_tasks

    calls = [0]

    async def snapshot(_session):  # type: ignore[no-untyped-def]
        calls[0] += 1
        return {"items": list(items), "sources": []}

    monkeypatch.setattr(download_tasks, "download_task_snapshot", snapshot)
    return calls


def _seed_today(client: TestClient) -> None:
    """两个库：全员可见的剧集库（今天入库 3 集、2 部），只给选定成员的库（今天 1 部电影）。"""
    from datetime import timedelta as _td

    from movieclaw_db.engine import get_database
    from movieclaw_db.models import FileSource, LibraryFile, MediaItem, utcnow
    from movieclaw_db.repositories.library_repo import LibraryRepository

    async def go() -> None:
        async with get_database().session() as session:
            repo = LibraryRepository(session)
            shows = await repo.create(name="剧集", kind="tv", root_paths=["/media/tv"])
            private = await repo.create(name="私人", kind="movie", root_paths=["/media/private"])
            private.access_mode = "selected"
            items = [
                MediaItem(kind="tv", tmdb_id=9100 + i, title=t, original_title=t, year=2024)
                for i, t in enumerate(["遮天", "仙逆", "私藏电影"])
            ]
            session.add_all(items)
            await session.commit()
            for item in items:
                await session.refresh(item)
            zhetian, xianni, movie = items
            rows = [
                (shows.id, zhetian.id, 1, 135, utcnow()),
                (shows.id, zhetian.id, 1, 136, utcnow()),
                # 同一集的第二个版本：不重复算
                (shows.id, zhetian.id, 1, 136, utcnow()),
                (shows.id, xianni.id, 1, 160, utcnow()),
                # 昨天以前的不算
                (shows.id, xianni.id, 1, 159, utcnow() - _td(days=2)),
                (private.id, movie.id, 0, 0, utcnow()),
            ]
            for n, (library_id, item_id, season, episode, created) in enumerate(rows):
                session.add(
                    LibraryFile(
                        library_id=library_id,
                        media_item_id=item_id,
                        season_number=season,
                        episode_number=episode,
                        file_path=f"/media/x/{n}.mkv",
                        size_bytes=1,
                        source=FileSource.IMPORTED,
                        created_at=created,
                    )
                )
            await session.commit()

    _call(client, go)


def test_status_first_frame_visibility_and_shared_snapshot(client: TestClient, monkeypatch) -> None:  # type: ignore[no-untyped-def]
    calls = _fake_downloads(
        monkeypatch,
        [
            _task(
                "遮天",
                "downloading",
                progress=0.41,
                size=1000,
                speed=2_000_000,
                eta=540,
                episodes=(135,),
            ),
            _task("仙逆", "stalled", progress=0.0, size=1000, speed=0, episodes=(160,)),
            _task(
                "牧神记",
                "downloading",
                progress=0.78,
                size=2000,
                speed=4_200_000,
                eta=120,
                episodes=(12, 13),
            ),
            # 刷流做种、已下完等入库的：不算进行中
            _task("刷流", "downloading", progress=0.5, size=9000, speed=9_000_000, source="boost"),
            _task("下完了", "completed", progress=1.0, size=1000, speed=0),
        ],
    )
    _seed_today(client)
    resp = client.post("/api/v1/members", json={**_MEMBER, "nickname": "家人"})
    assert resp.status_code in (200, 201), resp.text
    admin = _app_login(client, _ADMIN, installation="inst-admin", name="管理员的 vivo")
    family = _app_login(client, _MEMBER, installation="inst-family", name="家人的 vivo")
    _enable_stream(client, admin)
    _enable_stream(client, family)
    _notify(client, {0}, "补发的")
    _wait(lambda: len(_rows(client)) == 1)

    frames = _parse(_as_app(client, admin, "GET", _STREAM).text)
    # 首帧：连上的注释之后先是状态，再补发通知；状态不带 id（不动通知游标）
    assert frames[0] == {"comment": "connected"}
    assert frames[1]["event"] == "status" and "id" not in frames[1]
    assert frames[2]["event"] == "notification"
    (mine,) = _statuses(frames)  # 内容没变：一小时连接里只发这一帧
    assert mine["server"]
    assert mine["today"] == {"imported": 4, "updated": 3}
    assert mine["downloads"] == {
        "active": 3,
        "speed": 6_200_000,
        "progress": round((0.41 * 1000 + 0.78 * 2000) / 4000, 3),
        "items": [
            {
                "title": "牧神记",
                "episode": "E12 等 2 集",
                "progress": 0.78,
                "eta": 120,
                "state": "downloading",
            },
            {
                "title": "遮天",
                "episode": "E135",
                "progress": 0.41,
                "eta": 540,
                "state": "downloading",
            },
            {"title": "仙逆", "episode": "E160", "progress": 0.0, "eta": None, "state": "stalled"},
        ],
    }

    # 成员：看不到下载（同 dl.tasks 只给管理员），今天入库只数看得到的库
    (theirs,) = _statuses(_parse(_as_app(client, family, "GET", _STREAM).text))
    assert theirs["downloads"] is None
    assert theirs["today"] == {"imported": 3, "updated": 2}

    # 断线重连：新连接的首帧照样立刻有状态；快照共享，没有重新读下载器
    again = _parse(_as_app(client, admin, "GET", _STREAM).text)
    assert again[1]["event"] == "status" and _statuses(again) == [mine]
    assert calls[0] == 1


def test_status_pushes_count_changes_now_and_throttles_progress(
    client: TestClient, monkeypatch
) -> None:  # type: ignore[no-untyped-def]
    from movieclaw_api.services.push import status

    monkeypatch.setattr(status, "REFRESH_S", 0.05)
    monkeypatch.setattr(status, "PROGRESS_EVERY_S", 60.0)
    items = [_task("遮天", "downloading", progress=0.1, size=1000, speed=100, episodes=(135,))]
    _fake_downloads(monkeypatch, items)
    bearer = _app_login(client, _ADMIN, installation="inst-vivo-1", name="vivo")
    _enable_stream(client, bearer)

    def progress_only() -> None:
        items[0] = _task("遮天", "downloading", progress=0.5, size=1000, speed=900, episodes=(135,))

    def new_task() -> None:
        items.append(_task("仙逆", "queued", progress=0.0, size=1000, speed=0, episodes=(160,)))

    timers = [threading.Timer(0.3, progress_only), threading.Timer(0.8, new_task)]
    for t in timers:
        t.start()
    frames = _parse(_as_app(client, bearer, "GET", _STREAM).text)
    for t in timers:
        t.join()
    sent = _statuses(frames)
    # 只变进度：60 秒内不再发；多了一个任务：立刻发（带上最新进度）
    assert [s["downloads"]["active"] for s in sent] == [1, 2]
    assert sent[1]["downloads"]["items"][0]["progress"] == 0.5


def test_status_throttle_and_summary_units() -> None:
    from movieclaw_api.services.push import status

    def data(progress: float, active: int = 1) -> dict:
        return {
            "server": "NAS",
            "today": {"imported": 0, "updated": 0},
            "downloads": {
                "active": active,
                "speed": 1,
                "progress": progress,
                "items": [
                    {
                        "title": "遮天",
                        "episode": "E1",
                        "progress": progress,
                        "eta": 1,
                        "state": "downloading",
                    }
                ],
            },
        }

    throttle = status.Throttle()
    assert throttle.frame(None, 0) is None  # 还没有快照：不发假的
    first = throttle.frame(data(0.1), 0)
    assert first is not None and first.startswith("event: status\ndata: ")
    assert throttle.frame(data(0.1), 1) is None  # 没变
    assert throttle.frame(data(0.2), 29) is None  # 只变进度，没到 30 秒
    assert throttle.frame(data(0.3), 31) is not None  # 到了
    assert throttle.frame(data(0.3, active=2), 32) is not None  # 个数变了，立刻

    empty = status.summarize([])
    assert empty == {"active": 0, "speed": 0, "progress": None, "items": []}
    # 电影 / 手动下载没有集号；排序：在下的在前，暂停的在后
    summary = status.summarize(
        [
            {
                "name": "x",
                "media_title": None,
                "state": "paused",
                "progress": None,
                "size_bytes": None,
            },
            {
                "name": "奥本海默.mkv",
                "media_title": "奥本海默",
                "state": "downloading",
                "progress": 0.2,
                "size_bytes": None,
            },
        ]
    )
    assert [(i["title"], i["episode"], i["state"]) for i in summary["items"]] == [
        ("奥本海默", "", "downloading"),
        ("x", "", "paused"),
    ]
    assert summary["progress"] is None

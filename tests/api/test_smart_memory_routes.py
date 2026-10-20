"""智能订阅记忆：真实 HTTP 接口 → 服务 → 临时数据库（docs/design/smart-subscription-memory.md）。"""

from __future__ import annotations

import httpx
import pytest
from fastapi.testclient import TestClient
from tests.api.smart_memory_fixture import ROUTES

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.auth import reset_auth_state
from movieclaw_api.settings.store import reset_setting_store
from movieclaw_db.crypto import reset_secret_box
from movieclaw_media.tmdb import TmdbClient

BASE = "/api/v1/subscriptions"


def _tmdb() -> TmdbClient:
    def handler(request: httpx.Request) -> httpx.Response:
        payload = ROUTES.get(request.url.path)
        return httpx.Response(200 if payload else 404, json=payload or {})

    return TmdbClient("0123456789abcdef0123456789abcdef", transport=httpx.MockTransport(handler))


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'memory.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    from movieclaw_api.api.routes import subscriptions as routes
    from movieclaw_api.app import create_app

    monkeypatch.setattr(routes, "get_tmdb_client", _tmdb)
    with TestClient(create_app()) as test_client:
        assert (
            test_client.post(
                "/api/v1/auth/bootstrap", json={"username": "admin", "password": "s3cret-pass"}
            ).status_code
            == 200
        )
        yield test_client
    reset_setting_store()
    reset_secret_box()
    reset_auth_state()
    get_settings.cache_clear()


def _data(response):
    assert response.status_code == 200, response.text
    return response.json()["data"]


def _defaults(client, **overrides):
    current = _data(client.get(f"{BASE}/smart-defaults"))
    body = {
        "movie_revision": current["movie_revision"],
        "tv_revision": current["tv_revision"],
        "resolution": "2160p",
        "source": "web-dl",
        "allow_upgrade": True,
        "strict_resolution": False,
        "movie_wait_seconds": 86400,
        "tv_wait_seconds": 10800,
        **overrides,
    }
    return _data(client.put(f"{BASE}/smart-defaults", json=body))


def _preview(client, ref):
    return _data(client.post(f"{BASE}/title-preview", json={"title_ref": ref}))["smart"]


def _subscribe(client, ref, plan, **extra):
    body = {
        "title_ref": ref,
        "selection_mode": "smart",
        "smart_profile_revision": plan["profile_revision"],
        "smart_memory_revision": plan["memory_revision"],
        **extra,
    }
    if ref.startswith("tmdb:tv"):
        body["selected_seasons"] = [1]
    return _data(client.post(BASE, json=body))["subscription"]


def test_one_settings_set_for_movies_and_tv(client):
    assert _data(client.get(f"{BASE}/smart-defaults"))["configured"] is False
    unset = _preview(client, "tmdb:movie:701")
    assert unset["configured"] is False and unset["can_edit"] is True
    saved = _defaults(client, resolution="1080p", tv_wait_seconds=7200)
    assert saved["configured"] and saved["movie_revision"] == saved["tv_revision"] == 1
    assert saved["resolution"] == "1080p" and saved["tv_wait_seconds"] == 7200
    # 旧客户端按类型读的接口看到同一套画质
    for kind, wait in (("movie", 86400), ("tv", 7200)):
        profile = _data(client.get(f"{BASE}/smart-profiles/{kind}"))
        assert profile["preferences"]["resolution"] == "1080p"
        assert profile["preferences"]["wait_seconds"] == wait
    stale = client.put(
        f"{BASE}/smart-defaults",
        json={
            "movie_revision": 0,
            "tv_revision": 0,
            "resolution": "2160p",
            "source": "web-dl",
            "movie_wait_seconds": 0,
            "tv_wait_seconds": 0,
        },
    )
    assert stale.status_code == 409
    plan = _preview(client, "tmdb:tv:804")
    assert plan["wait_label"] == "最多等 2 小时 · 达标后停止洗版"
    _defaults(client, resolution="1080p", tv_wait_seconds=7200, strict_resolution=True)
    strict = _preview(client, "tmdb:tv:804")["wait_label"]
    assert strict == "最多等 2 小时 · 达标后停止洗版 · 只接受 1080p"


def test_language_question_once_then_remembered_and_applied_everywhere(client):
    _defaults(client)
    first = _preview(client, "tmdb:movie:701")
    assert first["subtitle_line"] == "英语 · 只下带中文字幕的"
    assert first["question"] == {
        "language": "en",
        "prompt": "这是英语片，要中文字幕吗？",
        "subtitles_label": "要，只下带中文字幕的",
        "understood_label": "不用，我看得懂英语",
    }
    sub = _subscribe(client, "tmdb:movie:701", first, smart_language_answer="subtitles")
    assert sub["smart_policy"]["watchable_languages"] == ["zh"]

    # 同一种语言不再问；剧集照用电影里答过的
    again = _preview(client, "tmdb:tv:804")
    assert again["question"] is None and again["subtitle_line"] == "英语 · 只下带中文字幕的"
    assert again["memory_revision"] == 1
    # 新语言再问，粤语单独算一种
    assert _preview(client, "tmdb:tv:805")["question"]["prompt"] == "这是日语片，要中文字幕吗？"
    assert _preview(client, "tmdb:movie:702")["question"]["prompt"] == "这是粤语片，要中文字幕吗？"
    # 中文作品不加要求、不显示
    chinese = _preview(client, "tmdb:movie:705")
    assert chinese["subtitle_line"] is None and chinese["question"] is None

    # 在设置里改成看得懂：在等的英语订阅立刻不再要求字幕
    memory = _data(client.get(f"{BASE}/smart-memory"))
    assert [lang["key"] for lang in memory["languages"]] == ["zh"]
    assert {o["key"] for o in memory["addable_languages"]} >= {"en", "ja", "yue"}
    patched = _data(
        client.patch(
            f"{BASE}/smart-memory",
            json={"revision": memory["revision"], "language": "en", "understood": True},
        )
    )
    assert [lang["label"] for lang in patched["languages"]] == ["中文", "英语"]
    assert patched["languages"][1]["source_title"] == "奥本海默"
    detail = _data(client.get(f"{BASE}/{sub['id']}"))
    assert detail["smart_policy"]["watchable_languages"] == []
    assert detail["smart_subtitle"]["line"] == "英语 · 不需要字幕"
    # 中文不能移除；旧版本号冲突
    assert (
        client.patch(
            f"{BASE}/smart-memory", json={"revision": 2, "language": "zh", "understood": False}
        ).status_code
        == 400
    )
    assert (
        client.patch(
            f"{BASE}/smart-memory", json={"revision": 0, "language": "ja", "understood": True}
        ).status_code
        == 409
    )


def test_understood_answer_accepts_any_understood_language(client):
    _defaults(client)
    plan = _preview(client, "tmdb:movie:701")
    sub = _subscribe(client, "tmdb:movie:701", plan, smart_language_answer="understood")
    assert sub["smart_policy"]["watchable_languages"] == []
    frieren = _preview(client, "tmdb:tv:805")
    assert frieren["subtitle_line"] == "日语 · 只下带中文或英语字幕的"
    assert frieren["question"]["subtitles_label"] == "要，只下带中文或英语字幕的"


def test_quality_habit_by_region_network_and_conflict_order(client):
    _defaults(client)
    plan = _preview(client, "tmdb:tv:801")
    assert [o["label"] for o in plan["scope_options"]] == [
        "只这部",
        "所有剧集",
        "韩国的剧",
        "tvN 的剧",
    ]
    region = next(o["value"] for o in plan["scope_options"] if o["label"] == "韩国的剧")
    sub = _subscribe(
        client,
        "tmdb:tv:801",
        plan,
        smart_language_answer="subtitles",
        smart_resolution="1080p",
        smart_scope=region,
    )
    assert sub["smart_policy"]["resolution"] == "1080p"
    habits = _data(client.get(f"{BASE}/smart-memory"))["habits"]
    assert habits == [
        {"key": region, "label": "韩国的剧", "quality_label": "1080p", "source_title": "请回答1988"}
    ]
    other = _preview(client, "tmdb:tv:802")
    assert other["quality_label"] == "优先 1080p WEB-DL"
    assert other["quality_note"] == "按「韩国的剧」的习惯"
    assert other["question"] is None
    # 平台习惯比地区更具体，写明被盖住的那条
    squid = _preview(client, "tmdb:tv:803")
    network = next(o["value"] for o in squid["scope_options"] if o["label"] == "Netflix 的剧")
    _subscribe(client, "tmdb:tv:803", squid, smart_resolution="2160p", smart_scope=network)
    glory = _preview(client, "tmdb:tv:806")
    assert glory["quality_label"] == "优先 4K WEB-DL"
    assert glory["quality_note"] == "按「Netflix 的剧」的习惯"
    assert glory["quality_shadow"] == "「韩国的剧」是 1080p"
    # 电影不受剧集习惯影响，也没有平台选项
    movie = _preview(client, "tmdb:movie:701")
    assert movie["quality_note"] is None
    assert [o["label"] for o in movie["scope_options"]] == ["只这部", "所有电影", "美国的电影"]
    # 删掉习惯：已有订阅跟着回到默认
    memory = _data(client.get(f"{BASE}/smart-memory"))
    _data(
        client.patch(
            f"{BASE}/smart-memory", json={"revision": memory["revision"], "remove_habit": region}
        )
    )
    assert _data(client.get(f"{BASE}/{sub['id']}"))["smart_policy"]["resolution"] == "2160p"
    bad = client.post(
        BASE,
        json={
            "title_ref": "tmdb:tv:802",
            "selected_seasons": [1],
            "selection_mode": "smart",
            "smart_profile_revision": 1,
            "smart_resolution": "1080p",
            "smart_scope": "region:tv:US",
        },
    )
    assert bad.status_code == 400


def test_only_this_title_and_series_carries_over(client):
    _defaults(client)
    dune = _preview(client, "tmdb:movie:703")
    sub = _subscribe(
        client,
        "tmdb:movie:703",
        dune,
        smart_language_answer="subtitles",
        smart_source="remux",
        smart_scope="only",
    )
    assert sub["smart_policy"]["source"] == "remux"
    assert _data(client.get(f"{BASE}/smart-memory"))["habits"] == []
    sequel = _preview(client, "tmdb:movie:704")
    assert sequel["quality_label"] == "优先 4K Remux"
    assert sequel["quality_note"] == "按《沙丘》的设置"
    created = _subscribe(client, "tmdb:movie:704", sequel)
    assert created["smart_policy"]["source"] == "remux"
    detail = _data(client.get(f"{BASE}/{created['id']}"))
    assert detail["smart_quality_note"] == "按《沙丘》的设置"
    # 不相干的英语片照默认
    assert _preview(client, "tmdb:movie:706")["quality_label"] == "优先 4K WEB-DL"


def test_stale_memory_revision_is_a_conflict_and_cancel_writes_nothing(client):
    _defaults(client)
    plan = _preview(client, "tmdb:movie:701")
    _subscribe(client, "tmdb:movie:701", plan, smart_language_answer="understood")
    stale = client.post(
        BASE,
        json={
            "title_ref": "tmdb:tv:804",
            "selected_seasons": [1],
            "selection_mode": "smart",
            "smart_profile_revision": 1,
            "smart_memory_revision": 0,
            "smart_language_answer": "subtitles",
        },
    )
    assert stale.status_code == 409
    assert stale.json()["code"] == "SMART_VERSION_CONFLICT"
    # 只打开弹层不订阅，什么都不写
    _preview(client, "tmdb:tv:805")
    assert _data(client.get(f"{BASE}/smart-memory"))["revision"] == 1


def test_members_see_conclusions_but_never_write_memory(client):
    _defaults(client)
    assert (
        client.post(
            "/api/v1/members", json={"username": "kid", "password": "member-pass-1"}
        ).status_code
        == 200
    )
    client.cookies.clear()
    assert (
        client.post(
            "/api/v1/auth/login", json={"username": "kid", "password": "member-pass-1"}
        ).status_code
        == 200
    )
    plan = _preview(client, "tmdb:movie:701")
    assert plan["question"] is None and plan["can_edit"] is False
    assert plan["subtitle_line"] == "英语 · 只下带中文字幕的"
    sub = _subscribe(
        client,
        "tmdb:movie:701",
        plan,
        smart_language_answer="understood",
        smart_resolution="1080p",
        smart_scope="only",
    )
    # 成员的选择不生效：按安全默认要字幕，画质照默认
    assert sub["smart_policy"]["watchable_languages"] == ["zh"]
    assert sub["smart_policy"]["resolution"] == "2160p"
    assert client.get(f"{BASE}/smart-memory").status_code == 403
    assert (
        client.patch(
            f"{BASE}/smart-memory", json={"revision": 0, "language": "en", "understood": True}
        ).status_code
        == 403
    )
    assert (
        client.put(
            f"{BASE}/smart-defaults",
            json={
                "movie_revision": 1,
                "tv_revision": 1,
                "resolution": "1080p",
                "source": "web-dl",
                "movie_wait_seconds": 0,
                "tv_wait_seconds": 0,
            },
        ).status_code
        == 403
    )


def test_callers_without_the_dialog_get_safe_defaults(client):
    """CLI、插件和没升级的 App 只传旧字段：照常用记忆，没问过的语言按要字幕处理。"""
    _defaults(client)
    legacy = _data(
        client.post(
            BASE,
            json={
                "title_ref": "tmdb:movie:701",
                "selection_mode": "smart",
                "smart_profile_revision": 1,
            },
        )
    )["subscription"]
    assert legacy["smart_policy"]["watchable_languages"] == ["zh"]
    assert _data(client.get(f"{BASE}/smart-memory"))["revision"] == 0
    rules = client.post(
        BASE,
        json={"title_ref": "tmdb:movie:705", "smart_language_answer": "subtitles"},
    )
    assert rules.status_code == 422  # 规则模式不能带智能字段

from __future__ import annotations

import asyncio
import json
from datetime import UTC, date, datetime
from pathlib import Path

import httpx
import pytest
from fastapi import FastAPI

from movieclaw_api.exceptions import AppException, BadRequestException
from movieclaw_api.handlers import register_exception_handlers
from movieclaw_api.i18n import current_locale, negotiate, render, t, use_locale
from movieclaw_api.i18n.format import absolute_time, month_day
from movieclaw_api.i18n.middleware import LocaleMiddleware

CASES = json.loads(Path(__file__).with_name("negotiation.json").read_text())


@pytest.mark.parametrize("case", CASES)
def test_negotiate(case):
    assert negotiate(case["header"]) == case["locale"]


def test_icu_rendering():
    message = (
        "{gender, select, female {{name} has "
        "{count, plural, one {# movie} other {# movies}}} other {No movies}}"
    )
    assert (
        render(message, "en", {"gender": "female", "name": "Sam", "count": 1}) == "Sam has 1 movie"
    )
    assert (
        render(message, "en", {"gender": "female", "name": "Sam", "count": 1200})
        == "Sam has 1,200 movies"
    )
    assert render("{count} 部影片", "zh-Hans", {"count": 1200}) == "1200 部影片"
    assert render("{count, number} 部影片", "zh-Hans", {"count": 1200}) == "1,200 部影片"
    assert render("{count, plural, =0 {Empty} other {# movies}}", "en", {"count": 0}) == "Empty"
    assert (
        render("{count, plural, offset:1 one {# movie} other {# movies}}", "en", {"count": 3})
        == "2 movies"
    )
    assert render("Don't delete '{title}'", "en", {"title": "Movie"}) == "Don't delete {title}"
    with pytest.raises(KeyError):
        render("{title}", "en", {})


def test_recipient_dates_and_timezones():
    instant = datetime(2026, 10, 23, 12, tzinfo=UTC)
    with use_locale("zh-Hans", "Asia/Shanghai"):
        assert month_day(date(2026, 10, 23)) == "10 月 23 日"
        assert absolute_time(instant) == "2026/10/23 20:00"
    with use_locale("en", "America/New_York"):
        assert month_day(date(2026, 10, 23)) == "Oct 23"
        assert absolute_time(instant) == "Oct 23, 2026, 08:00"


async def test_context_reset_and_concurrent_requests():
    app = FastAPI()
    app.add_middleware(LocaleMiddleware)
    register_exception_handlers(app)

    @app.get("/error")
    async def error():
        await asyncio.sleep(0)
        raise AppException(
            status_code=400, code="BAD_REQUEST", message_key="errors.auth.wrongPassword"
        )

    @app.get("/legacy")
    async def legacy():
        raise BadRequestException("旧版报错")

    previous = current_locale.get()
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app), base_url="http://test"
    ) as client:
        responses = await asyncio.gather(
            *[
                client.get("/error", headers={"Accept-Language": language})
                for language in ("en-US", "zh-CN", "ja", "zh-TW")
            ]
        )
        for response, expected in zip(responses, ("en", "zh-Hans", "en", "zh-Hans"), strict=True):
            assert response.headers["content-language"] == expected
            assert "Cookie" in response.headers["vary"]
            body = response.json()
            assert body["message_key"] == "errors.auth.wrongPassword"
            assert body["params"] == {}
            assert body["message"] == (
                "Incorrect username or password" if expected == "en" else "用户名或密码错误"
            )
        cookie = await client.get(
            "/error", headers={"Cookie": "mc_locale=zh-Hans", "Accept-Language": "en"}
        )
        assert cookie.headers["content-language"] == "zh-Hans"
        legacy = await client.get("/legacy")
        assert legacy.json()["message"] == "旧版报错"
        assert "message_key" not in legacy.json()
    assert current_locale.get() == previous
    with pytest.raises(RuntimeError), use_locale("en"):
        assert t("errors.auth.wrongPassword") == "Incorrect username or password"
        raise RuntimeError
    assert current_locale.get() == previous


def test_legacy_fixed_messages_require_equal_english_translations(monkeypatch):
    from movieclaw_api.i18n import stored

    catalogs = {
        "zh-Hans": {
            "history.resume": "恢复",
            "response.resume": "恢复",
            "window.close": "关闭",
            "subtitles.off": "关闭",
        },
        "en": {
            "history.resume": "Resume",
            "response.resume": "Resume",
            "window.close": "Close",
            "subtitles.off": "Off",
        },
    }
    monkeypatch.setattr(stored, "messages", catalogs.__getitem__)
    stored.legacy_keys.cache_clear()
    try:
        assert "恢复" in stored.legacy_keys()
        assert "关闭" not in stored.legacy_keys()
    finally:
        stored.legacy_keys.cache_clear()

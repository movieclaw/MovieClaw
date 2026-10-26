"""NexusPHP 用户资料：会话失效被重定向到登录页 / Cloudflare 挑战时的错误归类。"""

from __future__ import annotations

from unittest.mock import MagicMock

import httpx
import pytest

from movieclaw_api.services.verification import friendly_error
from movieclaw_tracker import load_all_sites
from movieclaw_tracker.exceptions import TrackerParseError
from movieclaw_tracker.frameworks.nexusphp import NexusPHPSite
from movieclaw_tracker.http import HttpClient
from movieclaw_tracker.registry import get_site_config


def _site(site_id: str, handler) -> NexusPHPSite:
    load_all_sites()
    config = get_site_config(site_id)
    client = HttpClient(transport=httpx.MockTransport(handler), max_retries=1)
    return NexusPHPSite(
        selectors=config.selectors,
        category_map=config.category_map,
        site_id=config.site_id,
        base_url=config.base_url,
        client=client,
        auth_manager=MagicMock(),
    )


@pytest.mark.asyncio
async def test_profile_redirected_to_login_page_reports_expired_login() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/userdetails.php":
            return httpx.Response(
                302, headers={"location": "/login.php?returnto=userdetails.php"}
            )
        return httpx.Response(200, text="<form action='takelogin.php'></form>")

    site = _site("keepfrds", handler)
    with pytest.raises(TrackerParseError) as info:
        await site.get_user_profile()
    await site.client.close()

    assert info.value.details["login_redirect"] is True
    message = friendly_error(info.value)
    assert "登录已失效" in message
    assert "改版" not in message


@pytest.mark.asyncio
async def test_profile_unparseable_page_still_reports_format_error() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, text="<html><body>new layout</body></html>")

    site = _site("ssd", handler)
    with pytest.raises(TrackerParseError) as info:
        await site.get_user_profile()
    await site.client.close()

    assert info.value.details["login_redirect"] is False
    assert "格式异常" in friendly_error(info.value)


@pytest.mark.asyncio
async def test_cloudflare_challenge_is_not_reported_as_bad_credentials() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/userdetails.php":
            return httpx.Response(302, headers={"location": "/login.php"})
        return httpx.Response(
            403,
            headers={"cf-mitigated": "challenge", "server": "cloudflare"},
            text="<title>Just a moment...</title>",
        )

    site = _site("audiences", handler)
    with pytest.raises(httpx.HTTPStatusError) as info:
        await site.get_user_profile()
    await site.client.close()

    message = friendly_error(info.value)
    assert "Cloudflare" in message
    assert "User-Agent" in message

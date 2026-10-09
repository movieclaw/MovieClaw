"""公开演示站下的 Jellyfin 登录：按来源地址限频的检查与「新设备」推送共用一个模块函数。

曾因函数内重复 import 同名函数，把模块级的 client_address 变成局部变量，开着演示模式时
第一行就抛 UnboundLocalError——Infuse 等第三方播放器全部登不上。
"""

from __future__ import annotations

from fastapi.testclient import TestClient
from tests.jellyfin.helpers import jf_login

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import demo as demo_service


def test_jellyfin_login_works_in_demo_mode(client: TestClient, monkeypatch) -> None:
    monkeypatch.setenv("MOVIECLAW_DEMO_MODE", "true")
    get_settings.cache_clear()
    demo_service.reset_demo_state()
    try:
        assert jf_login(client)
    finally:
        monkeypatch.delenv("MOVIECLAW_DEMO_MODE")
        get_settings.cache_clear()

"""开机自启：Windows 上走真实注册表（写到测试专用的临时键），其他平台一律视为关闭且不可开。"""

from __future__ import annotations

import contextlib
import sys
import uuid

import pytest
from movieclaw_transcoder_app import autostart

TEST_KEY = f"Software\\MovieClawTranscoderAppTest-{uuid.uuid4().hex[:8]}"


def teardown_function() -> None:
    if sys.platform == "win32":
        import winreg

        with contextlib.suppress(FileNotFoundError):
            winreg.DeleteKey(winreg.HKEY_CURRENT_USER, TEST_KEY)


def test_command_quotes_both_parts():
    assert autostart.command("C:\\Program Files\\x\\pythonw.exe", "C:\\app\\run.pyw") == (
        '"C:\\Program Files\\x\\pythonw.exe" "C:\\app\\run.pyw"'
    )


@pytest.mark.skipif(sys.platform != "win32", reason="注册表只在 Windows 上有")
def test_enable_query_disable_roundtrip():
    assert not autostart.enabled(TEST_KEY)

    if not autostart.enable('"pythonw.exe" "app.pyw"', TEST_KEY):
        pytest.skip("这台机器不允许写 HKCU（组策略/沙箱），跳过注册表往返")

    assert autostart.enabled(TEST_KEY)

    autostart.disable(TEST_KEY)

    assert not autostart.enabled(TEST_KEY)


@pytest.mark.skipif(sys.platform != "win32", reason="注册表只在 Windows 上有")
def test_disable_without_a_value_is_silent():
    autostart.disable(TEST_KEY)  # 不该抛 FileNotFoundError


@pytest.mark.skipif(sys.platform == "win32", reason="非 Windows 平台的行为")
def test_non_windows_is_always_off():
    assert autostart.enabled() is False
    autostart.enable('"x"', TEST_KEY)  # 空操作
    assert autostart.enabled() is False

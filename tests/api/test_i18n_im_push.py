"""Owned channel annotations and shared binding reasons are reader projections."""

import copy
import re

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import reference, render_value
from movieclaw_api.services.channel_hub import Binding, ChannelBindingError

from .test_channels_api import app_env, make_client  # noqa: F401


def test_owned_channels_have_english_metadata_without_changing_driver_fields(app_env):  # noqa: F811
    with make_client() as client:
        views = [
            client.get("/api/v1/channels", headers={"Accept-Language": locale}).json()["data"]
            for locale in ("en", "zh-Hans", "en")
        ]
        assert views[0] == views[2]
        english = {row["id"]: row for row in views[0]["channels"]}
        chinese = {row["id"]: row for row in views[1]["channels"]}
        assert english["weixin"]["title"] == "WeChat"
        assert chinese["weixin"]["title"] == "微信"
        assert english["feishu"]["title"] == "Feishu"
        for cid in ("weixin", "telegram", "discord", "feishu"):
            en, zh = english[cid], chinese[cid]
            assert not re.search(
                r"[\u3400-\u9fff]", en["title"] + en["description"] + en["binding"]["hint"]
            )
            assert en["entry_id"] == zh["entry_id"]
            assert en["binding"]["kind"] == zh["binding"]["kind"]
            for field, source in zip(en["binding"]["fields"], zh["binding"]["fields"], strict=True):
                assert not re.search(
                    r"[\u3400-\u9fff]", field["label"] + field["placeholder"] + field["help"]
                )
                assert (field["key"], field["secret"], field["required"]) == (
                    source["key"],
                    source["secret"],
                    source["required"],
                )
        response = client.post(
            "/api/v1/channels/bindings",
            json={"channel_id": "weixin"},
            headers={"Accept-Language": "en"},
        )
        assert response.status_code == 201, response.text
        path = "/api/v1/channels/bindings/" + response.json()["data"]["binding_id"]
        snapshots = [
            client.get(path, headers={"Accept-Language": locale}).json()["data"]
            for locale in ("en", "zh-Hans", "en")
        ]
        assert snapshots[0] == snapshots[2]
        assert snapshots[0]["message"] == "Scan the QR code with WeChat on your phone"
        assert snapshots[1]["message"] == "请用手机微信扫描二维码"
        assert snapshots[0]["qr"] == snapshots[1]["qr"] == "https://weixin.example/qr-1"


def test_shared_binding_reasons_keep_chinese_and_clear_old_plugin_translations():
    binding = Binding("fixture", "fixture", "flow")
    binding.set_message(
        "原流程", {"message_text": "原流程", "message_localized": {"en": "Old flow"}}
    )
    binding.set_reason(
        "channels.binding.failed",
        error={"message_text": "作者原因", "message_localized": {"en": "Author reason"}},
    )
    source = copy.deepcopy(binding)
    assert binding.message == "绑定失败：作者原因"
    for locale, expected in [
        ("en", "Could not link: Author reason"),
        ("zh-Hans", "绑定失败：作者原因"),
        ("en", "Could not link: Author reason"),
    ]:
        with use_locale(locale):
            assert render_value(binding.message_ref) == expected
    assert binding == source
    binding.set_message("未知第三方原文")
    assert binding.message_ref is None and binding.message == "未知第三方原文"
    with use_locale("en"):
        error = ChannelBindingError(
            "channels.binding.validationFailed",
            channel={"message_text": "原名", "message_localized": {"en": "Author channel"}},
            error="未知上游原因",
        )
    assert str(error) == "原名校验失败：未知上游原因"
    with use_locale("en"):
        assert render_value(error.message_ref) == "Could not validate Author channel: 未知上游原因"
    assert error.message_ref == reference("channels.binding.validationFailed", **error.params)


def test_missing_binding_input_preserves_its_original_chinese_response(app_env):  # noqa: F811
    with make_client() as client:
        for locale, message in [
            ("en", "This linking request does not exist or has expired"),
            ("zh-Hans", "绑定不存在或已过期"),
            ("en", "This linking request does not exist or has expired"),
        ]:
            response = client.post(
                "/api/v1/channels/bindings/missing/input",
                json={"value": "73"},
                headers={"Accept-Language": locale},
            )
            assert response.status_code == 404
            assert response.json()["message"] == message

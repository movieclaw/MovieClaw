"""Real HTTP errors keep semantic parameters and follow each caller's language."""

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import render_value
from movieclaw_api.services import app_update
from movieclaw_api.services.library.routing import validate_match_rules

from . import test_app_config as config
from . import test_collections_api as collections

config_client = config.client
collections_client = collections.client


def test_collection_missing_is_localized_without_changing_the_error_code(collections_client):
    for locale, message in [
        ("en", "This collection does not exist; it may have been deleted"),
        ("zh-Hans", "合集不存在（可能已被删除）"),
    ]:
        reply = collections_client.get(
            "/api/v1/collections/99999", headers={"Accept-Language": locale}
        )
        assert reply.status_code == 404
        error = reply.json()
        assert error["message"] == message
        assert error["message_key"] == "errors.collections.missing"
        assert error["code"] == "RESOURCE_NOT_FOUND"


def test_callers_without_a_language_header_keep_chinese(collections_client):
    """还没本地化的客户端（Android、桌面、鸿蒙、CLI、插件）不带语言头，回复保持中文；
    带了头但都不支持（如 fr）才回落英文。"""
    collections_client.headers.pop("Accept-Language")
    for headers, message, language in [
        ({}, "合集不存在（可能已被删除）", "zh-Hans"),
        ({"Accept-Language": ""}, "合集不存在（可能已被删除）", "zh-Hans"),
        (
            {"Accept-Language": "fr-FR,de;q=0.8"},
            "This collection does not exist; it may have been deleted",
            "en",
        ),
    ]:
        reply = collections_client.get("/api/v1/collections/99999", headers=headers)
        assert reply.status_code == 404
        assert reply.json()["message"] == message
        assert reply.headers["Content-Language"] == language


def test_invalid_remote_transcode_url_keeps_a_rerenderable_nested_issue(config_client):
    reply = config_client.put(
        "/api/v1/transcode-worker/config",
        json={"enabled": True, "base_url": "nas.example.com:3000"},
        headers={"Accept-Language": "en"},
    )
    assert reply.status_code == 400, reply.text
    error = reply.json()
    assert error["message_key"] == "errors.workers.enableFailed"
    assert error["params"]["issues"]["message_list"][0]["message_key"] == (
        "errors.workers.urlSchemeRequired"
    )
    assert error["message"] == (
        "Could not enable remote transcoding: The remote transcoding override address "
        'must begin with http:// or https://. Current value: "nas.example.com:3000"'
    )


def test_nested_scope_and_github_errors_can_be_rendered_again_in_another_language(monkeypatch):
    import httpx
    import pytest

    from movieclaw_api.exceptions import BadRequestException
    from movieclaw_api.i18n import t

    with use_locale("en"):
        with pytest.raises(BadRequestException) as caught:
            validate_match_rules([{"field": "genres", "values": []}])
        ref = {"message_key": caught.value.message_key, "params": caught.value.params}
        assert (
            caught.value.message
            == 'Select at least one value for "Genre" in the Collection scope condition'
        )
        assert t("errors.sites.authFieldsRequired", type="cookie", fields="Cookie") == (
            "Authorization type 'cookie' is missing required fields: Cookie"
        )
    with use_locale("zh-Hans"):
        assert render_value(ref) == "收藏范围条件「类型」的取值不能为空"
    monkeypatch.setattr(app_update, "resolve_proxy_url", lambda _service: None)
    ref = app_update._github_error_reference(httpx.ConnectTimeout("timed out"), "应用更新")
    with use_locale("en"):
        assert "application updates" in render_value(ref)
        assert "Connecting directly" in render_value(ref)
    with use_locale("zh-Hans"):
        assert render_value(ref) == (
            "连接 GitHub 超时，无法检查应用更新。当前为直连（未对 GitHub 启用代理）；"
            "若代理按域名分流，请确认 api.github.com 走的是代理而非直连"
        )

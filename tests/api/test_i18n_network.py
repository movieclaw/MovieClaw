"""Network labels and probe references preserve routing facts across reader languages."""

from types import SimpleNamespace

import httpx
import pytest

from . import test_network as network

client = network.client


def test_network_catalog_and_validation_names_follow_the_reader(client):
    views = []
    for language in ("en", "zh-Hans", "en"):
        response = client.get("/api/v1/network/config", headers={"Accept-Language": language})
        assert response.status_code == 200
        views.append(response.json()["data"])
    assert [row["id"] for row in views[0]["services"]] == [
        row["id"] for row in views[1]["services"]
    ]
    assert views[0] == views[2]
    for field in ("proxy_mode", "proxy_url", "proxy_services", "mirror_defaults"):
        assert views[0][field] == views[1][field]
    assert set(views[0]["pypi_index_presets"].values()) == set(
        views[1]["pypi_index_presets"].values()
    )
    assert views[0]["services"][0]["label"] != views[1]["services"][0]["label"]
    assert "Tsinghua mirror" in views[0]["pypi_index_presets"]
    for language, expected in (("en", "TMDB API mirror"), ("zh-Hans", "TMDB 接口镜像")):
        response = client.put(
            "/api/v1/network/config",
            json={"proxy_mode": "off", "tmdb_api_base_url": "invalid-value"},
            headers={"Accept-Language": language},
        )
        assert response.status_code == 400
        assert expected in response.json()["message"]
    after = client.get("/api/v1/network/config", headers={"Accept-Language": "en"}).json()["data"]
    assert after == views[0]


@pytest.mark.parametrize(
    "service",
    [
        "tmdb",
        "llm",
        "fanart",
        "web_search",
        "github",
        "movieclaw_cloud",
        "movieclaw_push",
        "telegram",
        "discord",
        "image",
    ],
)
@pytest.mark.parametrize("status", [200, 401, 403, 429, 503])
def test_probe_references_keep_status_and_renderable_parameters(service, status, monkeypatch):
    from movieclaw_api.i18n import use_locale
    from movieclaw_api.services import fanart, network_config

    monkeypatch.setattr(fanart, "current_fanart_setting", lambda: SimpleNamespace(api_key=""))
    results = []
    for language in ("en", "zh-Hans", "en"):
        with use_locale(language):
            results.append(network_config._classify_probe(service, status))
    assert all(result.ok and result.latency_ms is None for result in results)
    assert results[0].message_key == results[1].message_key
    assert results[0].message_params == results[1].message_params
    assert results[0].message == results[2].message != results[1].message
    assert all(not "\u3400" <= c <= "\u9fff" for c in results[0].message)


@pytest.mark.parametrize("failure", ["timeout", "connection"])
def test_failed_probe_keeps_reference_and_original_external_reason(client, monkeypatch, failure):
    from movieclaw_api.services import network_config

    def handle(request):
        if failure == "timeout":
            raise httpx.ReadTimeout("fixture timeout", request=request)
        raise httpx.ConnectError("Raw external reason 原始原因", request=request)

    monkeypatch.setattr(
        network_config, "egress_transport", lambda *a, **k: httpx.MockTransport(handle)
    )
    values = []
    for language in ("en", "zh-Hans"):
        response = client.post(
            "/api/v1/network/test",
            json={"service": "image"},
            headers={"Accept-Language": language},
        )
        assert response.status_code == 200
        value = response.json()["data"]
        assert value["ok"] is False and value["latency_ms"] is None
        values.append(value)
    assert values[0]["message_key"] == values[1]["message_key"]
    assert values[0]["message_params"] == values[1]["message_params"]
    if failure == "connection":
        assert values[0]["message_params"]["error"] == "Raw external reason 原始原因"
        assert "Raw external reason 原始原因" in values[0]["message"]

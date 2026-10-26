"""MCP management messages vary by reader; protocol definitions and credentials remain intact."""

import json

from sqlalchemy import text

from . import test_mcp_server as mcp_fixture

client = mcp_fixture.client


def _raw_config():
    from movieclaw_db.engine import get_database

    async def read():
        async with get_database().session() as session:
            return await session.scalar(
                text("SELECT value_json FROM app_setting WHERE namespace='mcp.endpoints'")
            )

    return read


def test_self_check_messages_keep_protocol_surface_and_stored_config(client):  # noqa: F811
    client.put("/api/v1/mcp/status", json={"enabled": True})
    created = client.post(
        "/api/v1/mcp/endpoints",
        json={
            "name": "作者端点",
            "slug": "locale-probe",
            "services": ["jobs"],
            "expand_tools": True,
        },
    )
    assert created.status_code == 200, created.text
    endpoint = created.json()["data"]["endpoint"]
    client.cookies.pop("mc_locale", None)
    raw = client.portal.call(_raw_config())

    def identity(value):
        data = json.loads(value)
        for entry in data["endpoints"]:
            entry.pop("last_used_at", None)
        return data

    previews = []
    for locale, expected in (
        ("en", "Protocol, tool definitions and API calls are working"),
        ("zh-Hans", "协议、工具面与调用链路都正常"),
        ("en", "Protocol, tool definitions and API calls are working"),
    ):
        checked = client.post(
            f"/api/v1/mcp/endpoints/{endpoint['id']}/check", headers={"Accept-Language": locale}
        )
        assert checked.status_code == 200, checked.text
        result = checked.json()["data"]
        assert result["ok"] and result["probe_ok"] and result["probe_tool"]
        assert result["message"] == expected
        assert result["warnings"]
        assert ("No external address" if locale == "en" else "还没配置外部访问地址") in result[
            "warnings"
        ][0]
        after_probe = client.portal.call(_raw_config())
        assert identity(after_probe) == identity(raw)
        previews.append(
            client.post(
                "/api/v1/mcp/endpoints/preview",
                headers={"Accept-Language": locale},
                json={"services": ["jobs"], "expand_tools": True},
            ).json()["data"]
        )
        assert client.portal.call(_raw_config()) == after_probe
    assert previews[0] == previews[1] == previews[2]
    assert any(
        "\u4e00" <= char <= "\u9fff"
        for tool in previews[0]["tools"]
        for char in tool["description"]
    )
    assert json.loads(raw)["endpoints"][0]["name"] == "作者端点"
    assert created.json()["data"]["token"] not in raw
    client.put("/api/v1/mcp/status", json={"enabled": False})
    checked = client.post(
        f"/api/v1/mcp/endpoints/{endpoint['id']}/check", headers={"Accept-Language": "en"}
    ).json()["data"]
    assert checked["warnings"][0].startswith("MCP is disabled globally")


def test_unknown_self_check_failure_is_not_translated(client, monkeypatch):  # noqa: F811
    import movieclaw_mcp.server as server

    created = client.post(
        "/api/v1/mcp/endpoints",
        json={
            "name": "Author endpoint",
            "slug": "broken-probe",
            "services": ["jobs"],
        },
    ).json()["data"]["endpoint"]

    def fail(*_args, **_kwargs):
        raise RuntimeError("作者 SDK 原因")

    monkeypatch.setattr(server, "build_server", fail)
    client.cookies.pop("mc_locale", None)
    for locale, expected in (
        ("en", "Could not complete the self-check: 作者 SDK 原因"),
        ("zh-Hans", "自检未能完成：作者 SDK 原因"),
    ):
        checked = client.post(
            f"/api/v1/mcp/endpoints/{created['id']}/check", headers={"Accept-Language": locale}
        ).json()["data"]
        assert not checked["ok"] and checked["message"] == expected

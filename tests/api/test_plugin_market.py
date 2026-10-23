"""插件市场（services/plugin_market.py）：签名索引 → 浏览 → 下载核对 → 待批准 → 批准安装。

真实应用、真实接口，只把 GitHub 换成内存里的假服务器（MockTransport）。覆盖：兼容性判断与推荐
版本、安装 → 升级到测试版 → 降级回正式版 → 停用 → 卸载；没签名 / 签名不对 / 包被调包一律拒绝；
GitHub 连不上时沿用旧索引；旧索引不倒退；README、依赖与图标按 sha256 核对。
"""

from __future__ import annotations

import base64
import hashlib
import json

import httpx
import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from tests.api.test_plugin_packages import MANIFEST, approve, data_dir, package, start  # noqa: F401

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import plugin_market

INDEX_URL = "https://github.com/movieclaw/movieclaw-plugins/releases/download/catalog/index.json"
REL = "https://github.com/movieclaw/movieclaw-plugins/releases/download"
RAW = "https://raw.githubusercontent.com/movieclaw/movieclaw-plugins"
ICON = b'<svg xmlns="http://www.w3.org/2000/svg"><rect width="4" height="4"/></svg>'
README = "# 包插件\n\n给测试用的插件。\n".encode()


def _asset(url: str, data: bytes) -> dict:
    return {"url": url, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}


def _archive(version: str, requires: str = '"subscription.candidates.filter" = "^1.0"') -> bytes:
    major = version.split(".", 1)[0]
    manifest = MANIFEST.format(
        id="acme-pkg",
        version=major,
        runtime="process",
        sdk="^1.0",
        requires=requires,
        operations='"app.plugins.list"',
    ).replace(f'version = "{major}.0.0"', f'version = "{version}"')
    return package(int(major), manifest=manifest)


class FakeGitHub:
    """内存里的 GitHub：地址 → 字节；``down`` 时一律连不上。"""

    def __init__(self) -> None:
        self.files: dict[str, bytes] = {}
        self.down = False
        self.requests: list[str] = []

    def handler(self, request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        self.requests.append(url)
        if self.down:
            raise httpx.ConnectError("unreachable", request=request)
        if url not in self.files:
            return httpx.Response(404)
        return httpx.Response(200, content=self.files[url])


@pytest.fixture
def github(data_dir, monkeypatch):  # noqa: F811
    fake = FakeGitHub()
    key = Ed25519PrivateKey.generate()
    public = base64.b64encode(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw))
    monkeypatch.setattr(plugin_market, "CATALOG_KEYS", {"test-1": public.decode()})
    monkeypatch.setattr(
        plugin_market, "transport_factory", lambda: httpx.MockTransport(fake.handler)
    )
    plugin_market.reset_for_tests()
    fake.key = key
    yield fake
    plugin_market.reset_for_tests()


def _version(version: str, archive: bytes, **extra) -> dict:
    tag = f"acme-pkg-v{version}"
    return {
        "version": version,
        "prerelease": "-" in version,
        "released_at": "2026-10-20T00:00:00Z",
        "yanked": None,
        "notes": f"- {version} 的说明\n",
        "changelog_url": f"https://github.com/movieclaw/movieclaw-plugins/releases/tag/{tag}",
        "source_url": f"https://github.com/movieclaw/movieclaw-plugins/tree/{tag}/plugins/acme-pkg",
        "readme": _asset(f"{RAW}/{tag}/plugins/acme-pkg/README.md", README),
        "runtime": "process",
        "sdk": "^1.0",
        "requires": {"subscription.candidates.filter": "^1.0"},
        "platforms": ["any"],
        "permissions": {
            "operations": ["app.plugins.list"],
            "paths": [],
            "network": False,
            "callbacks": [],
            "events": [],
        },
        "web": False,
        "dependencies": None,
        "artifacts": [
            {
                "platform": "any",
                "filename": f"acme-pkg-{version}.mcplugin",
                **_asset(f"{REL}/{tag}/acme-pkg-{version}.mcplugin", archive),
            }
        ],
        **extra,
    }


def publish(
    fake: FakeGitHub,
    *,
    signed: bool = True,
    generated_at="2026-10-20T00:00:00Z",
    yank: str | None = None,
    tamper: bool = False,
) -> dict:
    """发一份索引：1.0.0 正式版、1.5.0 要不存在的契约、2.0.0-beta.1 测试版。"""
    archives = {
        "1.0.0": _archive("1.0.0"),
        "1.5.0": _archive("1.5.0", requires='"no-such-contract" = "^1.0"'),
        "2.0.0-beta.1": _archive("2.0.0-beta.1"),
    }
    versions = [
        _version("2.0.0-beta.1", archives["2.0.0-beta.1"]),
        _version("1.5.0", archives["1.5.0"], requires={"no-such-contract": "^1.0"}),
        _version("1.0.0", archives["1.0.0"], yanked={"reason": yank} if yank else None),
    ]
    for item in versions:
        artifact = item["artifacts"][0]
        data = archives[item["version"]]
        fake.files[artifact["url"]] = data + (b"x" if tamper else b"")
        fake.files[item["readme"]["url"]] = README
    icon = _asset(f"{REL}/catalog/acme-pkg-icon-abc.svg", ICON)
    fake.files[icon["url"]] = ICON
    document = {
        "schema": 2,
        "generated_at": generated_at,
        "signed": signed,
        "key_id": "test-1" if signed else None,
        "repository": "https://github.com/movieclaw/movieclaw-plugins",
        "plugins": [
            {
                "id": "acme-pkg",
                "name": "包插件",
                "summary": "一句话",
                "description": "长一点的说明",
                "category": "tools",
                "author": {"name": "MovieClaw", "url": "https://github.com/movieclaw"},
                "homepage": "https://github.com/movieclaw/movieclaw-plugins",
                "repository": "https://github.com/movieclaw/movieclaw-plugins/tree/main/plugins/acme-pkg",
                "license": "MIT",
                "origin": "official",
                "icon": icon,
                "screenshots": [],
                "deprecated": None,
                "latest": "2.0.0-beta.1",
                "latest_stable": "1.5.0",
                "versions": versions,
            }
        ],
    }
    raw = json.dumps(document, ensure_ascii=False).encode()
    fake.files[INDEX_URL] = raw
    fake.files.pop(INDEX_URL + ".sig", None)
    if signed:
        fake.files[INDEX_URL + ".sig"] = base64.b64encode(fake.key.sign(raw)) + b"\n"
    return document


def market(client) -> dict:
    reply = client.get("/api/v1/app/plugins/market")
    assert reply.status_code == 200, reply.text
    return reply.json()["data"]


def acme(client) -> dict:
    return next(p for p in market(client)["plugins"] if p["id"] == "acme-pkg")


def install(client, version: str):
    return client.post("/api/v1/app/plugins/market/acme-pkg/install", json={"version": version})


def test_browse_install_upgrade_downgrade_disable_uninstall(github) -> None:
    publish(github)
    app, client = start()
    with client:
        view = market(client)
        assert view["source"]["signed"] and view["source"]["error"] is None
        plugin = view["plugins"][0]
        by_version = {v["version"]: v for v in plugin["versions"]}
        # 1.5.0 要本机没有的契约：列出来，但标不兼容，不推荐
        assert not by_version["1.5.0"]["compatible"]
        assert "no-such-contract" in by_version["1.5.0"]["incompatible_reason"]
        assert by_version["2.0.0-beta.1"]["prerelease"] and by_version["2.0.0-beta.1"]["compatible"]
        # 没装、有能装的正式版：推正式版，不推测试版
        assert plugin["recommended"] == "1.0.0" and plugin["installed"] is None
        assert plugin["icon_url"].startswith("/api/v1/app/plugins/market/acme-pkg/icon?v=")

        # 安装：下载核对后进待批准，批准页与上传的一样
        reply = install(client, "1.0.0")
        assert reply.status_code == 200, reply.text
        pending = reply.json()["data"]
        assert (pending["version"], pending["installed_version"]) == ("1.0.0", None)
        assert pending["operations"] == ["app.plugins.list"]
        assert app.state.kernel.fiber("acme-pkg") is None  # 没批准不加载
        assert approve(client, "1.0.0").json()["data"]["status"] == "active"
        plugin = acme(client)
        assert (
            plugin["installed"]["version"] == "1.0.0" and plugin["installed"]["state"] == "active"
        )
        assert plugin["update"] is None  # 1.5.0 不兼容、2.0.0-beta.1 是测试版
        # 同一版不能再装
        assert install(client, "1.0.0").status_code == 409
        # 不兼容的版本在下载前就拒绝
        reply = install(client, "1.5.0")
        assert reply.status_code == 409 and "no-such-contract" in reply.json()["message"]

        # 主动装测试版：升级
        pending = install(client, "2.0.0-beta.1").json()["data"]
        assert pending["installed_version"] == "1.0.0"
        assert approve(client, "2.0.0-beta.1").json()["data"]["status"] == "active"
        plugin = acme(client)
        assert plugin["installed"]["version"] == "2.0.0-beta.1"
        assert plugin["installed"]["previous_version"] == "1.0.0"
        # 装着测试版：推荐跟着测试版走，没有更新的就不提示
        assert plugin["recommended"] == "2.0.0-beta.1" and plugin["update"] is None

        # 降级回 1.0.0：同样走市场下载 + 批准
        assert install(client, "1.0.0").status_code == 200
        assert approve(client, "1.0.0").json()["data"]["status"] == "active"
        assert acme(client)["installed"]["version"] == "1.0.0"

        # 停用 / 启用：市场里的状态跟着变
        reply = client.put("/api/v1/app/plugins/acme-pkg/enabled", json={"enabled": False})
        assert reply.status_code == 200, reply.text
        assert acme(client)["installed"]["state"] == "disabled"
        client.put("/api/v1/app/plugins/acme-pkg/enabled", json={"enabled": True})
        assert acme(client)["installed"]["state"] == "active"

        # 卸载：回到没装的状态
        assert client.delete("/api/v1/app/plugins/packages/acme-pkg").status_code == 200
        plugin = acme(client)
        assert plugin["installed"] is None and plugin["recommended"] == "1.0.0"


def test_signature_and_hash_are_enforced(github, monkeypatch) -> None:
    app, client = start()
    with client:
        publish(github, signed=False)
        reply = client.get("/api/v1/app/plugins/market")
        assert reply.status_code == 400 and "没有签名" in reply.json()["message"]

        # 签名对不上：改一个字节
        publish(github)
        github.files[INDEX_URL] = github.files[INDEX_URL].replace(b"MIT", b"GPL")
        plugin_market.reset_for_tests()
        reply = client.get("/api/v1/app/plugins/market")
        assert reply.status_code == 400 and "签名校验失败" in reply.json()["message"]

        # 不认识的密钥
        monkeypatch.setattr(plugin_market, "CATALOG_KEYS", {"other": "AAAA"})
        publish(github)
        plugin_market.reset_for_tests()
        reply = client.get("/api/v1/app/plugins/market")
        assert reply.status_code == 400 and "本机不认识" in reply.json()["message"]

    # 自建索引可以放行未签名
    monkeypatch.setenv("PLUGIN_CATALOG_ALLOW_UNSIGNED", "true")
    get_settings.cache_clear()
    plugin_market.reset_for_tests()
    app, client = start()
    with client:
        publish(github, signed=False, tamper=True)
        assert not market(client)["source"]["signed"]
        # 包被调包：sha256 对不上，不进待批准
        reply = install(client, "1.0.0")
        assert reply.status_code == 400 and "校验值不一致" in reply.json()["message"]
        assert client.get("/api/v1/app/plugins/packages").json()["data"]["pending"] == []


def test_stale_index_survives_github_outage_and_never_goes_back(github, monkeypatch) -> None:
    publish(github, generated_at="2026-10-20T00:00:00Z")
    app, client = start()
    with client:
        assert market(client)["source"]["generated_at"] == "2026-10-20T00:00:00Z"
        github.down = True
        # 新鲜期内不回源
        assert market(client)["source"]["error"] is None
        # 用户点「检查更新」：失败要说出来
        reply = client.post("/api/v1/app/plugins/market/refresh")
        assert reply.status_code == 503 and "GitHub" in reply.json()["message"]
        # 过了新鲜期、GitHub 还是连不上：旧索引照用，标出失败原因
        monkeypatch.setattr(plugin_market, "FRESH_SECONDS", 0)
        view = market(client)
        assert view["plugins"] and view["source"]["error"]

        # 取到更旧的索引（镜像缓存 / 回放）：不倒退
        github.down = False
        document = publish(github, generated_at="2026-10-01T00:00:00Z")
        document_ids = {p["id"] for p in document["plugins"]}
        view = client.post("/api/v1/app/plugins/market/refresh").json()["data"]
        assert view["source"]["generated_at"] == "2026-10-20T00:00:00Z"
        assert {p["id"] for p in view["plugins"]} == document_ids


def test_detail_readme_icon_and_yanked(github) -> None:
    publish(github, yank="会删掉数据")
    app, client = start()
    with client:
        plugin = acme(client)
        # 唯一能装的正式版被撤回了：只剩测试版可推
        assert plugin["recommended"] == "2.0.0-beta.1"
        assert {v["version"]: v["yanked"] for v in plugin["versions"]}["1.0.0"] == "会删掉数据"

        detail = client.get("/api/v1/app/plugins/market/acme-pkg").json()["data"]
        assert detail["selected"] == "2.0.0-beta.1" and "给测试用的插件" in detail["readme"]
        assert detail["dependencies"] is None
        detail = client.get("/api/v1/app/plugins/market/acme-pkg?version=1.0.0").json()["data"]
        assert detail["selected"] == "1.0.0"
        assert client.get("/api/v1/app/plugins/market/nope").status_code == 404

        reply = client.get(plugin["icon_url"])
        assert reply.status_code == 200 and reply.content == ICON
        assert reply.headers["content-type"].startswith("image/svg+xml")
        assert "sandbox" in reply.headers["content-security-policy"]
        # 核对过的图标进了缓存：GitHub 挂了也照样出
        github.down = True
        assert client.get(plugin["icon_url"]).content == ICON


def test_optional_catalog_fields_ignore_garbage() -> None:
    assert plugin_market._download_count(None) is None
    assert plugin_market._download_count(0) == 0
    assert plugin_market._download_count(12) == 12
    assert plugin_market._download_count(-1) is None
    assert plugin_market._download_count(True) is None
    assert plugin_market._download_count("12") is None
    assert plugin_market._download_count(1.5) is None
    assert plugin_market._http_url(None) is None
    assert plugin_market._http_url("  ") is None
    assert plugin_market._http_url("javascript:alert(1)") is None
    assert plugin_market._http_url("/issues/new") is None
    kept = "https://github.com/acme/x/issues"
    assert plugin_market._http_url(f"  {kept}  ") == kept


def test_downloads_feedback_and_screenshots_pass_through_signed_index(
    github, monkeypatch
) -> None:
    """新字段在签名覆盖的原文里：旧索引可以没有，坏值不当次数或链接，改一个字节就拒。"""
    document = publish(github)
    shot_bytes = b'<svg xmlns="http://www.w3.org/2000/svg"/>'
    shot = _asset(f"{REL}/catalog/acme-shot.svg", shot_bytes)
    github.files[shot["url"]] = shot_bytes
    featured = document["plugins"][0]
    featured["downloads"] = 12847
    featured["feedback_url"] = (
        "https://github.com/movieclaw/movieclaw-plugins/issues/new?template=plugin.yml&plugin=acme-pkg"
    )
    featured["screenshots"] = [
        shot,
        {"url": "https://example.com/nope.txt", "sha256": "abc", "size": 1},
    ]
    quiet = json.loads(json.dumps(featured))
    quiet["id"] = "quiet-pkg"
    quiet["name"] = "没有这些字段"
    quiet.pop("downloads")
    quiet.pop("feedback_url")
    quiet.pop("screenshots")
    junk = json.loads(json.dumps(featured))
    junk["id"] = "junk-pkg"
    junk["name"] = "坏数据"
    junk["downloads"] = "12847"
    junk["feedback_url"] = "javascript:alert(1)"
    junk["screenshots"] = []
    document["plugins"] = [featured, quiet, junk]
    raw = json.dumps(document, ensure_ascii=False).encode()
    github.files[INDEX_URL] = raw
    github.files[INDEX_URL + ".sig"] = base64.b64encode(github.key.sign(raw)) + b"\n"
    plugin_market.reset_for_tests()

    _app, client = start()
    with client:
        by_id = {item["id"]: item for item in market(client)["plugins"]}
        assert by_id["acme-pkg"]["downloads"] == 12847
        assert "template=plugin.yml" in by_id["acme-pkg"]["feedback_url"]
        assert len(by_id["acme-pkg"]["screenshots"]) == 1
        assert by_id["quiet-pkg"]["downloads"] is None
        assert by_id["quiet-pkg"]["feedback_url"] is None
        assert by_id["quiet-pkg"]["screenshots"] == []
        assert by_id["junk-pkg"]["downloads"] is None
        assert by_id["junk-pkg"]["feedback_url"] is None

        detail = client.get("/api/v1/app/plugins/market/acme-pkg").json()["data"]
        assert detail["downloads"] == 12847 and detail["feedback_url"]
        reply = client.get(by_id["acme-pkg"]["screenshots"][0])
        assert reply.status_code == 200 and reply.content == shot_bytes
        assert reply.headers["content-type"].startswith("image/svg+xml")
        assert "sandbox" in reply.headers["content-security-policy"]

        # 刚取到的索引在新鲜期内不会回源，这里强制再取一次，并禁止失败时退回旧索引
        monkeypatch.setattr(plugin_market, "FRESH_SECONDS", 0)
        monkeypatch.setattr(plugin_market, "STALE_SECONDS", 0)
        github.files[INDEX_URL] = github.files[INDEX_URL].replace(b"12847", b"12848")
        plugin_market.reset_for_tests()
        reply = client.get("/api/v1/app/plugins/market")
        assert reply.status_code == 400 and "签名校验失败" in reply.json()["message"]


def test_version_key_follows_semver() -> None:
    key = plugin_market.version_key
    assert key("1.0.0") > key("1.0.0-rc.1") > key("1.0.0-beta.10") > key("1.0.0-beta.2")
    assert key("0.1.0-beta.2") > key("0.1.0-beta.1")
    assert key("2.0.0-beta.1") > key("1.5.0")

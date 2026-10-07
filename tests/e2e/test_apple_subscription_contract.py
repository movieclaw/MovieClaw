"""真实订阅 API → 旧 App Swift 模型解码；智能模式不能破坏已发布客户端。"""

# ruff: noqa: F811
import shutil
import subprocess
from pathlib import Path

import pytest
from tests.api.test_subscription_routes import client  # noqa: F401

REPO = Path(__file__).resolve().parents[2]
pytestmark = pytest.mark.integration


@pytest.fixture(scope="module")
def apple_decoder(tmp_path_factory):
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        pytest.skip("需要与 Apple App 相同的 Swift 工具链")
    target = tmp_path_factory.mktemp("apple-subscriptions") / "decode"
    api = REPO / "apps/apple/Shared/Core/API"
    compiled = subprocess.run(
        [
            swiftc,
            str(api / "JSONValue.swift"),
            str(api / "Generated/Models.swift"),
            str(Path(__file__).parent / "fixtures/LegacySubscriptions.swift"),
            "-o",
            str(target),
        ],
        capture_output=True,
        text=True,
        timeout=180,
    )
    assert compiled.returncode == 0, compiled.stderr
    return target


@pytest.mark.parametrize("mode", ["smart", "rules"])
def test_existing_apple_models_decode_subscription_workflow(client, apple_decoder, mode):
    def decode(shape, response):
        assert response.status_code == 200, response.text
        result = subprocess.run(
            [str(apple_decoder), shape],
            input=response.content,
            capture_output=True,
            timeout=10,
        )
        assert result.returncode == 0, result.stdout.decode() + result.stderr.decode()

    base = "/api/v1/subscriptions"
    payload = {"title_ref": "tmdb:tv:200", "selected_seasons": [1]}
    if mode == "smart":
        saved = client.put(
            f"{base}/smart-profiles/tv",
            json={"revision": 0, "preferences": {"allow_upgrade": True}},
        )
        assert saved.status_code == 200, saved.text
        payload.update(selection_mode="smart", smart_profile_revision=1)
    created = client.post(base, json=payload)
    decode("create", created)
    sub_id = created.json()["data"]["subscription"]["id"]
    url = f"{base}/{sub_id}"
    decode("list", client.get(base))
    decode("detail", client.get(url))
    # 旧 App 再次订阅、调季、暂停和恢复，均消费相同的详情模型。
    decode("create", client.post(base, json={"title_ref": "tmdb:tv:200"}))
    decode("detail", client.patch(url, json={"selected_seasons": [1]}))
    decode("detail", client.patch(f"{url}/follow-future", json={"enabled": True}))
    for state in ("paused", "active"):
        decode("detail", client.patch(f"{url}/tracking-state", json={"state": state}))
    if mode == "smart":
        decode("upgrade", client.post(f"{url}/upgrade-runs", json={}))

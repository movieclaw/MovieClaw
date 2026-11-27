"""JsonEtagMiddleware（/api/v1 JSON GET 的 ETag 协商缓存）行为测试。

不依赖真实业务路由：最小 FastAPI 应用 + register_middlewares 装配真实中间件栈，
逐条验证 200/304 协商、内容变化换指纹、流式/非 JSON/写方法直通。
"""

from __future__ import annotations

import json
from collections.abc import Iterator

import pytest
from fastapi import FastAPI
from fastapi.responses import PlainTextResponse, StreamingResponse
from fastapi.testclient import TestClient

from movieclaw_api.core.config import Settings
from movieclaw_api.middleware import register_middlewares

_PREFIX = "/api/v1/etag"


@pytest.fixture
def client() -> TestClient:
    app = FastAPI()
    register_middlewares(app, Settings())

    state = {"value": 1}

    @app.get(f"{_PREFIX}/ping")
    def ping() -> dict:
        return {"value": state["value"]}

    @app.post(f"{_PREFIX}/bump")
    def bump() -> dict:
        state["value"] += 1
        return {"value": state["value"]}

    @app.get(f"{_PREFIX}/stream")
    def stream() -> StreamingResponse:
        def gen() -> Iterator[bytes]:
            yield json.dumps({"value": state["value"]}).encode("utf-8")

        return StreamingResponse(gen(), media_type="application/json")

    @app.get(f"{_PREFIX}/text")
    def text() -> PlainTextResponse:
        return PlainTextResponse("plain")

    return TestClient(app)


def test_first_get_carries_etag(client: TestClient) -> None:
    resp = client.get(f"{_PREFIX}/ping")
    assert resp.status_code == 200
    assert resp.json() == {"value": 1}
    etag = resp.headers.get("etag")
    assert etag, "首访响应必须带 ETag，客户端才有能力发起后续协商"
    assert resp.headers.get("cache-control") == "private, no-cache"


def test_inm_match_returns_304_with_empty_body(client: TestClient) -> None:
    etag = client.get(f"{_PREFIX}/ping").headers["etag"]
    resp = client.get(f"{_PREFIX}/ping", headers={"If-None-Match": etag})
    assert resp.status_code == 304
    assert resp.content == b""
    assert resp.headers.get("etag") == etag


def test_weak_and_star_inm_match(client: TestClient) -> None:
    etag = client.get(f"{_PREFIX}/ping").headers["etag"]
    weak = client.get(f"{_PREFIX}/ping", headers={"If-None-Match": f"W/{etag}"})
    assert weak.status_code == 304
    star = client.get(f"{_PREFIX}/ping", headers={"If-None-Match": "*"})
    assert star.status_code == 304


def test_content_change_breaks_match(client: TestClient) -> None:
    first = client.get(f"{_PREFIX}/ping")
    old_etag = first.headers["etag"]
    client.post(f"{_PREFIX}/bump")
    resp = client.get(f"{_PREFIX}/ping", headers={"If-None-Match": old_etag})
    assert resp.status_code == 200
    assert resp.json() == {"value": 2}
    assert resp.headers["etag"] != old_etag
    # 新指纹随后可继续协商
    again = client.get(f"{_PREFIX}/ping", headers={"If-None-Match": resp.headers["etag"]})
    assert again.status_code == 304


def test_etag_is_content_fingerprint(client: TestClient) -> None:
    """同内容同指纹：不同客户端（不同 If-None-Match 历史）拿到的 ETag 一致。"""
    a = client.get(f"{_PREFIX}/ping").headers["etag"]
    b = client.get(f"{_PREFIX}/ping").headers["etag"]
    assert a == b


def test_streaming_json_passthrough(client: TestClient) -> None:
    """流式 JSON 没有 content-length，不缓冲、不接管。"""
    resp = client.get(f"{_PREFIX}/stream")
    assert resp.status_code == 200
    assert resp.json() == {"value": 1}
    assert "etag" not in resp.headers


def test_non_json_passthrough(client: TestClient) -> None:
    resp = client.get(f"{_PREFIX}/text")
    assert resp.status_code == 200
    assert resp.text == "plain"
    assert "etag" not in resp.headers


def test_post_not_etagged(client: TestClient) -> None:
    resp = client.post(f"{_PREFIX}/bump")
    assert resp.status_code == 200
    assert "etag" not in resp.headers


def test_inm_mismatch_unknown_etag_returns_200(client: TestClient) -> None:
    resp = client.get(f"{_PREFIX}/ping", headers={"If-None-Match": '"deadbeef"'})
    assert resp.status_code == 200
    assert resp.json() == {"value": 1}


def test_health_outside_prefix_untouched(client: TestClient) -> None:
    """前缀外的路由不经过该中间件（健康探针等保持原样）。"""

    @client.app.get("/health")
    def health() -> dict:  # type: ignore[misc]
        return {"ok": True}

    resp = client.get("/health")
    assert resp.status_code == 200
    assert "etag" not in resp.headers

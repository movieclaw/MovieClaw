"""设备授权配对：出示配对码 → 人在网页批准 → 令牌只回到发起请求的进程。

请求与响应的形状用服务端自己的 schema 校验（``DeviceAuthorizeRequest`` / ``DeviceAuthorizeView``）。
"""

from __future__ import annotations

import http.server
import json
import threading

import pytest
from movieclaw_transcoder import __version__, pairing
from movieclaw_transcoder.pairing import (
    PairingError,
    PairingRequest,
    check_server,
    http_json,
    request_pairing,
    revoke_credential,
    wait_for_approval,
)

from movieclaw_api.schemas.auth import DeviceAuthorizeRequest, DeviceAuthorizeView

SERVER = "http://nas:3000"


class Scripted:
    """替换 ``pairing.http_json``：按顺序给应答，并记下每次调用。"""

    def __init__(self, *responses):
        self.responses = list(responses)
        self.calls: list[tuple] = []

    def __call__(self, method, url, body=None, *, token=None, timeout=15.0):
        self.calls.append((method, url, body, token))
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return response


@pytest.fixture
def scripted(monkeypatch):
    def install(*responses):
        stub = Scripted(*responses)
        monkeypatch.setattr(pairing, "http_json", stub)
        return stub

    return install


# -- 发起配对 ----------------------------------------------------------------


def test_the_pairing_request_fits_the_servers_schema_and_names_this_machine(scripted):
    view = DeviceAuthorizeView(
        user_code="ABCD-EFGH",
        device_code="dev-code",
        verification_uri="http://nas:3000/activate",
        verification_uri_complete="http://nas:3000/activate?code=ABCD-EFGH",
        interval=5,
        expires_in=300,
    )
    stub = scripted((200, {"data": view.model_dump()}))

    request = request_pairing(SERVER, "gaming-pc", "install-1")

    method, url, body, token = stub.calls[0]
    assert (method, url, token) == ("POST", f"{SERVER}/api/v1/auth/device/authorize", None)
    sent = DeviceAuthorizeRequest.model_validate(body)  # 服务端认这份请求
    assert (sent.client_type, sent.client_name, sent.installation_id) == (
        "worker",
        "gaming-pc",
        "install-1",
    )
    assert sent.client_version == __version__
    assert sent.platform is not None and sent.platform.startswith("Windows ")
    assert request == PairingRequest(
        user_code="ABCD-EFGH",
        device_code="dev-code",
        verification_uri_complete="http://nas:3000/activate?code=ABCD-EFGH",
        interval=5,
        expires_in=300,
    )


def test_a_refused_pairing_request_carries_the_servers_message(scripted):
    scripted((400, {"message": "客户端形态不对"}))

    with pytest.raises(PairingError) as error:
        request_pairing(SERVER, "gaming-pc", "install-1")

    assert "HTTP 400" in str(error.value) and "客户端形态不对" in str(error.value)


# -- 等批准 ----------------------------------------------------------------


def request(**overrides) -> PairingRequest:
    values = {
        "user_code": "ABCD-EFGH",
        "device_code": "dev-code",
        "verification_uri_complete": "http://nas:3000/activate?code=ABCD-EFGH",
        "interval": 5.0,
        "expires_in": 300.0,
    }
    return PairingRequest(**{**values, **overrides})


def test_polling_waits_while_pending_backs_off_when_told_and_returns_the_token(scripted):
    stub = scripted(
        (202, {"data": None}),
        (429, {"data": None}),
        (202, {"data": None}),
        (200, {"data": {"token": "the-token", "client_name": "gaming-pc"}}),
    )
    sleeps: list[float] = []

    token = wait_for_approval(SERVER, request(), sleep=sleeps.append)

    assert token == "the-token"
    assert sleeps == [5.0, 5.0, 10.0, 10.0]  # 429 之后间隔翻倍
    assert all(
        call[:3] == ("POST", f"{SERVER}/api/v1/auth/device/token", {"device_code": "dev-code"})
        for call in stub.calls
    )


def test_the_backoff_is_capped(scripted):
    scripted(*[(429, {"data": None})] * 6, (200, {"data": {"token": "t"}}))
    sleeps: list[float] = []

    wait_for_approval(SERVER, request(), sleep=sleeps.append)

    assert max(sleeps) == 30.0


def test_a_denied_or_expired_request_stops_polling_with_the_servers_reason(scripted):
    stub = scripted((400, {"message": "接入请求已被拒绝，请重新发起配对"}))

    with pytest.raises(PairingError) as error:
        wait_for_approval(SERVER, request(), sleep=lambda _s: None)

    assert "已被拒绝" in str(error.value)
    assert len(stub.calls) == 1


def test_waiting_past_the_expiry_gives_up_without_polling(scripted):
    stub = scripted()

    with pytest.raises(PairingError) as error:
        wait_for_approval(SERVER, request(expires_in=0), sleep=lambda _s: None)

    assert "过期" in str(error.value)
    assert stub.calls == []


def test_ctrl_c_while_waiting_is_a_cancellation_not_an_expiry(scripted):
    stub = scripted()

    with pytest.raises(PairingError) as error:
        wait_for_approval(SERVER, request(), sleep=lambda _s: None, cancelled=lambda: True)

    assert "取消" in str(error.value)
    assert stub.calls == []


# -- 验证地址与断开配对 -----------------------------------------------------------


def test_check_server_accepts_a_movieclaw_health_endpoint(scripted):
    stub = scripted((200, {"status": "ok", "service": "MovieClaw API"}))

    assert check_server(SERVER) is None
    assert stub.calls[0][:2] == ("GET", f"{SERVER}/api/v1/health")


@pytest.mark.parametrize(
    ("answer", "expected"),
    [
        ((200, {"status": "ok", "service": "Plex Media Server"}), "不是 MovieClaw"),
        ((404, None), "HTTP 404"),
        ((200, None), "HTTP 200"),
        (OSError("connection refused"), "连不上"),
    ],
)
def test_check_server_says_what_is_wrong_with_the_address(scripted, answer, expected):
    scripted(answer)

    assert expected in (check_server(SERVER) or "")


def test_revoking_the_credential_sends_the_token_and_reports_success(scripted):
    stub = scripted((200, {"data": None}))

    assert revoke_credential(SERVER, "the-token") is True
    assert stub.calls == [("DELETE", f"{SERVER}/api/v1/auth/devices/current", None, "the-token")]


@pytest.mark.parametrize("answer", [(401, None), OSError("unreachable")])
def test_revoking_an_unreachable_or_rejected_credential_is_not_an_error(scripted, answer):
    """断开配对时服务器连不上也照样清本机：只是返回 False，由调用方提醒用户去网页手动注销。"""
    scripted(answer)

    assert revoke_credential(SERVER, "the-token") is False


# -- 真实的 HTTP 往返 --------------------------------------------------------------


class _Echo(http.server.BaseHTTPRequestHandler):
    seen: list[dict] = []

    def log_message(self, *_args):
        pass

    def _reply(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        self.seen.append(
            {
                "method": self.command,
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "content_type": self.headers.get("Content-Type"),
                "user_agent": self.headers.get("User-Agent"),
                "body": body,
            }
        )
        if self.path.endswith("/missing"):
            payload, status = b'{"message": "nope"}', 404
        elif self.path.endswith("/garbage"):
            payload, status = b"<html>not json</html>", 200
        else:
            payload, status = b'{"data": {"ok": true}}', 200
        self.send_response(status)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = do_DELETE = _reply  # noqa: N815


@pytest.fixture
def echo():
    _Echo.seen = []
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Echo)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_address[1]}", _Echo.seen
    server.shutdown()
    server.server_close()


def test_http_json_sends_json_and_the_bearer_token_and_parses_the_answer(echo):
    url, seen = echo

    status, view = http_json("POST", f"{url}/x", {"a": 1}, token="tok")

    assert (status, view) == (200, {"data": {"ok": True}})
    assert seen[0]["authorization"] == "Bearer tok"
    assert seen[0]["content_type"] == "application/json"
    assert json.loads(seen[0]["body"]) == {"a": 1}
    assert seen[0]["user_agent"] == f"MovieClawTranscoder/{__version__}"


def test_http_json_returns_error_statuses_instead_of_raising(echo):
    url, _ = echo

    assert http_json("GET", f"{url}/missing") == (404, {"message": "nope"})


def test_http_json_treats_a_non_json_body_as_empty(echo):
    url, _ = echo

    assert http_json("GET", f"{url}/garbage") == (200, None)


def test_requests_to_the_nas_ignore_the_system_proxy(echo, monkeypatch):
    """常驻的科学上网代理会把内网流量绕出去（实测单连接吞吐压到 1.7 MB/s）：一律直连。"""
    url, seen = echo
    monkeypatch.setenv("HTTP_PROXY", "http://127.0.0.1:9")
    monkeypatch.setenv("http_proxy", "http://127.0.0.1:9")

    assert http_json("GET", f"{url}/x")[0] == 200
    assert len(seen) == 1

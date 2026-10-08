"""iOS 设置验收夹具。只监听 8130；配置写入只修改内存，禁止转发其他写请求。

先启动 8128 临时 MovieClaw，再用 MC_TEST_PASSWORD 启动本脚本。
"""

import copy
import http.client
import http.cookiejar
import json
import os
import urllib.request
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

BASE = "http://127.0.0.1:8128/api/v1"
jar = http.cookiejar.CookieJar()
client = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
client.open(
    urllib.request.Request(
        BASE + "/auth/login",
        json.dumps(
            dict(username="admin", password=os.environ["MC_TEST_PASSWORD"], remember=False)
        ).encode(),
        {"Content-Type": "application/json"},
    )
).close()
paths = [
    "/scrape/config",
    "/network/config",
    "/playback/policy",
    "/transcode-worker/config",
    "/mcp/status",
]
initial = {path: json.load(client.open(BASE + path))["data"] for path in paths}
initial["/scrape/fanart"] = dict(configured=False, key_invalid=False, key_hint="")
initial["/cloud"] = dict(
    state="connected",
    health="ok",
    health_message=None,
    cloud_url="https://api.movieclaw.io",
    custom_cloud_url=False,
    server_name="家庭影院",
    report_stats=True,
    notices=[],
    connection=dict(
        instance_id="fixture",
        instance_name="家庭影院",
        account_display="家人@example.test",
        connected_at="2026-10-01T00:00:00Z",
        scopes=["push"],
        capabilities=["push"],
        limits={"day": 1000},
    ),
)
initial["/llm/providers"] = [
    dict(
        id=901,
        name="验收模型服务",
        provider_type="openai",
        base_url="https://example.test/v1",
        default_model="review-alpha",
        status="active",
        usable=True,
        extra_models=[],
        available_models=["review-alpha", "review-beta"],
        created_at="2026-10-01T00:00:00Z",
        updated_at="2026-10-01T00:00:00Z",
    )
]
initial["/llm/models"] = [
    dict(
        ref=name,
        label=name,
        model_id=name,
        provider_id=901,
        provider_name="验收模型服务",
        is_default=index == 0,
        thinking_levels=[],
    )
    for index, name in enumerate(["review-alpha", "review-beta"])
]
initial["/llm/defaults"] = dict(
    agent_model="review-alpha",
    subtitle_model=None,
    effective_agent_model="review-alpha",
    effective_subtitle_model="review-alpha",
)
initial["/mcp/status"].update(
    enabled=True, base_url="https://example.test", external_url_configured=True
)
initial["/mcp/status"]["endpoints"] = [
    dict(
        id="review",
        slug="review",
        name="验收助手",
        description="只读查询",
        services=["discover"],
        missing_services=[],
        expand_tools=False,
        enabled=True,
        token_hint="…review",
        timeout_seconds=60,
        tool_count=1,
        url="https://example.test/mcp/review",
        created_at="2026-10-01T00:00:00Z",
    )
]
profile_session = json.load(client.open(BASE + "/auth/me"))["data"]
profile_session["nickname"] = "家庭影迷"
profile_devices = [
    dict(
        id=f"ld-fixture-{i}",
        kind="worker",
        kind_label="转码器",
        family="paired",
        name=f"验收转码器{i}",
        scope="transcode",
        created_at="2026-10-01T00:00:00Z",
        current=False,
        connected=True,
        renamable=True,
        owner_id=0,
        owner_username="admin",
        owner_nickname="家庭影迷",
    )
    for i in range(2)
]
avatar_bytes = b""
state = {}


def reset(mode="connected"):
    state.clear()
    state.update(data=copy.deepcopy(initial), writes=[], mode=mode)
    if mode in ("disconnected", "cloud-failure", "pairing"):
        state["data"]["/cloud"].update(state="disconnected", connection=None)
    if mode in ("fanart-configured", "fanart-invalid"):
        state["data"]["/scrape/fanart"].update(
            configured=True, key_invalid=mode == "fanart-invalid", key_hint="1234"
        )
        state["data"]["/scrape/config"]["setting"]["fanart_enabled"] = True
    if mode.startswith("profile"):
        state["data"]["/auth/me"] = copy.deepcopy(profile_session)
        state["data"]["/auth/devices"] = copy.deepcopy(profile_devices)
    if mode == "unhealthy":
        state["data"]["/cloud"].update(
            health="unreachable", health_message="暂时无法连接云端，请重试。"
        )


reset()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, data, status=200, message=""):
        payload = json.dumps(dict(success=status < 400, data=data, message=message)).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def handle_request(self):
        path = urlsplit(self.path).path.removeprefix("/api/v1")
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        data = (
            json.loads(body)
            if body and "multipart/form-data" not in self.headers.get("Content-Type", "")
            else {}
        )
        if path == "/e2e/settings/reset":
            reset(data.get("mode", "connected"))
            return self.reply({})
        if path == "/e2e/settings/approve":
            state["data"]["/cloud"] = copy.deepcopy(initial["/cloud"])
            return self.reply({})
        if path == "/e2e/settings/state":
            return self.reply(state)
        if path == "/e2e/settings/mode":
            state["mode"] = data["mode"]
            return self.reply({})
        if state["mode"].startswith("profile"):
            global avatar_bytes
            session = state["data"]["/auth/me"]
            if path == "/e2e/profile-avatar.jpg":
                self.send_response(200)
                self.send_header("Content-Type", "image/jpeg")
                self.send_header("Content-Length", str(len(avatar_bytes)))
                self.end_headers()
                self.wfile.write(avatar_bytes)
                return
            if self.command == "PUT" and path in ("/auth/profile", "/auth/password"):
                logged = (
                    data
                    if path == "/auth/profile"
                    else {"sign_out_paired": data.get("sign_out_paired", False)}
                )
                state["writes"].append(dict(path=path, body=logged))
                if state["mode"] == "profile-failure":
                    return self.reply(None, 503, "验收：保存失败，请重试")
                if path == "/auth/profile":
                    name = data.get("nickname", "").strip()
                    if not 1 <= len(name) <= 32:
                        return self.reply(None, 422, "昵称需为1–32个字符")
                    session["nickname"] = name
                elif data.get("old_password") != os.environ["MC_TEST_PASSWORD"]:
                    return self.reply(None, 400, "当前密码不正确")
                return self.reply(session)
            if path == "/auth/avatar" and self.command == "POST":
                message = BytesParser(policy=policy.default).parsebytes(
                    ("Content-Type: " + self.headers["Content-Type"] + "\r\n\r\n").encode() + body
                )
                avatar_bytes = next(
                    part.get_payload(decode=True)
                    for part in message.iter_parts()
                    if part.get_param("name", header="content-disposition") == "file"
                )
                state["writes"].append(
                    dict(path=path, body={"jpeg": avatar_bytes.startswith(b"\xff\xd8")})
                )
                if state["mode"] == "profile-failure":
                    return self.reply(None, 503, "验收：头像上传失败")
                session["avatar_url"] = "/api/v1/e2e/profile-avatar.jpg?v=1"
                return self.reply(session)
            if path == "/playback/history" and self.command == "DELETE":
                state["writes"].append(dict(path=path, body={"query": urlsplit(self.path).query}))
                if state["mode"] == "profile-failure":
                    return self.reply(None, 503, "验收：清空失败")
                return self.reply(
                    dict(deleted_states=3, deleted_metrics=2), message="观看记录已清空"
                )
        if path == "/scrape/fanart":
            if self.command == "GET" and state["mode"] == "fanart-status-failure":
                return self.reply(None, 503, "验收：无法读取密钥状态")
            if self.command == "PUT":
                key = data.get("api_key", "").strip()
                state["writes"].append(dict(path=path, body={"api_key": "[redacted]"}))
                if key != "fixture-valid-key":
                    return self.reply(None, 400, "验收：API Key 无效，原密钥未变更")
                status = state["data"][path]
                status.update(configured=True, key_invalid=False, key_hint=key[-4:])
                return self.reply(status)
        if self.command == "GET" and path in state["data"]:
            return self.reply(state["data"][path])
        if self.command == "PUT" and path in state["data"]:
            state["writes"].append(dict(path=path, body=data))
            if state["mode"] == "save-failure":
                return self.reply(None, 503, "验收：保存失败，请重试")
            target = state["data"][path]
            if path == "/scrape/config":
                target["setting"].update(data)
            else:
                target.update(data)
            if path == "/llm/defaults":
                target["effective_agent_model"] = target["agent_model"] or "review-alpha"
                target["effective_subtitle_model"] = (
                    target["subtitle_model"] or target["effective_agent_model"]
                )
            return self.reply(target)
        if path.startswith("/cloud/"):
            cloud = state["data"]["/cloud"]
            state["writes"].append(dict(path=path, body=data))
            if path == "/cloud/pairing":
                if state["mode"] == "pairing":
                    cloud.update(
                        state="pairing",
                        pairing=dict(
                            user_code="REVIEW-1234",
                            verification_uri="http://127.0.0.1:8130/approval",
                            verification_uri_complete="http://127.0.0.1:8130/approval",
                            qrcode_image="",
                            expires_at="2099-01-01T00:00:00Z",
                            status="pending",
                            instance_name=data.get("instance_name", "家庭影院"),
                        ),
                    )
                    return self.reply(cloud)
                return self.reply(None, 503, "验收：暂时无法连接云端，请重试")
            if path == "/cloud/settings":
                if state["mode"] == "save-failure":
                    return self.reply(None, 503, "验收：保存失败，请重试")
                cloud.update(data)
            elif path == "/cloud/disconnect":
                cloud.update(state="disconnected", connection=None)
            elif path == "/cloud/renew":
                cloud.update(health="ok", health_message=None)
            return self.reply(cloud)
        if path == "/network/test":
            return self.reply(dict(ok=True, latency_ms=28, message="验收连接成功"))
        if path == "/mcp/endpoints/preview":
            if state["mode"] == "preview-failure":
                return self.reply(None, 503, "验收：工具目录暂时不可用")
            return self.reply(
                dict(
                    tool_count=1,
                    command_count=7,
                    approx_bytes=1500,
                    tools=[
                        dict(
                            name="discover",
                            summary="发现影片",
                            description="发现影片",
                            service="discover",
                            read_only=True,
                            destructive=False,
                            parameters=[],
                            commands=[],
                        )
                    ],
                )
            )
        if path.startswith("/mcp/endpoints/") and self.command == "PUT":
            endpoint = next(
                e
                for e in state["data"]["/mcp/status"]["endpoints"]
                if e["id"] == path.split("/")[-1]
            )
            endpoint.update(data)
            state["writes"].append(dict(path=path, body=data))
            return self.reply(endpoint)
        if path.startswith("/llm/providers/"):
            provider = state["data"]["/llm/providers"][0]
            if self.command == "PUT":
                state["writes"].append(dict(path=path, body=data))
                if state["mode"] == "save-failure":
                    return self.reply(None, 503, "验收：保存失败，请重试")
                provider.update({k: v for k, v in data.items() if k != "api_key"})
            return self.reply(provider)
        if path == "/approval":
            payload = b"<html><body><h1>MovieClaw fixture approval</h1></body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        # Only authentication may mutate the disposable upstream server.
        if self.command != "GET" and path not in ("/auth/login", "/auth/device/login"):
            return self.reply(None, 403, "夹具禁止转发写请求")
        upstream = http.client.HTTPConnection("127.0.0.1", 8128, timeout=20)
        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in ("host", "connection", "content-length")
        }
        upstream.request(self.command, self.path, body, headers)
        response = upstream.getresponse()
        payload = response.read()
        if (
            state["mode"].startswith("profile")
            and path in ("/auth/login", "/auth/device/login")
            and response.status == 200
        ):
            envelope = json.loads(payload)
            if path == "/auth/device/login":
                envelope["data"]["session"] = state["data"]["/auth/me"]
            else:
                envelope["data"] = state["data"]["/auth/me"]
            payload = json.dumps(envelope).encode()
        self.send_response(response.status)
        for key, value in response.getheaders():
            if key.lower() not in ("transfer-encoding", "connection", "content-length"):
                self.send_header(key, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        upstream.close()

    do_GET = do_POST = do_PUT = do_DELETE = handle_request


ThreadingHTTPServer(("127.0.0.1", 8130), Handler).serve_forever()

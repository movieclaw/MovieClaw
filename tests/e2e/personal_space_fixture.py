"""我的页 UI 验收：python3 tests/e2e/personal_space_fixture.py。

只监听 127.0.0.1:18842，所有数据和会话改动均在内存，无真实服务器连接。
设置 TEST_RUNNER_MC_TEST_PERSONAL_SPACE=1 后运行 xcodebuild test，
只选择 -only-testing:MovieClawUITests/PersonalSpaceUITests。
"""

import json
from datetime import UTC, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

STAMP = datetime.now(UTC).isoformat()
sessions = []
requests = []


def reset():
    now = datetime.now().astimezone().replace(hour=12, minute=0, second=0, microsecond=0)
    titles = [
        "帮我整理周末想看的电影",
        "查看今天的订阅更新",
        "分析最近一周的观看记录",
        "整理科幻电影收藏",
        "继续查找适合全家一起看的电影",
        "检查媒体库中缺失的海报",
    ]
    sessions[:] = [
        dict(
            id=f"personal-{i}",
            title=f"会话 {i:02d}：帮我整理周末想看的电影",
            entry_count=0,
            running=i == 2,
            created_at=STAMP,
            updated_at=(
                now - timedelta(days=0 if i < 4 else 1 if i < 8 else 4, minutes=i)
            ).isoformat(),
        )
        for i in range(25)
    ]
    for i, title in enumerate(titles):
        sessions[i]["title"] = title
    requests.clear()


def identity(username):
    return dict(
        username=username,
        nickname="yee" if username == "admin" else "家庭成员",
        role="admin" if username == "admin" else "member",
        capabilities=dict(
            allow_subscribe=False,
            allow_search=False,
            allow_direct_download=False,
            allow_video_download=username != "restricted",
        ),
    )


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def respond(self, data, status=200, raw=False):
        payload = json.dumps(
            data if raw else dict(success=status == 200, data=data), ensure_ascii=False
        ).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Movieclaw-Spec-Hash", "personal-space-fixture")
        self.end_headers()
        self.wfile.write(payload)

    def handle_request(self):
        url = urlsplit(self.path)
        path = url.path.removeprefix("/api/v1")
        if path.startswith("/e2e/poster/"):
            poster = (
                Path(__file__).resolve().parents[2]
                / "work/personal-space/fixtures"
                / Path(path).name
            )
            if not poster.is_file():
                return self.respond({}, 404)
            payload = poster.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if path == "/e2e/reset":
            reset()
            return self.respond({})
        if path == "/e2e/state":
            return self.respond(dict(requests=requests, count=len(sessions)))
        requests.append(dict(method=self.command, path=path, query=url.query))
        username = self.headers.get("Authorization", "Bearer personal-admin").removeprefix(
            "Bearer personal-"
        )
        if path == "/health":
            return self.respond(
                dict(
                    status="ok",
                    service="movieclaw",
                    environment="test",
                    spec_hash="personal-space-fixture",
                    version="0.38.0",
                    instance_id="personal-space-fixture",
                ),
                raw=True,
            )
        if path == "/auth/bootstrap":
            return self.respond(dict(initialized=True))
        if path == "/auth/device/login":
            username = body["username"]
            device = dict(
                id="ld-personal",
                kind="ios",
                kind_label="iPhone",
                family="login",
                name="验收 iPhone",
                scope="full",
                created_at=STAMP,
                current=True,
                connected=False,
                renamable=True,
                owner_id=0,
                owner_username=username,
                owner_nickname=identity(username)["nickname"],
            )
            return self.respond(
                dict(token="personal-" + username, device=device, session=identity(username))
            )
        if path == "/auth/me":
            return self.respond(identity(username))
        if path == "/sessions":
            query = parse_qs(url.query)
            offset = int(query.get("offset", [0])[0])
            limit = int(query.get("limit", [20])[0])
            return self.respond(sessions[offset : offset + limit])
        if path.startswith("/sessions/"):
            item = next((s for s in sessions if s["id"] == path.split("/")[2]), None)
            if item is None:
                return self.respond({}, 404)
            if self.command == "DELETE":
                sessions.remove(item)
                return self.respond({})
            if self.command == "PATCH":
                item["title"] = body["title"]
                return self.respond(item)
            return self.respond(dict(session=item, entries=[]))
        if path == "/app/update/status":
            return self.respond(
                dict(
                    current_version="0.37.0",
                    code_source="bundled",
                    can_update=True,
                    has_previous=False,
                    bad_versions=[],
                )
            )
        if path == "/app/update/progress":
            return self.respond(dict(phase="idle", detail=""))
        if path == "/app/update/pending":
            return self.respond(
                dict(
                    app_version="0.38.0",
                    app_compatible=True,
                    app_changelog="个人页验收更新说明",
                    app_published_at=STAMP,
                    model_tag=None,
                    checked_at=STAMP,
                )
            )
        if path == "/system/notices":
            return self.respond(
                [
                    dict(
                        id=1,
                        severity="warning",
                        source="site",
                        title="测试站点需要重新登录",
                        message="仅供页面验收",
                        payload={},
                        created_at=STAMP,
                        updated_at=STAMP,
                    )
                ]
            )
        if path in (
            "/libraries",
            "/auth/devices",
            "/llm/models",
            "/llm/providers",
            "/playback/resume",
            "/subscriptions",
        ):
            return self.respond([])
        if path == "/llm/defaults":
            return self.respond({})
        return self.respond({}, 404)

    do_GET = handle_request
    do_POST = handle_request
    do_PATCH = handle_request
    do_DELETE = handle_request


if __name__ == "__main__":
    reset()
    print("Personal space fixture: http://127.0.0.1:18842", flush=True)
    ThreadingHTTPServer(("127.0.0.1", 18842), Handler).serve_forever()

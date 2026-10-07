"""iOS 维护页联调：8129 端口提供更新/任务夹具，其余只读请求转到 8128 临时服务。

启动临时服务后运行 python tests/e2e/maintenance_fixture.py；UI 测试另设
MC_TEST_MAINTENANCE_FIXTURE=1。更新、回退、重启和缓存清理永不转发。
"""

import http.client
import json
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

state = {}


def reset(mode="available"):
    state.clear()
    state.update(mode=mode, version="0.31.0", polls=None, keep=4, actions=[], cleaned=False)
    state["task"] = dict(
        key="fixture",
        title="检查服务器更新",
        description="定期检查版本，不会自动安装。",
        enabled=True,
        trigger_type="interval",
        interval_seconds=1200,
        cron_expr=None,
        last_run_at=None,
        next_run_at=None,
    )


reset()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, data, status=200):
        payload = json.dumps({"success": status < 400, "data": data, "message": ""}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def handle_request(self):
        path = urlsplit(self.path).path.removeprefix("/api/v1")
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        data = json.loads(body) if body else {}
        if path == "/e2e/maintenance/reset":
            reset(data.get("mode", "available"))
            return self.reply({})
        if path == "/e2e/maintenance/state":
            return self.reply(state)
        if path == "/app/storage":
            directory = dict(
                key="posters",
                title="海报缓存",
                summary="浏览时下载的海报图片",
                description="清空后将在下次浏览时重新下载，不影响媒体文件。",
                path="/fixture/cache/posters",
                group="cache",
                rebuild_cost="cheap",
                clearable=True,
                orphan_aware=True,
                exists=True,
                bytes=0 if state["cleaned"] else 104857600,
                entries=120,
            )
            return self.reply(
                dict(
                    computing=False,
                    usage=dict(
                        data_root="/fixture/data",
                        disk_total=100000000000,
                        disk_used=40000000000,
                        disk_free=60000000000,
                        cache_bytes=104857600,
                        data_bytes=1073741824,
                        dirs=[directory],
                        unregistered=[],
                        computed_at=int(time.time()),
                    ),
                )
            )
        if path == "/app/storage/posters/clean":
            state["cleaned"] = True
            state["actions"].append("clean")
            return self.reply(
                dict(
                    key="posters",
                    mode=data["mode"],
                    removed=120,
                    skipped_busy=0,
                    freed_bytes=104857600,
                )
            )
        if path == "/app/update/status":
            return self.reply(
                dict(
                    current_version=state["version"],
                    code_source="overlay",
                    can_update=True,
                    has_previous=True,
                    bad_versions=[],
                    model_tag="2026.10",
                    overlay_version=state["version"],
                )
            )
        if path == "/app/update/pending":
            return self.reply(
                dict(
                    app_version="0.32.0" if state["version"] == "0.31.0" else None,
                    app_compatible=state["mode"] != "incompatible",
                    app_changelog="## 本次更新\n\n- 改善播放体验\n- 优化服务器设置",
                    app_published_at="",
                )
            )
        if path == "/app/update/check":
            return self.reply(
                dict(
                    current_version=state["version"],
                    latest_version="0.32.0",
                    update_available=state["version"] != "0.32.0",
                    compatible=state["mode"] != "incompatible",
                    requires_runtime=1,
                    changelog="## 本次更新\n\n改善播放体验。",
                    published_at="",
                    latest_known_bad=False,
                )
            )
        if path == "/app/update/rollback/options":
            return self.reply(
                dict(
                    keep_versions=state["keep"],
                    versions_dir_bytes=104857600,
                    targets=[
                        dict(
                            kind="overlay",
                            version="0.30.0",
                            schema_action="switch",
                            size_bytes=52428800,
                        )
                    ],
                )
            )
        if path == "/app/update/retention":
            state["keep"] = data["keep_versions"]
            return self.reply(None)
        if path == "/app/update/apply":
            state["polls"] = 0
            state["actions"].append("apply")
            return self.reply(dict(phase="downloading", detail="正在下载更新", percent=10))
        if path == "/app/update/progress":
            if state["polls"] is None:
                return self.reply(dict(phase="idle", detail=""))
            state["polls"] += 1
            if state["polls"] < 3:
                return self.reply(dict(phase="downloading", detail="正在下载更新", percent=40))
            if state["mode"] == "failed":
                return self.reply(
                    dict(
                        phase="failed",
                        detail="",
                        error="测试网络中断，请重试",
                        target_version="0.32.0",
                    )
                )
            state["version"] = "0.32.0"
            state["polls"] = None
            return self.reply(dict(phase="idle", detail=""))
        if path == "/scheduled-tasks":
            return self.reply([state["task"]])
        if path == "/scheduled-tasks/fixture" and self.command == "PUT":
            state["task"].update(data)
            return self.reply(state["task"])
        if self.command != "GET" and not path.startswith("/auth/"):
            return self.reply({"blocked": path}, 403)
        connection = http.client.HTTPConnection("127.0.0.1", 8128, timeout=30)
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in ("host", "connection", "accept-encoding")
        }
        connection.request(self.command, self.path, body=body, headers=headers)
        response = connection.getresponse()
        payload = response.read()
        self.send_response(response.status)
        for key, value in response.getheaders():
            if key.lower() not in ("content-length", "transfer-encoding", "connection"):
                self.send_header(key, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        connection.close()

    do_GET = handle_request
    do_POST = handle_request
    do_PUT = handle_request
    do_DELETE = handle_request


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8129), Handler).serve_forever()

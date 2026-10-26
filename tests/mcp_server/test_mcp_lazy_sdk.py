"""MCP 官方 SDK 按需加载：没人用 MCP 时不导入（整包常驻约 25MB），第一次合法协议请求才加载。

在干净子进程里验证：pytest 进程里别的用例早把 ``mcp`` 导进 ``sys.modules`` 了。
"""

import json
import subprocess
import sys
from pathlib import Path
from textwrap import dedent

SCRIPT = dedent("""
    import json, os, sys, tempfile
    tmp = tempfile.mkdtemp()
    os.environ.update({
        "DATABASE_URL": f"sqlite+aiosqlite:///{tmp}/test.db",
        "SECRET_KEY_FILE": f"{tmp}/.secret_key",
        "SCHEDULER_ENABLED": "false",
        "TMDB_API_KEY": "test-key-not-used",
    })
    from fastapi.testclient import TestClient
    from movieclaw_api.app import create_app
    from movieclaw_mcp.catalog import operations_by_domain
    from movieclaw_mcp.dispatch import build_request

    steps = {}
    with TestClient(create_app()) as c:
        c.post("/api/v1/auth/bootstrap", json={"username": "admin", "password": "s3cret-pass"})
        steps["startup"] = "mcp" in sys.modules
        # 管理页全套：总开关、建端点、列表、预览——都只读工具面，不该碰 SDK
        c.put("/api/v1/mcp/status", json={"enabled": True})
        created = c.post("/api/v1/mcp/endpoints", json={
            "name": "t", "slug": "probe", "services": ["subscriptions", "jobs"],
            "expand_tools": True,
        }).json()["data"]
        listed = c.get("/api/v1/mcp/status")
        preview = c.post("/api/v1/mcp/endpoints/preview", json={
            "services": ["subscriptions"], "expand_tools": False,
        })
        # 插件宿主调用复用 dispatch.build_request
        build_request(next(op for op in operations_by_domain()["jobs"] if not op.required), {})
        # 端点不存在、令牌不对：调度层就答完了
        missing = c.post("/mcp/nope", json={})
        bad_token = c.post("/mcp/probe", headers={"Authorization": "Bearer x"}, json={})
        steps["management"] = "mcp" in sys.modules
        rpc = c.post("/mcp/probe", headers={
            "Authorization": f"Bearer {created['token']}",
            "Accept": "application/json, text/event-stream",
            "MCP-Protocol-Version": "2026-07-28",
            "Mcp-Method": "tools/list",
        }, json={"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {"_meta": {
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientInfo": {"name": "pytest", "version": "1"},
            "io.modelcontextprotocol/clientCapabilities": {},
        }}})
        steps["after_rpc"] = "mcp" in sys.modules
        tools = rpc.json()["result"]["tools"]
        steps["codes"] = [listed.status_code, preview.status_code, missing.status_code,
                          bad_token.status_code, rpc.status_code]
        steps["readonly"] = next(
            t["annotations"]["readOnlyHint"] for t in tools if t["name"] == "subscriptions_list"
        )
    print(json.dumps(steps))
""")


def test_sdk_loads_only_on_first_authenticated_mcp_request():
    result = subprocess.run(
        [sys.executable, "-c", SCRIPT],
        cwd=Path(__file__).resolve().parents[2],
        env={"PATH": "/usr/bin:/bin", "PYTHONPATH": "src"},
        capture_output=True,
        text=True,
        timeout=120,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    steps = json.loads(result.stdout.strip().splitlines()[-1])
    assert steps["startup"] is False
    assert steps["management"] is False
    assert steps["codes"] == [200, 200, 404, 401, 200]
    # 轻量工具结构转成 SDK 类型后，注解照常下发
    assert steps["readonly"] is True
    assert steps["after_rpc"] is True

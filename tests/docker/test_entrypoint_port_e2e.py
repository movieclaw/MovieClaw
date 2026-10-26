"""真实镜像端到端验证：MOVIECLAW_DOCKER_TEST_IMAGE=<本地镜像> pytest -m integration 本文件。

两容器共享网络命名空间，复现 host 模式的端口冲突，同时隔离宿主机的现有服务。
挂载仓库中的镜像启动文件，实际运行 nginx、Next.js 与 FastAPI，数据卷随容器清理。
"""

from __future__ import annotations

import json
import os
import subprocess
import time
import uuid
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen

import pytest

_ROOT = Path(__file__).resolve().parents[2]
_IMAGE = os.environ.get("MOVIECLAW_DOCKER_TEST_IMAGE", "")
pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(not _IMAGE, reason="需指定本地 MOVIECLAW_DOCKER_TEST_IMAGE"),
]


def test_real_image_avoids_internal_frontend_port_conflict() -> None:
    def docker(*args: str) -> str:
        return subprocess.check_output(
            ["docker", *args], text=True, stderr=subprocess.STDOUT, timeout=30
        ).strip()

    name = f"movieclaw-port-e2e-{uuid.uuid4().hex[:8]}"
    app_name = f"{name}-app"
    try:
        # 默认入口 3000 与内部前端 3001 都由其他服务占用。
        docker(
            "run",
            "-d",
            "--name",
            name,
            "-p",
            "127.0.0.1::3005",
            "--entrypoint",
            "node",
            _IMAGE,
            "-e",
            "for (const port of [3000, 3001]) "
            "require('http').createServer((q,s)=>s.end('occupied')).listen(port,'0.0.0.0');",
        )
        docker(
            "exec",
            name,
            "node",
            "-e",
            "fetch('http://127.0.0.1:3001').then(r=>r.text()).then(t=>"
            "{if(t!=='occupied')process.exit(1)}).catch(()=>process.exit(1));",
        )
        mounts = []
        for source, target in (
            ("docker/entrypoint.sh", "/tmp/test-entrypoint.sh"),
            ("docker/resolve-web-port.sh", "/tmp/test-resolve-web-port.sh"),
            ("docker/nginx.conf.template", "/etc/movieclaw/nginx.conf.template"),
            ("docker/runtime-version", "/etc/movieclaw-runtime"),
        ):
            mounts.extend(["-v", f"{_ROOT / source}:{target}:ro"])
        docker(
            "run",
            "-d",
            "--name",
            app_name,
            "--init",
            "--network",
            f"container:{name}",
            "--health-interval=1s",
            "--health-start-period=0s",
            "--health-retries=3",
            "-e",
            "MOVIECLAW_WEB_PORT=3005",
            "-e",
            "MOVIECLAW_NEXT_PORT=13001",
            "-e",
            "MOVIECLAW_HEALTHCHECK_INTERVAL_SECONDS=1",
            "-e",
            "MOVIECLAW_HEALTHCHECK_FAILURE_THRESHOLD=2",
            "--entrypoint",
            "bash",
            *mounts,
            _IMAGE,
            "-c",
            "cp /tmp/test-entrypoint.sh /entrypoint.sh && "
            "cp /tmp/test-resolve-web-port.sh /resolve-web-port.sh && "
            "chmod +x /entrypoint.sh /resolve-web-port.sh && exec /entrypoint.sh",
        )
        address = docker("port", name, "3005/tcp")
        base = f"http://{address}"
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            assert docker("inspect", "-f", "{{.State.Running}}", app_name) == "true"
            try:
                with urlopen(f"{base}/api/v1/health", timeout=2) as response:
                    assert response.status == 200
                with urlopen(base, timeout=2) as response:
                    page = response.read().decode()
                    if not response.headers.get("X-Movieclaw-Starting") and "/_next/" in page:
                        break
            except (OSError, URLError):
                pass
            time.sleep(1)
        else:
            raise AssertionError("自定义端口的页面和 API 未能就绪")

        # 真实 Next 的 rewrite 必须仍能到达 8000，且看门狗持续探测新端口。
        docker(
            "exec",
            app_name,
            "node",
            "-e",
            "fetch('http://127.0.0.1:13001/api/v1/health').then(r=>"
            "process.exit(r.ok?0:1)).catch(()=>process.exit(1));",
        )
        time.sleep(5)
        state = json.loads(docker("inspect", "-f", "{{json .State}}", app_name))
        assert state["Running"]
        assert state["Health"]["Status"] == "healthy"
        assert "前端反代 已就绪：http://127.0.0.1:13001" in docker("logs", app_name)
    except Exception:
        subprocess.run(["docker", "logs", app_name], check=False, timeout=10)
        raise
    finally:
        subprocess.run(["docker", "rm", "-f", "-v", app_name, name], check=False, timeout=30)

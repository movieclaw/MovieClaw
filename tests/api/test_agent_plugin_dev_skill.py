"""内置技能 movieclaw-plugin-dev（Agent 开发插件）的守护测试。

技能是给 Agent 读的文档 + 脚本，最容易悄悄过期：
- 文档里引用的源码路径、技能内文件都必须存在；
- 随技能携带的示例插件与仓库 examples/plugins 一字不差（示例由 CI 端到端测试守着）；
- 骨架脚本生成的插件能通过检查脚本，并能真的打包、上传、批准、在独立进程里加载、调通路由、卸载；
- 检查脚本能拦下典型错误。
"""

from __future__ import annotations

import io
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from movieclaw_agent.skills import BUILTIN_SKILLS_DIR, scan_skills

_REPO = Path(__file__).resolve().parents[2]
_SRC = _REPO / "src"
_SKILL = BUILTIN_SKILLS_DIR / "movieclaw-plugin-dev"
_SCRIPTS = _SKILL / "scripts"
_ENV = {**os.environ, "PYTHONPATH": str(_SRC)}


def _run(script: str, *args: str, cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(_SCRIPTS / script), *args],
        capture_output=True,
        text=True,
        cwd=cwd,
        env=_ENV,
        timeout=180,
    )


def _docs() -> list[Path]:
    return [_SKILL / "SKILL.md", *sorted((_SKILL / "references").glob("*.md"))]


def test_skill_is_discovered_with_description() -> None:
    skills = {s.name: s for s in scan_skills(BUILTIN_SKILLS_DIR, "builtin")}
    skill = skills["movieclaw-plugin-dev"]
    assert "插件" in skill.description and len(skill.description) <= 1024


def _expand(path: str) -> list[str]:
    """``a/{b,c}/d`` → [a/b/d, a/c/d]。"""
    match = re.search(r"\{([^}]+)\}", path)
    if not match:
        return [path]
    return [
        expanded
        for option in match.group(1).split(",")
        for expanded in _expand(path[: match.start()] + option + path[match.end() :])
    ]


def test_source_paths_in_docs_exist() -> None:
    missing: list[str] = []
    for doc in _docs():
        for raw in re.findall(r"\$SRC/([A-Za-z0-9_./{},*-]+)", doc.read_text("utf-8")):
            for path in _expand(raw.rstrip(".,")):
                found = any(_SRC.glob(path)) if "*" in path else (_SRC / path).exists()
                if not found:
                    missing.append(f"{doc.name}: $SRC/{path}")
    assert not missing, "技能文档引用的源码路径不存在：\n" + "\n".join(missing)


def test_skill_relative_paths_in_docs_exist() -> None:
    missing: list[str] = []
    for doc in _docs():
        text = doc.read_text("utf-8")
        for raw in re.findall(r"`((?:references|templates|scripts)/[A-Za-z0-9_./-]+)", text):
            if not (_SKILL / raw.rstrip(".")).exists():
                missing.append(f"{doc.name}: {raw}")
    assert not missing, "技能文档引用的技能内文件不存在：\n" + "\n".join(missing)


def test_bundled_examples_match_repository_examples() -> None:
    bundled = _SKILL / "references" / "examples"
    original = _REPO / "examples" / "plugins"
    drift = [
        str(path.relative_to(bundled))
        for path in sorted(bundled.rglob("*"))
        if path.is_file()
        and path.name != "README.md"
        and path.read_bytes() != (original / path.relative_to(bundled)).read_bytes()
    ]
    assert not drift, (
        "技能里的示例插件与 examples/plugins 不一致，请从 examples/plugins 重新复制：\n"
        + "\n".join(drift)
    )


def test_contracts_script_lists_the_whole_surface(tmp_path) -> None:
    import json

    surface = json.loads((_SRC / "movieclaw_sdk" / "surface.json").read_text("utf-8"))
    listing = _run("contracts.py", cwd=tmp_path)
    assert listing.returncode == 0, listing.stderr
    for name in surface:
        assert f"{name}  [" in listing.stdout, name
    detail = _run("contracts.py", "library.ingest.imported", cwd=tmp_path)
    assert "from movieclaw_api.domain_events import LIBRARY_INGEST_IMPORTED" in detail.stdout
    assert "class IngestImported" in detail.stdout


def test_check_script_accepts_declared_contracts(tmp_path) -> None:
    """清单 [requires] 写了开放契约：检查通过（契约目录要先加载，不能误报「未知契约」）。"""
    made = _run(
        "new_plugin.py", "plugins/me.ok", "--id", "me.ok", "--title", "好插件", cwd=tmp_path
    )
    assert made.returncode == 0, made.stdout + made.stderr
    manifest = tmp_path / "plugins" / "me.ok" / "movieclaw-plugin.toml"
    manifest.write_text(
        manifest.read_text("utf-8").replace(
            '# "library.ingest.imported" = "^1.0"',
            '"library.ingest.imported" = "^1.0"\n"plugin-routes" = "^1.0"',
        ),
        "utf-8",
    )
    checked = _run("check_plugin.py", "plugins/me.ok", cwd=tmp_path)
    assert checked.returncode == 0, checked.stdout + checked.stderr
    assert "未知契约" not in checked.stdout


def test_check_script_catches_typical_mistakes(tmp_path) -> None:
    made = _run(
        "new_plugin.py", "plugins/me.bad", "--id", "me.bad", "--title", "坏插件", cwd=tmp_path
    )
    assert made.returncode == 0, made.stdout + made.stderr
    plugin_dir = tmp_path / "plugins" / "me.bad"
    entry = plugin_dir / "bad.py"
    entry.write_text(
        entry.read_text("utf-8").replace('PLUGIN_ID = "me.bad"', 'PLUGIN_ID = "me.other"'), "utf-8"
    )
    manifest = plugin_dir / "movieclaw-plugin.toml"
    manifest.write_text(
        manifest.read_text("utf-8").replace("operations = []", 'operations = ["no.such-op"]'),
        "utf-8",
    )
    checked = _run("check_plugin.py", "plugins/me.bad", cwd=tmp_path)
    assert checked.returncode == 1
    assert "宿主操作 no.such-op 不存在" in checked.stdout or "读不到宿主操作目录" in checked.stdout
    assert "没有名为 me.bad 的 @plugin" in checked.stdout


# ---------------------------------------------------------------------- 骨架端到端
@pytest.fixture
def data_dir(tmp_path, monkeypatch):
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.services import durable_events, plugin_packages, plugin_runtime

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'skill.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setattr(plugin_runtime, "BACKOFF_MAX", 0.05)
    monkeypatch.setattr(plugin_packages, "GRACE_POLL", 0.1)
    from movieclaw_api import spec_state

    # 路由挂载会在后台重算整份 spec（好几秒），与本用例无关
    monkeypatch.setattr(spec_state, "routes_changed", lambda app: None)
    get_settings.cache_clear()
    durable_events.reset_state()
    yield tmp_path
    for name in [m for m in sys.modules if m.startswith("movieclaw_packages")]:
        del sys.modules[name]
    durable_events.reset_state()
    get_settings.cache_clear()


def _zip(directory: Path) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for path in sorted(directory.rglob("*")):
            if path.is_file() and "__pycache__" not in path.parts:
                archive.write(path, path.relative_to(directory).as_posix())
    return buffer.getvalue()


def test_scaffolded_plugin_installs_serves_and_uninstalls(data_dir) -> None:
    work = data_dir / "workspace"
    work.mkdir()
    made = _run(
        "new_plugin.py",
        "plugins/me.media-stats",
        "--id",
        "me.media-stats",
        "--title",
        "媒体统计",
        cwd=work,
    )
    assert made.returncode == 0, made.stdout + made.stderr
    plugin_dir = work / "plugins" / "me.media-stats"
    assert (plugin_dir / "media_stats.py").is_file()
    checked = _run("check_plugin.py", "plugins/me.media-stats", cwd=work)
    assert checked.returncode == 0, checked.stdout + checked.stderr
    assert "✗" not in checked.stdout

    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services import plugin_runtime
    from movieclaw_api.services.auth import Principal

    app = create_app()
    admin = Principal(kind="admin", name="tester", is_admin=True)
    app.dependency_overrides[require_admin] = lambda: admin
    app.dependency_overrides[require_login] = lambda: admin
    with TestClient(app) as client:
        reply = client.post(
            "/api/v1/app/plugins/packages",
            files={"file": ("me.media-stats.mcplugin", _zip(plugin_dir), "application/zip")},
        )
        assert reply.status_code == 200, reply.text
        assert reply.json()["data"]["runtime"] == "process"
        result = client.post(
            "/api/v1/app/plugins/packages/me.media-stats/approve",
            json={"version": "0.1.0", "operations": [], "paths": []},
        ).json()["data"]
        assert result["status"] == "active", result

        status = client.get("/api/v1/plugins/me.media-stats/status")
        assert status.status_code == 200, status.text
        body = status.json()
        assert body["plugin"] == "me.media-stats" and body["loads"] == 1 and body["loaded_at"]
        assert "me.media-stats" in plugin_runtime.sessions  # 在独立进程里运行

        reply = client.delete("/api/v1/app/plugins/packages/me.media-stats?purge_data=true")
        assert reply.status_code == 200, reply.text
        assert app.state.kernel.fiber("me.media-stats") is None
        assert client.get("/api/v1/plugins/me.media-stats/status").status_code == 404

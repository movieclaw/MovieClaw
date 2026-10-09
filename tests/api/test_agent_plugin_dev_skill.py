"""内置技能 movieclaw-plugin-dev（Agent 开发插件）的守护测试。

技能是给 Agent 读的文档 + 脚本，最容易悄悄过期：
- 文档里引用的源码路径、技能内文件都必须存在；
- 示例插件只在技能的 references/examples/ 一处（端到端测试 test_example_plugins*.py 等守着）；
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


def test_extension_point_catalog_covers_the_whole_surface() -> None:
    """扩展点目录逐个列出全部开放契约：契约有增删时文档必须同步（Agent 靠它判断能不能做）。"""
    import json

    surface = json.loads((_SRC / "movieclaw_sdk" / "surface.json").read_text("utf-8"))
    catalog = (_SKILL / "references" / "extension-points.md").read_text("utf-8")
    missing = [
        name
        for name in surface
        if f"`{name}`" not in catalog and f"/ `{name.rsplit('.', 1)[-1]}`" not in catalog
    ]
    assert not missing, "extension-points.md 缺少这些契约：" + "、".join(missing)


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


def test_scaffold_refuses_to_write_into_the_source_tree(tmp_path) -> None:
    """Agent cd 进技能目录再用相对路径时，插件会被生成进主程序源码：直接拒绝。"""
    target = _SKILL / "plugins" / "stray"
    made = _run("new_plugin.py", str(target), "--id", "stray", "--title", "误放", cwd=tmp_path)
    assert made.returncode == 1
    assert "主程序源码目录" in made.stdout
    assert not (_SKILL / "plugins").exists()


def test_check_script_accepts_declared_contracts(tmp_path) -> None:
    """清单 [requires] 写了开放契约：检查通过（契约目录要先加载，不能误报「未知契约」）。"""
    made = _run(
        "new_plugin.py", "plugins/ok-plugin", "--id", "ok-plugin", "--title", "好插件", cwd=tmp_path
    )
    assert made.returncode == 0, made.stdout + made.stderr
    manifest = tmp_path / "plugins" / "ok-plugin" / "movieclaw-plugin.toml"
    manifest.write_text(
        manifest.read_text("utf-8").replace(
            '# "library.ingest.imported" = "^1.0"',
            '"library.ingest.imported" = "^1.0"\n"plugin-routes" = "^1.0"',
        ),
        "utf-8",
    )
    checked = _run("check_plugin.py", "plugins/ok-plugin", cwd=tmp_path)
    assert checked.returncode == 0, checked.stdout + checked.stderr
    assert "未知契约" not in checked.stdout


def test_check_script_catches_typical_mistakes(tmp_path) -> None:
    made = _run("new_plugin.py", "plugins/bad", "--id", "bad", "--title", "坏插件", cwd=tmp_path)
    assert made.returncode == 0, made.stdout + made.stderr
    plugin_dir = tmp_path / "plugins" / "bad"
    entry = plugin_dir / "bad.py"
    entry.write_text(
        entry.read_text("utf-8").replace('PLUGIN_ID = "bad"', 'PLUGIN_ID = "other"'), "utf-8"
    )
    manifest = plugin_dir / "movieclaw-plugin.toml"
    manifest.write_text(
        manifest.read_text("utf-8").replace("operations = []", 'operations = ["no.such-op"]'),
        "utf-8",
    )
    checked = _run("check_plugin.py", "plugins/bad", cwd=tmp_path)
    assert checked.returncode == 1
    assert "宿主操作 no.such-op 不存在" in checked.stdout or "读不到宿主操作目录" in checked.stdout
    assert "没有名为 bad 的 @plugin" in checked.stdout


def test_check_script_rejects_a_registry_in_inject(tmp_path) -> None:
    """真实会话里出过的错：把 IM_CHANNELS 写进 inject，插件永远等不到这个「服务」。"""
    made = _run("new_plugin.py", "plugins/chan", "--id", "chan", "--title", "通道", cwd=tmp_path)
    assert made.returncode == 0, made.stdout + made.stderr
    entry = tmp_path / "plugins" / "chan" / "chan.py"
    source = entry.read_text("utf-8")
    source = source.replace(
        "from movieclaw_sdk import Context, plugin",
        "from movieclaw_sdk import Context, plugin\nfrom movieclaw_sdk.channels import IM_CHANNELS",
    )
    source = source.replace(
        "inject=(PLUGIN_DATA, PLUGIN_ROUTES)", "inject=(PLUGIN_DATA, PLUGIN_ROUTES, IM_CHANNELS)"
    )
    entry.write_text(source, "utf-8")
    checked = _run("check_plugin.py", "plugins/chan", cwd=tmp_path)
    assert checked.returncode == 1
    # 宿主的 @plugin 也会拦（导入就失败），两种报法都要指明改用 ctx.contribute
    assert "im-channels" in checked.stdout and "ctx.contribute" in checked.stdout


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
        "plugins/media-stats",
        "--id",
        "media-stats",
        "--title",
        "媒体统计",
        cwd=work,
    )
    assert made.returncode == 0, made.stdout + made.stderr
    plugin_dir = work / "plugins" / "media-stats"
    assert (plugin_dir / "media_stats.py").is_file()
    checked = _run("check_plugin.py", "plugins/media-stats", cwd=work)
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
            files={"file": ("media-stats.mcplugin", _zip(plugin_dir), "application/zip")},
        )
        assert reply.status_code == 200, reply.text
        assert reply.json()["data"]["runtime"] == "process"
        result = client.post(
            "/api/v1/app/plugins/packages/media-stats/approve",
            json={"version": "0.1.0", "operations": [], "paths": []},
        ).json()["data"]
        assert result["status"] == "active", result

        status = client.get("/api/v1/plugins/media-stats/status")
        assert status.status_code == 200, status.text
        body = status.json()
        assert body["plugin"] == "media-stats" and body["loads"] == 1 and body["loaded_at"]
        assert "media-stats" in plugin_runtime.sessions  # 在独立进程里运行

        reply = client.delete("/api/v1/app/plugins/packages/media-stats?purge_data=true")
        assert reply.status_code == 200, reply.text
        assert app.state.kernel.fiber("media-stats") is None
        assert client.get("/api/v1/plugins/media-stats/status").status_code == 404

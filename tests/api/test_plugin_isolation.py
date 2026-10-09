"""插件进程隔离（docs/design/plugin-phase3.md §6.1、§6.3，C6b）。

运行目录复制的单测；强制开启隔离（用户就是当前用户，不需要 root）跑一遍真实的进程外插件，
确认它从复制出的运行目录导入代码、HOME 指向自己的临时目录；以 root 运行时再验证真的切换了用户。
"""

from __future__ import annotations

import os
import stat
import sys
import textwrap

import pytest
from fastapi.testclient import TestClient

from movieclaw_api.core.config import get_settings
from movieclaw_api.services import durable_events, plugin_isolation, plugin_runtime


@pytest.fixture
def runtime_root(tmp_path, monkeypatch):
    root = tmp_path / "runtime"
    monkeypatch.setattr(plugin_isolation, "runtime_root", lambda: root)
    return root


def test_stage_source_copies_once_without_caches(tmp_path, runtime_root) -> None:
    src = tmp_path / "src"
    (src / "movieclaw_api" / "__pycache__").mkdir(parents=True)
    (src / "movieclaw_api" / "__init__.py").write_text("__version__ = 'x'\n")
    (src / "movieclaw_api" / "__pycache__" / "a.pyc").write_bytes(b"x")
    (src / "movieclaw_api" / "secret.py").write_text("X = 1\n")
    os.chmod(src / "movieclaw_api" / "secret.py", 0o600)

    first = plugin_isolation.stage_source(src, "1.0")
    assert (first / "movieclaw_api" / "__init__.py").exists()
    assert not (first / "movieclaw_api" / "__pycache__").exists()
    # 插件用户只读：目录 0755、文件 0644（原来 0600 的也放开读，但不可写）
    assert stat.S_IMODE((first / "movieclaw_api" / "secret.py").stat().st_mode) == 0o644
    assert stat.S_IMODE((first / "movieclaw_api").stat().st_mode) == 0o755
    # 同一版本复用；换版本重拷并清掉旧副本
    assert plugin_isolation.stage_source(src, "1.0") == first
    second = plugin_isolation.stage_source(src, "2.0")
    assert second != first and not first.exists()


def test_stage_plugin_copies_only_its_own_code(tmp_path, runtime_root) -> None:
    plugins = tmp_path / "plugins"
    (plugins / "packages").mkdir(parents=True)
    (plugins / "mine.py").write_text("A = 1\n")
    (plugins / "other.py").write_text("B = 2\n")
    staged = plugin_isolation.stage_plugin("acme.mine", plugins, "mine")
    assert sorted(p.name for p in staged.iterdir()) == ["mine.py"]

    package = tmp_path / "pkg"
    (package / "vendor").mkdir(parents=True)
    (package / "movieclaw-plugin.toml").write_text("")
    (package / "entry.py").write_text("")
    (package / "vendor" / "dep.py").write_text("")
    staged = plugin_isolation.stage_plugin("acme.pkg", package, "entry")
    assert (staged / "vendor" / "dep.py").exists() and (staged / "movieclaw-plugin.toml").exists()

    scratch = plugin_isolation.scratch_dir("acme.pkg", plugin_isolation.Isolation())
    assert stat.S_IMODE(scratch.stat().st_mode) == 0o700


PLUGIN = """
import os
import sys

import movieclaw_api
from movieclaw_api import hooks
from movieclaw_sdk import plugin


@plugin("acme.jail", title="隔离验收")
async def apply(ctx) -> None:
    def pick(query):
        where = f"{os.getuid()}|{movieclaw_api.__file__}|{os.environ.get('HOME')}|{os.getcwd()}"
        return hooks.DownloaderChoice(downloader_id=1, reason=where)

    ctx.on(hooks.DOWNLOADER_SELECT, pick, id="pick")
"""


@pytest.fixture
def jailed(tmp_path, runtime_root, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'jail.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    if os.geteuid() != 0:
        # 不是 root：强制开启隔离，但「插件用户」就是自己（只验证运行目录与环境）
        monkeypatch.setattr(
            plugin_isolation,
            "isolation",
            lambda: plugin_isolation.Isolation(uid=os.getuid(), gid=os.getgid()),
        )
    get_settings.cache_clear()
    durable_events.reset_state()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "jail.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            """
            - id: acme.jail
              local: true
              module: jail
              runtime: process
            """
        ),
        encoding="utf-8",
    )
    from movieclaw_api.app import create_app

    app = create_app()
    with TestClient(app) as client:
        yield app, client, runtime_root
    durable_events.reset_state()
    get_settings.cache_clear()


def where(client) -> list[str]:
    from movieclaw_api import hooks

    async def ask():
        choice = await hooks.bail(
            hooks.DOWNLOADER_SELECT, hooks.DownloaderQuery(title="x", media_kind="tv")
        )
        return choice.reason

    return client.portal.call(ask).split("|")


def test_process_plugin_runs_from_the_staged_runtime(jailed) -> None:
    app, client, root = jailed
    assert app.state.kernel.fiber("acme.jail").state.value == "active"
    uid, module_file, home, cwd = where(client)
    # 代码来自复制出的运行目录，不是宿主的源码目录；HOME 是它自己的临时目录
    assert module_file.startswith(str(root.resolve())) or module_file.startswith(str(root))
    assert os.path.realpath(home) == os.path.realpath(root / "run" / "acme.jail")
    assert os.path.realpath(cwd) == os.path.realpath(root / "code" / "acme.jail")
    expected_uid = plugin_isolation.DEFAULT_UID if os.geteuid() == 0 else os.getuid()
    assert int(uid) == expected_uid
    assert plugin_runtime.sessions["acme.jail"].pid != os.getpid()


@pytest.mark.skipif(
    not hasattr(os, "geteuid") or os.geteuid() != 0 or not sys.platform.startswith("linux"),
    reason="真正切换用户需要以 root 运行（Docker 镜像里就是）",
)
def test_root_host_switches_the_plugin_to_nobody(jailed) -> None:
    app, client, _root = jailed
    uid, *_ = where(client)
    assert int(uid) == plugin_isolation.DEFAULT_UID

"""进程外运行器（docs/design/plugin-phase3.md §4，C2）。

真实应用 + ``plugins.yaml`` 里 ``runtime: process`` 的本地插件：插件代码只在子进程里导入；钩子经代理
跨进程调用，``next()`` 带改过的载荷也成立；子进程被杀 → 钩子立刻走默认实现、自动重启后恢复；
卸载不留进程；子进程拿不到主进程的敏感环境变量。
"""

from __future__ import annotations

import os
import sys
import textwrap
import time

import pytest
from fastapi.testclient import TestClient

from movieclaw_api import hooks
from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import durable_events, plugin_runtime

PLUGIN = """
import os

from pydantic import BaseModel

from movieclaw_api import hooks
from movieclaw_sdk import plugin


class Config(BaseModel):
    groups: list[str] = []


@plugin("acme.blocklist", title="发布组黑名单", config=Config)
async def apply(ctx) -> None:
    blocked = set(ctx.config.groups)

    async def drop_groups(batch, next_):
        result = await next_()
        mine = tuple(
            hooks.Rejection(
                key=c.key, reason_code="group", reason_text=f"屏蔽发布组 {c.release_group}"
            )
            for c in batch.candidates
            if c.release_group in blocked
        )
        return hooks.FilterResult(rejected=result.rejected + mine)

    async def more_keywords(payload, next_):
        # 改了载荷再交给下游：下游看到的是改过的
        return await next_(payload.model_copy(update={"keywords": (*payload.keywords, "国语")}))

    def pick(query):
        if query.media_kind == "tv":
            reason = f"剧集走 7 号（pid {os.getpid()}）"
            return hooks.DownloaderChoice(downloader_id=7, reason=reason)
        return None

    ctx.on(hooks.CANDIDATES_FILTER, drop_groups, id="groups")
    ctx.on(hooks.SEARCH_KEYWORDS, more_keywords, id="keywords")
    ctx.on(hooks.DOWNLOADER_SELECT, pick, id="downloader")
    print("blocklist ready", "MASTER_KEY" in os.environ, "DATABASE_URL" in os.environ)
"""


@pytest.fixture
def app_client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'proc.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setenv("MASTER_KEY", "must-not-leak")
    monkeypatch.setattr(plugin_runtime, "BACKOFF_MAX", 0.2)
    get_settings.cache_clear()
    durable_events.reset_state()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "blocklist.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            """
            - id: acme.blocklist
              local: true
              runtime: process
              config: { groups: [BAD] }
            """
        ),
        encoding="utf-8",
    )
    from movieclaw_api.app import create_app

    app = create_app()
    with TestClient(app) as client:
        yield app, client
    durable_events.reset_state()
    get_settings.cache_clear()


def media() -> hooks.MediaBrief:
    return hooks.MediaBrief(id=1, kind="tv", title="测试剧集")


def candidate(key: str, group: str) -> hooks.CandidateView:
    site, torrent = key.split("/")
    return hooks.CandidateView(
        key=key, site_id=site, torrent_id=torrent, title=f"Show S01 {group}", release_group=group
    )


def run_hooks(client) -> tuple[hooks.FilterResult, tuple, hooks.DownloaderChoice | None]:
    batch = hooks.CandidateBatch(
        media=media(),
        subscription_id=1,
        selection_mode="best",
        purpose="wanted",
        candidates=(candidate("s/1", "GOOD"), candidate("s/2", "BAD")),
    )
    keywords = hooks.Keywords(
        media=media(), subscription_id=1, purpose="wanted", keywords=("测试",)
    )

    async def scenario():
        filtered = await hooks.waterfall(
            hooks.CANDIDATES_FILTER, batch, terminal=lambda b: hooks.FilterResult()
        )
        # 终点收到的是插件改过的载荷
        searched = await hooks.waterfall(
            hooks.SEARCH_KEYWORDS, keywords, terminal=lambda k: k.keywords
        )
        chosen = await hooks.bail(
            hooks.DOWNLOADER_SELECT, hooks.DownloaderQuery(title="测试剧集", media_kind="tv")
        )
        return filtered, searched, chosen

    return client.portal.call(scenario)


def wait_for(predicate, timeout: float = 20.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("等待超时")


def test_process_plugin_runs_hooks_out_of_process_and_survives_a_crash(app_client, caplog):
    app, client = app_client
    fiber = app.state.kernel.fiber("acme.blocklist")
    assert fiber.state.value == "active", fiber.error
    # 插件代码只在子进程里导入
    assert not [m for m in sys.modules if m.startswith(PACKAGE) or m == "blocklist"]
    session = plugin_runtime.sessions["acme.blocklist"]
    pid = session.pid
    assert pid != os.getpid()

    filtered, searched, chosen = run_hooks(client)
    assert [r.key for r in filtered.rejected] == ["s/2"]
    assert filtered.rejected[0].reason_text == "屏蔽发布组 BAD"
    assert searched == ("测试", "国语")
    assert chosen is not None and chosen.downloader_id == 7
    assert f"pid {pid}" in chosen.reason
    # 子进程的 print 进了宿主日志；敏感环境变量没有传过去
    logged = [r.getMessage() for r in (*caplog.get_records("setup"), *caplog.records)]
    assert any("blocklist ready False False" in line for line in logged)

    # 杀掉子进程：钩子立刻走默认实现（不卡住决策），随后自动重启恢复
    os.kill(pid, 9)
    wait_for(lambda: not session.online)
    filtered, searched, chosen = run_hooks(client)
    assert filtered.rejected == () and searched == ("测试",) and chosen is None
    wait_for(lambda: session.online and session.pid != pid)
    filtered, _, chosen = run_hooks(client)
    assert [r.key for r in filtered.rejected] == ["s/2"]
    assert chosen is not None and f"pid {session.pid}" in chosen.reason

    # 卸载：进程退出、代理撤销，钩子回到默认
    last_pid = session.pid
    client.portal.call(app.state.kernel.unmount, "acme.blocklist")
    assert "acme.blocklist" not in plugin_runtime.sessions
    with pytest.raises(ProcessLookupError):
        os.kill(last_pid, 0)
    assert not hooks.active(hooks.CANDIDATES_FILTER)


def test_process_plugin_startup_failure_marks_the_entry_failed(tmp_path, monkeypatch) -> None:
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'bad.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    durable_events.reset_state()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "broken.py").write_text(
        textwrap.dedent(
            """
            from movieclaw_sdk import plugin

            @plugin("acme.broken", title="起不来")
            async def apply(ctx) -> None:
                raise RuntimeError("缺少配置 token")
            """
        ),
        encoding="utf-8",
    )
    (tmp_path / "plugins.yaml").write_text(
        "- id: acme.broken\n  local: true\n  runtime: process\n", encoding="utf-8"
    )
    from movieclaw_api.app import create_app

    app = create_app()
    try:
        with TestClient(app):
            fiber = app.state.kernel.fiber("acme.broken")
            assert fiber.state.value == "failed"
            assert "缺少配置 token" in fiber.error
            assert "acme.broken" not in plugin_runtime.sessions
    finally:
        durable_events.reset_state()
        get_settings.cache_clear()


def test_crash_loop_stops_restarting_and_reports(tmp_path, monkeypatch) -> None:
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'loop.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setattr(plugin_runtime, "BACKOFF_MAX", 0.05)
    get_settings.cache_clear()
    durable_events.reset_state()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "flaky.py").write_text(
        textwrap.dedent(
            """
            import asyncio
            import os

            from movieclaw_sdk import plugin

            @plugin("acme.flaky", title="一跑就崩")
            async def apply(ctx) -> None:
                async def die() -> None:
                    await asyncio.sleep(0.05)
                    os._exit(3)

                ctx.task(die(), name="die")
            """
        ),
        encoding="utf-8",
    )
    (tmp_path / "plugins.yaml").write_text(
        "- id: acme.flaky\n  local: true\n  runtime: process\n", encoding="utf-8"
    )
    from movieclaw_api.app import create_app

    app = create_app()
    try:
        with TestClient(app):
            fiber = app.state.kernel.fiber("acme.flaky")
            assert fiber.state.value == "active"
            session = plugin_runtime.sessions["acme.flaky"]
            wait_for(lambda: fiber.stats.last_error is not None, timeout=30)
            assert "已停止重启" in fiber.stats.last_error
            assert not session.online
            pid = session.pid
            with pytest.raises(ProcessLookupError):
                os.kill(pid, 0)
    finally:
        durable_events.reset_state()
        get_settings.cache_clear()

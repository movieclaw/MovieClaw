"""插件安全模式（docs/design/plugin-phase3.md §5）。

决策规则的单测，加一条真实应用的端到端：上次带着本地插件没能稳定运行 → 本次跳过插件
（代码都不导入）、出待处理事项、诊断可见 → 退出安全模式当场挂回 → 正常停机清掉「启动中」记录。
"""

from __future__ import annotations

import json
import sys
import textwrap
import time

import pytest
from fastapi.testclient import TestClient
from sqlmodel import select

from movieclaw_api.core.config import get_settings
from movieclaw_api.plugins import safe_mode
from movieclaw_api.plugins.local import PACKAGE
from movieclaw_api.services import durable_events


class _Settings:
    def __init__(self, data_dir) -> None:
        self.data_dir = str(data_dir)


def state(tmp_path) -> dict:
    return json.loads((tmp_path / safe_mode.STATE_FILE).read_text(encoding="utf-8"))


def write_state(tmp_path, data: dict) -> None:
    (tmp_path / safe_mode.STATE_FILE).write_text(json.dumps(data), encoding="utf-8")


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch):
    monkeypatch.delenv(safe_mode.ENV, raising=False)
    yield
    safe_mode._current = safe_mode.SafeMode()


# ---------------------------------------------------------------------- 决策
def test_unsettled_start_with_plugins_enters_safe_mode_and_stays(tmp_path) -> None:
    settings = _Settings(tmp_path)
    assert not safe_mode.decide(settings, ["acme.a"], now=1000).active
    assert state(tmp_path)["pending"] == {"started_at": 1000, "plugins": ["acme.a"]}

    # 上次的记录还在（没稳定、也没正常停机）：本次跳过插件
    mode = safe_mode.decide(settings, ["acme.a", "acme.b"], now=1030)
    assert mode.active and mode.forced is None
    assert mode.skipped == ["acme.a", "acme.b"]
    assert "acme.a" in mode.reason
    assert state(tmp_path)["pending"] == {"started_at": 1030, "plugins": []}

    # 安全模式下稳定运行、正常停机：记录清掉，但安全模式保持到用户退出
    safe_mode.mark_settled(settings)
    assert safe_mode.decide(settings, ["acme.a"], now=2000).active

    safe_mode.exit_safe_mode(settings, ["acme.a"], now=2100)
    assert not safe_mode.current().active
    assert state(tmp_path) == {"safe": None, "pending": {"started_at": 2100, "plugins": ["acme.a"]}}
    # 挂回的插件又把应用拖垮：下次还会进来
    assert safe_mode.decide(settings, ["acme.a"], now=2130).active


@pytest.mark.parametrize(
    ("pending", "plugins"),
    [
        (None, ["acme.a"]),  # 上次正常停机 / 稳定过
        ({"started_at": 1000, "plugins": []}, ["acme.a"]),  # 上次没加载插件：不怪插件
        ({"started_at": 1000, "plugins": ["acme.a"]}, []),  # 这次没有插件可跳
        ({"started_at": 1000 - 3700, "plugins": ["acme.a"]}, ["acme.a"]),  # 一小时前的陈旧记录
    ],
)
def test_no_safe_mode_without_a_recent_unsettled_plugin_start(tmp_path, pending, plugins) -> None:
    write_state(tmp_path, {"pending": pending})
    assert not safe_mode.decide(_Settings(tmp_path), plugins, now=1000).active


def test_forced_safe_mode_by_env_or_file(tmp_path, monkeypatch) -> None:
    settings = _Settings(tmp_path)
    (tmp_path / safe_mode.FLAG_FILE).touch()
    mode = safe_mode.decide(settings, ["acme.a"])
    assert mode.active and mode.forced == "file"
    safe_mode.exit_safe_mode(settings, ["acme.a"])
    assert not (tmp_path / safe_mode.FLAG_FILE).exists()

    monkeypatch.setenv(safe_mode.ENV, "1")
    assert safe_mode.decide(settings, ["acme.a"]).forced == "env"
    with pytest.raises(PermissionError, match=safe_mode.ENV):
        safe_mode.exit_safe_mode(settings, ["acme.a"])


def test_state_write_failures_never_break_startup(tmp_path, caplog) -> None:
    # 数据目录是个文件：记录写不进去，只告警，照常启动
    blocked = tmp_path / "not-a-dir"
    blocked.write_text("x", encoding="utf-8")
    assert not safe_mode.decide(_Settings(blocked), ["acme.a"]).active
    safe_mode.mark_settled(_Settings(blocked))
    assert "写不进去" in caplog.text


def test_concurrent_writers_do_not_collide(tmp_path) -> None:
    import threading

    settings = _Settings(tmp_path)
    errors: list[BaseException] = []

    def churn() -> None:
        try:
            for _ in range(50):
                safe_mode.decide(settings, ["acme.a"])
                safe_mode.mark_settled(settings)
        except BaseException as exc:  # noqa: BLE001
            errors.append(exc)

    threads = [threading.Thread(target=churn) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert errors == []
    assert not [p for p in tmp_path.iterdir() if p.name.endswith(".tmp")]


def test_unreadable_state_counts_as_no_record(tmp_path) -> None:
    (tmp_path / safe_mode.STATE_FILE).write_text("{oops", encoding="utf-8")
    assert not safe_mode.decide(_Settings(tmp_path), ["acme.a"]).active


# ---------------------------------------------------------------------- 端到端
PLUGIN = """
from movieclaw_kernel import plugin

IMPORTED = True


@plugin("acme.crashy", title="会拖垮应用的插件")
async def apply(ctx) -> None:
    pass
"""


@pytest.fixture
def data_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'safe.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    get_settings.cache_clear()
    durable_events.reset_state()
    (tmp_path / "plugins").mkdir()
    (tmp_path / "plugins" / "crashy.py").write_text(PLUGIN, encoding="utf-8")
    (tmp_path / "plugins.yaml").write_text(
        textwrap.dedent(
            """
            - id: acme.crashy
              local: true
            """
        ),
        encoding="utf-8",
    )
    yield tmp_path
    for name in [m for m in sys.modules if m == PACKAGE or m.startswith(PACKAGE + ".")]:
        del sys.modules[name]
    durable_events.reset_state()
    get_settings.cache_clear()


def open_notices(client) -> list:
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import NoticeStatus, SystemNotice

    async def rows() -> list:
        async with get_database().session() as session:
            return list(
                (
                    await session.execute(
                        select(SystemNotice).where(
                            SystemNotice.dedupe_key == safe_mode.NOTICE_KEY,
                            SystemNotice.status != NoticeStatus.RESOLVED.value,
                        )
                    )
                ).scalars()
            )

    return client.portal.call(rows)


def test_safe_mode_skips_local_plugins_until_the_user_exits(data_dir) -> None:
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    # 上次启动带着 acme.crashy、10 秒前开始，没稳定也没正常停机（进程被它拖垮了）
    write_state(data_dir, {"pending": {"started_at": time.time() - 10, "plugins": ["acme.crashy"]}})
    app = create_app()
    admin = Principal(kind="admin", name="tester")
    app.dependency_overrides[require_admin] = lambda: admin
    app.dependency_overrides[require_login] = lambda: admin
    with TestClient(app) as client:
        kernel = app.state.kernel
        assert kernel.fiber("acme.crashy") is None
        assert f"{PACKAGE}.crashy" not in sys.modules  # 代码都没导入
        view = client.get("/api/v1/app/plugins").json()["data"]["safe_mode"]
        assert view["active"] and view["skipped"] == ["acme.crashy"]
        [notice] = open_notices(client)
        assert "acme.crashy" in notice.message

        reply = client.post("/api/v1/app/plugins/safe-mode/exit")
        assert reply.status_code == 200, reply.text
        assert reply.json()["data"]["mounted"] == {"acme.crashy": "active"}
        assert kernel.fiber("acme.crashy").state.value == "active"
        assert not client.get("/api/v1/app/plugins").json()["data"]["safe_mode"]["active"]
        assert open_notices(client) == []
        assert client.post("/api/v1/app/plugins/safe-mode/exit").status_code == 409
        # 挂回后重新开始计时：这期间再被拖垮，下次还会进安全模式
        assert state(data_dir)["pending"]["plugins"] == ["acme.crashy"]
    # 正常停机：记录清掉，下次正常启动
    assert state(data_dir) == {"safe": None, "pending": None}

    app = create_app()
    with TestClient(app):
        assert app.state.kernel.fiber("acme.crashy").state.value == "active"
        assert not safe_mode.current().active

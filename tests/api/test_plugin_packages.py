"""第三方插件包（docs/design/plugin-phase3.md §2、§3，C5）。

真实应用、真实接口：上传 → 校验 → 待批准 → 批准安装（独立进程）→ 升级失败自动回滚 → 再升级 →
手动回滚 → 重启后照常加载 → 卸载并删数据；不合规的包在上传时就被拒；宽限期内崩溃成循环自动回滚；
申请进程内运行须单独确认。
"""

from __future__ import annotations

import io
import sys
import textwrap
import time
import zipfile

import pytest
from fastapi.testclient import TestClient

from movieclaw_api import hooks
from movieclaw_api.core.config import get_settings
from movieclaw_api.services import durable_events, plugin_packages, plugin_runtime

PLUGIN = """
from movieclaw_api import hooks
from movieclaw_api.plugins.keys import HOST_OPS, PLUGIN_DATA
from movieclaw_sdk import plugin

import acme_dep  # 随包携带的依赖（vendor/）

VERSION = {version}


@plugin(
    "acme-pkg",
    title="包插件",
    inject=(HOST_OPS, PLUGIN_DATA),
    permissions=("app.plugins.list",),
)
async def apply(ctx) -> None:
    {extra}
    ops = await ctx.use(HOST_OPS).client(ctx)
    store = ctx.use(PLUGIN_DATA).scoped(ctx)
    loaded = {{"version": VERSION, "dep": acme_dep.VALUE, "ops": sorted(ops.operations)}}
    await store.set("loaded", loaded)

    def pick(query):
        if query.media_kind == "tv":
            return hooks.DownloaderChoice(downloader_id=VERSION, reason=f"v{{VERSION}}")
        return None

    ctx.on(hooks.DOWNLOADER_SELECT, pick, id="pick")
"""

MANIFEST = """
[plugin]
id = "{id}"
title = "包插件"
version = "{version}.0.0"
entry = "acme_pkg"
runtime = "{runtime}"
sdk = "{sdk}"

[requires]
{requires}

[permissions]
operations = [{operations}]
"""


def package(
    version: int = 1,
    *,
    extra: str = "pass",
    entry_id: str = "acme-pkg",
    runtime: str = "process",
    sdk: str = "^1.0",
    requires: str = '"subscription.candidates.filter" = "^1.0"',
    operations: str = '"app.plugins.list"',
    files: dict[str, str] | None = None,
    manifest: str | None = None,
    source: str | None = None,
) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        if manifest is None:
            manifest = MANIFEST.format(
                id=entry_id,
                version=version,
                runtime=runtime,
                sdk=sdk,
                requires=requires,
                operations=operations,
            )
        if manifest:
            archive.writestr("movieclaw-plugin.toml", manifest)
        if source is None:
            source = textwrap.dedent(PLUGIN.format(version=version, extra=extra))
        archive.writestr("acme_pkg.py", source)
        archive.writestr("vendor/acme_dep.py", "VALUE = 42\n")
        for name, content in (files or {}).items():
            archive.writestr(name, content)
    return buffer.getvalue()


@pytest.fixture
def data_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'pkg.db'}")
    monkeypatch.setenv("SECRET_KEY_FILE", str(tmp_path / ".secret_key"))
    monkeypatch.setenv("SITE_CONFIGS_DIR", str(tmp_path / "site-configs"))
    monkeypatch.setenv("MOVIECLAW_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SCHEDULER_ENABLED", "false")
    monkeypatch.setattr(plugin_runtime, "BACKOFF_MAX", 0.05)
    monkeypatch.setattr(plugin_packages, "GRACE_POLL", 0.1)
    get_settings.cache_clear()
    durable_events.reset_state()
    yield tmp_path
    for name in [m for m in sys.modules if m.startswith("movieclaw_packages")]:
        del sys.modules[name]
    durable_events.reset_state()
    get_settings.cache_clear()


def start():
    from movieclaw_api.api.deps import require_admin, require_login
    from movieclaw_api.app import create_app
    from movieclaw_api.services.auth import Principal

    app = create_app()
    admin = Principal(kind="admin", name="tester")
    app.dependency_overrides[require_admin] = lambda: admin
    app.dependency_overrides[require_login] = lambda: admin
    return app, TestClient(app)


def upload(client, data: bytes):
    return client.post(
        "/api/v1/app/plugins/packages",
        files={"file": ("acme.mcplugin", data, "application/zip")},
    )


def approve(client, version: str, operations=("app.plugins.list",), **extra):
    return client.post(
        "/api/v1/app/plugins/packages/acme-pkg/approve",
        json={"version": version, "operations": list(operations), **extra},
    )


def chosen(client) -> int | None:
    async def ask():
        choice = await hooks.bail(
            hooks.DOWNLOADER_SELECT, hooks.DownloaderQuery(title="剧", media_kind="tv")
        )
        return choice.downloader_id if choice else None

    return client.portal.call(ask)


def stored(client) -> dict | None:
    from movieclaw_api.services.plugin_data import PluginStore
    from movieclaw_db.engine import get_database

    store = PluginStore(get_database(), "acme-pkg")
    return client.portal.call(lambda: store.get("loaded"))


def installed(client) -> dict:
    data = client.get("/api/v1/app/plugins/packages").json()["data"]
    return {p["id"]: p for p in data["installed"]}


def open_notice(client):
    """插件包 acme-pkg 未消退的回滚通知（没有返回 None）。"""
    from sqlmodel import select

    from movieclaw_db.engine import get_database
    from movieclaw_db.models import NoticeStatus, SystemNotice

    async def query():
        async with get_database().session() as session:
            return (
                await session.execute(
                    select(SystemNotice).where(
                        SystemNotice.dedupe_key == "plugin-package:acme-pkg",
                        SystemNotice.status != NoticeStatus.RESOLVED.value,
                    )
                )
            ).scalar()

    return client.portal.call(query)


def wait_for(predicate, timeout: float = 30.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.1)
    raise AssertionError("等待超时")


def test_install_upgrade_rollback_restart_and_uninstall(data_dir) -> None:
    app, client = start()
    with client:
        # 上传：校验通过，进入待批准，列出申请的权限
        reply = upload(client, package(1))
        assert reply.status_code == 200, reply.text
        view = reply.json()["data"]
        assert view["operations"] == ["app.plugins.list"]
        assert view["new_operations"] == ["app.plugins.list"]
        assert view["runtime"] == "process" and view["installed_version"] is None
        # 批准页逐项列出：中文说明 + 是否危险
        [detail] = view["operation_details"]
        assert detail["id"] == "app.plugins.list" and detail["summary"] and not detail["dangerous"]
        assert client.get("/api/v1/app/plugins/packages").json()["data"]["pending"][0]["id"] == (
            "acme-pkg"
        )
        assert app.state.kernel.fiber("acme-pkg") is None  # 没批准不加载

        # 批准的操作必须与申请一致
        assert approve(client, "1.0.0", operations=()).status_code == 400
        result = approve(client, "1.0.0").json()["data"]
        assert result["status"] == "active" and result["version"] == "1.0.0"
        fiber = app.state.kernel.fiber("acme-pkg")
        assert fiber.entry.source == "package" and fiber.plugin.title == "包插件（独立进程）"
        assert chosen(client) == 1
        # 依赖随包携带（vendor/）；宿主操作只拿到批准的那个
        assert stored(client) == {"version": 1, "dep": 42, "ops": ["app.plugins.list"]}

        # 升级到起不来的 v2：自动回到 v1，v2 记为坏版本，并发通知
        assert upload(client, package(2, extra='raise RuntimeError("缺少配置")')).status_code == 200
        result = approve(client, "2.0.0").json()["data"]
        assert result["status"] == "rolled_back" and "缺少配置" in result["error"]
        assert result["version"] == "1.0.0" and result["state"] == "active"
        assert installed(client)["acme-pkg"]["bad_versions"] == ["2.0.0"]
        assert chosen(client) == 1
        assert not (data_dir / "plugins" / "packages" / "acme-pkg" / "2.0.0").exists()
        # 回滚留下一条待处理事项，「去处理」落到插件管理页（网页、App、推送同一套映射）
        from movieclaw_api.services.push.events import notice_path

        notice = open_notice(client)
        assert notice is not None and "缺少配置" in notice.message
        assert notice_path(notice.source, notice.payload) == "/settings/plugins"

        # 正常升级到 v3，再手动回到 v1
        assert upload(client, package(3)).status_code == 200
        assert approve(client, "3.0.0").json()["data"]["status"] == "active"
        assert chosen(client) == 3
        # 新版本跑起来了：回滚那件事翻篇，通知自动消退
        assert open_notice(client) is None
        record = installed(client)["acme-pkg"]
        assert (record["version"], record["previous_version"]) == ("3.0.0", "1.0.0")
        reply = client.post("/api/v1/app/plugins/packages/acme-pkg/rollback")
        assert reply.json()["data"]["version"] == "1.0.0"
        assert chosen(client) == 1
        assert installed(client)["acme-pkg"]["previous_version"] == "3.0.0"

    # 重启：已安装的包照常加载，批准的宿主操作照常生效
    app, client = start()
    with client:
        assert app.state.kernel.fiber("acme-pkg").state.value == "active"
        assert chosen(client) == 1
        assert stored(client)["ops"] == ["app.plugins.list"]

        # 卸载并删数据：进程、目录、数据都不留
        reply = client.delete("/api/v1/app/plugins/packages/acme-pkg?purge_data=true")
        assert reply.status_code == 200, reply.text
        assert reply.json()["data"]["purged_rows"] == 1
        assert app.state.kernel.fiber("acme-pkg") is None
        assert "acme-pkg" not in plugin_runtime.sessions
        assert not (data_dir / "plugins" / "packages" / "acme-pkg").exists()
        assert chosen(client) is None
        assert stored(client) is None


GOOD_MANIFEST = MANIFEST.format(
    id="acme-pkg",
    version=1,
    runtime="process",
    sdk="^1.0",
    requires="",
    operations='"app.plugins.list"',
)
BAD_PACKAGES = {
    "not-zip": (b"not a zip", "不是有效的插件包"),
    "no-manifest": (package(manifest=""), "缺少 movieclaw-plugin.toml"),
    "traversal": (package(files={"../evil.py": "x"}), "不安全的路径"),
    # 内置条目里不带点的 id（带点的内置条目与插件包 id 格式本就不相交）
    "reserved-id": (package(entry_id="scheduler"), "已被内置插件或本地插件占用"),
    "bad-id": (package(entry_id="Acme"), "id"),
    "legacy-id": (package(entry_id="acme.new-plugin"), "旧格式（带点）"),
    "sdk": (package(sdk="^2.0"), "要求 SDK ^2.0"),
    "contract": (package(requires='"no.such.contract" = "^1.0"'), "未知契约"),
    "operation": (package(operations='"no.such.operation"'), "宿主操作 no.such.operation 不存在"),
    "entry": (
        package(manifest=GOOD_MANIFEST.replace('entry = "acme_pkg"', 'entry = "missing"')),
        "找不到入口模块",
    ),
}


@pytest.mark.parametrize("case", sorted(BAD_PACKAGES))
def test_bad_packages_are_rejected_on_upload(data_dir, case) -> None:
    data, message = BAD_PACKAGES[case]
    app, client = start()
    with client:
        reply = upload(client, data)
        assert reply.status_code == 400
        assert message in reply.json()["message"]
        assert client.get("/api/v1/app/plugins/packages").json()["data"]["pending"] == []


def test_symlinks_are_rejected(data_dir) -> None:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr(
            "movieclaw-plugin.toml",
            MANIFEST.format(
                id="acme-pkg", version=1, runtime="process", sdk="^1.0", requires="", operations=""
            ),
        )
        archive.writestr("acme_pkg.py", "")
        link = zipfile.ZipInfo("link")
        link.external_attr = 0o120777 << 16
        archive.writestr(link, "/etc/passwd")
    app, client = start()
    with client:
        reply = upload(client, buffer.getvalue())
        assert reply.status_code == 400 and "软链接" in reply.json()["message"]


def test_crash_loop_during_grace_period_rolls_back(data_dir) -> None:
    # 起得来，但 0.2 秒后就退出：每次重启都一样，崩溃成循环
    flaky = PLUGIN.format(version=2, extra="pass").replace(
        '    ctx.on(hooks.DOWNLOADER_SELECT, pick, id="pick")',
        '    ctx.on(hooks.DOWNLOADER_SELECT, pick, id="pick")\n'
        "    import asyncio, os\n\n"
        "    async def die():\n"
        "        await asyncio.sleep(0.2)\n"
        "        os._exit(3)\n\n"
        '    ctx.task(die(), name="die")',
    )
    app, client = start()
    with client:
        assert upload(client, package(1)).status_code == 200
        assert approve(client, "1.0.0").json()["data"]["status"] == "active"
        assert upload(client, package(2, source=textwrap.dedent(flaky))).status_code == 200
        # 激活时是好的（进程起来了），随后崩溃成循环 → 宽限期观察到后自动回到 v1
        assert approve(client, "2.0.0").json()["data"]["status"] == "active"
        wait_for(lambda: installed(client)["acme-pkg"]["version"] == "1.0.0", timeout=60)
        assert installed(client)["acme-pkg"]["bad_versions"] == ["2.0.0"]
        wait_for(lambda: chosen(client) == 1)
        # 回滚之后直接卸载：通知跟着消退，不留一条再也处理不了的待处理事项
        assert open_notice(client) is not None
        assert client.delete("/api/v1/app/plugins/packages/acme-pkg").status_code == 200
        assert open_notice(client) is None


def test_inline_runtime_needs_explicit_consent(data_dir) -> None:
    app, client = start()
    with client:
        assert upload(client, package(1, runtime="inline")).status_code == 200
        reply = approve(client, "1.0.0")
        assert reply.status_code == 400 and "主进程里运行" in reply.json()["message"]
        result = approve(client, "1.0.0", allow_inline=True).json()["data"]
        assert result["status"] == "active"
        assert "acme-pkg" not in plugin_runtime.sessions  # 没有起子进程
        assert any(m.startswith("movieclaw_packages.acme_pkg") for m in sys.modules)
        assert chosen(client) == 1


def test_inline_upgrade_and_reinstall_run_the_new_code(data_dir) -> None:
    """进程内的包每次挂载都按盘上的代码重新导入：升级、卸载后重装同版本都不跑旧代码。"""
    app, client = start()
    with client:
        assert upload(client, package(1, runtime="inline")).status_code == 200
        assert approve(client, "1.0.0", allow_inline=True).json()["data"]["status"] == "active"
        assert chosen(client) == 1

        assert upload(client, package(2, runtime="inline")).status_code == 200
        assert approve(client, "2.0.0", allow_inline=True).json()["data"]["status"] == "active"
        assert chosen(client) == 2

        assert client.delete("/api/v1/app/plugins/packages/acme-pkg").status_code == 200
        changed = textwrap.dedent(PLUGIN.format(version=7, extra="pass"))
        assert upload(client, package(2, runtime="inline", source=changed)).status_code == 200
        assert approve(client, "2.0.0", allow_inline=True).json()["data"]["status"] == "active"
        assert chosen(client) == 7


REGISTRY_IN_INJECT = """
from movieclaw_sdk import plugin
from movieclaw_sdk.channels import IM_CHANNELS


@plugin("acme-pkg", title="包插件", inject=(IM_CHANNELS,))
async def apply(ctx) -> None:
    pass
"""


@pytest.mark.parametrize("runtime", ["process", "inline"])
def test_registry_written_into_inject_says_how_to_fix(data_dir, runtime) -> None:
    """把注册表写进 inject：两种运行方式都当场失败，并说清该用 ctx.contribute。"""
    app, client = start()
    with client:
        data = package(1, runtime=runtime, source=REGISTRY_IN_INJECT, operations="")
        assert upload(client, data).status_code == 200
        result = approve(client, "1.0.0", operations=(), allow_inline=True).json()["data"]
        assert result["status"] == "rolled_back"
        assert "im-channels 是注册表" in result["error"]
        assert "ctx.contribute" in result["error"]


WAITS_FOR_MISSING_SERVICE = """
from movieclaw_kernel import ServiceKey, Stability
from movieclaw_sdk import plugin

NEVER = ServiceKey("acme/never-provided", stability=Stability.EXPERIMENTAL)


@plugin("acme-pkg", title="包插件", inject=(NEVER,))
async def apply(ctx) -> None:
    pass
"""


def test_rollback_names_the_service_a_pending_package_waits_for(data_dir) -> None:
    app, client = start()
    with client:
        data = package(1, runtime="inline", source=WAITS_FOR_MISSING_SERVICE, operations="")
        assert upload(client, data).status_code == 200
        result = approve(client, "1.0.0", operations=(), allow_inline=True).json()["data"]
        assert result["status"] == "rolled_back"
        assert "acme/never-provided（没有插件提供）" in result["error"]


def test_installed_legacy_dotted_id_keeps_loading_and_upgrading(data_dir, monkeypatch) -> None:
    """改格式前装上的带点 id（代码里写死了）照常加载、照常升级；只有新上传的被拒。"""
    from movieclaw_api.plugins import packages as pkg

    legacy = "acme.legacy"
    source = textwrap.dedent(PLUGIN.format(version=1, extra="pass")).replace("acme-pkg", legacy)
    app, client = start()
    with client:
        # 模拟改格式之前的安装：那时带点 id 合法
        with monkeypatch.context() as m:
            m.setattr(pkg, "is_legacy_id", lambda _id: False)
            assert upload(client, package(1, entry_id=legacy, source=source)).status_code == 200
        reply = client.post(
            f"/api/v1/app/plugins/packages/{legacy}/approve",
            json={"version": "1.0.0", "operations": ["app.plugins.list"]},
        )
        assert reply.json()["data"]["status"] == "active"
        assert chosen(client) == 1

        upgraded = source.replace("VERSION = 1", "VERSION = 2")
        assert upload(client, package(2, entry_id=legacy, source=upgraded)).status_code == 200
        reply = client.post(
            f"/api/v1/app/plugins/packages/{legacy}/approve",
            json={"version": "2.0.0", "operations": ["app.plugins.list"]},
        )
        assert reply.json()["data"]["status"] == "active"
        assert chosen(client) == 2

    app, client = start()
    with client:  # 重启后照常加载
        assert installed(client)[legacy]["version"] == "2.0.0"
        assert chosen(client) == 2

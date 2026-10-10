"""插件详情：把散在内核、插件包、回调、可靠事件里的信息，按用户关心的问题聚合起来。

用户在详情页要回答的问题（不是内核记了什么就摊什么）：

1. 它是什么、谁提供的：说明、版本、来源、是否替换了内置版本、安装时间；
2. 它现在好不好：状态、原因、健康问题（这些在 ``plugin`` 里，前端翻成人话）；
3. 给了它什么权限：宿主操作（危险的标出）、目录、联网、运行方式、回调地址；
4. 装了它系统多了什么（``adds``）：通道、定时任务、后台任务、入库步骤、站点、AI 能调的命令、
   它在什么时候被触发、会影响哪些判断——把它在内核里的登记翻成人话；
5. 它最近干了什么：可靠事件的积压与死信、回调地址的调用；
6. 存了什么：插件数据条数、私有目录占用。

内核细节（服务键、契约版本、耗时）留在 ``plugin`` 里给「技术信息」折叠区用。
"""

from __future__ import annotations

import asyncio
import tomllib
from pathlib import Path
from typing import Any

from movieclaw_kernel import Delivery, Event, Kernel, Mode
from movieclaw_kernel.contracts import CATALOG


def _dir_size(path: Path) -> int:
    if not path.is_dir():
        return 0
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def _manifest_description(path: Path) -> str:
    manifest = path / "movieclaw-plugin.toml"
    if not manifest.is_file():
        return ""
    try:
        return str(tomllib.loads(manifest.read_text("utf-8"))["plugin"].get("description") or "")
    except (OSError, tomllib.TOMLDecodeError, KeyError):
        return ""


def _flatten(routes: list[Any]) -> list[Any]:
    """展开挂进来的子路由器（新版 FastAPI 把它们包成一层，接口在 ``original_router`` 里）。"""
    out: list[Any] = []
    for route in routes:
        inner = getattr(route, "original_router", None)
        out.extend(_flatten(inner.routes) if inner is not None else [route])
    return out


def _owned(entry_id: str, owner: str) -> bool:
    """条目属于这个插件：本身，或它的子条目（``<插件>/<名字>``）。"""
    return owner == entry_id or owner.startswith(f"{entry_id}/")


def _adds(
    kernel: Kernel, entry_id: str, accounts: dict[str, int], durable_events: list[str]
) -> list[dict]:
    """它往系统里加了什么，翻成人话。"""
    from movieclaw_api.pipeline import INGEST_STEPS
    from movieclaw_api.plugins.keys import IM_CHANNELS, SITE_CLASSES, SITE_DATA_PACKS
    from movieclaw_api.services.jobs import JOB_HANDLERS
    from movieclaw_api.services.library.delete_participants import LIBRARY_DELETE_PARTICIPANTS
    from movieclaw_scheduler import SCHEDULED_TASKS

    out: list[dict] = []
    for c in kernel.registry(IM_CHANNELS).contributions():
        if _owned(entry_id, c.entry_id):
            count = accounts.get(c.id, 0)
            detail = f"已接入 {count} 个账号" if count else "还没有接入账号"
            title = getattr(c.item, "title", "") or c.id
            out.append(
                {
                    "kind": "channel",
                    "title": f"消息通道「{title}」",
                    "detail": detail,
                    "href": "/settings/im-push",
                }
            )
    for c in kernel.registry(SCHEDULED_TASKS).contributions():
        if _owned(entry_id, c.entry_id):
            out.append(
                {
                    "kind": "task",
                    "title": f"定时任务「{getattr(c.item, 'title', c.id)}」",
                    "detail": "周期可在「定时任务」里调整",
                    "href": "/settings/app?tab=tasks",
                }
            )
    for c in kernel.registry(INGEST_STEPS).contributions():
        if _owned(entry_id, c.entry_id):
            out.append(
                {
                    "kind": "ingest",
                    "title": f"入库步骤「{getattr(c.item, 'title', c.id)}」",
                    "detail": "整理入库时多做的一步",
                    "href": None,
                }
            )
    jobs = [
        c for c in kernel.registry(JOB_HANDLERS).contributions() if _owned(entry_id, c.entry_id)
    ]
    if jobs:
        out.append(
            {
                "kind": "job",
                "title": f"后台任务 {len(jobs)} 种",
                "detail": "进度在「活动 → 任务」里看",
                "href": "/activity",
            }
        )
    for key, label in ((SITE_DATA_PACKS, "站点配置"), (SITE_CLASSES, "站点适配")):
        mine = [c for c in kernel.registry(key).contributions() if _owned(entry_id, c.entry_id)]
        if mine:
            out.append(
                {
                    "kind": "site",
                    "title": f"{label} {len(mine)} 项",
                    "detail": "在「资源站点」里可用",
                    "href": "/settings/sites",
                }
            )
    for c in kernel.registry(LIBRARY_DELETE_PARTICIPANTS).contributions():
        if _owned(entry_id, c.entry_id):
            out.append(
                {
                    "kind": "delete",
                    "title": f"删除影片时的选项「{_item_label(c)}」",
                    "detail": "删除影片 / 文件的弹窗里可以勾选，默认不勾",
                    "href": None,
                }
            )
    # 其余注册表：不维护清单，凡是它登记过的都列出来，用注册表契约自己的说明。
    # 以后新加的注册表不改这里也能显示（上面几种只是换成更好读的说法）
    known = {
        key.name
        for key in (
            IM_CHANNELS,
            SCHEDULED_TASKS,
            INGEST_STEPS,
            JOB_HANDLERS,
            SITE_DATA_PACKS,
            SITE_CLASSES,
            LIBRARY_DELETE_PARTICIPANTS,
        )
    }
    for registry in kernel.registries():
        if registry.key.name in known:
            continue
        for c in registry.contributions():
            if _owned(entry_id, c.entry_id):
                out.append(
                    {
                        "kind": "other",
                        "title": _item_label(c),
                        "detail": registry.key.doc or registry.key.name,
                        "href": None,
                    }
                )
    # 插件接口：每条都是 mclaw 命令，AI 助手能直接调用（插件路由挂在宿主的插件路由器上）
    from movieclaw_api.services.plugin_routes import host_router

    prefix = f"plugins.{entry_id}."
    commands = sorted(
        {
            "mclaw " + route.operation_id.replace(".", " ")
            for route in _flatten(host_router.routes)
            if (getattr(route, "operation_id", None) or "").startswith(prefix)
        }
    )
    for command in commands:
        out.append(
            {"kind": "command", "title": command, "detail": "AI 助手和命令行都能调用", "href": None}
        )
    # 什么时候被触发、会影响哪些判断
    for listener in kernel.bus.owned_by(entry_id):
        out.append(_listener_view(listener.event))
    for fiber in kernel.fibers:
        if fiber.id != entry_id and _owned(entry_id, fiber.id):
            for listener in kernel.bus.owned_by(fiber.id):
                out.append(_listener_view(listener.event))
    for name in durable_events:
        event = CATALOG.get(name)
        if isinstance(event, Event):
            out.append(_listener_view(event))
    seen: set[tuple[str, str]] = set()
    unique = []
    for item in out:
        key = (item["kind"], item["title"])
        if key not in seen:
            seen.add(key)
            unique.append(item)
    # 先列它带来的功能，再列什么时候被触发，最后是会影响哪些判断
    order = [
        "channel",
        "task",
        "ingest",
        "job",
        "site",
        "delete",
        "other",
        "command",
        "trigger",
        "decision",
    ]
    return sorted(unique, key=lambda item: order.index(item["kind"]))


def _item_label(contribution: Any) -> str:
    """登记项的人话名字：它自己的 label / title / name，没有就用登记 id（去掉插件前缀）。"""
    for attr in ("label", "title", "name"):
        value = getattr(contribution.item, attr, None)
        if isinstance(value, str) and value:
            return value
    prefix = f"{contribution.entry_id}:"
    cid = contribution.id
    return cid[len(prefix) :] if cid.startswith(prefix) else cid


def _event_title(name: str) -> str:
    """事件的人话名字（契约说明），拿不到就用事件名。"""
    contract = CATALOG.get(name)
    return (getattr(contract, "doc", "") or name) if contract is not None else name


def _listener_view(event: Event[Any, Any]) -> dict:
    doc = event.doc or event.name
    if event.mode is Mode.EMIT:
        if event.delivery is Delivery.DURABLE:
            return {
                "kind": "trigger",
                "title": f"「{doc}」后会自动处理",
                "detail": "重启不丢，失败会重试",
                "href": None,
            }
        return {"kind": "trigger", "title": f"「{doc}」时会收到通知", "detail": "", "href": None}
    return {
        "kind": "decision",
        "title": f"会影响：{doc}",
        "detail": "在系统做这个判断时参与决定",
        "href": None,
    }


def _display_path(path: Path, settings: Any) -> str:
    """给人看的路径：数据目录里的按 data/… 显示，应用源码按 src/… 显示（部署目录各不相同）。"""
    path = path.resolve()
    data = Path(getattr(settings, "data_dir", "./data")).resolve()
    try:
        return f"data/{path.relative_to(data).as_posix()}"
    except ValueError:
        pass
    parts = path.parts
    if "src" in parts:
        index = len(parts) - 1 - parts[::-1].index("src")
        return "/".join(parts[index:])
    return str(path)


def _source(
    kernel: Kernel, settings: Any, entry_id: str, kind: str, record: Any, shipped: Any
) -> dict | None:
    """源码在哪：系统模块是入口函数，官方插件是随带的插件包目录，插件包是安装目录，本地插件是文件。"""
    import inspect

    if kind == "package" and record is not None:
        from movieclaw_api.plugins import packages as pkg

        folder = pkg.version_dir(settings, entry_id, record.version)
        return {"path": _display_path(folder, settings), "entry": None}
    if kind == "official" and shipped is not None:
        return {
            "path": _display_path(shipped.path, settings),
            "entry": shipped.manifest.plugin.entry,
        }
    if kind == "local":
        from movieclaw_api.plugins.local import local_specs, plugins_dir

        spec = next((s for s in local_specs(settings) if s.id == entry_id), None)
        if spec is not None:
            root = plugins_dir(settings)
            target = root / f"{spec.module}.py"
            if not target.exists():
                target = root / spec.module
            return {"path": _display_path(target, settings), "entry": spec.module}
        return None
    fiber = kernel.fiber(entry_id)
    if fiber is None:
        return None
    apply = inspect.unwrap(fiber.entry.plugin.apply)
    try:
        file = inspect.getsourcefile(apply)
        line = inspect.getsourcelines(apply)[1]
    except (OSError, TypeError):
        return None
    if file is None:
        return None
    # 名称只放函数名：模块就是 path 里那个文件，再写一遍点号形式像是第二个路径
    return {
        "path": f"{_display_path(Path(file), settings)}:{line}",
        "entry": f"{apply.__qualname__}()",
    }


async def plugin_detail(kernel: Kernel, settings: Any, entry_id: str, item: dict) -> dict:
    """``item`` 是插件列表里这一行（已带状态、健康、层级）。"""
    from movieclaw_api.plugins import packages as pkg
    from movieclaw_api.plugins.bundled import bundled, canonical
    from movieclaw_api.plugins.keys import PLUGIN_DATA
    from movieclaw_api.services.plugin_callbacks import get_service
    from movieclaw_api.services.plugin_packages import operation_details
    from movieclaw_kernel import DURABLE_EVENTS

    record = pkg.installed(settings).get(entry_id)
    shipped = bundled().get(canonical(entry_id))
    source = item["source"]
    kind = (
        "package"
        if record is not None
        else "official"
        if item.get("tier") == "official"
        else "local"
        if source == "local"
        else "system"
    )
    description = ""
    version = None
    package = None
    network = None
    if record is not None:
        folder = pkg.version_dir(settings, entry_id, record.version)
        description = _manifest_description(folder)
        version = record.version
        package = {
            "version": record.version,
            "installed_at": record.installed_at or None,
            "previous_version": (record.previous or {}).get("version"),
            "bad_versions": record.bad,
            "operations": operation_details(record.operations),
            "paths": record.paths,
            "callbacks": record.callbacks,
            "replaces_builtin": shipped is not None,
        }
        try:
            manifest = pkg.Manifest.model_validate(
                tomllib.loads((folder / pkg.MANIFEST).read_text("utf-8"))
            )
            network = manifest.permissions.network
        except (OSError, ValueError, tomllib.TOMLDecodeError):
            network = None
    elif shipped is not None:
        description = shipped.manifest.plugin.description
        version = shipped.manifest.plugin.version

    accounts: dict[str, int] = {}
    try:
        from movieclaw_api.services.channel_hub import get_hub

        hub = get_hub()
        if hub is not None:
            for row in await hub.accounts():
                accounts[row.channel_id] = accounts.get(row.channel_id, 0) + 1
    except Exception:  # noqa: BLE001 -- 通道中枢没在运行时不影响详情
        accounts = {}

    store = kernel.service(DURABLE_EVENTS)
    consumers: list[dict] = []
    dead_letters: list[dict] = []
    if store is not None:
        durable = await store.describe()
        consumers = [
            {**c, "title": _event_title(c["event"])}
            for c in durable["consumers"]
            if c["consumer_id"].startswith(f"{entry_id}:")
        ]
        dead_letters = [
            {**d, "title": _event_title(d["event"])}
            for d in durable["dead_letters"]
            if d["consumer_id"].startswith(f"{entry_id}:")
        ]
    callbacks = get_service()
    data_service = kernel.service(PLUGIN_DATA)
    data_rows = (await data_service.counts()).get(entry_id, 0) if data_service is not None else 0
    folder = Path(getattr(settings, "data_dir", "./data")) / "plugins" / "data" / entry_id
    disk_bytes = await asyncio.to_thread(_dir_size, folder)
    children = [p for p in kernel.snapshot() if p.get("parent") == entry_id]
    return {
        "kind": kind,
        "description": description,
        "version": version,
        "network": network,
        "package": package,
        "adds": _adds(kernel, entry_id, accounts, [c["event"] for c in consumers]),
        "consumers": consumers,
        "dead_letters": dead_letters,
        "callbacks": await callbacks.overview(entry_id) if callbacks is not None else [],
        "data_rows": data_rows,
        "disk_bytes": disk_bytes,
        "children": [c["id"] for c in children],
        "source": _source(kernel, settings, entry_id, kind, record, shipped),
    }

"""插件扩展底座：可靠事件投递与宿主操作（docs/design/plugin-phase2a.md §2、§3）。

``kernel.durable-events`` 提供 ``DURABLE_EVENTS``：订阅了可靠事件的插件注入它，内核经它登记
监听器。本插件停用时那些插件因缺依赖进入等待；业务侧照常写事件行（名单由库里的消费者行决定），恢复后补投。

``kernel.host-ops`` 提供 ``HOST_OPS``：插件以自己的身份调用本进程的 OpenAPI 操作。
"""

from __future__ import annotations

from movieclaw_api.plugins.keys import (
    DB,
    HOST_OPS,
    PLUGIN_CALLBACKS,
    PLUGIN_DATA,
    PLUGIN_FILES,
    PLUGIN_HEALTH,
    PLUGIN_ROUTES,
)
from movieclaw_kernel import DURABLE_EVENTS, Context, plugin


@plugin(
    "kernel.durable-events",
    title="可靠事件投递",
    inject=(DB,),
    provides=(DURABLE_EVENTS,),
    disableable=True,
    reloadable=True,
)
async def durable_events(ctx: Context) -> None:
    from movieclaw_api.services.durable_events import DurableEvents

    store = DurableEvents(ctx.use(DB))
    ctx.effect(store.close, label="close-durable-events")
    store.start_housekeeping()
    ctx.provide(DURABLE_EVENTS, store)


@plugin(
    "kernel.host-ops",
    title="宿主操作",
    provides=(HOST_OPS,),
    disableable=True,
    reloadable=True,
)
async def host_ops(ctx: Context) -> None:
    from movieclaw_api.plugins.local import configure_host_ops
    from movieclaw_api.services import host_ops as service

    if service._app is None:
        raise RuntimeError("应用尚未绑定（宿主操作只能在运行中的应用里提供）")
    host = service.HostOps(service._app)
    # 用户在 plugins.yaml 里给本地插件的批准（grants、act_as）
    configure_host_ops(host, ctx.settings)
    # 插件包：用户在安装时批准的宿主操作（plugins/packages.py）
    from movieclaw_api.plugins import packages

    packages.configure_host_ops(host, ctx.settings)
    ctx.provide(HOST_OPS, host)


@plugin(
    "kernel.plugin-data",
    title="插件数据",
    inject=(DB,),
    provides=(PLUGIN_DATA,),
    disableable=True,
    reloadable=True,
)
async def plugin_data(ctx: Context) -> None:
    from movieclaw_api.services.plugin_data import PluginDataService

    ctx.provide(PLUGIN_DATA, PluginDataService(ctx.use(DB)))


@plugin(
    "kernel.plugin-health",
    title="插件健康",
    inject=(DB,),
    provides=(PLUGIN_HEALTH,),
    disableable=True,
    reloadable=True,
)
async def plugin_health(ctx: Context) -> None:
    from movieclaw_api.services.plugin_health import PluginHealthService

    ctx.provide(PLUGIN_HEALTH, PluginHealthService(ctx.use(DB)))


@plugin(
    "kernel.plugin-routes",
    title="插件路由",
    inject=(DB,),
    provides=(PLUGIN_ROUTES,),
    disableable=True,
    reloadable=True,
)
async def plugin_routes(ctx: Context) -> None:
    from movieclaw_api.services import host_ops
    from movieclaw_api.services.plugin_data import PluginStore
    from movieclaw_api.services.plugin_routes import PluginRoutes

    if host_ops._app is None:
        raise RuntimeError("应用尚未绑定（插件路由只能挂在运行中的应用上）")
    db = ctx.use(DB)
    ctx.provide(
        PLUGIN_ROUTES, PluginRoutes(host_ops._app, lambda entry_id: PluginStore(db, entry_id))
    )


@plugin(
    "kernel.plugin-callbacks",
    title="插件回调端点",
    inject=(DB,),
    provides=(PLUGIN_CALLBACKS,),
    disableable=True,
    reloadable=True,
)
async def plugin_callbacks(ctx: Context) -> None:
    from movieclaw_api.services import plugin_callbacks as callbacks

    service = callbacks.PluginCallbacks(ctx.settings, ctx.use(DB))
    callbacks.set_service(service)
    ctx.effect(lambda: callbacks.set_service(None), label="callbacks")
    ctx.provide(PLUGIN_CALLBACKS, service)


@plugin(
    "kernel.plugin-files",
    title="插件文件",
    inject=(DB,),
    provides=(PLUGIN_FILES,),
    disableable=True,
    reloadable=True,
)
async def plugin_files(ctx: Context) -> None:
    from movieclaw_api.plugins import packages
    from movieclaw_api.plugins.local import local_specs
    from movieclaw_api.services.plugin_files import PluginFilesService, parse_grants

    service = PluginFilesService(ctx.use(DB), getattr(ctx.settings, "data_dir", "./data"))
    # 用户批准的路径：本地插件在 plugins.yaml，插件包在安装记录
    for spec in local_specs(ctx.settings):
        service.configure(spec.id, spec.paths)
    for package in packages.installed(ctx.settings).values():
        service.configure(package.id, parse_grants(package.paths))
    ctx.provide(PLUGIN_FILES, service)

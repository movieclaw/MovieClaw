"""__PLUGIN_TITLE__：__PLUGIN_DESCRIPTION__

骨架只演示最常用的三件事，按需求删改：
- 插件数据（PLUGIN_DATA）：存自己的状态，重启、升级都在；
- 插件路由（PLUGIN_ROUTES）：GET /api/v1/plugins/__PLUGIN_ID__/status（管理员区），方便验证插件在跑；
- 日志：ctx.logger。
"""

import time

from fastapi import APIRouter

from movieclaw_api.plugins.keys import PLUGIN_DATA, PLUGIN_ROUTES
from movieclaw_sdk import Context, plugin

PLUGIN_ID = "__PLUGIN_ID__"


@plugin(
    PLUGIN_ID,                      # 必须与清单 [plugin] id 完全一致
    title="__PLUGIN_TITLE__",
    inject=(PLUGIN_DATA, PLUGIN_ROUTES),
    permissions=(),                 # 与清单 permissions.operations 保持一致
)
async def apply(ctx: Context) -> None:
    # apply 只做登记，30 秒内必须返回；耗时工作放进 ctx.task(...)
    store = ctx.use(PLUGIN_DATA).scoped(ctx)
    routes = ctx.use(PLUGIN_ROUTES)

    loads = int(await store.get("loads", default=0)) + 1
    await store.set("loads", loads)
    await store.set("loaded_at", int(time.time()))

    router = APIRouter()

    @router.get(
        "/status",
        operation_id=f"plugins.{PLUGIN_ID}.status",   # 必须以 plugins.<条目 id>. 开头
        summary="__PLUGIN_TITLE__：运行状态",
    )
    async def status() -> dict:
        return {
            "plugin": PLUGIN_ID,
            "loads": await store.get("loads", default=0),
            "loaded_at": await store.get("loaded_at"),
        }

    routes.mount(ctx, router)       # 默认 admin 区；卸载时自动摘除
    ctx.logger.info("%s 已加载（第 %d 次）", PLUGIN_ID, loads)

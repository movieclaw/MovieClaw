"""可靠事件投递（docs/design/plugin-phase2a.md §2）。

提供 ``DURABLE_EVENTS``：订阅了可靠事件的插件注入它，内核经它登记监听器。本插件停用时
那些插件因缺依赖进入等待；业务侧照常写事件行（名单由库里的消费者行决定），恢复后补投。
"""

from __future__ import annotations

from movieclaw_api.plugins.keys import DB
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

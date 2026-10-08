"""插件启动失败 → 待处理事项（docs/design/plugin-kernel.md §9）。

非关键子系统启动失败或超时不再中止启动：内核把它标成失败，其余照常。这个插件订阅
内核的状态事件，把失败写成一条待处理事项（同时推到管理员手机），插件恢复运行或被
禁用时自动消退——问题不会被忽视，也不会在修好之后还挂着。

内核本身不依赖待处理事项（它是叶子包）；这里是第一阶段唯一一个真实的事件订阅者。
"""

from __future__ import annotations

import logging

from movieclaw_api.plugins.keys import DB, SETTING_STORE
from movieclaw_kernel import PLUGIN_STATE, Context, PluginStateChanged, plugin

logger = logging.getLogger("movieclaw_api.plugins.notices")

#: 待处理事项的去重键前缀：一个插件条目一行
NOTICE_PREFIX = "plugin:"


@plugin("kernel.notices", title="插件故障提醒", inject=(DB, SETTING_STORE))
async def plugin_notices(ctx: Context) -> None:
    from sqlmodel import select

    from movieclaw_api.services.system_notice import resolve_notices, upsert_notice
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import NoticeSeverity, NoticeStatus, SystemNotice

    # 只对「有过告警」的条目做消退，免得启动时几十个插件各查一次库
    async with get_database().session() as session:
        rows = (
            await session.execute(
                select(SystemNotice.dedupe_key).where(
                    SystemNotice.dedupe_key.startswith(NOTICE_PREFIX),  # type: ignore[union-attr]
                    SystemNotice.status != NoticeStatus.RESOLVED.value,  # type: ignore[arg-type]
                )
            )
        ).scalars()
        open_keys: set[str] = set(rows)

    async def on_state(change: PluginStateChanged) -> None:
        key = f"{NOTICE_PREFIX}{change.entry_id}"
        if change.state == "failed":
            async with get_database().session() as session:
                await upsert_notice(
                    session,
                    dedupe_key=key,
                    severity=NoticeSeverity.WARNING,
                    source="plugin",
                    title=f"「{change.title or change.entry_id}」启动失败",
                    message=(
                        f"{change.error or '未知原因'}。其余功能不受影响；"
                        "修复后重启应用即可恢复，详情见「设置 → 更新与维护 → 模块」。"
                    ),
                    payload={"entry_id": change.entry_id},
                )
            open_keys.add(key)
        elif change.state in ("active", "disabled") and key in open_keys:
            async with get_database().session() as session:
                await resolve_notices(session, dedupe_key=key)
            open_keys.discard(key)

    ctx.on(PLUGIN_STATE, on_state, id="failure-notices")

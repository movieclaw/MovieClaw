"""插件健康服务 ``PLUGIN_HEALTH``（docs/design/plugin-phase2b.md §5）。

常驻任务要能说出「我现在不好」：令牌过期、外部系统连不上。

::

    health = ctx.use(PLUGIN_HEALTH).reporter(ctx)
    await health.degraded("trakt", "Trakt 令牌已过期", action_href="/settings/plugins?tab=builtin")
    await health.ok("trakt")

降级 → 系统通知（warning，键 ``plugin:<条目 id>:health:<键>``，与启动失败的
``plugin:<条目 id>`` 分开）；恢复 → 消退。
当前状态在内存里，诊断接口直接读；插件卸载时它的降级通知一并消退。
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from movieclaw_db.engine import Database
from movieclaw_db.models import utcnow


@dataclass
class HealthItem:
    key: str
    ok: bool
    message: str
    action_href: str | None
    since: str


def _notice_key(entry_id: str, key: str) -> str:
    return f"plugin:{entry_id}:health:{key}"


class HealthReporter:
    def __init__(self, service: PluginHealthService, entry_id: str, title: str) -> None:
        self._service = service
        self.entry_id = entry_id
        self._title = title

    async def degraded(self, key: str, message: str, *, action_href: str | None = None) -> None:
        if action_href is not None and not action_href.startswith("/"):
            raise ValueError("action_href 只能是站内路径（以 / 开头）")
        await self._service._report(self.entry_id, self._title, key, False, message, action_href)

    async def ok(self, key: str, message: str = "") -> None:
        await self._service._report(self.entry_id, self._title, key, True, message, None)


class PluginHealthService:
    def __init__(self, db: Database) -> None:
        self._db = db
        self._state: dict[str, dict[str, HealthItem]] = {}

    def reporter(self, ctx: Any) -> HealthReporter:
        reporter = HealthReporter(self, ctx.entry_id, ctx.title)
        ctx.effect(lambda: self.forget(ctx.entry_id), label="forget-health")
        return reporter

    def snapshot(self) -> dict[str, list[dict[str, Any]]]:
        return {
            entry: [vars(item) for item in items.values()]
            for entry, items in self._state.items()
            if items
        }

    async def forget(self, entry_id: str) -> None:
        """插件卸载：它报告的降级不再成立，通知消退。"""
        items = self._state.pop(entry_id, {})
        if any(not item.ok for item in items.values()):
            from movieclaw_api.services.system_notice import resolve_notices

            async with self._db.session() as session:
                await resolve_notices(session, prefix=f"plugin:{entry_id}:health:")

    async def _report(
        self,
        entry_id: str,
        title: str,
        key: str,
        ok: bool,
        message: str,
        action_href: str | None,
    ) -> None:
        from movieclaw_api.services.system_notice import resolve_notices, upsert_notice
        from movieclaw_db.models import NoticeSeverity

        items = self._state.setdefault(entry_id, {})
        previous = items.get(key)
        changed = previous is None or previous.ok != ok or previous.message != message
        items[key] = HealthItem(
            key=key,
            ok=ok,
            message=message,
            action_href=action_href,
            since=previous.since
            if previous is not None and previous.ok == ok
            else utcnow().isoformat() + "+00:00",
        )
        if not changed:
            return
        async with self._db.session() as session:
            if ok:
                await resolve_notices(session, dedupe_key=_notice_key(entry_id, key))
            else:
                await upsert_notice(
                    session,
                    dedupe_key=_notice_key(entry_id, key),
                    severity=NoticeSeverity.WARNING,
                    source="plugin",
                    title=f"插件「{title}」运行异常",
                    message=message,
                    payload={"entry_id": entry_id, "key": key, "action_href": action_href},
                )

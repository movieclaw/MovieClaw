"""插件建自己的后台任务（``PLUGIN_JOBS``，docs/design/plugin-strm-prefetch.md §2）::

    jobs = ctx.use(PLUGIN_JOBS).scoped(ctx)
    ref = await jobs.create("my-sync:sync", dedupe_key="all", priority=-10)

只能建本插件贡献的任务类型（``JOB_HANDLERS`` 里归它的，或带它 id 前缀的）；去重键按插件隔离
（落库时加插件 id 前缀），不会撞到别的插件或主程序的任务。
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Any

from movieclaw_kernel import Registry
from movieclaw_sdk.jobs import JobRef, ResourceRef


class PluginJobsService:
    def __init__(self, handlers: Registry[Any]) -> None:
        self._handlers = handlers

    def scoped(self, ctx: Any) -> ScopedJobs:
        return ScopedJobs(self._handlers, ctx.entry_id)


class ScopedJobs:
    def __init__(self, handlers: Registry[Any], entry_id: str) -> None:
        self._handlers = handlers
        self.entry_id = entry_id

    def _owns(self, job_type: str) -> bool:
        if job_type.startswith(f"{self.entry_id}:"):
            return True
        return job_type in self._handlers.owned_by(self.entry_id)

    async def create(
        self,
        job_type: str,
        *,
        input: dict[str, Any] | None = None,
        subject: str | None = None,
        priority: int = 0,
        dedupe_key: str | None = None,
        resources: Sequence[ResourceRef] = (),
    ) -> JobRef:
        from movieclaw_api.services import jobs
        from movieclaw_db.engine import get_database

        if not self._owns(job_type):
            raise PermissionError(f"插件 {self.entry_id} 只能建自己的任务类型，{job_type} 不是")
        # 进程外插件在 apply 里建任务时处理器还没登记（就绪时才一并声明）：先记为认识的类型，
        # 执行器等处理器到了再领，而不是当成没人认识的类型领走报「请更新」
        jobs.note_job_type(job_type)
        async with get_database().session() as session:
            result = await jobs.create_job(
                session,
                job_type=job_type,
                input_data=dict(input or {}),
                subject=subject,
                priority=priority,
                dedupe_key=f"{self.entry_id}:{dedupe_key}" if dedupe_key else None,
                resources=list(resources),
                actor_kind="plugin",
                actor_name=self.entry_id,
                origin="plugin",
            )
        if result.created:
            jobs.wake_job_dispatcher()
        job = result.job
        return JobRef(
            id=job.id,
            job_type=job.job_type,
            status=getattr(job.status, "value", job.status),
            created=result.created,
        )

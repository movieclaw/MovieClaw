"""Real rescheduling with an initially empty APScheduler and an isolated mount table."""

import os
from contextlib import asynccontextmanager

from tests.e2e._smart_api_launcher import app

from movieclaw_api.api.routes import scheduled_tasks
from movieclaw_api.services.library import mounts
from movieclaw_scheduler.config import SchedulerConfig
from movieclaw_scheduler.service import SchedulerService

mounts.MOUNTS_FILE = os.environ["E2E_SCHEDULE_MOUNTS"]
mounts._mounts_snapshot.cache_clear()
original_lifespan = app.router.lifespan_context
scheduler = None


@asynccontextmanager
async def lifespan(application):
    global scheduler
    async with original_lifespan(application):
        scheduler = SchedulerService(SchedulerConfig())
        # Keep unrelated built-ins unscheduled. The real API adds only the tasks changed by the UI.
        scheduler._scheduler.start()
        scheduled_tasks.try_get_scheduler = lambda: scheduler
        try:
            yield
        finally:
            await scheduler.shutdown()


app.router.lifespan_context = lifespan


@app.get("/__lab/scheduled/jobs")
async def scheduled_jobs():
    if scheduler is None:
        return []
    return [
        {
            "key": job.id,
            "next_run_at": job.next_run_time.isoformat(),
            "trigger_type": type(job.trigger).__name__,
            "seconds": job.trigger.interval.total_seconds()
            if hasattr(job.trigger, "interval")
            else None,
        }
        for job in scheduler._scheduler.get_jobs()
    ]

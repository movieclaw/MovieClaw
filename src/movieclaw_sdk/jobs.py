"""后台任务契约（docs/design/plugin-strm-prefetch.md §2、persistent-jobs.md）。

插件贡献任务处理器（``JOB_HANDLERS``），用 ``PLUGIN_JOBS`` 建自己的任务；任务落库、排队、按优先级
领取、断点续跑、取消、在任务中心展示都由主程序负责::

    from movieclaw_sdk import plugin
    from movieclaw_sdk.jobs import JOB_HANDLERS, PLUGIN_JOBS, JobContext, RegisteredJobHandler

    async def sync(context: JobContext, data: dict) -> dict:
        await context.update_progress(mode="determinate", phase="sync", message="同步中")
        ...
        return {"synced": 3}

    @plugin("my-sync", title="同步", inject=(PLUGIN_JOBS,))
    async def apply(ctx):
        ctx.contribute(JOB_HANDLERS, "my-sync:sync",
                       RegisteredJobHandler(sync, frozenset({1}), title="同步收藏"))
        await ctx.use(PLUGIN_JOBS).scoped(ctx).create("my-sync:sync", dedupe_key="all")

- **任务类型**写成 ``<插件 id>:<名字>``：第三方插件的贡献 id 本来就会被加上这个前缀，自己写全了
  不会重复加，随带版与同 id 的替换包因此产生同样的任务类型；
- 插件停用 / 卸载时主程序取消它的全部活动任务；
- 处理器抛 ``JobRetry`` 稍后重试、``JobBlocked`` 等用户处理、``JobFailed`` 失败，在安全点发现
  取消请求时抛 ``JobCancelled``（``context.raise_if_cancelled()``）。

本模块只依赖内核：进程外插件导入它不带数据库层（``tests/kernel/test_contract_import_weight.py``）。
"""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from typing import Any, Protocol

from movieclaw_kernel import RegistryKey, ServiceKey, Stability


# ---------------------------------------------------------------------- 处理器的结论
class JobControlError(Exception):
    """处理器主动给执行器的结构化结论，绝不把内部异常文本直接暴露。"""

    def __init__(
        self,
        message: str,
        *,
        code: str,
        actions: list[dict[str, Any]] | None = None,
        details: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.actions = actions or []
        self.details = details or {}

    def as_error(self) -> dict[str, Any]:
        return {
            "code": self.code,
            "message": self.message,
            "details": self.details,
            "actions": self.actions,
        }


class JobFailed(JobControlError):
    def __init__(
        self,
        message: str,
        *,
        code: str = "JOB_FAILED",
        actions: list[dict[str, Any]] | None = None,
        details: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message, code=code, actions=actions, details=details)


class JobBlocked(JobControlError):
    def __init__(
        self,
        message: str,
        *,
        code: str = "JOB_BLOCKED",
        actions: list[dict[str, Any]] | None = None,
        details: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message, code=code, actions=actions, details=details)


class JobRetry(JobControlError):
    def __init__(
        self,
        message: str,
        *,
        delay_seconds: int = 15,
        code: str = "JOB_RETRY",
        actions: list[dict[str, Any]] | None = None,
    ) -> None:
        super().__init__(message, code=code, actions=actions)
        self.delay_seconds = max(1, delay_seconds)


class JobCancelled(Exception):
    """处理器已在安全边界响应取消。"""


# ---------------------------------------------------------------------- 处理器
class JobContext(Protocol):
    """处理器拿到的上下文（主进程与进程外同一套方法）：报进度、读检查点、查取消。"""

    job_id: str

    def progress_due(self, *, min_interval: float = 1.0) -> bool:
        """高频循环里是否该持久化一次进度（时间节流）。"""
        ...

    async def update_progress(
        self,
        *,
        mode: str,
        phase: str,
        message: str,
        current: int | None = None,
        total: int | None = None,
        percent: float | None = None,
        phase_index: int | None = None,
        phase_count: int | None = None,
        details: dict[str, Any] | None = None,
        usage: dict[str, Any] | None = None,
    ) -> None: ...

    async def current_progress(self) -> dict[str, Any]:
        """最近一次已持久化的进度（可重入处理器据此恢复检查点）。"""
        ...

    async def cancel_requested(self) -> bool: ...

    async def raise_if_cancelled(self) -> None: ...


JobHandler = Callable[[Any, dict[str, Any]], Awaitable[dict[str, Any] | None]]


@dataclass(frozen=True)
class RegisteredJobHandler:
    handler: JobHandler
    definition_versions: frozenset[int]
    #: 任务中心里这类任务的名字（不填显示任务类型）
    title: str | None = None


JOB_HANDLERS: RegistryKey[RegisteredJobHandler] = RegistryKey(
    "job-handlers",
    version="1.1",  # 1.1：处理器可带 title（任务中心显示的名字）
    schema=RegisteredJobHandler,
    stability=Stability.EXPERIMENTAL,
    doc="持久化后台任务的处理器（领域插件贡献；第三方插件的任务类型自动带插件 id 前缀）",
)


# ---------------------------------------------------------------------- 建任务
@dataclass(frozen=True)
class ResourceRef:
    """领域资源中性引用；前端可据此把任务聚合到库、条目或文件。

    ``relation="target"`` 的资源同一时刻只让一个任务占用（执行器加锁）；``"context"`` 只做归属。
    """

    resource_type: str
    resource_id: str | int
    relation: str = "target"


@dataclass(frozen=True)
class JobRef:
    id: str
    job_type: str
    status: str
    #: 这次新建的（False：按去重键找到了正在进行的同一任务）
    created: bool


class PluginJobs(Protocol):
    """一个插件自己的任务（``PLUGIN_JOBS.scoped(ctx)``）：只能建自己贡献的任务类型。"""

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
        """建一个任务。``dedupe_key`` 相同且还在进行的任务已存在时返回它（``created=False``）；
        去重键只在本插件内有效。优先级高的先被领取（同级按创建先后）。"""
        ...


class PluginJobsService(Protocol):
    def scoped(self, ctx: Any) -> PluginJobs: ...


PLUGIN_JOBS: ServiceKey[PluginJobsService] = ServiceKey(
    "plugin-jobs",
    stability=Stability.EXPERIMENTAL,
    doc="插件建自己的后台任务（只能建本插件贡献的任务类型，去重键按插件隔离）",
)


__all__ = [
    "JOB_HANDLERS",
    "PLUGIN_JOBS",
    "JobBlocked",
    "JobCancelled",
    "JobContext",
    "JobControlError",
    "JobFailed",
    "JobHandler",
    "JobRef",
    "JobRetry",
    "PluginJobs",
    "PluginJobsService",
    "RegisteredJobHandler",
    "ResourceRef",
]

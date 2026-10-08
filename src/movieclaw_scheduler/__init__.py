"""movieclaw 定时任务调度层。

分层职责：本包是**调度基础设施**，只提供「引擎 + 注册 + 执行 + 台账」这套通用能力，
不含任何具体业务。它依赖 movieclaw_db（读写调度定义与运行历史），但**绝不依赖**
movieclaw_api，也**不主动依赖**各业务领域包——业务任务反过来 import 本包完成注册。

对外暴露：
- ``register_task``：领域包用它声明自己的任务（引擎与业务分离的关键）。
- ``contribute_tasks`` / ``SCHEDULED_TASKS``：插件把模块里声明的任务贡献进内核注册表。
- ``TriggerType``：声明触发方式（interval / cron）。
- ``SchedulerConfig`` / ``init_scheduler`` / ``get_scheduler``：由插件内核初始化与驱动。

典型接线（见 movieclaw_api.plugins）：领域插件 ``contribute_tasks(ctx, 某任务模块)``；
调度器插件启动 ``get_scheduler().start()`` 后订阅注册表增删，运行中挂上 / 卸下的插件
的任务随之排上 / 撤下。没有内核时回落到 ``@register_task`` 的声明目录。
"""

from __future__ import annotations

from movieclaw_db.models.scheduled_task import TriggerType
from movieclaw_scheduler.config import SchedulerConfig
from movieclaw_scheduler.registry import (
    SCHEDULED_TASKS,
    TaskDefinition,
    bind_registry,
    contribute_tasks,
    get_task,
    iter_tasks,
    register_task,
)
from movieclaw_scheduler.service import (
    SchedulerService,
    get_scheduler,
    init_scheduler,
)

__all__ = [
    "SCHEDULED_TASKS",
    "bind_registry",
    "contribute_tasks",
    "TriggerType",
    "SchedulerConfig",
    "TaskDefinition",
    "register_task",
    "get_task",
    "iter_tasks",
    "SchedulerService",
    "init_scheduler",
    "get_scheduler",
]

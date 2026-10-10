"""媒体库与获取领域之间的接口（docs/design/library-boundary.md §10）。

媒体库只管库、条目、文件、回收站；「内容从哪来」（订阅、下载器、手动下载）归获取领域。
媒体库需要获取领域的信息或要通知它时，只经这里的接口，不 import 获取领域的表与服务。
接口由获取领域实现（``downloads`` 系统模块绑定）；**没绑定时用空实现**：什么都不知道、
什么都不做——媒体库退化为纯本地库。

入参出参只有媒体库自己的概念（台账行、路径、条目、库）。按阶段分批迁入，见设计稿 §10.3。
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any, Protocol

from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_db.models import LibraryFile


class AcquisitionBridge(Protocol):
    async def describe_origins(
        self, session: AsyncSession, rows: list[LibraryFile]
    ) -> dict[int, dict[str, Any]]:
        """没有来源快照的旧行（``origin`` 为空）读时推导的来源文案：{文件 id: 快照}。不写回。"""
        ...

    async def paths_in_use(self) -> set[str] | None:
        """外部软件（下载器）正在用的落盘根名；整理 / 转移前据此提示「搬走会断做种」。

        ``None`` = 现在确认不了（下载器连不上），调用方如实报「无法确认」。
        """
        ...

    async def item_moved(
        self, session: AsyncSession, media_item_id: int, target_library_id: int
    ) -> bool:
        """条目的文件整体转移到了另一个库：跟随它的东西（订阅的目标库）一并改挂。返回是否有东西跟着改了。"""
        ...


class NullBridge:
    """没有获取领域：媒体库作为纯本地库运行。"""

    async def describe_origins(
        self, session: AsyncSession, rows: list[LibraryFile]
    ) -> dict[int, dict[str, Any]]:
        return {}

    async def paths_in_use(self) -> set[str] | None:
        return set()

    async def item_moved(
        self, session: AsyncSession, media_item_id: int, target_library_id: int
    ) -> bool:
        return False


_NULL = NullBridge()
_bound: AcquisitionBridge | None = None


def bind(bridge: AcquisitionBridge) -> Callable[[], None]:
    global _bound
    _bound = bridge

    def unbind() -> None:
        global _bound
        if _bound is bridge:
            _bound = None

    return unbind


def current() -> AcquisitionBridge:
    return _bound if _bound is not None else _NULL

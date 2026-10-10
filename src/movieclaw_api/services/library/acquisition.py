"""媒体库与获取领域之间的接口（docs/design/library-boundary.md §10）。

媒体库只管库、条目、文件、回收站；「内容从哪来」（订阅、下载器、手动下载）归获取领域。
媒体库需要获取领域的信息或要通知它时，只经这里的接口，不 import 获取领域的表与服务。
接口由获取领域实现（``downloads`` 系统模块绑定）；**没绑定时用空实现**：什么都不知道、
什么都不做——媒体库退化为纯本地库。

入参出参只有媒体库自己的概念（台账行、路径、条目、库）。按阶段分批迁入，见设计稿 §10.3。
"""

from __future__ import annotations

from collections.abc import Callable, Collection
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Protocol

from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_db.models import LibraryFile


@dataclass(frozen=True)
class TaskFile:
    """外部下载任务里的一个文件。"""

    source: Path | None  # 本机路径；翻译不了（路径映射缺失、异常相对路径）为 None
    selected: bool  # 任务要下这个文件
    size_bytes: int
    completed: bool  # 这个文件已写完


@dataclass(frozen=True)
class TaskFiles:
    """一个外部下载任务的文件清单。``info_hash`` 是任务标识（小写）。"""

    info_hash: str
    completed: bool
    files: tuple[TaskFile, ...]


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

    async def identity_changed(
        self,
        session: AsyncSession,
        *,
        gained: Collection[int],
        displaced: Collection[int] = (),
        moved_file_ids: Collection[int] = (),
    ) -> None:
        """文件归属变了：``gained`` 的条目有单元在库了；
        ``displaced`` 的条目因身份改正（认领、复核拍板、重新识别）丢了单元，
        ``moved_file_ids`` 是改挂走的文件。

        ``displaced`` 只能来自单条目粒度、用户意图的身份变更；全量扫描标 missing、用户删文件都不算
        （盘掉线不该让整库订阅重下）。
        """
        ...

    async def title_hints(self, session: AsyncSession) -> list[tuple[str, str]]:
        """目录 → 一段描述文字（如种子副标题），按写入先后：扫描识别落在该目录下的文件时参考。"""
        ...

    async def download_roots(self, session: AsyncSession) -> dict[str, object]:
        """外部软件直接下进库里的内容根（``保存目录/内容名``）→ 不透明的来源标记。

        扫描按路径匹配到某个内容根时，入账后把标记交回 ``file_recorded``；媒体库不解读标记。
        """
        ...

    async def file_recorded(self, session: AsyncSession, file_id: int, token: object) -> None:
        """扫描入账的文件落在 ``download_roots`` 的某个内容根下：获取领域记下它的来源。"""
        ...

    # ---- 入库：条目要不要处理（入库桥块 A、B）
    async def download_tasks(self) -> list | None:
        """外部下载任务概览（每项有 ``name``、``content_name``、``completed``、``info_hash``）。

        ``[]`` = 确实没有任务；``None`` = 有下载器但现在问不到——
        调用方必须保守等待，不能拿静默窗口猜完成。
        """
        ...

    async def task_files(self, matches: list) -> list[TaskFiles] | None:
        """``download_tasks`` 里这几项的文件清单；任一拿不到返回 None。"""
        ...

    async def managed_claim(self, session: AsyncSession, entry: Path) -> bool:
        """条目是 MovieClaw 自己投递、还没下完的（下载器概览暂时漏掉也算）：先等，别抢着入库。"""
        ...

    async def redelivered_since(
        self, session: AsyncSession, entry: Path, since: datetime, info_hashes: list[str]
    ) -> bool:
        """``since`` 之后同一任务又被重新投递且仍在途：入库的旧结论已过时，要重新处理。"""
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

    async def identity_changed(
        self,
        session: AsyncSession,
        *,
        gained: Collection[int],
        displaced: Collection[int] = (),
        moved_file_ids: Collection[int] = (),
    ) -> None:
        return None

    async def title_hints(self, session: AsyncSession) -> list[tuple[str, str]]:
        return []

    async def download_roots(self, session: AsyncSession) -> dict[str, object]:
        return {}

    async def file_recorded(self, session: AsyncSession, file_id: int, token: object) -> None:
        return None

    async def download_tasks(self) -> list | None:
        return []

    async def task_files(self, matches: list) -> list[TaskFiles] | None:
        return None

    async def managed_claim(self, session: AsyncSession, entry: Path) -> bool:
        return False

    async def redelivered_since(
        self, session: AsyncSession, entry: Path, since: datetime, info_hashes: list[str]
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

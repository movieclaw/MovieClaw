"""删除参与方：媒体库删除流程的领域中立扩展点（docs/design/library-boundary.md §3）。

媒体库只管文件、条目、库、回收站，不认识种子、下载器、订阅。别的模块想在「删除影片 / 删除文件」时
一起做点什么（典型：下载模块「同时删除下载任务和源文件」），登记一个参与方：

- 一个勾选项（``label`` / ``help``）；**默认一律不勾，由宿主强制**；
- 一段只读预览：按这次要删的文件说明勾上会发生什么，或者为什么不能勾；
- 一个后续任务类型：用户勾选后，宿主在删除的同一次提交里为它建一个任务，提交后由任务执行器跑。

媒体库只知道「有人给了个选项、用户勾了没」。请求里只有媒体库自己的事实（文件 id、路径、季集、
大小），参与方按文件 id 查它自己的数据（谁的数据谁清理：媒体库删文件不级联删别人的记录）。

契约先标 ``INTERNAL``，只给系统模块用；下载模块用稳后再开放给插件（§9）。
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict

from movieclaw_kernel import Registry, RegistryKey, Stability

logger = logging.getLogger("movieclaw_api.library.delete_participants")

PREVIEW_TIMEOUT = 3.0
"""单个参与方预览的时限（秒）：预览常要问下载器，连不上时不能卡住删除弹窗。"""
PREVIEW_BUDGET = 5.0
"""一次预览所有参与方的总时限（秒）：参与方并发预览，超出的按超时处理。"""


class _Frozen(BaseModel):
    model_config = ConfigDict(frozen=True)


class DeleteFile(_Frozen):
    """这次要删的一个台账文件（只有媒体库自己的事实）。"""

    id: int
    path: str
    season: int | None = None
    episode: int | None = None
    size_bytes: int = 0


class DeleteRequest(_Frozen):
    library_id: int
    media_item_id: int
    title: str
    whole_item: bool
    """整部删除（条目在本库的文件全删）；删单文件但它是最后一个文件时也是整部。"""
    files: tuple[DeleteFile, ...]


class PreviewLine(_Frozen):
    text: str
    tone: Literal["info", "warn", "danger"] = "info"


class Preview(_Frozen):
    available: bool
    reason: str | None = None
    """``available=False`` 时为什么不能勾（例：「这个种子还供着《电影乙》的文件」）。"""
    lines: tuple[PreviewLine, ...] = ()


@dataclass(frozen=True)
class DeleteParticipant:
    label: str
    """勾选项文案，如「同时删除下载任务和源文件」。"""
    help: str
    """写后果，如「源文件删除不可恢复」。"""
    preview: Callable[[DeleteRequest], Awaitable[Preview]]
    """只读、无副作用；限时 ``PREVIEW_TIMEOUT``。"""
    job_type: str
    """用户勾选后要建的后续任务类型（在 ``JOB_HANDLERS`` 里登记的处理器）。"""
    applies_to: frozenset[str] = frozenset({"item", "file"})
    """``item`` = 删除整部影片的弹窗；``file`` = 删除单个文件的弹窗。"""


LIBRARY_DELETE_PARTICIPANTS: RegistryKey[DeleteParticipant] = RegistryKey(
    "library.delete-participants",
    schema=DeleteParticipant,
    stability=Stability.INTERNAL,
    doc="删除影片 / 文件时的附加选项：勾选项 + 只读预览 + 勾选后的后续任务",
)

_bound: Registry[DeleteParticipant] | None = None


def bind_participants(registry: Registry[DeleteParticipant]) -> Callable[[], None]:
    global _bound
    _bound = registry

    def unbind() -> None:
        global _bound
        if _bound is registry:
            _bound = None

    return unbind


def participants(scope: str) -> dict[str, DeleteParticipant]:
    """当前生效的参与方：对外键（``<条目 id>:<id>``）→ 参与方，按注册表顺序。"""
    if _bound is None:
        return {}
    out: dict[str, DeleteParticipant] = {}
    for contribution in _bound.contributions():
        item = contribution.item
        if scope not in item.applies_to:
            continue
        prefix = f"{contribution.entry_id}:"
        key = contribution.id if contribution.id.startswith(prefix) else prefix + contribution.id
        out[key] = item
    return out


@dataclass(frozen=True)
class OptionPreview:
    key: str
    label: str
    help: str
    preview: Preview


async def _one(key: str, participant: DeleteParticipant, request: DeleteRequest) -> Preview:
    try:
        result = await asyncio.wait_for(participant.preview(request), PREVIEW_TIMEOUT)
    except TimeoutError:
        logger.warning("删除参与方 %s 预览超时", key)
        return Preview(available=False, reason="暂时无法预览（超时），这次不能勾选")
    except Exception:  # noqa: BLE001 -- 参与方出错只影响它自己的选项
        logger.exception("删除参与方 %s 预览出错", key)
        return Preview(available=False, reason="暂时无法预览（出错），这次不能勾选")
    if not isinstance(result, Preview):
        logger.warning("删除参与方 %s 预览返回了 %r", key, type(result).__name__)
        return Preview(available=False, reason="暂时无法预览，这次不能勾选")
    return result


async def preview_options(
    request: DeleteRequest, scope: str, keys: list[str] | None = None
) -> list[OptionPreview]:
    """并发问各参与方（``keys`` 给定时只问这几个），总时限 ``PREVIEW_BUDGET``。"""
    found = participants(scope)
    chosen = [(k, p) for k, p in found.items() if keys is None or k in keys]
    if not chosen:
        return []
    tasks = [asyncio.create_task(_one(k, p, request)) for k, p in chosen]
    done, pending = await asyncio.wait(tasks, timeout=PREVIEW_BUDGET)
    for task in pending:
        task.cancel()
    results: list[OptionPreview] = []
    for (key, participant), task in zip(chosen, tasks, strict=True):
        if task in done and not task.cancelled():
            preview = task.result()
        else:
            preview = Preview(available=False, reason="暂时无法预览（超时），这次不能勾选")
        results.append(OptionPreview(key, participant.label, participant.help, preview))
    return results


class OptionError(ValueError):
    """勾选的参与方不存在、不适用或当前不可用：删除接口回 400，不静默忽略。"""


async def check_options(request: DeleteRequest, scope: str, keys: list[str]) -> list[str]:
    """删除前核对勾选：键要存在且适用，并按当前状态重新预览一次，不可用就拒绝。"""
    keys = list(dict.fromkeys(keys))
    if not keys:
        return []
    found = participants(scope)
    unknown = [k for k in keys if k not in found]
    if unknown:
        raise OptionError(f"没有这个删除选项：{'、'.join(unknown)}")
    for option in await preview_options(request, scope, keys):
        if not option.preview.available:
            reason = option.preview.reason or "不可用"
            raise OptionError(f"「{option.label}」这次不能勾选：{reason}")
    return keys


async def enqueue_follow_ups(
    session: Any, request: DeleteRequest, keys: list[str], scope: str
) -> list[dict[str, str]]:
    """在删除的同一次提交里为每个勾选的参与方建后续任务（不提交，随删除一起成立）。"""
    from movieclaw_api.services.jobs import create_job

    found = participants(scope)
    follow_ups: list[dict[str, str]] = []
    for key in keys:
        participant = found[key]
        created = await create_job(
            session,
            job_type=participant.job_type,
            input_data={"option": key, "request": request.model_dump(mode="json")},
            subject=f"{participant.label}：{request.title}",
            origin="library.delete",
            conflict_policy="queue",
            commit=False,
        )
        assert created.job.id is not None
        follow_ups.append({"option": key, "label": participant.label, "job_id": created.job.id})
    return follow_ups

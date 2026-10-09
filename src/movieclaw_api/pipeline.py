"""流水线槽位（docs/design/plugin-phase2b.md §7）。

插件往槽位里贡献**步骤**，宿主在流水线走到那一步时为每个步骤创建一个持久化任务，
挂在当前任务下（父任务 / 根任务），与流水线自己的结论同一次提交。步骤本身就是插件
贡献的任务处理器，享有持久化任务的全部能力：重试、阻塞待处理、取消、进度、跨重启续跑。

第一个槽位 ``ingest.staged``：自定义目录（暂存）规则把识别、改名后的文件放到暂存目录之后。典型用途是
「上传网盘、生成 .strm 放进媒体库」——入库任务持有媒体库资源锁，几十 GB 的上传不能挡在它里面。

::

    @plugin("acme.cloud", inject=(...))
    async def apply(ctx):
        ctx.contribute(JOB_HANDLERS, "upload", RegisteredJobHandler(upload, frozenset({1})))
        step = IngestStep(job_type=f"{ctx.entry_id}:upload", title="上传网盘")
        ctx.contribute(INGEST_STEPS, "upload", step)
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from movieclaw_kernel import Registry, RegistryKey, Stability

logger = logging.getLogger("movieclaw_api.pipeline")

INGEST_STAGED = "ingest.staged"


@dataclass(frozen=True)
class IngestStep:
    job_type: str
    """插件贡献的任务处理器的类型（第三方插件的类型带插件 id 前缀，如 ``acme.cloud:upload``）。"""
    title: str
    slot: str = INGEST_STAGED
    kinds: tuple[str, ...] = ()
    """只处理这些内容形态（``movie`` / ``tv``）；空 = 全部。"""


INGEST_STEPS: RegistryKey[IngestStep] = RegistryKey(
    "ingest-steps",
    schema=IngestStep,
    stability=Stability.EXPERIMENTAL,
    doc="入库流水线槽位的步骤：暂存完成后为每个步骤建一个挂在入库任务下的持久化任务",
)

_bound: Registry[IngestStep] | None = None


def bind_steps(registry: Registry[IngestStep]) -> Callable[[], None]:
    global _bound
    _bound = registry

    def unbind() -> None:
        global _bound
        if _bound is registry:
            _bound = None

    return unbind


def steps_for(slot: str, kind: str | None) -> list[IngestStep]:
    if _bound is None:
        return []
    return [
        item
        for _cid, item in _bound.items()
        if item.slot == slot and (not item.kinds or kind in item.kinds)
    ]


@dataclass(frozen=True)
class StagedFile:
    path: Path
    season: int
    episode: int
    info_hash: str | None = None


async def enqueue_staged(
    session: Any,
    *,
    files: list[StagedFile],
    item: Any,
    rule: Any,
    library_id: int | None,
    batch_id: str,
    ingest_job_id: str | None,
    info_hashes: list[str],
) -> list[str]:
    """暂存完成：为 ``ingest.staged`` 槽位的每个步骤建一个任务（不提交，随入库结论一起提交）。

    部分失败的入库也要调：文件已经搬过去了，重试时这些文件不会再报。
    """
    from movieclaw_api.services import jobs

    if not files or item is None:
        return []
    created: list[str] = []
    for step in steps_for(INGEST_STAGED, getattr(item, "kind", None)):
        input_data = {
            "slot": INGEST_STAGED,
            "media": {
                "id": item.id,
                "kind": item.kind,
                "title": item.title,
                "year": item.year,
                "tmdb_id": item.tmdb_id,
            },
            "library_id": library_id,
            "rule": {"id": rule.id, "kind": rule.kind, "target_path": rule.target_path},
            "files": [
                {
                    "path": str(f.path),
                    "season": f.season,
                    "episode": f.episode,
                    "info_hash": f.info_hash,
                }
                for f in files
            ],
            "batch_id": batch_id,
            "ingest_job_id": ingest_job_id,
        }
        result = await jobs.create_job(
            session,
            job_type=step.job_type,
            subject=f"{step.title}：{item.title}",
            input_data=input_data,
            dedupe_key=f"{step.job_type}:{batch_id}",
            parent_job_id=ingest_job_id,
            root_job_id=ingest_job_id,
            triggered_by_job_id=ingest_job_id,
            correlation_id=info_hashes[0] if info_hashes else None,
            origin="system",
            commit=False,
        )
        created.append(result.job.id)
        logger.info(
            "暂存完成，已排下游步骤「%s」：%s（%d 个文件，任务 %s）",
            step.title,
            item.title,
            len(files),
            result.job.id,
        )
    return created

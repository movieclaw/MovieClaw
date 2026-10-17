"""把库里的本地文件传到网盘（docs/design/cloud-storage.md §5）。

主根在网盘的库（库的某个网盘文件夹 ``is_primary``），本地入库的文件逐个上传到那个文件夹，
目录结构与本地一致：

1. **指纹**：一次顺序读算 SHA1 / MD5 / 前 128 KB SHA1，存起来（文件没变就不再算）；
2. **秒传**：``begin_upload`` 按指纹试；网盘要校验一段字节就由宿主读出来再交过去；
3. **真传**：秒传不中就按插件给的分片大小逐片读、逐片交给插件。读字节在宿主这边——外网有人
   在看片时先停（``uplink``），每传完一片把续传状态记进任务进度，重启后从那一片接着传；
4. **核验**：``stat`` 网盘上的文件，大小与哈希对上才把副本记为已核验。释放本地是下一步（§6）。

每个库一个任务（``drive.upload``），逐个文件传，新入库的先传；任务锁住网盘账号（同一账号一次
只传一个），不锁媒体库——几十 GB 的上传不能挡住扫描与整理。新文件入库、库的主根换到网盘、
每 10 分钟的巡检都会排它。
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
import posixpath
from datetime import timedelta
from pathlib import Path, PurePath
from typing import Any

from movieclaw_api.services import jobs
from movieclaw_api.services.drives import gateway, uplink
from movieclaw_api.services.drives.registry import BackendUnavailable
from movieclaw_db.engine import get_database
from movieclaw_db.models.base import utcnow
from movieclaw_db.models.library import Library
from movieclaw_db.models.library_cloud_folder import LibraryCloudFolder
from movieclaw_db.models.library_file import LibraryFile
from movieclaw_db.models.scheduled_task import TriggerType
from movieclaw_db.repositories.drive_account_repo import DriveAccountRepository
from movieclaw_db.repositories.library_cloud_repo import LibraryCloudRepository
from movieclaw_scheduler.registry import register_task
from movieclaw_sdk import drives as dv

logger = logging.getLogger(__name__)

JOB_TYPE = "drive.upload"
#: 上次失败的文件过多久再试
RETRY_FAILED_AFTER = timedelta(hours=12)
#: 读盘算指纹的块大小
READ_CHUNK = 4 * 1024 * 1024
#: 网盘要校验的字节段最长多少（防插件要整份文件）
MAX_CHALLENGE_BYTES = 64 * 1024 * 1024
#: 分片最大多少：一片要整块读进内存再交给插件（插件宜用几十 MB 的分片）
MAX_PART_BYTES = 512 * 1024 * 1024
#: 外网有人在看时，多久看一眼让完路没有
YIELD_POLL_S = 5.0
#: 核验时网盘那边可能还没入库：最多看几次、每次隔多久
VERIFY_ATTEMPTS = 4
VERIFY_INTERVAL_S = 5.0


class LocalChanged(Exception):
    """本地文件在上传过程中变了或不见了：这次放弃，等扫描对齐台账后再说。"""


# ---------------------------------------------------------------------- 读本地文件


def compute_fingerprint(path: Path) -> dv.Fingerprint:
    """（阻塞）一次顺序读同时算全文 SHA1、MD5 与前 128 KB SHA1。"""
    sha1 = hashlib.sha1()  # noqa: S324 -- 网盘秒传协议要 SHA1，不是安全用途
    md5 = hashlib.md5()  # noqa: S324 -- 同上
    head = hashlib.sha1()  # noqa: S324 -- 同上
    head_left = dv.HEAD_BYTES
    size = 0
    with path.open("rb") as fh:
        while chunk := fh.read(READ_CHUNK):
            sha1.update(chunk)
            md5.update(chunk)
            if head_left > 0:
                head.update(chunk[:head_left])
                head_left -= min(head_left, len(chunk))
            size += len(chunk)
    return dv.Fingerprint(
        size=size,
        sha1=sha1.hexdigest().upper(),
        md5=md5.hexdigest().upper(),
        head_sha1=head.hexdigest().upper(),
    )


def read_range(path: Path, offset: int, length: int) -> bytes:
    """（阻塞）读一段字节。"""
    with path.open("rb") as fh:
        fh.seek(offset)
        return fh.read(length)


def _stat(path: Path) -> tuple[int, int] | None:
    try:
        st = path.stat()
    except OSError:
        return None
    return st.st_size, st.st_mtime_ns


async def fingerprint_for(file: LibraryFile) -> tuple[dv.Fingerprint, tuple[int, int]]:
    """库文件的指纹与算的时候文件的（大小, 修改时间）。

    存过且文件没变就用存的，否则现算并存下。文件不在或正在变抛 ``LocalChanged``。
    """
    assert file.id is not None
    path = Path(file.file_path)
    before = await asyncio.to_thread(_stat, path)
    if before is None:
        raise LocalChanged("本地文件不见了")
    async with get_database().session() as session:
        stored = await LibraryCloudRepository(session).fingerprint_of(file.id)
    if (
        stored is not None
        and stored.md5
        and stored.head_sha1
        and (stored.size_bytes, stored.file_mtime_ns) == before
    ):
        return dv.Fingerprint(stored.size_bytes, stored.sha1, stored.md5, stored.head_sha1), before
    fingerprint = await asyncio.to_thread(compute_fingerprint, path)
    if await asyncio.to_thread(_stat, path) != before or fingerprint.size != before[0]:
        raise LocalChanged("算指纹的时候文件还在变（可能还在写入）")
    async with get_database().session() as session:
        await LibraryCloudRepository(session).save_fingerprint(
            file.id,
            size_bytes=fingerprint.size,
            file_mtime_ns=before[1],
            sha1=fingerprint.sha1,
            md5=fingerprint.md5,
            head_sha1=fingerprint.head_sha1,
        )
    return fingerprint, before


def remote_dir_for(library: Library, file_path: str) -> str:
    """文件在网盘主文件夹里该放的目录（相对路径）：与它在本地库根下的目录一致。"""
    path = PurePath(file_path)
    for root in library.root_paths:
        try:
            relative = path.parent.relative_to(PurePath(root))
        except ValueError:
            continue
        return "/".join(part for part in relative.parts if part not in ("", "."))
    return ""


# ---------------------------------------------------------------------- 排任务


async def enqueue(library_id: int | None = None, *, origin: str = "system") -> list[str]:
    """给有待传文件的「主根在网盘」的库排上传任务（同一库已有任务就复用）。返回任务 id。"""
    created: list[str] = []
    async with get_database().session() as session:
        repo = LibraryCloudRepository(session)
        folders = await repo.primary_folders()
        for folder in folders:
            if library_id is not None and folder.library_id != library_id:
                continue
            pending = await repo.upload_candidates(
                folder.library_id, retry_failed_before=utcnow() - RETRY_FAILED_AFTER, limit=1
            )
            if not pending:
                continue
            library = await session.get(Library, folder.library_id)
            if library is None:
                continue
            result = await jobs.create_job(
                session,
                job_type=JOB_TYPE,
                subject=library.name,
                input_data={"library_id": folder.library_id},
                resources=[
                    jobs.ResourceRef("library", folder.library_id, "context"),
                    jobs.ResourceRef("drive_account", folder.account_id),
                ],
                dedupe_key=f"{JOB_TYPE}:{folder.library_id}",
                conflict_policy="return_existing",
                handler_revision="drive.upload.v1",
                max_attempts=10,
                actor_kind="system",
                actor_name="网盘上传",
                origin=origin,
                progress=jobs.default_progress("等待上传到网盘"),
            )
            created.append(result.job.id)
    return created


@register_task(
    "drive_upload_sweep",
    title="网盘上传巡检",
    trigger_type=TriggerType.INTERVAL,
    interval_seconds=600,
    description=(
        "主根在网盘的库：还没传上去的本地文件（新入库的、上次失败过一段时间的）排进上传任务。"
        "新文件入库时会立即排，这里兜底。"
    ),
)
async def upload_sweep() -> None:
    await enqueue()


# ---------------------------------------------------------------------- 任务


def _drive_error_to_job(exc: dv.DriveError, account_name: str) -> jobs.JobControlError:
    if isinstance(exc, dv.AuthExpired):
        return jobs.JobBlocked(
            f"网盘「{account_name}」需要重新登录，登录后上传自动继续",
            code="DRIVE_AUTH_EXPIRED",
            actions=[
                {"type": "open_settings", "label": "去重新登录", "target": "drives"},
                {"type": "retry_job", "label": "登录后重试"},
            ],
        )
    if isinstance(exc, dv.QuotaExceeded):
        return jobs.JobBlocked(
            f"网盘「{account_name}」空间不够了：{exc.message}",
            code="DRIVE_QUOTA_EXCEEDED",
            actions=[{"type": "retry_job", "label": "腾出空间后重试"}],
        )
    if isinstance(exc, dv.RateLimited):
        return jobs.JobRetry(
            f"网盘「{account_name}」限流：{exc.message}",
            delay_seconds=int(exc.retry_after or gateway.RATE_LIMIT_PAUSE),
            code="DRIVE_RATE_LIMITED",
        )
    if isinstance(exc, dv.RiskControl):
        return jobs.JobRetry(
            f"网盘「{account_name}」触发风控，稍后再传：{exc.message}",
            delay_seconds=int(gateway.RISK_CONTROL_PAUSE),
            code="DRIVE_RISK_CONTROL",
        )
    if isinstance(exc, dv.ApiChanged):
        return jobs.JobBlocked(
            f"网盘接口变了，需要更新网盘插件：{exc.message}",
            code="DRIVE_API_CHANGED",
            actions=[{"type": "retry_job", "label": "更新插件后重试"}],
        )
    return jobs.JobRetry(f"网盘暂时连不上：{exc.message}", delay_seconds=60)


class _Uploader:
    """一次任务里传一个库的文件。"""

    def __init__(
        self,
        context: jobs.JobContext,
        library: Library,
        folder: LibraryCloudFolder,
        account_name: str,
    ) -> None:
        self.context = context
        self.library = library
        self.folder = folder
        self.account_name = account_name
        self.dirs: dict[str, str] = {}
        self.done = 0
        self.rapid = 0
        self.failed = 0
        self.total = 0

    async def call(self, method: str, **args: Any) -> Any:
        return await gateway.call(
            self.folder.account_id, method, priority=gateway.Priority.BACKGROUND, **args
        )

    async def progress(
        self, message: str, *, percent: float | None = None, checkpoint: dict | None = None
    ) -> None:
        details = {"done": self.done, "rapid": self.rapid, "failed": self.failed}
        if checkpoint is not None:
            details["checkpoint"] = checkpoint
        await self.context.update_progress(
            mode="determinate",
            phase="uploading",
            message=message,
            current=self.done,
            total=self.total,
            percent=percent,
            details=details,
        )

    async def dir_id(self, relative: str) -> str:
        if relative not in self.dirs:
            self.dirs[relative] = (
                await self.call("ensure_dir", parent_id=self.folder.remote_dir_id, path=relative)
                if relative
                else self.folder.remote_dir_id
            )
        return self.dirs[relative]

    async def wait_for_uplink(self) -> None:
        """外网有人在看片：先停，让完路再传（§5.3）。"""
        announced = False
        while uplink.busy():
            if not announced:
                await self.progress("外网有人在看片，上传先让路")
                announced = True
            await self.context.raise_if_cancelled()
            await asyncio.sleep(YIELD_POLL_S)

    async def upload(self, file: LibraryFile, checkpoint: dict[str, Any] | None) -> None:
        """传一个文件并核验。成功副本记为已核验；这个文件本身的问题记进副本、不抛。"""
        assert file.id is not None
        path = Path(file.file_path)
        name = path.name
        async with get_database().session() as session:
            await LibraryCloudRepository(session).start_upload(
                file, account_id=self.folder.account_id, folder_id=self.folder.id or 0
            )
        await self.progress(f"读取「{name}」算指纹")
        fingerprint, seen_stat = await fingerprint_for(file)
        relative = remote_dir_for(self.library, file.file_path)
        dir_id = await self.dir_id(relative)
        resume = checkpoint if checkpoint and checkpoint.get("file_id") == file.id else None
        state = resume.get("state") if resume else None
        step = await self.call(
            "begin_upload",
            dir_id=dir_id,
            name=name,
            fingerprint=fingerprint,
            state=state,
            range_data=None,
        )
        while step.need_range is not None:
            offset, length = step.need_range
            if length <= 0 or length > MAX_CHALLENGE_BYTES or offset + length > fingerprint.size:
                raise dv.ApiChanged(f"网盘要校验的字节段不合理（{offset}+{length}）")
            data = await asyncio.to_thread(read_range, path, offset, length)
            step = await self.call(
                "begin_upload",
                dir_id=dir_id,
                name=name,
                fingerprint=fingerprint,
                state=step.state,
                range_data=data,
            )
        remote = step.file
        if remote is not None:
            if resume is None:
                self.rapid += 1
        else:
            remote = await self._send_parts(file, path, fingerprint, step, seen_stat)
        await self._verify(file, remote, fingerprint, relative, name)

    async def _send_parts(
        self,
        file: LibraryFile,
        path: Path,
        fingerprint: dv.Fingerprint,
        step: dv.UploadStep,
        seen_stat: tuple[int, int],
    ) -> dv.RemoteFile:
        part_size = min(step.part_size or fingerprint.size, max(fingerprint.size, 1))
        if part_size <= 0 or part_size > MAX_PART_BYTES:
            raise dv.ApiChanged(f"网盘给的分片大小不合理（{part_size} 字节）")
        parts = max(1, -(-fingerprint.size // part_size))
        state = step.state
        name = path.name
        for index in range(step.next_part, parts):
            await self.wait_for_uplink()
            await self.context.raise_if_cancelled()
            if await asyncio.to_thread(_stat, path) != seen_stat:
                raise LocalChanged("上传过程中本地文件变了")
            data = await asyncio.to_thread(read_range, path, index * part_size, part_size)
            state = await self.call("upload_part", state=state, index=index, data=data)
            sent = min((index + 1) * part_size, fingerprint.size)
            await self.progress(
                f"上传「{name}」",
                percent=round(sent * 100 / max(fingerprint.size, 1), 1),
                checkpoint={"file_id": file.id, "state": state, "next_part": index + 1},
            )
        if await asyncio.to_thread(_stat, path) != seen_stat:
            raise LocalChanged("上传过程中本地文件变了")
        return await self.call("finish_upload", state=state)

    async def _verify(
        self,
        file: LibraryFile,
        remote: dv.RemoteFile,
        fingerprint: dv.Fingerprint,
        relative: str,
        name: str,
    ) -> None:
        """网盘上的文件大小与哈希对得上本地指纹，才记为已核验。"""
        assert file.id is not None
        seen: dv.RemoteFile | None = None
        for attempt in range(VERIFY_ATTEMPTS):
            try:
                seen = await self.call("stat", remote_id=remote.remote_id)
                break
            except dv.NotFound:
                if attempt == VERIFY_ATTEMPTS - 1:
                    raise
                await asyncio.sleep(VERIFY_INTERVAL_S)
        assert seen is not None
        if seen.size != fingerprint.size or (
            seen.sha1 is not None and seen.sha1.upper() != fingerprint.sha1
        ):
            raise LocalChanged(
                "网盘上的文件和本地对不上（大小或哈希不同），没有记为已上传；网盘上那份请自行检查"
            )
        async with get_database().session() as session:
            await LibraryCloudRepository(session).finish_upload(
                file.id,
                remote_id=remote.remote_id,
                remote_path=posixpath.join(self.folder.display_path, relative, name),
                size_bytes=seen.size,
                sha1=(seen.sha1 or fingerprint.sha1).upper(),
            )


@jobs.register_job_handler(JOB_TYPE)
async def run_upload_job(
    context: jobs.JobContext, input_data: dict[str, object]
) -> dict[str, object]:
    library_id = int(input_data["library_id"])  # type: ignore[arg-type]
    async with get_database().session() as session:
        library = await session.get(Library, library_id)
        folder = await LibraryCloudRepository(session).primary_folder(library_id)
        account = await DriveAccountRepository(session).get(folder.account_id) if folder else None
    if library is None or folder is None or account is None:
        return {"message": "这个库的新内容已不再存到网盘，没有要传的"}
    uploader = _Uploader(context, library, folder, account.name)
    details = (await context.current_progress()).get("details") or {}
    checkpoint = details.get("checkpoint") if isinstance(details, dict) else None
    uploader.done = int(details.get("done") or 0) if isinstance(details, dict) else 0
    uploader.rapid = int(details.get("rapid") or 0) if isinstance(details, dict) else 0
    skipped: set[int] = set()
    while True:
        await context.raise_if_cancelled()
        async with get_database().session() as session:
            candidates = await LibraryCloudRepository(session).upload_candidates(
                library_id, retry_failed_before=utcnow() - RETRY_FAILED_AFTER
            )
        candidates = [f for f in candidates if f.id not in skipped]
        if not candidates:
            break
        uploader.total = uploader.done + len(candidates)
        # 有没传完的就先把它传完（续传），否则传最新入库的
        file = next(
            (f for f in candidates if checkpoint and f.id == checkpoint.get("file_id")),
            candidates[0],
        )
        assert file.id is not None
        try:
            await uploader.upload(file, checkpoint)
            uploader.done += 1
            # 传完核验了：闸门都过就当场腾空本地（过不了的由腾空巡检稍后再试）
            from movieclaw_api.services.drives import release

            reason = await release.try_release(file.id)
            if reason is not None:
                logger.debug("「%s」先不腾空本地：%s", PurePath(file.file_path).name, reason)
        except LocalChanged as exc:
            skipped.add(file.id)
            uploader.failed += 1
            async with get_database().session() as session:
                await LibraryCloudRepository(session).fail_upload(file.id, str(exc))
            logger.info("「%s」这次不上传：%s", PurePath(file.file_path).name, exc)
        except dv.Conflict as exc:
            skipped.add(file.id)
            uploader.failed += 1
            async with get_database().session() as session:
                await LibraryCloudRepository(session).fail_upload(
                    file.id, f"网盘上已有同名的不同文件：{exc.message}"
                )
        except OSError as exc:
            skipped.add(file.id)
            uploader.failed += 1
            async with get_database().session() as session:
                await LibraryCloudRepository(session).fail_upload(file.id, f"本地文件读不了：{exc}")
        except BackendUnavailable as exc:
            raise jobs.JobRetry(str(exc), delay_seconds=300) from exc
        except dv.DriveError as exc:
            raise _drive_error_to_job(exc, uploader.account_name) from exc
        checkpoint = None
        await uploader.progress(f"已上传 {uploader.done} 个（秒传 {uploader.rapid}）")
    message = f"上传完成：{uploader.done} 个文件（秒传 {uploader.rapid}）"
    if uploader.failed:
        message += f"，{uploader.failed} 个没传成（原因记在文件上，过一段时间再试）"
    return {
        "message": message,
        "uploaded": uploader.done,
        "rapid": uploader.rapid,
        "failed": uploader.failed,
    }

"""媒体库里的网盘文件夹：纳管与复查（docs/design/cloud-storage.md §4、§9）。

挂在库上的网盘文件夹由扫描一并处理，只是「遍历」换成网盘的整树列举：

- **列谁**：新挂上、还没列过的文件夹；手动扫描时全部；其余每周复查一次（定期对账顺带判断
  到没到期）；操作动态说某个文件夹有变化时只列它（``cloud_only`` 的扫描，不碰本地根目录）。
- **怎么入账**：列出来的视频按文件名走现有识别链，台账行 ``local_bytes`` 为假 + 副本记为已
  核验。文件的台账路径是虚拟位置（``local_dir`` + 相对路径），已经入账的按网盘文件 id 认回
  原来那一行（在网盘里挪了位置也不变）。
- **对账**：列过的文件夹里，台账有、网盘上没有了的标缺失（副本 ``lost``）；回来了的认回来。
  纳管、复查**永远不删网盘上的文件**。

原盘目录、ISO 一期跳过并计数，写进纳管报告。
"""

from __future__ import annotations

import logging
import posixpath
import re
import time
from dataclasses import dataclass, field
from datetime import timedelta
from pathlib import Path

from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.services.drives import gateway
from movieclaw_api.services.library.profile import LibraryProfile
from movieclaw_db.models.base import utcnow
from movieclaw_db.models.library import Library
from movieclaw_db.models.library_cloud_folder import LibraryCloudFolder
from movieclaw_db.models.library_file import FileState, LibraryFile
from movieclaw_db.models.library_file_replica import REPLICA_LOST, REPLICA_VERIFIED
from movieclaw_db.models.scheduled_task import TriggerType
from movieclaw_db.repositories.library_cloud_repo import LibraryCloudRepository
from movieclaw_db.repositories.library_file_repo import LibraryFileRepository
from movieclaw_scheduler.registry import register_task
from movieclaw_sdk import drives as dv

logger = logging.getLogger(__name__)

#: 没有操作动态兜底的变化（复制、改名、第三方上传）多久复查一次
RECHECK_INTERVAL = timedelta(days=7)
#: 纳管文件虚拟位置的目录名（在库主根下，扫描不进隐藏目录）
CLOUD_DIR_NAME = ".movieclaw-cloud"


def local_dir_for(library: Library, account_id: int, display_path: str) -> str:
    """一个网盘文件夹的虚拟位置：主根下的隐藏目录 + 账号 + 网盘路径。"""
    root = Path(library.root_paths[0]) if library.root_paths else Path("/")
    parts = [p for p in re.split(r"[/\\]+", display_path) if p not in ("", ".", "..")]
    return str(root.joinpath(CLOUD_DIR_NAME, str(account_id), *parts))


@dataclass(slots=True)
class CloudEntry:
    """本轮列出来的一个视频：台账路径对应到哪个文件夹、哪个网盘文件。"""

    folder_id: int
    account_id: int
    remote: dv.RemoteFile
    remote_path: str


@dataclass(slots=True)
class FolderListing:
    folder_id: int
    account_id: int
    display_path: str
    remote_ids: set[str] = field(default_factory=set)
    dir_ids: list[str] = field(default_factory=list)
    videos: int = 0
    discs: set[str] = field(default_factory=set)
    iso: int = 0
    extras: int = 0
    calls: int = 0
    started: float = field(default_factory=time.monotonic)


@dataclass(slots=True)
class CloudRound:
    """一轮扫描里网盘文件夹那一部分的状态。"""

    entries: dict[str, CloudEntry] = field(default_factory=dict)
    #: (根, 文件, 是否原盘)：并进扫描的待处理列表
    pending: list[tuple[Path, Path, bool]] = field(default_factory=list)
    listings: list[FolderListing] = field(default_factory=list)
    #: 虚拟目录 → 目录里的集数（同名双版本消歧的证据，本地扫描靠读目录得到）
    episode_counts: dict[Path, int | None] = field(default_factory=dict)


async def folders_to_list(
    session: AsyncSession,
    library_id: int,
    *,
    folder_ids: set[int] | None,
    everything: bool,
) -> list[LibraryCloudFolder]:
    """这一轮要列哪些文件夹：点了名的；手动扫描全部；其余只列没列过或到了复查时间的。"""
    folders = await LibraryCloudRepository(session).folders(library_id)
    if folder_ids is not None:
        return [f for f in folders if f.id in folder_ids]
    if everything:
        return folders
    due = utcnow() - RECHECK_INTERVAL
    return [f for f in folders if f.listed_at is None or f.listed_at < due]


async def collect(
    session: AsyncSession,
    library: Library,
    profile: LibraryProfile,
    folders: list[LibraryCloudFolder],
    errors: list[str],
) -> CloudRound:
    """整树列举这些文件夹，挑出视频，给每个视频定好台账路径。"""
    from movieclaw_api.services.library.scan import _stem_episode, classify_cloud_path

    assert library.id is not None
    known_paths = await LibraryCloudRepository(session).replica_paths()
    cloud = CloudRound()
    episodes: dict[Path, set[int]] = {}
    for folder in folders:
        assert folder.id is not None
        listing = FolderListing(folder.id, folder.account_id, folder.display_path)
        before = gateway.usage_today(folder.account_id)
        try:
            tree = await gateway.call(
                folder.account_id,
                "list_tree",
                priority=gateway.Priority.BACKGROUND,
                dir_id=folder.remote_dir_id,
            )
        except dv.DriveError as exc:
            errors.append(f"网盘文件夹「{folder.display_path}」没列出来：{exc.message}")
            continue
        except Exception as exc:  # noqa: BLE001 -- 插件不在等情况：这个文件夹本轮跳过
            errors.append(f"网盘文件夹「{folder.display_path}」没列出来：{exc}")
            continue
        listing.calls = gateway.usage_today(folder.account_id) - before
        listing.dir_ids = list(tree.dir_ids)
        base = Path(folder.local_dir)
        for remote in tree.files:
            rel = (remote.rel_path or remote.name).strip("/")
            verdict = classify_cloud_path(rel, ignore=profile.ignore_rules, exts=profile.media_exts)
            if verdict is None:
                continue
            kind, disc_dir = verdict
            if kind == "disc":
                listing.discs.add(disc_dir or "")
                continue
            if kind == "iso":
                listing.iso += 1
                continue
            if kind == "extra":
                listing.extras += 1
                continue
            listing.videos += 1
            listing.remote_ids.add(remote.remote_id)
            known = known_paths.get((folder.account_id, remote.remote_id))
            if known is not None and (known[1] or known[2] != library.id):
                # 我们传上去、本地还在的文件归本地扫描管；转移到别的库的，别在这里再入一遍账
                continue
            path = known[0] if known is not None else str(base / rel)
            if path in cloud.entries:
                continue  # 同一个文件被两个嵌套的文件夹列到：先到先得
            remote_path = posixpath.join(folder.display_path, rel)
            cloud.entries[path] = CloudEntry(folder.id, folder.account_id, remote, remote_path)
            cloud.pending.append((base, Path(path), False))
            episode = _stem_episode(Path(rel).stem)
            if episode:
                episodes.setdefault(Path(path).parent, set()).add(episode)
        cloud.listings.append(listing)
    cloud.episode_counts = {d: (len(e) if len(e) >= 2 else None) for d, e in episodes.items()}
    return cloud


async def record(
    session: AsyncSession, row: LibraryFile, entry: CloudEntry, *, fresh: bool = False
) -> None:
    """新入账（或识别重试、缺失回归）的纳管文件：记副本，台账行标「只在网盘上」。"""
    await LibraryCloudRepository(session).record_import(
        row,
        folder_id=entry.folder_id,
        account_id=entry.account_id,
        remote_id=entry.remote.remote_id,
        remote_path=entry.remote_path,
        size_bytes=entry.remote.size,
        sha1=entry.remote.sha1,
        fresh=fresh,
    )


async def touch(session: AsyncSession, row: LibraryFile, entry: CloudEntry) -> None:
    """已入账的纳管文件又被列到：更新展示路径、大小、哈希；之前标了丢失的认回来。"""
    repo = LibraryCloudRepository(session)
    replica = await repo.replica_of(row.id)  # type: ignore[arg-type]
    if replica is None or replica.remote_id != entry.remote.remote_id:
        await record(session, row, entry)
        return
    was_lost = replica.state == REPLICA_LOST
    await repo.mark_checked(
        replica,
        remote_path=entry.remote_path,
        size_bytes=entry.remote.size,
        sha1=entry.remote.sha1,
        at=utcnow(),
    )
    if was_lost and row.state == FileState.MISSING:
        row.revive()
        row.updated_at = utcnow()
        session.add(row)
    await repo.commit()


async def finish(
    session: AsyncSession, library_id: int, cloud: CloudRound, *, cancelled: bool
) -> int:
    """列过的文件夹收尾：网盘上没有了的标缺失、写报告与列举时间。返回标了缺失的个数。

    扫描中途停止的不判缺失（没处理完不等于没有），只更新报告。
    """
    repo = LibraryCloudRepository(session)
    files = LibraryFileRepository(session)
    now = utcnow()
    marked = 0
    for listing in cloud.listings:
        folder = await repo.get_folder(listing.folder_id)
        if folder is None:
            continue
        identified = pending = 0
        for replica, row in await repo.folder_replicas(listing.folder_id):
            if replica.state not in (REPLICA_VERIFIED, REPLICA_LOST):
                continue  # 还在传、传失败的：网盘上本来就可能没有
            if replica.remote_id not in listing.remote_ids:
                if cancelled:
                    continue
                if replica.state != REPLICA_LOST:
                    await repo.mark_lost(replica, at=now)
                # 本地还在的只丢了副本（上传巡检会重新传）；只在网盘上的就是缺失了
                if row.state == FileState.IN_PLACE and not row.local_bytes:
                    await files.mark_missing(row.id, since=now)  # type: ignore[arg-type]
                    marked += 1
                continue
            if row.local_bytes and replica.state == REPLICA_LOST:
                await repo.mark_checked(
                    replica, remote_path=None, size_bytes=None, sha1=None, at=now
                )
            if row.state == FileState.MISSING or row.ignored_at is not None:
                continue
            if row.media_item_id is not None and row.unidentified_code is None:
                identified += 1
            else:
                pending += 1
        folder.listed_at = now if not cancelled else folder.listed_at
        folder.dir_ids = listing.dir_ids
        folder.report = {
            "finished_at": now.isoformat(),
            "seconds": round(time.monotonic() - listing.started, 1),
            "calls": listing.calls,
            "videos": listing.videos,
            "identified": identified,
            "pending": pending,
            "skipped": {
                "disc": len(listing.discs),
                "iso": listing.iso,
                "extra": listing.extras,
            },
            "cancelled": cancelled,
        }
        await repo.save_folder(folder)
    await repo.commit()
    from movieclaw_api.services.drives import sources

    await sources.load_registry()
    if marked:
        logger.warning("媒体库 #%s：%d 个纳管文件在网盘上找不到了，已标缺失", library_id, marked)
    return marked


# ---------------------------------------------------------------------- 库配置


@dataclass(frozen=True, slots=True)
class FolderSpec:
    """编辑库时提交的一个网盘根目录。"""

    account_id: int
    remote_dir_id: str
    display_path: str
    is_primary: bool = False


@dataclass(slots=True)
class FolderChange:
    added: list[int] = field(default_factory=list)
    removed: int = 0
    #: 被拿掉的文件夹里的文件挂着的条目（调用方清理没有文件了的条目）
    orphan_item_ids: list[int] = field(default_factory=list)


def _clean_path(display_path: str) -> str:
    return "/".join(p for p in re.split(r"[/\\]+", display_path.strip()) if p not in ("", "."))


def _nested(a: str, b: str) -> bool:
    return a == b or a.startswith(b + "/") or b.startswith(a + "/")


async def validate_folders(
    session: AsyncSession, library: Library | None, specs: list[FolderSpec]
) -> list[FolderSpec]:
    """检查一组网盘根目录能不能这样挂；不行抛 ``ValueError``（给用户看的一句话）。"""
    from movieclaw_db.models.library import Library as LibraryModel
    from movieclaw_db.repositories.drive_account_repo import DriveAccountRepository

    cleaned = [
        FolderSpec(s.account_id, s.remote_dir_id.strip(), _clean_path(s.display_path), s.is_primary)
        for s in specs
    ]
    if sum(1 for s in cleaned if s.is_primary) > 1:
        raise ValueError("主根只能有一个")
    accounts = DriveAccountRepository(session)
    for spec in cleaned:
        if not spec.remote_dir_id:
            raise ValueError("网盘目录缺少 id")
        if await accounts.get(spec.account_id) is None:
            raise ValueError("网盘账号不存在（可能已被移除）")
    for i, a in enumerate(cleaned):
        for b in cleaned[i + 1 :]:
            if a.account_id == b.account_id and (
                a.remote_dir_id == b.remote_dir_id or _nested(a.display_path, b.display_path)
            ):
                raise ValueError(
                    f"「{a.display_path or '根目录'}」和「{b.display_path or '根目录'}」重叠了，"
                    "选外层的一个就行"
                )
    library_id = library.id if library is not None else None
    for other in await LibraryCloudRepository(session).all_folders():
        if other.library_id == library_id:
            continue
        for spec in cleaned:
            if spec.account_id != other.account_id:
                continue
            if spec.remote_dir_id == other.remote_dir_id or _nested(
                spec.display_path, other.display_path
            ):
                owner = await session.get(LibraryModel, other.library_id)
                raise ValueError(
                    f"「{spec.display_path or '根目录'}」与媒体库《{owner.name if owner else '?'}》"
                    f"的网盘目录「{other.display_path}」重叠，同一份文件只能在一个库里"
                )
    return cleaned


async def apply_folders(
    session: AsyncSession, library: Library, specs: list[FolderSpec]
) -> FolderChange:
    """把库的网盘根目录改成 ``specs``（先 ``validate_folders``）：新的建行，没了的只删台账。"""
    assert library.id is not None
    repo = LibraryCloudRepository(session)
    current = {(f.account_id, f.remote_dir_id): f for f in await repo.folders(library.id)}
    change = FolderChange()
    wanted = {(s.account_id, s.remote_dir_id) for s in specs}
    for key, folder in current.items():
        if key not in wanted:
            change.orphan_item_ids.extend(await repo.remove_folder(folder))
            change.removed += 1
    for order, spec in enumerate(specs):
        folder = current.get((spec.account_id, spec.remote_dir_id))
        if folder is None:
            folder = await repo.add_folder(
                LibraryCloudFolder(
                    library_id=library.id,
                    account_id=spec.account_id,
                    remote_dir_id=spec.remote_dir_id,
                    display_path=spec.display_path,
                    local_dir=local_dir_for(library, spec.account_id, spec.display_path),
                    is_primary=spec.is_primary,
                    sort_order=order,
                )
            )
            assert folder.id is not None
            change.added.append(folder.id)
            continue
        if (folder.is_primary, folder.sort_order) != (spec.is_primary, order):
            folder.is_primary = spec.is_primary
            folder.sort_order = order
            await repo.save_folder(folder)
    if change.removed:
        from movieclaw_api.services.drives import sources

        await sources.load_registry()
    return change


# ---------------------------------------------------------------------- 操作动态

#: 一次最多翻几页动态（每页一次调用）；没翻完的下一轮接着翻
CHANGE_PAGES = 10


@register_task(
    "drive_changes",
    title="网盘变化同步",
    trigger_type=TriggerType.INTERVAL,
    interval_seconds=300,
    description=(
        "拉网盘的操作动态（上传、转存、移动、删除），只处理落在媒体库网盘目录里的：删掉的标缺失，"
        "其余只重新列有变化的那个目录。网盘不支持操作动态时靠每周复查。"
    ),
)
async def poll_drive_changes() -> None:
    from movieclaw_api.services.drives.registry import backends
    from movieclaw_db.engine import get_database
    from movieclaw_db.repositories.drive_account_repo import DriveAccountRepository

    async with get_database().session() as session:
        folders = await LibraryCloudRepository(session).all_folders()
        accounts = {row.id: row for row in await DriveAccountRepository(session).list_all()}
    by_account: dict[int, list[LibraryCloudFolder]] = {}
    for folder in folders:
        by_account.setdefault(folder.account_id, []).append(folder)
    available = backends()
    for account_id, account_folders in by_account.items():
        account = accounts.get(account_id)
        if account is None:
            continue
        backend = available.get(account.backend)
        if backend is None or not backend.capabilities.change_feed:
            continue
        cursor = account.change_cursor
        changes: list[dv.Change] = []
        try:
            for _ in range(CHANGE_PAGES):
                page = await gateway.call(
                    account_id, "changes", priority=gateway.Priority.BACKGROUND, cursor=cursor
                )
                changes.extend(page.changes)
                cursor = page.cursor
                if not page.has_more:
                    break
        except Exception as exc:  # noqa: BLE001 -- 一个账号拉不到不影响别的账号
            logger.info("网盘「%s」的操作动态没拉到：%s", account.name, exc)
            continue
        async with get_database().session() as session:
            row = await DriveAccountRepository(session).get(account_id)
            if row is not None:
                row.change_cursor = cursor
                session.add(row)
                await session.commit()
        if account.change_cursor is None:
            continue  # 第一次只是记下起点
        if changes:
            await apply_changes(account_id, account_folders, changes)


async def apply_changes(
    account_id: int, folders: list[LibraryCloudFolder], changes: list[dv.Change]
) -> set[int]:
    """把一批操作动态落到库里：删掉的已入账文件直接标缺失，其余只标出要重新列的文件夹。

    返回要重新列的文件夹 id（已为它们排好只列网盘的扫描）。
    """
    from movieclaw_api.services.drives import sources
    from movieclaw_api.services.library.scan import enqueue_scan_job
    from movieclaw_db.engine import get_database

    by_dir: dict[str, LibraryCloudFolder] = {}
    for folder in folders:
        by_dir[folder.remote_dir_id] = folder
        for dir_id in folder.dir_ids or ():
            by_dir.setdefault(str(dir_id), folder)
    dirty: set[int] = set()
    lost_files: list[int] = []
    now = utcnow()
    async with get_database().session() as session:
        repo = LibraryCloudRepository(session)
        files = LibraryFileRepository(session)
        known = {
            replica.remote_id: (replica, row)
            for replica, row in await repo.account_replicas(
                account_id, [c.remote_id for c in changes if not c.is_dir]
            )
        }
        for change in changes:
            hit = known.get(change.remote_id) if not change.is_dir else None
            if hit is not None:
                replica, row = hit
                if change.kind == "removed":
                    if replica.state != REPLICA_LOST:
                        await repo.mark_lost(replica, at=now)
                    if row.state == FileState.IN_PLACE and not row.local_bytes:
                        await files.mark_missing(row.id, since=now)  # type: ignore[arg-type]
                    lost_files.append(row.id)  # type: ignore[arg-type]
                    sources.forget_links(account_id, change.remote_id)
                elif replica.folder_id is not None:
                    dirty.add(replica.folder_id)  # 挪了位置或改了名：重新列它更新展示路径
                continue
            folder = by_dir.get(change.parent_id or "") or by_dir.get(change.remote_id)
            if folder is not None and folder.id is not None:
                dirty.add(folder.id)
        await repo.commit()
        libraries: dict[int, list[int]] = {}
        for folder in folders:
            if folder.id in dirty:
                libraries.setdefault(folder.library_id, []).append(folder.id)  # type: ignore[arg-type]
        for library_id, folder_ids in libraries.items():
            library = await session.get(Library, library_id)
            if library is None:
                continue
            await enqueue_scan_job(
                session,
                library_id,
                library.name,
                actor_kind="system",
                actor_name="网盘变化同步",
                origin="system",
                cloud_folder_ids=folder_ids,
                cloud_only=True,
            )
    for file_id in lost_files:
        await sources.refresh_file(file_id)
    if lost_files:
        logger.info("网盘动态：%d 个纳管文件被删了，已标缺失", len(lost_files))
    return dirty


# ---------------------------------------------------------------------- 规格补探

#: 后台补探只用每日预算的这一小部分（取一次直链 = 一次调用），余量留给播放与纳管
PROBE_SHARE = 0.3
#: 每轮最多探几个（每个要一次取链 + ffprobe 读文件头）
PROBE_BATCH = 20


@register_task(
    "drive_probe_specs",
    title="网盘片源规格补探",
    trigger_type=TriggerType.INTERVAL,
    interval_seconds=600,
    description=(
        "纳管进来的网盘文件入库时不读字节，分辨率、HDR、音轨在这里按每日预算的一小部分慢慢补齐"
        "（新入库的先探）；没补到的在起播时当场探。"
    ),
)
async def probe_cloud_specs() -> int:
    """探一批还没有规格的只在网盘上的文件。返回这轮探成了几个。"""
    from sqlmodel import select

    from movieclaw_api.services.drives.registry import backends
    from movieclaw_api.services.playback.strm_probe import probe_file
    from movieclaw_db.engine import get_database
    from movieclaw_db.models.library_file_replica import REPLICA_VERIFIED, LibraryFileReplica
    from movieclaw_db.repositories.drive_account_repo import DriveAccountRepository

    async with get_database().session() as session:
        rows = (
            await session.execute(
                select(LibraryFile.id, LibraryFileReplica.account_id)
                .join(LibraryFileReplica, LibraryFileReplica.library_file_id == LibraryFile.id)
                .where(
                    LibraryFile.local_bytes.is_(False),  # type: ignore[attr-defined]
                    LibraryFile.state == FileState.IN_PLACE,
                    LibraryFile.video_codec.is_(None),  # type: ignore[union-attr]
                    LibraryFile.ignored_at.is_(None),  # type: ignore[union-attr]
                    LibraryFileReplica.state == REPLICA_VERIFIED,
                )
                .order_by(LibraryFile.id.desc())  # type: ignore[union-attr]
                .limit(PROBE_BATCH * 5)
            )
        ).all()
        accounts = {row.id: row for row in await DriveAccountRepository(session).list_all()}
    available = backends()
    probed = attempted = 0
    for file_id, account_id in rows:
        if attempted >= PROBE_BATCH:
            break
        account = accounts.get(account_id)
        if account is None:
            continue
        _qps, budget, _slots = gateway.effective(account, available.get(account.backend))
        if gateway.usage_today(account_id) >= budget * PROBE_SHARE:
            continue
        result = await probe_file(file_id, respect_backoff=True)
        if result.status == "backoff":
            continue
        attempted += 1
        probed += result.status == "probed"
    if attempted:
        logger.info("网盘片源规格补探：探了 %d 个，成功 %d 个", attempted, probed)
    return probed

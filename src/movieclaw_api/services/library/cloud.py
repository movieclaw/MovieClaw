"""媒体库里的网盘文件夹：纳管与复查（docs/design/cloud-storage.md §4、§9）。

挂在库上的网盘文件夹由扫描一并处理，只是「遍历」换成网盘的整树列举：

- **列谁**：新挂上、还没列过的文件夹；手动扫描时全部；其余每周复查一次（定期对账顺带判断
  到没到期）；操作动态只列有变化的那个目录（``cloud_only`` 的扫描，不碰本地根目录）；
  插件/外部工具点名了文件夹下的子目录时只列那棵子树（``CloudScope``，判缺失也只在子树里）。
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
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import timedelta
from pathlib import Path

from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.i18n import t
from movieclaw_api.i18n.stored import source_text, stored_fields
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


@dataclass(frozen=True, slots=True)
class CloudScope:
    """范围扫描点名的一棵子树：挂着的文件夹 + 子目录 id + 子目录相对文件夹的路径。"""

    folder_id: int
    dir_id: str
    #: 相对挂着的文件夹的路径（``/`` 分隔）；空串就是整个文件夹；``None`` 是列举时按网盘给的
    #: 路径链定（操作动态只知道目录 id），定不了就改列整个文件夹
    prefix: str | None


@dataclass(slots=True)
class FolderListing:
    folder_id: int
    account_id: int
    display_path: str
    #: 只列了文件夹下的这棵子树（``CloudScope.prefix``）；空串是列了整个文件夹
    prefix: str = ""
    dir_id: str = ""
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


async def resolve_scopes(
    session: AsyncSession, library_id: int, paths: list[str]
) -> list[CloudScope]:
    """把网盘路径（挂着的文件夹之下的子目录）解析成范围：从文件夹往下逐级找子目录 id。

    不在挂着的文件夹之下、找不到的抛 ``ValueError``（给调用方看的一句话）；网盘那边出错
    原样抛 ``DriveError``。
    """
    folders = await LibraryCloudRepository(session).folders(library_id)
    scopes: list[CloudScope] = []
    for raw in paths:
        path = _clean_path(raw)
        folder = max(
            (f for f in folders if path == f.display_path or path.startswith(f.display_path + "/")),
            key=lambda f: len(f.display_path),
            default=None,
        )
        if folder is None or folder.id is None:
            raise ValueError(t("library.cloud.scopeOutside", path=raw))
        prefix = path[len(folder.display_path) :].strip("/")
        dir_id = folder.remote_dir_id
        for name in prefix.split("/") if prefix else ():
            children = await gateway.call(
                folder.account_id, "list_dir", priority=gateway.Priority.USER, dir_id=dir_id
            )
            match = next((d for d in children if d.name == name), None)
            if match is None:
                raise ValueError(t("library.cloud.scopeNotFound", path=raw))
            dir_id = match.remote_id
        scopes.append(CloudScope(folder.id, dir_id, prefix))
    return scopes


def _prefix_in(chain: tuple[dv.RemoteDir, ...], folder_dir_id: str) -> str | None:
    """路径链里挂着的文件夹之下的那一段（按目录 id 找，改了名也认得）；不在它底下返回 None。"""
    ids = [d.remote_id for d in chain]
    if folder_dir_id not in ids:
        return None
    return "/".join(d.name for d in chain[ids.index(folder_dir_id) + 1 :])


async def collect(
    session: AsyncSession,
    library: Library,
    profile: LibraryProfile,
    folders: list[LibraryCloudFolder],
    add_error: Callable[[dict], None],
    scopes: list[CloudScope] | None = None,
) -> CloudRound:
    """整树列举这些文件夹（给了 ``scopes`` 就只列点名的子树），挑出视频，给每个视频定好台账路径。"""
    from movieclaw_api.services.library.scan import _stem_episode, classify_cloud_path

    assert library.id is not None
    known_paths = await LibraryCloudRepository(session).replica_paths()
    cloud = CloudRound()
    episodes: dict[Path, set[int]] = {}
    by_id = {f.id: f for f in folders}
    targets = (
        [CloudScope(f.id, f.remote_dir_id, "") for f in folders if f.id is not None]
        if scopes is None
        else [s for s in scopes if s.folder_id in by_id]
    )
    for scope in targets:  # 定不了路径的会往后追加整个文件夹
        folder = by_id[scope.folder_id]
        assert folder.id is not None
        shown = (
            posixpath.join(folder.display_path, scope.prefix)
            if scope.prefix
            else folder.display_path
        )
        before = gateway.usage_today(folder.account_id)
        try:
            tree = await gateway.call(
                folder.account_id,
                "list_tree",
                priority=gateway.Priority.BACKGROUND,
                dir_id=scope.dir_id,
            )
        except dv.DriveError as exc:
            add_error(stored_fields("library.cloud.listFailed", path=shown, detail=exc.message))
            continue
        except Exception as exc:  # noqa: BLE001 -- 插件不在等情况：这个文件夹本轮跳过
            add_error(stored_fields("library.cloud.listFailed", path=shown, detail=str(exc)))
            continue
        prefix = scope.prefix
        if prefix is None:
            prefix = _prefix_in(tree.path, folder.remote_dir_id)
            if prefix is None:
                # 不在文件夹底下了（挪出了库）或插件没给路径链：整个文件夹列一遍对账
                whole = CloudScope(folder.id, folder.remote_dir_id, "")
                if whole not in targets:
                    targets.append(whole)
                continue
        listing = FolderListing(
            folder.id, folder.account_id, folder.display_path, prefix, scope.dir_id
        )
        listing.calls = gateway.usage_today(folder.account_id) - before
        listing.dir_ids = list(tree.dir_ids)
        base = Path(folder.local_dir)
        for remote in tree.files:
            rel = (remote.rel_path or remote.name).strip("/")
            if prefix:
                rel = posixpath.join(prefix, rel)
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

    扫描中途停止的不判缺失（没处理完不等于没有），只更新报告。只列了子树的：只判子树里的
    副本，子树外的完全不动；也不写报告与列举时间（那是整个文件夹的结论，每周复查照旧到期），
    只把子树里的目录 id 并进文件夹，好让操作动态认得新目录。
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
        under = posixpath.join(folder.display_path, listing.prefix) if listing.prefix else None
        for replica, row in await repo.folder_replicas(listing.folder_id):
            if replica.state not in (REPLICA_VERIFIED, REPLICA_LOST):
                continue  # 还在传、传失败的：网盘上本来就可能没有
            if under is not None and not (
                replica.remote_path == under or (replica.remote_path or "").startswith(under + "/")
            ):
                continue
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
        if under is not None:
            folder.dir_ids = sorted({*(folder.dir_ids or ()), *listing.dir_ids, listing.dir_id})
            await repo.save_folder(folder)
            continue
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
        raise ValueError(t("library.cloud.onePrimary"))
    accounts = DriveAccountRepository(session)
    for spec in cleaned:
        if not spec.remote_dir_id:
            raise ValueError(t("library.cloud.missingId"))
        if await accounts.get(spec.account_id) is None:
            raise ValueError(t("library.cloud.accountMissing"))
    for i, a in enumerate(cleaned):
        for b in cleaned[i + 1 :]:
            if a.account_id == b.account_id and (
                a.remote_dir_id == b.remote_dir_id or _nested(a.display_path, b.display_path)
            ):
                root = t("library.cloud.rootDir")
                raise ValueError(
                    t("library.cloud.overlap", a=a.display_path or root, b=b.display_path or root)
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
                    t(
                        "library.cloud.overlapLibrary",
                        path=spec.display_path or t("library.cloud.rootDir"),
                        library=owner.name if owner else "?",
                        other=other.display_path,
                    )
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
#: 一批动态在一个文件夹里涉及的目录超过这么多，直接整个列一遍（逐个列反而更贵）
CHANGE_DIRS_MAX = 50


@register_task(
    "drive_changes",
    title="网盘变化同步",
    title_key="settings.scheduledTasks.catalog.driveChangesTitle",
    trigger_type=TriggerType.INTERVAL,
    interval_seconds=300,
    description=(
        "拉网盘的操作动态（上传、转存、移动、删除），只处理落在媒体库网盘目录里的：删掉的标缺失，"
        "其余只重新列有变化的那个目录。网盘不支持操作动态时靠每周复查。"
    ),
    description_key="settings.scheduledTasks.catalog.driveChangesDescription",
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
    """把一批操作动态落到库里（cloud-storage.md §4.3）。

    - 已入账的文件被删了：直接标缺失；已入账、核验过的文件「新增」（我们自己传上去的、范围扫描
      刚入过账的）：台账里已经有了，什么都不做；
    - 其余落在库目录里的变化只列事发的那个目录：文件列它所在的目录，目录列它自己，删掉的目录列
      上级。目录在文件夹之下的路径由列举时网盘给的路径链定，定不了的改列整个文件夹（``collect``）；
    - 已入账的文件挪到了没列过的目录（可能已经出了库）、一批涉及的目录太多：整个文件夹列一遍。

    返回有变化的文件夹 id（已为它们排好只列网盘的扫描）。
    """
    from movieclaw_api.services.drives import sources
    from movieclaw_api.services.library.scan import enqueue_scan_job
    from movieclaw_db.engine import get_database

    by_dir: dict[str, LibraryCloudFolder] = {}
    for folder in folders:
        by_dir[folder.remote_dir_id] = folder
        for dir_id in folder.dir_ids or ():
            by_dir.setdefault(str(dir_id), folder)
    #: 文件夹 id → 要列的目录 id
    targets: dict[int, set[str]] = {}
    #: 要整个列一遍的文件夹 id
    whole: set[int] = set()
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
                    continue
                if change.kind == "added" and replica.state == REPLICA_VERIFIED:
                    continue  # 我们自己传上去的、范围扫描刚入过账的
                folder = by_dir.get(change.parent_id or "")
                if folder is not None and folder.id == replica.folder_id:
                    targets.setdefault(folder.id, set()).add(change.parent_id or "")
                elif replica.folder_id is not None:
                    whole.add(replica.folder_id)  # 挪到了没列过的目录或库外
                continue
            folder = by_dir.get(change.parent_id or "") or by_dir.get(change.remote_id)
            if folder is None or folder.id is None:
                continue
            if change.is_dir and change.kind != "removed":
                by_dir.setdefault(change.remote_id, folder)  # 同一批里它底下的变化也认得
                target = change.remote_id
            else:
                target = change.parent_id or ""
            if by_dir.get(target) is folder:
                targets.setdefault(folder.id, set()).add(target)
            else:
                whole.add(folder.id)  # 被删的就是挂着的文件夹本身之类：整个对一遍
        await repo.commit()
        scopes: dict[int, list[CloudScope]] = {}
        for folder in folders:
            if folder.id is None or (folder.id not in whole and folder.id not in targets):
                continue
            dirs = targets.get(folder.id, set())
            if folder.id in whole or folder.remote_dir_id in dirs or len(dirs) > CHANGE_DIRS_MAX:
                listed = [CloudScope(folder.id, folder.remote_dir_id, "")]
            else:
                listed = [CloudScope(folder.id, d, None) for d in sorted(dirs)]
            scopes.setdefault(folder.library_id, []).extend(listed)
        for library_id, library_scopes in scopes.items():
            library = await session.get(Library, library_id)
            if library is None:
                continue
            await enqueue_scan_job(
                session,
                library_id,
                library.name,
                actor_kind="system",
                actor_name=source_text("library.cloud.syncActor"),
                origin="system",
                cloud_scopes=library_scopes,
            )
    for file_id in lost_files:
        await sources.refresh_file(file_id)
    if lost_files:
        logger.info("网盘动态：%d 个纳管文件被删了，已标缺失", len(lost_files))
    return whole | set(targets)


# ---------------------------------------------------------------------- 规格补探

#: 后台补探只用每日预算的这一小部分（取一次直链 = 一次调用），余量留给播放与纳管
PROBE_SHARE = 0.3
#: 每轮最多探几个（每个要一次取链 + ffprobe 读文件头）
PROBE_BATCH = 20


@register_task(
    "drive_probe_specs",
    title="网盘片源规格补探",
    title_key="settings.scheduledTasks.catalog.driveProbeSpecsTitle",
    trigger_type=TriggerType.INTERVAL,
    interval_seconds=600,
    description=(
        "纳管进来的网盘文件入库时不读字节，分辨率、HDR、音轨在这里按每日预算的一小部分慢慢补齐"
        "（新入库的先探）；没补到的在起播时当场探。"
    ),
    description_key="settings.scheduledTasks.catalog.driveProbeSpecsDescription",
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

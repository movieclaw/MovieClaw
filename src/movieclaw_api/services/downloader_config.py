"""下载器配置服务：用户接入的下载软件的增删改查与连接验证。

下载器配置写入时原子登记验证租约，后台任务持令牌写入结论：
- 写入前做业务校验（名称唯一）；
- 真正的连通性验证交给后台任务 ``verify_downloader``（测一次连接）；
- VERIFYING 期间拒绝更新/删除/重复验证（409 并发守卫，原理见 SiteConfigService）。
"""

from __future__ import annotations

import asyncio
import logging

from anyio import CancelScope
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.exceptions import BadRequestException, ConflictException, NotFoundException
from movieclaw_api.i18n import t
from movieclaw_api.i18n.stored import stored_fields
from movieclaw_api.services.download_health import adopt_landing_groups
from movieclaw_api.services.downloader_paths import PathProbe, detail_key, probe_mappings, summarize
from movieclaw_db.engine import get_database
from movieclaw_db.models.downloader_client import DownloaderClient
from movieclaw_db.models.site_credential import ConfigStatus
from movieclaw_db.repositories.downloader_repo import DownloaderRepository
from movieclaw_downloader import (
    BaseDownloader,
    DownloaderConfig,
    DownloaderException,
    DownloaderInfo,
    create_downloader,
)

logger = logging.getLogger("movieclaw_api.downloader_config")

# 连接测试用较短超时：测试只为回答"通不通"，没必要等默认 30 秒
_TEST_TIMEOUT = 10.0
# RPC 可能有多次往返，路径探测也可能遇到阻塞的挂载；整个验证探测另设截止时间。
_VERIFY_TIMEOUT = 30


async def recover_stale_downloader_verifications(
    session: AsyncSession, downloader_id: int | None = None
) -> None:
    interrupted = stored_fields("errors.downloader.verifyInterrupted")
    count = await DownloaderRepository(session).fail_stale_verifying(
        last_error=interrupted["message"], last_error_ref=interrupted, downloader_id=downloader_id
    )
    if count:
        logger.info("已将 %d 条过期的下载器验证标记为中断", count)


class DownloaderConfigService:
    """下载器配置的业务服务。绑定一个数据库会话。"""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session
        self._repo = DownloaderRepository(session)

    @staticmethod
    def _verification_conflict(name: str) -> ConflictException:
        return ConflictException(message_key="errors.downloaders.testing", params={"name": name})

    # -- 查询 --------------------------------------------------------------

    async def list_all(self) -> list[DownloaderClient]:
        """返回所有已配置的下载器（含各自验证状态）。"""
        rows = await self._repo.list_all()
        if any(self._repo.verification_expired(row) for row in rows):
            await recover_stale_downloader_verifications(self._session)
            rows = await self._repo.list_all(refresh=True)
        return rows

    async def get(self, downloader_id: int) -> DownloaderClient:
        """按 id 获取；不存在抛 404。"""
        row = await self._repo.get(downloader_id)
        if row is not None and self._repo.verification_expired(row):
            await recover_stale_downloader_verifications(self._session, downloader_id)
            row = await self._repo.get(downloader_id, refresh=True)
        if row is None:
            raise NotFoundException(
                message_key="errors.downloaders.missing", params={"id": downloader_id}
            )
        return row

    # -- 写入 --------------------------------------------------------------

    async def _assert_name_available(self, name: str, *, exclude_id: int | None = None) -> None:
        """名称唯一性校验（更新时排除自身）。"""
        existing = await self._repo.get_by_name(name)
        if existing is not None and existing.id != exclude_id:
            raise ConflictException(
                message_key="errors.downloaders.nameInUse", params={"name": name}
            )

    @staticmethod
    def _assert_type_known(client_type: str) -> None:
        """类型要有已登记的适配器（官方插件或第三方插件提供）；没有就说清楚有哪些。"""
        from movieclaw_downloader.registry import adapters

        known = adapters()
        if client_type not in known:
            names = "、".join(f"{a.title}（{kind}）" for kind, a in known.items()) or t(
                "common.value.none"
            )
            raise BadRequestException(
                message_key="errors.downloaders.typeMissing",
                params={"type": client_type, "types": names},
            )

    async def create(
        self,
        *,
        name: str,
        client_type: str,
        url: str,
        username: str | None,
        password: str | None,
        save_path: str | None,
        path_mappings: list[dict[str, str]] | None = None,
        enabled: bool = True,
    ) -> DownloaderClient:
        """新增下载器配置并占位为 VERIFYING，等待异步测试连接。"""
        self._assert_type_known(client_type)
        await self._assert_name_available(name)
        return await self._repo.create(
            name=name,
            client_type=client_type,
            url=url,
            username=username,
            password=password,
            save_path=save_path,
            path_mappings=path_mappings,
            enabled=enabled,
            verify=True,
        )

    async def update(
        self,
        downloader_id: int,
        *,
        name: str,
        client_type: str,
        url: str,
        username: str | None,
        password: str | None,
        save_path: str | None,
        path_mappings: list[dict[str, str]] | None = None,
        enabled: bool,
    ) -> DownloaderClient:
        """整体更新下载器配置；不存在抛 404，正在验证中抛 409。"""
        row = await self.get(downloader_id)
        if row.status == ConfigStatus.VERIFYING:
            raise self._verification_conflict(row.name)
        if client_type != row.client_type:
            self._assert_type_known(client_type)
        await self._assert_name_available(name, exclude_id=downloader_id)
        updated = await self._repo.update_and_start_verification(
            downloader_id,
            name=name,
            client_type=client_type,
            url=url,
            username=username,
            password=password,
            save_path=save_path,
            path_mappings=path_mappings,
            enabled=enabled,
        )
        if updated is None:
            raise self._verification_conflict(row.name)
        return updated

    async def start_verification(self, downloader_id: int) -> DownloaderClient:
        """原子占位为 VERIFYING，交给请求所属进程的后台任务。"""
        row = await self.get(downloader_id)
        if row.status == ConfigStatus.VERIFYING:
            raise self._verification_conflict(row.name)
        claimed = await self._repo.start_verification(downloader_id)
        if claimed is None:
            raise self._verification_conflict(row.name)
        return claimed

    async def set_enabled(self, downloader_id: int, enabled: bool) -> DownloaderClient:
        """启用/停用；与验证状态正交，不受 VERIFYING 守卫限制。"""
        ok = await self._repo.set_enabled(downloader_id, enabled)
        if not ok:
            raise NotFoundException(
                message_key="errors.downloaders.missing", params={"id": downloader_id}
            )
        return await self.get(downloader_id)

    async def set_default(self, downloader_id: int) -> DownloaderClient:
        """设为默认下载器；与验证状态正交，不受 VERIFYING 守卫限制。

        会同时清掉其他台的默认标记（有且只有一个默认的不变量由 repo 维护）。
        """
        ok = await self._repo.set_default(downloader_id)
        if not ok:
            raise NotFoundException(
                message_key="errors.downloaders.missing", params={"id": downloader_id}
            )
        return await self.get(downloader_id)

    async def delete(self, downloader_id: int) -> list[str]:
        """删除下载器配置；不存在抛 404，正在验证中抛 409。

        选它做刷流下载器的站点会先关闭刷流，返回这些站点的 site_id。用户为
        站点单独选刷流下载器是为了与订阅/手动下载隔离，删掉后若让外键置空、
        改投默认下载器，恰好破坏隔离（与「选定的下载器不可用就停、不改投」
        同一原则，见 docs/design/site-protection-ratio-boost.md §2.10）。关闭刷流
        不删种，想继续刷就重新开启并选一台。先关刷流再删配置：暂停中的站点
        解除做种限速时还要连这台下载器。
        """
        from sqlmodel import select

        from movieclaw_api.services.site_config import SiteConfigService
        from movieclaw_db.models.site_credential import SiteCredential

        row = await self.get(downloader_id)
        if row.status == ConfigStatus.VERIFYING:
            raise self._verification_conflict(row.name)
        boost_sites = (
            (
                await self._session.execute(
                    select(SiteCredential.site_id).where(
                        SiteCredential.boost_downloader_id == downloader_id,
                        SiteCredential.boost_enabled == True,  # noqa: E712 -- SQL 表达式
                    )
                )
            )
            .scalars()
            .all()
        )
        for site_id in boost_sites:
            await SiteConfigService(self._session).set_ratio_boost(site_id, enabled=False)
            logger.info(
                "下载器「%s」将被删除，已关闭站点 %s 的刷流（它选的刷流下载器就是这台）",
                row.name,
                site_id,
            )
        await self._repo.delete(downloader_id)
        # 配置已不存在，它的连接失败告警（若有）随之作废
        from movieclaw_api.services.system_notice import resolve_notices

        await resolve_notices(self._session, dedupe_key=f"downloader:{downloader_id}")
        return list(boost_sites)


# ---------------------------------------------------------------------------
# 后台连接测试（与 verification.verify_site 同构的背景任务）
# ---------------------------------------------------------------------------


async def _close_downloader(downloader: BaseDownloader) -> None:
    try:
        async with asyncio.timeout(_TEST_TIMEOUT):
            await downloader.close()
    except Exception:
        logger.warning("关闭下载器测试连接失败", exc_info=True)


async def _check_downloader(
    config: DownloaderConfig, path_mappings: list[dict[str, str]] | None
) -> tuple[DownloaderInfo, list[PathProbe]]:
    downloader = create_downloader(config)
    try:
        async with asyncio.timeout(_VERIFY_TIMEOUT):
            info = await downloader.test_connection()
            # 连接成功才探测路径。在线程里访问文件系统，挂载阻塞时验证仍能超时退出。
            probes = await asyncio.to_thread(probe_mappings, path_mappings)
        return info, probes
    finally:
        cleanup = asyncio.create_task(_close_downloader(downloader))
        try:
            await asyncio.shield(cleanup)
        except asyncio.CancelledError:
            with CancelScope(shield=True):
                await asyncio.shield(cleanup)
            raise


async def verify_downloader(downloader_id: int, verification_token: str) -> None:
    """执行已登记的验证，全程处理取消并按令牌写入结论。"""
    try:
        await _verify_owned_downloader(downloader_id, verification_token)
    except asyncio.CancelledError:
        # 原会话可能在读取或 COMMIT 时被取消。独立事务只标记仍归本任务的记录。
        interrupted = stored_fields("errors.downloader.verifyInterrupted")
        with CancelScope(shield=True):
            try:
                async with get_database().session() as session:
                    await DownloaderRepository(session).update_status(
                        downloader_id,
                        ConfigStatus.FAILED,
                        verification_token=verification_token,
                        last_error=interrupted["message"],
                        last_error_ref=interrupted,
                    )
            except Exception:
                logger.exception("无法记录下载器验证中断：id=%s", downloader_id)
        raise


async def _verify_owned_downloader(downloader_id: int, verification_token: str) -> None:
    db = get_database()
    async with db.session() as session:
        row = await DownloaderRepository(session).get(downloader_id)
        if row is None or not DownloaderRepository.owns_verification(row, verification_token):
            return

    try:
        config = DownloaderConfig(
            type=row.client_type,
            url=row.url,
            username=row.username,
            password=DownloaderRepository.decrypted_password(row),
            timeout=_TEST_TIMEOUT,
        )
        info, probes = await _check_downloader(config, row.path_mappings)
        path_health = [probe.as_dict() for probe in probes] or None
    except DownloaderException as exc:
        logger.info("下载器连接测试失败：%s（%s）", row.name, exc.message)
        error, error_ref = exc.message, exc.message_ref
    except TimeoutError:
        logger.info("下载器连接测试超时：%s", row.name)
        error_ref = stored_fields("errors.downloader.verifyTimeout", seconds=_VERIFY_TIMEOUT)
        error = error_ref["message"]
    except Exception as exc:
        logger.exception("下载器连接测试发生未知错误：%s", row.name)
        error_ref = stored_fields(
            "errors.downloader.verifyUnexpected", kind=type(exc).__name__, detail=str(exc)
        )
        error = error_ref["message"]
    else:
        async with db.session() as session:
            if not await DownloaderRepository(session).update_status(
                downloader_id,
                ConfigStatus.ACTIVE,
                verification_token=verification_token,
                version=info.version,
                path_health=path_health,
            ):
                return
            logger.info("下载器连接测试通过：%s（%s %s）", row.name, info.type, info.version)
            # 连接恢复，红灯熄灭
            from movieclaw_api.services.system_notice import resolve_notices

            await resolve_notices(session, dedupe_key=f"downloader:{downloader_id}")
            await _notify_paths(session, downloader_id, row.name, probes)
        return
    async with db.session() as session:
        if await DownloaderRepository(session).update_status(
            downloader_id,
            ConfigStatus.FAILED,
            verification_token=verification_token,
            last_error=error,
            last_error_ref=error_ref,
        ):
            await _notify_failed(session, downloader_id, row.name, error_ref or error)


async def _notify_paths(
    session: AsyncSession, downloader_id: int, name: str, probes: list[PathProbe]
) -> None:
    """路径体检结论 → 全局红灯（或熄灯）。

    与连接失败的红灯分开 key：连接失败是"下载器不可达"，路径异常是"下载器
    好好的、movieclaw 看不到它放的文件"。两者的修法完全不同，混成一盏灯会把
    用户引去重启下载器，而真正要重启的是 movieclaw 自己。
    """
    from movieclaw_api.services.system_notice import resolve_notices, upsert_notice
    from movieclaw_db.models import NoticeSeverity

    key = f"downloader.paths:{downloader_id}"
    worst = summarize(probes)
    if worst is None:
        await resolve_notices(session, dedupe_key=key)
        return
    state, detail = worst
    broken = [p for p in probes if not p.healthy]
    logger.warning(
        "下载器「%s」路径体检发现 %d 条映射异常（最严重：%s）", name, len(broken), state.value
    )
    await upsert_notice(
        session,
        dedupe_key=key,
        severity=NoticeSeverity.ERROR,
        source="downloader",
        title_key="notify.downloaderPaths.title",
        message_key="notify.downloaderPaths.body",
        message_params={
            "name": name,
            "count": len(broken),
            "detail": {"message_key": detail_key(state)},
        },
        payload={
            "group_key": key,
            "downloader_id": downloader_id,
            "paths": [p.as_dict() for p in broken],
        },
    )
    # 同一挂载故障可能已经被完成种子的落点核验撞上、亮了目录级红灯：收编到
    # 这盏更上游的灯下面，告警中心只显示一条
    await adopt_landing_groups(session, downloader_id)


async def _notify_failed(
    session: AsyncSession, downloader_id: int, name: str, error: str | dict
) -> None:
    """下载器验证失败 → 全局红灯：下载器坏了，订阅投递与完成检测全部停摆。"""
    from movieclaw_api.services.system_notice import upsert_notice
    from movieclaw_db.models import NoticeSeverity

    await upsert_notice(
        session,
        dedupe_key=f"downloader:{downloader_id}",
        severity=NoticeSeverity.ERROR,
        source="downloader",
        title_key="notify.downloader.connectionTitle",
        message_key="notify.downloader.connectionBody",
        message_params={"name": name, "reason": error},
        payload={"downloader_id": downloader_id},
    )

"""种子快照同步任务——把 PT 站点最新发布前向同步进本地索引。

调度模型（见与产品讨论确定的方案）
--------------------------------
调度器引擎只支持「一个任务 + 一个固定间隔」，天然表达不了「每站不同频率」。
因此这里注册**单个全局任务** ``sync_site_torrents``，以较短的 tick（默认 120 秒）
被唤醒；每次 tick 只是扫一遍各站游标，**只对「到期」的站点真正发起访问**。
per-site 的自适应节奏藏在 ``SiteSyncCursor`` 里，对调度器透明。

- **tick** = 多久醒来看一眼（调度精度 / 最大延迟），不是每站的访问频率。
- **每站 interval** = 该站真正被访问的频率，按发布速率自适应，夹在 [min, max]。
- **首刷**：用户加站点时游标 ``next_sync_at`` 为 NULL（立即到期），下一个 tick 即首刷；
  首刷只取第 1 页建立基线，**不回补 t0 之前的历史**（本系统不做全站镜像）。
- **回补**：仅在「非首刷且首页全是新种」（说明两次间隔太长、发生漏种）时，才往后
  翻页直到接上已知区间，有界（``MAX_BACKFILL_PAGES``）且不越过 t0。

本模块沿用 ``verify_site`` 的背景任务范式：自开短会话、吞掉所有异常并记为可读中文
原因、用完关闭 HTTP 客户端。
"""

from __future__ import annotations

import asyncio
import logging
from datetime import UTC, datetime, timedelta

# 同步写入的新种与刷新都要维护检索文本（见 services/torrent_match_text.py）
import movieclaw_api.services.torrent_match_text  # noqa: F401
from movieclaw_api.services.site_access import (
    get_site_access,
    invalidate_site_access,
)
from movieclaw_api.services.subscription import (
    effective_forecast_probe_at,
    forecast_probe_times_by_site,
)
from movieclaw_api.services.verification import friendly_error, is_transient_error
from movieclaw_db.engine import get_database
from movieclaw_db.models.base import utcnow
from movieclaw_db.models.scheduled_task import TriggerType
from movieclaw_db.models.site_credential import ConfigStatus, SiteCredential
from movieclaw_db.models.site_torrent import TorrentSource
from movieclaw_db.repositories.credential_repo import CredentialRepository
from movieclaw_db.repositories.torrent_repo import (
    TorrentObservation,
    TorrentRepository,
)
from movieclaw_enrich import ENRICH_VERSION, enrich
from movieclaw_scheduler.registry import register_task
from movieclaw_tracker.exceptions import TrackerAuthError, TrackerParseError
from movieclaw_tracker.models import TorrentListItem

logger = logging.getLogger("movieclaw_api.torrent_sync")

# -- 自适应节奏参数 --------------------------------------------------------
# tick：全局任务被唤醒的固定间隔。必须 ≤ MIN_INTERVAL，否则最快的站也排不上。
_TICK_SECONDS = 120
# 每站轮询间隔的上下限与起始值（秒）
_MIN_INTERVAL = 300  # 5 分钟：发布最快的站也不会比这更密（礼貌下限之上的调度下限）
_MAX_INTERVAL = 21600  # 6 小时：冷站最疏到此为止
# 回补翻页上限：长时间宕机后避免失控狂爬；到顶仍未接上则记录缺口
_MAX_BACKFILL_PAGES = 10
# 站点时间最多允许比当前 UTC 快 15 分钟（容忍服务器轻微漂移）。超过通常意味着
# 本地时间未归一化；整页拒绝入库，避免污染发布时间、高水位和订阅预测。
_MAX_FUTURE_SKEW = timedelta(minutes=15)

# -- 熔断参数 --------------------------------------------------------------
# 连续失败达到该阈值、且当前这次失败为**非瞬时**（认证/解析类）时触发熔断：
# 把凭据状态置为 FAILED——_active_sites 只挑 ACTIVE，同步随之自动停止。
# 按退避节奏，10 次失败约跨 1 天以上，足以排除站点临时维护；此时仍解析失败
# 基本可断定站点已改版、关站或封禁账号，需人工介入（重新验证成功即恢复）。
# 瞬时故障（宕机/网络/限流）永不触发熔断：维持封顶 6 小时的退避重试，
# 站点自愈后同步自动恢复，不需要用户做任何事。
_BREAKER_THRESHOLD = 10
# 认证类失败（TrackerAuthError：账号停用、Key 失效、密码错误等）的快速熔断阈值。
# 站点已明确宣判凭据不可用，再宽容 10 轮毫无意义，只会让用户误以为一切正常
#（状态仍显示已验证）。但不在第 1 次就熔断：共享会话过期也会表现为认证失败，
# 失败后会话已被作废，下一轮会用存储的凭据重建并重新登录——真过期这轮就自愈了；
# 连续第 2 次仍是认证失败，才能确认凭据本身已死。
_AUTH_BREAKER_THRESHOLD = 2


def _adapt_interval(
    current: int,
    *,
    new_count: int,
    full_page: bool,
    consecutive_failures: int,
    pinned: bool = False,
) -> int:
    """依上一轮结果计算下次轮询间隔，夹在 [MIN, MAX]。

    - 首次失败：维持当前间隔再试一次——可能只是网络抖动，热站不必立刻放缓。
    - 连续失败：间隔 ×2 指数退避（上一轮已翻倍，效果即 2^n），封顶 MAX——
      站点宕机期间绝不以高频反复打一个挂掉的站。成功后按下面的规则自然收敛回来。
    - 有新增且首页全是新的（可能漏种）：间隔减半——把节奏调密、尽快补上。
    - 完全没有新增：间隔 ×1.5——这个站很冷，放疏省资源。
    - 其余（有新增但没到「满页全新」）：稳态，维持当前间隔。

    ``pinned``：成功时钉在 MIN 不参与放疏——刷流抢免费新种拼的是发现速度，
    冷站退避到小时级会错过整个免费窗口。是否钉住由 ``ratio_boost.wants_fast_sync``
    **动态判定**：开着刷流且有准入余量才钉；预算满且无可汰换时发现了也下
    不了，高频刷索引纯属浪费，自动回落到正常自适应。失败退避不受钉住影响
    （对挂掉的站高频重试没有意义）。
    """
    if consecutive_failures > 0:
        if consecutive_failures == 1:
            return current
        return min(_MAX_INTERVAL, current * 2)
    if pinned:
        return _MIN_INTERVAL
    if new_count > 0 and full_page:
        nxt = current // 2
    elif new_count == 0:
        nxt = int(current * 1.5)
    else:
        nxt = current
    return max(_MIN_INTERVAL, min(_MAX_INTERVAL, nxt))


def _to_observation(
    site_id: str, item: TorrentListItem, *, trust_volatile: bool
) -> TorrentObservation:
    """把 tracker 的 ``TorrentListItem`` 映射为持久化观测。

    这是「上游前提 A」的落点：``TorrentListItem`` 把「没解析到」塌缩成了 0/False/1.0，
    在这里由消费方决定易变层可不可信——``trust_volatile=False`` 时一律置 None（未观测），
    交给 upsert 保留旧值，避免把好数据冲掉。
    """
    category_value = item.category.value if item.category else None
    return TorrentObservation(
        site_id=site_id,
        torrent_id=item.torrent_id,
        source=TorrentSource.LIST,
        title=item.title,
        subtitle=item.subtitle,
        category=category_value,
        site_category_id=item.site_category_id,
        size_bytes=item.size_bytes,  # 0 会被 validator 归一为 None
        size_text=item.size,
        publish_time=item.upload_time,
        uploader=item.uploader,
        seeders=item.seeders if trust_volatile else None,
        leechers=item.leechers if trust_volatile else None,
        snatched=item.snatched if trust_volatile else None,
        download_volume_factor=item.download_volume_factor if trust_volatile else None,
        upload_volume_factor=item.upload_volume_factor if trust_volatile else None,
        free_deadline=item.free_deadline,
        hit_and_run=item.hit_and_run,
        # 扩充属性在入库前算好（本地正则 + NER 推理）。exclude_defaults 只存
        # 真提取到的字段——没提取到任何字段时是 {}，与"从未扩充"（NULL）可区分
        attrs=enrich(item.title, item.subtitle, category_value).model_dump(
            mode="json", exclude_defaults=True
        ),
        enrich_version=ENRICH_VERSION,
        detail_url=item.detail_url,
        download_url=item.download_url,
    )


async def _to_observations(
    site_id: str, items: list[TorrentListItem], *, trust_volatile: bool
) -> list[TorrentObservation]:
    """在线程池完成整页扩充，避免同步 NER 推理阻塞 API 事件循环。"""
    return await asyncio.to_thread(
        lambda: [_to_observation(site_id, item, trust_volatile=trust_volatile) for item in items]
    )


def _validate_page_times(
    site_id: str, page_num: int, items: list[TorrentListItem]
) -> None:
    """在写库前验证一页发布时间，解析失效或时区错误时整页熔断。"""
    values = [item.upload_time for item in items if item.upload_time is not None]
    if not values:
        raise TrackerParseError(
            f"站点 {site_id} 第 {page_num} 页未解析到任何种子发布时间，"
            "可能是页面结构已变化；本页已拒绝写入以保护同步游标"
        )
    if len(values) != len(items):
        logger.warning(
            "站点 %s 第 %d 页有 %d/%d 条未解析到发布时间；已保留为未知，"
            "请检查站点选择器",
            site_id,
            page_num,
            len(items) - len(values),
            len(items),
        )
    ceiling = utcnow() + _MAX_FUTURE_SKEW
    for value in values:
        normalized = (
            value.astimezone(UTC).replace(tzinfo=None)
            if value.tzinfo is not None
            else value
        )
        if normalized > ceiling:
            raise TrackerParseError(
                f"站点 {site_id} 第 {page_num} 页发布时间晚于当前时间超过 15 分钟，"
                "可能是站点时区未正确归一化；本页已拒绝写入"
            )


def _volatile_trustworthy(items: list[TorrentListItem]) -> bool:
    """页级健康检查：整页做种/下载/完成数**全为 0** 视为解析异常（选择器可能失效）。

    这种情况下不信任本页易变层——避免把一次批量解析故障当成「所有种子都没人做种、
    都不免费」写进库，把已有的好数据冲掉。返回 False 时映射会把易变字段置 None。
    """
    if not items:
        return True
    all_zero = all(it.seeders == 0 and it.leechers == 0 and it.snatched == 0 for it in items)
    return not all_zero


async def _active_sites() -> list[SiteCredential]:
    """取所有「已启用且验证通过」的站点——只有这些才参与同步。"""
    async with get_database().session() as session:
        creds = await CredentialRepository(session).list_all()
    return [c for c in creds if c.enabled and c.status == ConfigStatus.ACTIVE]


async def _plan_sync(
    sites: list[SiteCredential],
) -> tuple[list[SiteCredential], int | None]:
    """规划本轮 tick：返回（已到期站点列表，未到期站点中最近的到期还剩多少秒）。

    顺带对每个站 ensure_cursor：新站在此建立 t0（幂等），使得即便加站点时没显式
    建游标，也能被自愈接管；``next_sync_at`` 为 NULL 视为立即到期。追新预测的
    探测点只会把同步提前，且由 ``last_sync_at`` 判定是否已被普通/预测同步消费。

    第二个返回值供 tick 打印"最近一个还差多久同步"，把静默跳过变成可见反馈。
    """
    now = utcnow()
    due: list[SiteCredential] = []
    soonest_wait: int | None = None
    async with get_database().session() as session:
        repo = TorrentRepository(session)
        cursors = {}
        for cred in sites:
            cursors[cred.site_id] = await repo.ensure_cursor(cred.site_id)
        probes_by_site = await forecast_probe_times_by_site(
            session, site_ids=set(cursors)
        )

        for cred in sites:
            cursor = cursors[cred.site_id]
            normal_due = cursor.next_sync_at is None or now >= cursor.next_sync_at

            # 只看上次同步之后的预测点：无论那次是普通轮询还是预测触发，都说明
            # 更早探测已经被消费。若刚同步过，则把探测推迟到礼貌间隔之后。
            forecast_due_at = effective_forecast_probe_at(
                probes_by_site.get(cred.site_id, []),
                last_sync_at=cursor.last_sync_at,
            )

            forecast_due = forecast_due_at is not None and now >= forecast_due_at
            if forecast_due and not normal_due:
                # 区分「预测提前」与常规到期，事后能从日志还原每一次额外访问的来由
                logger.info(
                    "站点 %s 因追新预测提前同步（常规同步还差 %d 分钟）",
                    cred.site_id,
                    int((cursor.next_sync_at - now).total_seconds() // 60)
                    if cursor.next_sync_at is not None
                    else 0,
                )
            if normal_due or forecast_due:
                due.append(cred)
            else:
                due_times = [
                    value
                    for value in (cursor.next_sync_at, forecast_due_at)
                    if value is not None
                ]
                if due_times:
                    wait = max(0, int((min(due_times) - now).total_seconds()))
                    if soonest_wait is None or wait < soonest_wait:
                        soonest_wait = wait
    return due, soonest_wait


async def _fetch_pages(site, site_id: str, *, is_first_sync: bool):
    """拉取最新页并按需回补，返回 (观测列表, 首页是否全新, 最新种子)。

    停止条件：
    - 首刷 → 只取第 1 页做基线，绝不回补历史；
    - 接上已知区间（本页出现已知 torrent_id）→ 停；
    - 达到回补页数上限 → 停并告警（存在缺口）；
    - 本页最旧种子已早于 t0 → 停（不越过跟踪起点）。
    """
    observations: list[TorrentObservation] = []
    newest_item: TorrentListItem | None = None
    first_page_all_new = False

    async with get_database().session() as session:
        repo = TorrentRepository(session)
        cursor = await repo.ensure_cursor(site_id)
        tracking_since = cursor.tracking_since

    page_num = 1
    while True:
        page = await site.list_torrents(page=page_num)
        items = page.items
        if not items:
            break
        _validate_page_times(site_id, page_num, items)

        # 取整体最新（按发布时间），不假设站点一定严格倒序
        page_newest = max(items, key=lambda it: it.upload_time or datetime.min)
        if newest_item is None or (
            (page_newest.upload_time or datetime.min) > (newest_item.upload_time or datetime.min)
        ):
            newest_item = page_newest

        ids = [it.torrent_id for it in items]
        async with get_database().session() as session:
            existing = await TorrentRepository(session).existing_ids(site_id, ids)
        reached_known = len(existing) > 0

        trust = _volatile_trustworthy(items)
        if not trust:
            logger.warning(
                "站点 %s 第 %d 页做种数据整页为 0，疑似解析异常，本页不刷新易变字段",
                site_id,
                page_num,
            )
        observations.extend(await _to_observations(site_id, items, trust_volatile=trust))

        if page_num == 1:
            first_page_all_new = not reached_known and len(ids) > 0

        # -- 停止判断 --
        if is_first_sync:
            break  # 首刷只建立基线
        if reached_known:
            break  # 接上已知区间
        if page_num >= _MAX_BACKFILL_PAGES:
            logger.warning(
                "站点 %s 回补达到上限 %d 页仍未接上已知区间，可能存在缺口（发布过快或宕机过久）",
                site_id,
                _MAX_BACKFILL_PAGES,
            )
            break
        oldest = min((it.upload_time for it in items if it.upload_time), default=None)
        if oldest is not None and oldest < tracking_since:
            break  # 已翻到 t0 之前，无需再往前
        page_num += 1

    return observations, first_page_all_new, newest_item


async def _sync_one_site(cred: SiteCredential) -> None:
    """同步单个站点。每站单写者、串行 upsert，杜绝同站并发撞唯一键。"""
    site_id = cred.site_id
    db = get_database()

    # 首刷以“从未成功同步”判定。torrent_id 只是增量身份游标，不能代替成功台账：
    # 某站发布时间选择器失效时 ID 可能长期为空，但成功记录仍应阻止反复首刷。
    async with db.session() as session:
        cursor = await TorrentRepository(session).ensure_cursor(site_id)
        is_first_sync = cursor.last_success_at is None
        current_interval = cursor.sync_interval_seconds
        prev_failures = cursor.consecutive_failures

    new_count = 0
    updated_count = 0
    full_page = False
    error: str | None = None
    transient = False
    auth_failed = False
    newest_pt: datetime | None = None
    newest_tid: str | None = None
    try:
        # 取共享的已认证客户端（认证由管理器负责，一次构建全局复用；不得 close 它）
        site = await get_site_access().get(site_id)
        observations, full_page, newest = await _fetch_pages(
            site, site_id, is_first_sync=is_first_sync
        )
        if newest is not None:
            newest_pt = newest.upload_time
            newest_tid = newest.torrent_id
        if observations:
            async with db.session() as session:
                stats = await TorrentRepository(session).bulk_upsert(observations)
                new_count = stats.inserted  # 此前不存在、首次入库的
                updated_count = stats.updated  # 命中已有、刷新一遍的（复看）
        logger.info(
            "站点 %s 同步完成：共观测 %d 条（新增 %d，刷新 %d）%s",
            site_id,
            len(observations),
            new_count,
            updated_count,
            "（首刷建立基线）" if is_first_sync else "",
        )
    except Exception as exc:  # noqa: BLE001 -- 背景任务吞掉异常并记录可读原因
        error = friendly_error(exc)
        transient = is_transient_error(exc)
        auth_failed = isinstance(exc, TrackerAuthError)
        logger.warning("站点 %s 同步失败：%s", site_id, error, exc_info=True)
        if not transient:
            # 非瞬时失败（认证/解析类）可能是会话过期：作废共享缓存，下一个 tick
            # 重建并重新认证（自愈）。瞬时故障（站点宕机/网络抖动）则保留会话——
            # 对着挂掉的站反复重登录没有意义，还可能触发站点的登录频控
            await invalidate_site_access(site_id)

    # 计算下次节奏并回写游标（出错也要排下次，避免卡死不再重试）
    failures = 0 if error is None else prev_failures + 1
    # 认证类失败走快速阈值：站点已明确拒绝凭据，无需再宽容 10 轮
    threshold = _AUTH_BREAKER_THRESHOLD if auth_failed else _BREAKER_THRESHOLD
    tripped = error is not None and not transient and failures >= threshold
    # 刷流快节奏是动态的：开着刷流且有准入余量才钉住（见 wants_fast_sync）
    from movieclaw_api.services.ratio_boost import wants_fast_sync

    async with db.session() as session:
        pinned = await wants_fast_sync(session, cred)
    next_interval = _adapt_interval(
        current_interval,
        new_count=new_count,
        full_page=full_page,
        consecutive_failures=failures,
        pinned=pinned,
    )
    if error is not None and transient:
        # 瞬时故障对用户是「不用管」的：把重试计划写进原因里，安抚而非报警
        error += (
            f"；将于约 {max(1, next_interval // 60)} 分钟后自动重试（已连续失败 {failures} 次）"
        )
    if tripped:
        if auth_failed:
            error += (
                f"；已连续 {failures} 次认证失败，同步已暂停。"
                "站点明确拒绝了当前凭据（账号可能被停用或凭据已失效），"
                "请到「设置 → 站点」更新凭据并重新验证以恢复同步"
            )
        else:
            error += (
                f"；已连续失败 {failures} 次，同步已暂停。"
                "站点可能已关站、改版或封禁了你的账号，确认站点可用后请重新验证以恢复同步"
            )
    async with db.session() as session:
        await TorrentRepository(session).update_cursor_after_sync(
            site_id,
            newest_publish_time=newest_pt,
            newest_torrent_id=newest_tid,
            new_count=new_count,
            full_page=full_page,
            error=error,
            consecutive_failures=failures,
            next_interval_seconds=next_interval,
        )
        if tripped:
            # 熔断动作：凭据置 FAILED，站点从活跃列表消失、不再被同步。
            # 恢复路径复用既有机制：用户在站点页「重新验证」成功转 ACTIVE 即恢复
            await CredentialRepository(session).update_status(
                site_id, ConfigStatus.FAILED, last_error=error
            )
            # 与验证失败共用同一盏全局红灯（dedupe_key 一致）：熔断意味着该站点
            # 已静默退出搜索与投递，必须被用户感知；重新验证成功后红灯自动熄灭
            from movieclaw_api.services.system_notice import upsert_notice
            from movieclaw_db.models import NoticeSeverity

            await upsert_notice(
                session,
                dedupe_key=f"site:{site_id}",
                severity=NoticeSeverity.ERROR,
                source="site",
                title=f"站点「{site_id}」同步已熔断",
                message=f"站点「{site_id}」{error or '原因未知'}。"
                "该站点已不参与搜索与投递，请到「设置 → 站点」检查凭据并重新验证",
                payload={"site_id": site_id},
            )
    if tripped:
        logger.warning(
            "站点 %s 触发熔断：连续 %d 次非瞬时失败，已暂停同步并将站点标记为验证失败",
            site_id,
            failures,
        )


@register_task(
    "sync_site_torrents",
    title="同步站点最新种子",
    trigger_type=TriggerType.INTERVAL,
    interval_seconds=_TICK_SECONDS,
    description="全局 tick：扫描各站游标，只对到期站点拉取最新发布并前向同步进本地索引。",
)
async def sync_site_torrents() -> None:
    """全局 tick 任务体：找出到期站点，逐个串行同步。

    绝大多数 tick 会发现「没有站到期」，只做几次本地游标查询即返回，不发起任何
    站点请求。真正的站点访问只发生在到期站上。
    """
    sites = await _active_sites()
    if not sites:
        logger.debug("本轮 tick：没有已启用且验证通过的站点，跳过")
        return
    due, soonest_wait = await _plan_sync(sites)
    if not due:
        # 明说"为什么没同步"：都没到期，以及最近一个还差多久——避免"看着像没干活"
        wait_hint = f"，最近一个约 {soonest_wait} 秒后" if soonest_wait is not None else ""
        logger.info("本轮 tick：%d 个活跃站点均未到期%s", len(sites), wait_hint)
        return
    logger.info(
        "本轮 tick：%d/%d 个站点到期，开始同步：%s",
        len(due),
        len(sites),
        [c.site_id for c in due],
    )
    for cred in due:
        await _sync_one_site(cred)

    # 订阅被动匹配：本轮落库的新种子立即反查订阅缺口（水位驱动、无参调用，
    # 自身吞异常不影响同步任务；进程重启漏网由低频兜底任务补扫）
    from movieclaw_api.services.torrent_matcher import process_new_torrents

    await process_new_torrents()

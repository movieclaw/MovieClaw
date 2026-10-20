"""智能订阅的记忆：读写、按作品解析、跟随变化（docs/design/smart-subscription-memory.md）。

纯规则在 ``movieclaw_matcher.smart_memory``；这里负责数据库：

- 记忆是单行表 ``smart_memory``，revision 做乐观并发，和类型设置同一套冲突口径；
- 作品事实取自 ``media_metadata``（订阅弹层打开时 prepare 已经建档刮削过）；
- 订阅上的 ``smart_policy`` 是「当前设置 + 记忆 + 本订阅单独设置」解析后的副本。
  类型设置或记忆一变，所有智能订阅重新解析，在等的单元立即重新决策——用户说了
  「我看得懂英语」，正在等字幕的英语片就该马上不等。已经下载的不受影响。
"""

from __future__ import annotations

from dataclasses import dataclass, field

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from movieclaw_api.exceptions import BadRequestException
from movieclaw_api.services.subscription.smart_profiles import conflict
from movieclaw_db.models import (
    ActivityType,
    MediaItem,
    SmartMemoryRow,
    SmartProfile,
    Subscription,
    SubscriptionActivity,
    SubscriptionStatus,
    WantedItem,
    WantedStatus,
)
from movieclaw_db.models.base import utcnow
from movieclaw_db.models.media_metadata import MediaMetadata
from movieclaw_matcher.smart import SmartPolicy, SmartPreferences
from movieclaw_matcher.smart_memory import (
    DEFAULT_UNDERSTOOD,
    QualityHabit,
    QualityOverride,
    Resolved,
    SmartFacts,
    SmartMemory,
    language_key,
    parse_scope,
    resolve,
)


async def load_memory(session: AsyncSession) -> SmartMemory:
    row = await session.get(SmartMemoryRow, 1, populate_existing=True)
    if row is None:
        return SmartMemory()
    return SmartMemory(revision=row.revision, languages=row.languages, habits=row.habits)


async def store_memory(session: AsyncSession, memory: SmartMemory, expected: int) -> SmartMemory:
    """按 revision 写入（不提交）。别人先改了就 409，和类型设置冲突同一个错误码。"""
    values = {
        "languages": [a.model_dump(mode="json") for a in memory.languages],
        "habits": [h.model_dump(mode="json") for h in memory.habits],
        "revision": expected + 1,
        "updated_at": utcnow(),
    }
    if await session.get(SmartMemoryRow, 1) is None:
        if expected != 0:
            raise conflict()
        session.add(SmartMemoryRow(id=1, **values))
        await session.flush()
    else:
        result = await session.execute(
            update(SmartMemoryRow)
            .where(SmartMemoryRow.id == 1, SmartMemoryRow.revision == expected)
            .values(**values)
        )
        if result.rowcount != 1:
            await session.rollback()
            raise conflict()
    return memory.model_copy(update={"revision": expected + 1})


async def facts_for(session: AsyncSession, item: MediaItem) -> SmartFacts:
    meta = (
        await session.execute(select(MediaMetadata).where(MediaMetadata.media_item_id == item.id))
    ).scalar_one_or_none()
    kind = "tv" if item.kind == "tv" else "movie"
    if meta is None:
        return SmartFacts(kind=kind, title=item.title)
    countries = [c for c in (meta.origin_countries or []) if c]
    studios = [s for s in (meta.studios or []) if s]
    return SmartFacts(
        kind=kind,
        title=item.title,
        language=language_key(meta.original_language),
        region=countries[0] if countries else None,
        # 剧集的 studios 是播出网络；电影的是制作公司，不当平台用
        network=studios[0] if kind == "tv" and studios else None,
        series_key=meta.series_key,
    )


async def series_override(
    session: AsyncSession, facts: SmartFacts, *, exclude: int | None = None
) -> QualityOverride | None:
    """同系列最近一部单独改过画质的智能订阅：续集沿用它。"""
    if not facts.series_key:
        return None
    rows = (
        await session.execute(
            select(Subscription.id, Subscription.smart_overrides, MediaItem.title)
            .join(MediaItem, MediaItem.id == Subscription.media_item_id)
            .join(MediaMetadata, MediaMetadata.media_item_id == MediaItem.id)
            .where(
                MediaMetadata.series_key == facts.series_key,
                Subscription.selection_mode == "smart",
                Subscription.smart_overrides.is_not(None),  # type: ignore[union-attr]
            )
            .order_by(Subscription.id.desc())  # type: ignore[union-attr]
        )
    ).all()
    for sub_id, raw, title in rows:
        if sub_id == exclude or not raw:
            continue
        try:
            source = QualityOverride.model_validate(raw)
        except ValueError:
            continue
        if source.resolution or source.source:
            return QualityOverride(
                resolution=source.resolution,
                source=source.source,
                origin="series",
                series_title=title,
            )
    return None


async def profile_prefs(
    session: AsyncSession, kind: str
) -> tuple[SmartProfile | None, SmartPreferences | None]:
    row = await session.get(SmartProfile, kind)
    if row is None:
        return None, None
    return row, SmartPreferences.model_validate(row.preferences)


@dataclass
class SmartPlan:
    """订阅弹层要的解析结果。"""

    profile: SmartProfile | None
    prefs: SmartPreferences | None
    memory: SmartMemory
    facts: SmartFacts
    resolved: Resolved | None
    series: QualityOverride | None = None
    extra: dict = field(default_factory=dict)


async def plan_for(session: AsyncSession, item: MediaItem) -> SmartPlan:
    facts = await facts_for(session, item)
    profile, prefs = await profile_prefs(session, facts.kind)
    memory = await load_memory(session)
    series = await series_override(session, facts)
    resolved = resolve(prefs, facts, memory, series=series) if prefs else None
    return SmartPlan(profile, prefs, memory, facts, resolved, series)


@dataclass
class SmartChoice:
    """订阅弹层里管理员做的选择。成员不能写记忆，传了也不生效。"""

    language_answer: str | None = None  # "subtitles" / "understood"
    resolution: str | None = None
    source: str | None = None
    scope: str | None = None  # "only" 或范围选项的 value
    memory_revision: int | None = None


async def freeze_smart(
    session: AsyncSession,
    item: MediaItem,
    revision: int | None,
    choice: SmartChoice | None,
    *,
    is_admin: bool,
) -> tuple[dict, dict | None, bool]:
    """解析新订阅的策略：先把管理员的回答写进记忆（不提交），再按记忆解析。

    返回 (smart_policy, smart_overrides, 记忆是否变了)。
    """
    plan = await plan_for(session, item)
    if plan.profile is None or plan.prefs is None:
        raise BadRequestException("请先保存智能设置")
    if revision != plan.profile.revision:
        raise conflict()
    memory, facts = plan.memory, plan.facts
    changed = False
    override: QualityOverride | None = None
    if choice is not None and is_admin:
        if choice.memory_revision is not None and choice.memory_revision != memory.revision:
            raise conflict()
        now = utcnow()
        if (
            choice.language_answer in {"subtitles", "understood"}
            and facts.language is not None
            and facts.language != DEFAULT_UNDERSTOOD
        ):
            understood = choice.language_answer == "understood"
            current = next((a for a in memory.languages if a.key == facts.language), None)
            if current is None or current.understood != understood:
                memory = memory.with_language(
                    facts.language, understood, source_title=facts.title, at=now
                )
                changed = True
        baseline = resolve(plan.prefs, facts, memory, series=plan.series)
        diff = {
            name: value
            for name, value in (("resolution", choice.resolution), ("source", choice.source))
            if value is not None and value != getattr(baseline, name)
        }
        if diff:
            scope = choice.scope or "only"
            if scope == "only":
                override = QualityOverride(**diff)
            else:
                parsed = parse_scope(scope, facts)
                if parsed is None:
                    raise BadRequestException("这部作品没有这个习惯范围")
                key = f"{parsed[0]}:{facts.kind}:{parsed[1]}"
                existing = next((h for h in memory.habits if h.key == key), None)
                merged = {
                    "resolution": existing.resolution if existing else None,
                    "source": existing.source if existing else None,
                    **diff,
                }
                memory = memory.with_habit(
                    QualityHabit(
                        scope=parsed[0],
                        value=parsed[1],
                        kind=facts.kind,
                        source_title=facts.title,
                        at=now,
                        **merged,
                    )
                )
                changed = True
        if changed:
            memory = await store_memory(session, memory, plan.memory.revision)
    if override is None and plan.series is not None:
        override = plan.series  # 续集沿用，冻结在订阅上
    resolved = resolve(plan.prefs, facts, memory, override=override)
    policy = resolved.policy(
        plan.prefs, kind=facts.kind, profile_revision=plan.profile.revision
    ).model_dump(mode="json")
    return policy, (override.model_dump(mode="json") if override else None), changed


def _override_of(sub: Subscription) -> QualityOverride | None:
    if not sub.smart_overrides:
        return None
    try:
        return QualityOverride.model_validate(sub.smart_overrides)
    except ValueError:
        return None


def _wait_text(seconds: int) -> str:
    return "不等待" if seconds == 0 else f"最多等 {seconds // 3600} 小时"


async def resolve_subscription(
    session: AsyncSession, sub: Subscription, *, memory: SmartMemory | None = None
) -> tuple[Resolved, SmartPolicy] | None:
    item = await session.get(MediaItem, sub.media_item_id)
    profile, prefs = await profile_prefs(session, sub.kind)
    if item is None or profile is None or prefs is None:
        return None
    facts = await facts_for(session, item)
    resolved = resolve(
        prefs, facts, memory or await load_memory(session), override=_override_of(sub)
    )
    return resolved, resolved.policy(prefs, kind=sub.kind, profile_revision=profile.revision)


async def apply_to_subscriptions(
    session: AsyncSession, kinds: tuple[str, ...] = ("movie", "tv")
) -> None:
    """所有智能订阅按当前设置与记忆重新解析（不提交）。

    策略真的变了才写，并把在等单元的下次决策提前到现在；截止由决策引擎按新预算
    收紧（只缩短不延长、手动延长保留）。已收齐的订阅也换上新策略（补缺时生效），
    但不往它们的时间线里刷动态。
    """
    memory = await load_memory(session)
    subs = (
        (
            await session.execute(
                select(Subscription).where(
                    Subscription.selection_mode == "smart",
                    Subscription.kind.in_(kinds),  # type: ignore[attr-defined]
                )
            )
        )
        .scalars()
        .all()
    )
    now = utcnow()
    for sub in subs:
        solved = await resolve_subscription(session, sub, memory=memory)
        if solved is None:
            continue
        _resolved, policy = solved
        payload = policy.model_dump(mode="json")
        if payload == sub.smart_policy:
            continue
        sub.smart_policy, sub.updated_at = payload, now
        session.add(sub)
        await session.execute(
            update(WantedItem)
            .where(
                WantedItem.subscription_id == sub.id,
                WantedItem.status == WantedStatus.WANTED,
                WantedItem.next_selection_at > now,  # type: ignore[operator]
            )
            .values(next_selection_at=now)
        )
        if sub.status == SubscriptionStatus.COMPLETED:
            continue
        target = f"{policy.resolution} {policy.source}"
        subtitles = "，只下看得懂的字幕版本" if policy.watchable_languages else ""
        session.add(
            SubscriptionActivity(
                subscription_id=sub.id,
                type=ActivityType.ADJUSTED,
                message=(
                    f"已跟随当前智能设置与记忆：{_wait_text(policy.wait_seconds)}，目标 {target}"
                    f"{subtitles}{'，达标后停止洗版' if policy.allow_upgrade else '，不洗版'}"
                ),
                payload={"smart_policy": payload},
            )
        )


async def notify_awaiting_subtitles(
    session: AsyncSession, sub: Subscription, policy: SmartPolicy, states: dict
) -> None:
    """等待到期仍只有看不懂的原版：知会一次（每个单元每次到期一次，由状态转换去重）。"""
    from movieclaw_api import event_refs, events
    from movieclaw_matcher.smart_memory import acceptable_text, language_label
    from movieclaw_sdk.events import (
        SUBSCRIPTION_AWAITING_SUBTITLES,
        SubscriptionAwaitingSubtitles,
    )

    item = await session.get(MediaItem, sub.media_item_id)
    media = event_refs.media_ref(item) if item else None
    if item is None or media is None or not policy.watchable_languages:
        return
    facts = await facts_for(session, item)
    now = utcnow()
    first = min(states.values(), key=lambda s: s.anchor)
    await events.publish(
        session,
        SUBSCRIPTION_AWAITING_SUBTITLES,
        lambda: SubscriptionAwaitingSubtitles(
            subscription_id=sub.id,
            media=media,
            units=event_refs.units(sorted(states)),
            language=language_label(facts.language) if facts.language else "外语",
            acceptable=acceptable_text(policy.watchable_languages),
            originals=max(s.subtitle_blocked for s in states.values()),
            waited_hours=max(1, int((now - first.anchor).total_seconds() // 3600)),
        ),
    )
    await session.commit()

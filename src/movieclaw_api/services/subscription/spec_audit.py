"""入库规格核验：实测规格与种子声称不符时出声（issue #242）。

投递前的规则过滤（``evaluate_rules``）只能采信种子名解析，这没问题——那是
当时唯一可用的信息。但入库后 ffprobe 已经拿到真实规格，"种子名声称 1080p /
实测 960×540"这个矛盾在对账那一刻是**可判定**的：声称值在
``attempt.quality``（投递时的种子名快照）里，实测值在 ``library_file`` 的
probe 列里（也已经写进 ``wanted_item.quality``）。此前两边数据都在，却没有
任何一处对照，坏种子就静静躺进了媒体库，规则组的分辨率白名单形同虚设。

核验规则：

- 只比**可实测**的维度（分辨率、视频编码族）——片源/制作组这类出处维度
  ffprobe 测不出，拿名称解析比名称解析没有意义；
- 两侧都识别出值、且不一致才算矛盾（三态铁律：未知不当已知用。探测失败
  或种子名没写规格都不是证据）；
- 实测值还违反规则组的硬过滤（分辨率/编码白名单）时升级为待处理告警——
  这是"本不该进来的文件进来了"，用户需要知道并复查。

**只报告、不动文件**：已经下完入库的内容要不要判失败、要不要写进负面记忆
换源重下，是有行为风险的策略决定（issue #242 讨论里维护者尚未拍板），不在
核验的职责范围内。核验负责的是让矛盾不再完全静默。
"""

from __future__ import annotations

import logging

from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import select

from movieclaw_api.i18n.stored import reference, reference_fields, source_render, source_text
from movieclaw_db.models import (
    ActivityType,
    MediaItem,
    NoticeSeverity,
    SubscriptionActivity,
    SubscriptionDownloadAttempt,
    WantedItem,
)
from movieclaw_db.repositories import SubscriptionRepository
from movieclaw_enrich.vocab import codec_family
from movieclaw_matcher import QualitySnapshot, RuleSetSpec

logger = logging.getLogger("movieclaw_api.subscription.spec_audit")


def spec_mismatches(claimed: QualitySnapshot, measured: QualitySnapshot) -> list[dict]:
    """声称与实测的差异清单：``[{"dimension", "claimed", "measured"}, ...]``。

    分辨率按归一化值比较；视频编码按**编码族**比较（x265/H.265/HEVC 是同一
    种编码的三种写法，写法不同不算货不对板）。
    """
    diffs: list[dict] = []
    if (
        claimed.resolution
        and measured.resolution
        and claimed.resolution.casefold() != measured.resolution.casefold()
    ):
        diffs.append(
            {
                "dimension": source_text("subscription.spec.resolution"),
                "claimed": claimed.resolution,
                "measured": measured.resolution,
            }
        )
    if (
        claimed.video_codec
        and measured.video_codec
        and codec_family(claimed.video_codec) != codec_family(measured.video_codec)
    ):
        diffs.append(
            {
                "dimension": source_text("subscription.spec.videoCodec"),
                "claimed": claimed.video_codec,
                "measured": measured.video_codec,
            }
        )
    return diffs


_DIMENSION_KEYS = ("subscription.spec.resolution", "subscription.spec.videoCodec")


def _dimension_reference(label: str) -> dict | str:
    """载荷里存的是维度的中文名（历史数据同口径）；文案按读者语言给。"""
    for key in _DIMENSION_KEYS:
        if source_text(key) == label:
            return reference(key)
    return label


def rule_violation(measured: QualitySnapshot, spec: RuleSetSpec) -> dict | None:
    """实测规格是否违反规则组硬过滤；返回原因的文案引用或 None。

    只判本模块实测得到的两个维度，不复用 ``evaluate_rules``——后者还要判
    做种数/体积/促销这些只有站点候选才有的字段，拿一个合成候选去跑会得到
    与投递时口径不一致的结论。
    """
    if spec.resolutions and measured.resolution:
        allowed = {value.casefold() for value in spec.resolutions}
        if measured.resolution.casefold() not in allowed:
            return reference(
                "subscription.spec.resolutionViolation",
                value=measured.resolution,
                allowed="/".join(spec.resolutions),
            )
    if spec.video_codecs and measured.video_codec:
        allowed = {codec_family(value) for value in spec.video_codecs}
        if codec_family(measured.video_codec) not in allowed:
            return reference(
                "subscription.spec.codecViolation",
                value=measured.video_codec,
                allowed="/".join(spec.video_codecs),
            )
    return None


async def audit_ingest_specs(
    session: AsyncSession, media_item_id: int, wanted_rows: list[WantedItem]
) -> None:
    """核验一批刚入库单元的实测规格与投递时的声称规格，不一致时记录。

    在库存对账写完质量快照之后调用（``wanted.quality`` 此时已是实测口径）。
    每个单元只在入库那一次核验，不会反复打扰。
    """
    from movieclaw_api.services.subscription.upgrade import (
        _specs_for_subscriptions,
        _unit_reference,
        _unit_text,
    )
    from movieclaw_api.services.system_notice import upsert_notice

    rows = [w for w in wanted_rows if w.quality and w.info_hash]
    if not rows:
        return
    specs = await _specs_for_subscriptions(session, {w.subscription_id for w in rows})
    item = await session.get(MediaItem, media_item_id)
    repo = SubscriptionRepository(session)

    for wanted in rows:
        attempt = (
            await session.execute(
                select(SubscriptionDownloadAttempt).where(
                    SubscriptionDownloadAttempt.subscription_id == wanted.subscription_id,
                    SubscriptionDownloadAttempt.info_hash == wanted.info_hash,
                )
            )
        ).scalar_one_or_none()
        if attempt is None or not attempt.quality:
            continue  # 手工入库/扫描收编：没有声称值，无从对照
        claimed = QualitySnapshot.model_validate(attempt.quality)
        measured = QualitySnapshot.model_validate(wanted.quality)
        diffs = spec_mismatches(claimed, measured)
        if not diffs:
            continue

        spec = specs.get(wanted.subscription_id)
        violation = rule_violation(measured, spec) if spec is not None else None
        title = item.title if item is not None else source_text("media.kind.unknown")
        detail = {
            "message_list": [
                reference(
                    "subscription.spec.detail",
                    dimension=_dimension_reference(d["dimension"]),
                    measured=d["measured"],
                    claimed=d["claimed"],
                )
                for d in diffs
            ],
            "separator_key": "common.list.issueSeparator",
        }
        message = (
            reference(
                "activity.subscription.specMismatchViolation",
                unit=_unit_reference(wanted),
                detail=detail,
                violation=violation,
            )
            if violation
            else reference(
                "activity.subscription.specMismatchOk", unit=_unit_reference(wanted), detail=detail
            )
        )
        await repo.add_activity(
            SubscriptionActivity(
                subscription_id=wanted.subscription_id,
                wanted_item_id=wanted.id,
                type=ActivityType.SPEC_MISMATCH,
                **reference_fields(message),
                payload={
                    "units": [[wanted.season_number, wanted.episode_number]],
                    "info_hash": wanted.info_hash,
                    "site_id": attempt.site_id,
                    "torrent_id": attempt.torrent_id,
                    "mismatches": diffs,
                    "rule_violation": source_render(violation) if violation else None,
                },
            )
        )
        logger.warning(
            "《%s》%s 入库规格与种子声称不符：%s", title, _unit_text(wanted), source_render(detail)
        )
        if violation is None:
            continue
        # 硬过滤被违反：这是"本不该进来的文件进来了"，光记时间线不够——
        # 用户不复查的话，它还会因为档位不可比而卡住洗版（issue #242）
        await upsert_notice(
            session,
            dedupe_key=(
                f"subscription.spec_mismatch:{wanted.subscription_id}:"
                f"{wanted.season_number}:{wanted.episode_number}"
            ),
            severity=NoticeSeverity.WARNING,
            source="subscription",
            title_key="notify.specMismatch.title",
            message_key="notify.specMismatch.body",
            message_params={
                "title": item.title if item else {"message_key": "media.kind.unknown"},
                "unit": _unit_text(wanted)
                if wanted.season_number or wanted.episode_number
                else {"message_key": "media.kind.feature"},
                "detail": detail,
                "violation": violation,
            },
            payload={
                "subscription_id": wanted.subscription_id,
                "info_hash": wanted.info_hash,
                "mismatches": diffs,
            },
        )

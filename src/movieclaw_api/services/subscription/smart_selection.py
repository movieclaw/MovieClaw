"""持久化智能候选与等待决定；不执行网络访问。"""

from __future__ import annotations

from datetime import datetime, timedelta

from pydantic import TypeAdapter
from sqlalchemy import update
from sqlalchemy.dialects.sqlite import insert
from sqlmodel import select

from movieclaw_api.services.subscription.smart_profiles import conflict
from movieclaw_db.models import (
    SiteTorrent,
    SmartCandidate,
    SmartDecisionRecord,
    SmartSeason,
    Subscription,
    SubscriptionDownloadAttempt,
    SubscriptionStatus,
    WantedItem,
    WantedStatus,
    utcnow,
)
from movieclaw_matcher import QualitySnapshot, match_identity
from movieclaw_matcher.smart import (
    SelectionDecision,
    SelectionState,
    candidate_key,
    decide,
    eligible,
    series_key,
    series_key_attrs,
)


async def confirm_import(session, subscription, wanted, snapshot):
    from movieclaw_api.services.subscription.smart_profiles import read_policy
    from movieclaw_matcher.smart import quality_vector, verified_target_met

    policy = read_policy(subscription)
    if policy is None:
        return
    now = utcnow()
    state = (
        SelectionState.model_validate(wanted.selection_state)
        if wanted.selection_state
        else SelectionState(anchor=now, deadline=now, observation_end=now)
    )
    state.target_reached = state.target_reached or verified_target_met(snapshot, policy)
    state.quality_evidence = {
        "resolution_verified": snapshot.resolution_verified,
        "source": snapshot.source_evidence,
    }
    state.reason = "target_reached" if state.target_reached else "imported"
    wanted.selection_state = state.model_dump(mode="json")
    wanted.next_selection_at = None
    wanted.selection_version += 1
    if (
        subscription.kind == "tv"
        and snapshot.release_group
        and snapshot.resolution_verified
        and snapshot.source_evidence in {"consistent_declaration", "manual", "disc"}
        and None not in quality_vector(snapshot)
    ):
        key = series_key_attrs(snapshot)
        follow = (
            await session.execute(
                select(SmartSeason).where(
                    SmartSeason.subscription_id == subscription.id,
                    SmartSeason.season_number == wanted.season_number,
                )
            )
        ).scalar_one_or_none()
        if follow is None:
            await session.execute(
                insert(SmartSeason)
                .values(
                    subscription_id=subscription.id,
                    season_number=wanted.season_number,
                    series_key=key,
                    confirmed=True,
                    evidence={"reason": "existing_verified_import"},
                    created_at=now,
                    updated_at=now,
                )
                .on_conflict_do_nothing(index_elements=["subscription_id", "season_number"])
            )
            follow = (
                await session.execute(
                    select(SmartSeason).where(
                        SmartSeason.subscription_id == subscription.id,
                        SmartSeason.season_number == wanted.season_number,
                    )
                )
            ).scalar_one()
        if follow:
            evidence = dict(follow.evidence)
            if key == follow.series_key or (
                state.selected_series == follow.series_key
                and key.split("|")[:3] == follow.series_key.split("|")[:3]
            ):
                follow.confirmed = True
                evidence["confirmed_episode"] = wanted.episode_number
                evidence["source_evidence"] = snapshot.source_evidence
            elif state.selected_series == follow.series_key and snapshot.source_evidence in {
                "consistent_declaration",
                "manual",
                "disc",
            }:
                # 只计真实入库测得的品质差异；网络/站点/磁盘失败绝不计入。
                failures = set(evidence.get("quality_failure_episodes", []))
                failures.add(wanted.episode_number)
                evidence["quality_failure_episodes"] = sorted(failures)
            follow.evidence = evidence
            follow.updated_at = now
            await maybe_switch_series(session, subscription, follow, wanted)


async def maybe_switch_series(session, subscription, follow, imported):
    """至少三集实测品质问题 + 三集替代系列成功；切换后重新积累证据。"""
    if len(follow.evidence.get("quality_failure_episodes", [])) < 3:
        return
    rows = (
        (
            await session.execute(
                select(WantedItem).where(
                    WantedItem.subscription_id == subscription.id,
                    WantedItem.season_number == follow.season_number,
                    WantedItem.status == WantedStatus.IMPORTED,
                    WantedItem.in_scope.is_(True),
                )
            )
        )
        .scalars()
        .all()
    )
    successes = {}
    for row in rows:
        if not row.quality or row.episode_number <= follow.evidence.get("switched_at_episode", -1):
            continue
        quality = QualitySnapshot.model_validate(row.quality)
        key = series_key_attrs(quality)
        if (
            key
            and key != follow.series_key
            and quality.resolution_verified
            and quality.source_evidence in {"consistent_declaration", "manual", "disc"}
        ):
            successes.setdefault(key, set()).add(row.episode_number)
    candidates = [key for key, episodes in successes.items() if len(episodes) >= 3]
    if not candidates:
        return
    from movieclaw_db.models import ActivityType, SubscriptionActivity

    old = follow.series_key
    chosen = sorted(candidates, key=lambda k: (-len(successes[k]), k))[0]
    follow.series_key, follow.confirmed = chosen, True
    follow.evidence = {
        "reason": "verified_quality_failures",
        "previous": old,
        "failure_episodes": follow.evidence["quality_failure_episodes"],
        "success_episodes": sorted(successes[chosen]),
        "switched_at_episode": max(r.episode_number for r in rows),
    }
    session.add(
        SubscriptionActivity(
            subscription_id=subscription.id,
            wanted_item_id=imported.id,
            type=ActivityType.ADJUSTED,
            message="多个单集的实测品质不符，已根据成功入库记录更换跟随版本",
            payload=follow.evidence,
        )
    )


async def candidate_pool(session, contexts, torrents):
    """首次看到的事实保留发现时间；后续属性更新不能重置工单截止。"""
    from movieclaw_api.services.subscription.matching import to_candidate

    pools = {}
    now = utcnow()
    for media_id, ctx in contexts.items():
        if ctx.subscription.selection_mode != "smart":
            pools[media_id] = torrents
            continue
        existing = {
            f"{c.site_id}/{c.torrent_id}": c
            for c in (
                await session.execute(
                    select(SmartCandidate)
                    .where(SmartCandidate.subscription_id == ctx.subscription.id)
                    .execution_options(populate_existing=True)
                )
            ).scalars()
        }
        for row in torrents:
            candidate = to_candidate(row)
            match = match_identity(candidate, ctx.identity) if candidate else None
            old = existing.get(f"{row.site_id}/{row.torrent_id}")
            if (match is None or match.id_conflict) and old is None:
                continue
            observations = list(old.observations) if old else []
            fact = {
                "series": series_key(candidate) if candidate else None,
                "eligible": bool(match and not match.id_conflict and eligible(candidate, ctx.spec)),
                "episodes": sorted([list(u) for u in match.episodes]) if match else [],
                "pack": match.is_pack if match else False,
            }
            previous = (
                {k: v for k, v in observations[-1].items() if k != "at"} if observations else None
            )
            if fact != previous:
                observations.append({**fact, "at": now.isoformat()})
            values = dict(
                subscription_id=ctx.subscription.id,
                site_id=row.site_id,
                torrent_id=row.torrent_id,
                snapshot=row.model_dump(mode="json"),
                created_at=now,
                observations=observations[-16:],
                updated_at=now,
            )
            await session.execute(
                insert(SmartCandidate)
                .values(**values)
                .on_conflict_do_update(
                    index_elements=["subscription_id", "site_id", "torrent_id"],
                    set_={
                        "snapshot": values["snapshot"],
                        "updated_at": now,
                        "observations": values["observations"],
                    },
                )
            )
        await session.commit()
        cached = (
            (
                await session.execute(
                    select(SmartCandidate)
                    .where(SmartCandidate.subscription_id == ctx.subscription.id)
                    .execution_options(populate_existing=True)
                )
            )
            .scalars()
            .all()
        )
        pools[media_id] = [SiteTorrent.model_validate(c.snapshot) for c in cached]
    return pools


async def plan_selection(session, ctx, entries, *, identity_rejections=None):
    from movieclaw_api.services.subscription.matching import (
        covered_units,
        drop_proven_missing,
        publish_calendar_date,
    )
    from movieclaw_api.services.subscription.smart_runtime import runtime_settings
    from movieclaw_matcher import TorrentCandidate
    from movieclaw_matcher.smart import quality_vector

    now = utcnow()
    identity_rejections = identity_rejections or {}
    runtime = await runtime_settings()
    mode = "shadow" if runtime.shadow_only else "active"
    all_rows = (
        (
            await session.execute(
                select(WantedItem).where(
                    WantedItem.subscription_id == ctx.subscription.id, WantedItem.in_scope.is_(True)
                )
            )
        )
        .scalars()
        .all()
    )
    follows = {
        r.season_number: r.series_key
        for r in (
            await session.execute(
                select(SmartSeason).where(SmartSeason.subscription_id == ctx.subscription.id)
            )
        ).scalars()
    }
    open_rows = {**ctx.open_wanted, **ctx.upgrade_wanted}
    rejected = {
        (attempt.site_id, attempt.torrent_id)
        for attempt in (
            await session.execute(
                select(SubscriptionDownloadAttempt).where(
                    SubscriptionDownloadAttempt.subscription_id == ctx.subscription.id,
                    SubscriptionDownloadAttempt.status == "failed",
                )
            )
        ).scalars()
        if (attempt.submission or {}).get("stage") == "rejected"
    }
    usable = []
    coverage = {}
    for entry in entries:
        candidate, match = entry[:2]


        if (candidate.site_id, candidate.torrent_id) in rejected:
            continue
        covered = drop_proven_missing(
            ctx,
            candidate,
            covered_units(
                match, open_rows, published=publish_calendar_date(candidate.publish_time)
            ),
        )
        units = {(w.season_number, w.episode_number) for w in covered}
        if not units:
            continue
        usable.append(entry)
        coverage[candidate_key(candidate)] = units
    seen = (
        (
            await session.execute(
                select(SmartCandidate).where(SmartCandidate.subscription_id == ctx.subscription.id)
            )
        )
        .scalars()
        .all()
    )
    release_history, first_seen = {}, {}
    for row in seen:
        key = f"{row.site_id}/{row.torrent_id}"
        for fact in row.observations:
            if not fact["eligible"]:
                continue
            at = datetime.fromisoformat(fact["at"])
            first_seen[key] = min(first_seen.get(key, at), at)
        # 重新核对身份。仅独立单集可用于估计发布延迟；合包仍参与当前集时间锚点。
        from movieclaw_api.services.subscription.matching import to_candidate
        from movieclaw_matcher.smart_waiting import publication_anchor

        historical = to_candidate(SiteTorrent.model_validate(row.snapshot))
        match = match_identity(historical, ctx.identity) if historical else None
        published = publication_anchor([historical], now) if historical else None
        if (
            historical
            and match
            and not match.id_conflict
            and not match.is_pack
            and len(match.episodes) == 1
            and eligible(historical, ctx.spec)
            and published
            and key in first_seen
        ):
            season, episode = next(iter(match.episodes))
            release_history.setdefault(season, []).append(
                {
                    "episode": episode,
                    "series": series_key(historical),
                    "quality": list(quality_vector(historical.attrs)),
                    "published_at": published.isoformat(),
                    "observed_at": first_seen[key].isoformat(),
                }
            )
    reliability = {}
    for row in all_rows:
        if row.status == WantedStatus.IMPORTED and row.quality:
            snapshot = QualitySnapshot.model_validate(row.quality)
            key = series_key_attrs(snapshot)
            if (
                key
                and snapshot.resolution_verified
                and snapshot.source_evidence in {"consistent_declaration", "manual", "disc"}
            ):
                reliability.setdefault(row.season_number, {}).setdefault(key, set()).add(
                    row.episode_number
                )
    records = {}
    for record in (
        await session.execute(
            select(SmartDecisionRecord)
            .where(
                SmartDecisionRecord.wanted_id.in_([w.id for w in open_rows.values()]),
                SmartDecisionRecord.mode == mode,
            )
            .order_by(SmartDecisionRecord.id)
        )
    ).scalars():
        records[record.wanted_id] = record
    saved = {}
    for unit, wanted in open_rows.items():
        record = records.get(wanted.id)
        payload = (
            record.outcome.get("state")
            if runtime.shadow_only and record
            else wanted.selection_state
        )
        try:
            saved[unit] = SelectionState.model_validate(payload) if payload else None
        except ValueError:
            continue  # 损坏状态不能重新计时，也不能回落到规则模式。
    # 先比较同品质版本在本季的覆盖，再比较单个资源；镜像不累加覆盖。
    version_units = {}
    for candidate, *_ in usable:
        if eligible(candidate, ctx.spec):
            key = (
                series_key(candidate) or candidate_key(candidate),
                quality_vector(candidate.attrs),
            )
            version_units.setdefault(key, set()).update(coverage[candidate_key(candidate)])
    decisions, inputs, local_follows = {}, {}, dict(follows)
    for unit, wanted in sorted(open_rows.items()):
        if unit not in saved:
            continue
        choices = [e[0] for e in usable if unit in coverage[candidate_key(e[0])]]
        state = saved[unit]
        if state and (
            state.reason == "identity_unconfirmed" or state.candidate_key in identity_rejections
        ):
            # 未通过身份核验的资源不提供发布时间锚点；保留用户显式延长的预算。
            state = state if state.manual_extended else None
        if not choices and state is None and not identity_rejections:
            continue
        observed_at = min((first_seen.get(candidate_key(c), now) for c in choices), default=now)
        following = local_follows.get(unit[0]) if ctx.subscription.kind == "tv" else None
        arguments = dict(
            now=now,
            first_seen=observed_at,
            state=state,
            following=following,
            current=QualitySnapshot.model_validate(wanted.quality)
            if wanted.status == WantedStatus.IMPORTED and wanted.quality
            else None,
            release_history=release_history.get(unit[0], [])
            if runtime.prediction_enabled
            else None,
            episode=unit[1],
            coverage={
                candidate_key(c): [
                    sum(
                        u[0] == unit[0]
                        for u in version_units.get(
                            (series_key(c) or candidate_key(c), quality_vector(c.attrs)), set()
                        )
                    ),
                    sum(u[0] == unit[0] for u in coverage[candidate_key(c)]),
                ]
                for c in choices
            },
            reliability={
                key: len(episodes) for key, episodes in reliability.get(unit[0], {}).items()
            },
        )
        result = decide(ctx.spec, choices, **arguments)
        if not choices and identity_rejections and result.action != "stop":
            result = SelectionDecision(
                action="no_candidate", reason="identity_unconfirmed",
                state=(state or SelectionState(
                    anchor=now, deadline=now, observation_end=now,
                )).model_copy(update={
                    "reason": "identity_unconfirmed",
                    "candidate_key": None, "candidate_title": None, "forced_candidate": None,
                    "choice_explanation": None, "wait_explanation": None, "prediction": None,
                    "identity_explanation": "\n\n".join(
                        dict.fromkeys(identity_rejections.values())
                    ),
                }),
            )
        decisions[unit] = result
        inputs[unit] = (choices, arguments)
        if result.action == "download" and ctx.subscription.kind == "tv" and following is None:
            chosen = next(c for c in choices if candidate_key(c) == result.candidate_key)
            if key := series_key(chosen):
                local_follows[unit[0]] = key
    transaction = await session.begin_nested()
    for unit, result in decisions.items():
        wanted = open_rows[unit]
        record = records.get(wanted.id)
        outcome = result.model_dump(mode="json")
        if record is None or record.outcome != outcome:
            choices, arguments = inputs[unit]
            candidates = TypeAdapter(list[TorrentCandidate]).dump_python(choices, mode="json")
            for candidate in candidates:
                candidate["download_url"] = None
            serialized = {
                k: v.model_dump(mode="json")
                if hasattr(v, "model_dump")
                else v.isoformat()
                if isinstance(v, datetime)
                else v
                for k, v in arguments.items()
            }
            session.add(
                SmartDecisionRecord(
                    wanted_id=wanted.id,
                    mode=mode,
                    inputs={
                        "policy": ctx.spec.model_dump(mode="json"),
                        "candidates": candidates,
                        "parser_versions": {
                            f"{c.site_id}/{c.torrent_id}": c.snapshot.get("enrich_version")
                            for c in seen
                            if f"{c.site_id}/{c.torrent_id}"
                            in {candidate_key(choice) for choice in choices}
                        },
                        **serialized,
                    },
                    outcome=outcome,
                )
            )
        if runtime.shadow_only:
            continue
        payload = result.state.model_dump(mode="json") if result.state else None
        if payload != wanted.selection_state or result.next_at != wanted.next_selection_at:
            changed = await session.execute(
                update(WantedItem)
                .where(
                    WantedItem.id == wanted.id,
                    WantedItem.selection_version == wanted.selection_version,
                    WantedItem.in_scope.is_(True),
                    WantedItem.status == wanted.status,
                    WantedItem.subscription_id.in_(
                        select(Subscription.id).where(Subscription.status != "paused")
                    ),
                )
                .values(
                    selection_state=payload,
                    next_selection_at=result.next_at,
                    selection_version=WantedItem.selection_version + 1,
                )
            )
            if changed.rowcount != 1:
                await transaction.rollback()
                # 只刷新当前订阅；失败决定不能使同批其他上下文失效。
                for row in all_rows:
                    await session.refresh(row)
                await session.refresh(ctx.subscription)
                return [], {}
    await transaction.commit()
    await session.commit()
    if runtime.shadow_only:
        return [], {}
    allowed = {}
    for entry in usable:
        key = candidate_key(entry[0])
        units = coverage[key]
        chosen_units = {
            u
            for u in units
            if u in decisions
            and decisions[u].action == "download"
            and decisions[u].candidate_key == key
        }
        if chosen_units:
            allowed[key] = {open_rows[u].id: open_rows[u].selection_version for u in chosen_units}
    return [e for e in usable if candidate_key(e[0]) in allowed], allowed


async def change_wait(
    session,
    wanted_id: int,
    version: int,
    *,
    extend_seconds: int = 0,
    immediate_candidate: str | None = None,
):
    wanted = await session.get(WantedItem, wanted_id)
    sub = await session.get(Subscription, wanted.subscription_id) if wanted else None
    if not wanted or not sub or sub.selection_mode != "smart" or not wanted.selection_state:
        raise conflict()
    if (
        not wanted.in_scope
        or wanted.status != WantedStatus.WANTED
        or sub.status != SubscriptionStatus.ACTIVE
    ):
        raise conflict()
    state = SelectionState.model_validate(wanted.selection_state)
    if state.reason == "identity_unconfirmed":
        raise conflict()
    old_deadline = state.deadline
    if immediate_candidate:
        if state.candidate_key != immediate_candidate:
            raise conflict()
        from movieclaw_api.services.subscription.matching import (
            covered_units,
            load_match_context,
            publish_calendar_date,
            to_candidate,
        )

        cached = (
            (
                await session.execute(
                    select(SmartCandidate).where(SmartCandidate.subscription_id == sub.id)
                )
            )
            .scalars()
            .all()
        )
        selected = next(
            (c for c in cached if f"{c.site_id}/{c.torrent_id}" == immediate_candidate), None
        )
        if selected is None:
            raise conflict()
        live = (
            await session.execute(
                select(SiteTorrent).where(
                    SiteTorrent.site_id == selected.site_id,
                    SiteTorrent.torrent_id == selected.torrent_id,
                )
            )
        ).scalar_one_or_none()
        candidate = to_candidate(live or SiteTorrent.model_validate(selected.snapshot))
        contexts = await load_match_context(session, subscription_ids={sub.id})
        ctx = contexts.get(sub.media_item_id)
        match = match_identity(candidate, ctx.identity) if candidate and ctx else None
        if (
            not match
            or match.id_conflict
            or not eligible(candidate, ctx.spec)
            or not covered_units(
                match,
                {(wanted.season_number, wanted.episode_number): wanted},
                published=publish_calendar_date(candidate.publish_time),
            )
        ):
            raise conflict()
        state.reason = "manual_requested"
        state.forced_candidate = immediate_candidate
        next_at = utcnow()
    else:
        state.deadline += timedelta(seconds=extend_seconds)
        state.observation_end = state.deadline
        state.reason = "user_extended"
        state.manual_extended = True
        next_at = state.deadline
    result = await session.execute(
        update(WantedItem)
        .where(
            WantedItem.id == wanted_id,
            WantedItem.selection_version == version,
            WantedItem.subscription_id.in_(
                select(Subscription.id).where(Subscription.status == SubscriptionStatus.ACTIVE)
            ),
            WantedItem.status == WantedStatus.WANTED,
            WantedItem.in_scope.is_(True),
        )
        .values(
            selection_state=state.model_dump(mode="json"),
            selection_version=version + 1,
            next_selection_at=next_at,
        )
    )
    if result.rowcount != 1:
        await session.rollback()
        raise conflict()
    from movieclaw_db.models import ActivityType, SubscriptionActivity

    session.add(
        SubscriptionActivity(
            subscription_id=sub.id,
            wanted_item_id=wanted_id,
            type=ActivityType.ADJUSTED,
            message="已请求立即下载当前候选" if immediate_candidate else "用户延长了等待时间",
            payload={
                "old_deadline": old_deadline.isoformat(),
                "deadline": state.deadline.isoformat(),
                "selection_version": version + 1,
            },
        )
    )
    await session.commit()
    return {"selection_state": state.model_dump(mode="json"), "selection_version": version + 1}

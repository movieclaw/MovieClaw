# ruff: noqa: F811
"""洗版核验通过真实文件台账与回收站，不用标题代替实测品质。"""

import pytest
from sqlmodel import select
from tests.api.test_upgrade_verify import _add_upgrade_delivery, _seed, db  # noqa: F401

from movieclaw_api.services.subscription.wanted_fulfillment import close_fulfilled_wanted
from movieclaw_db.models import Subscription, SubscriptionDownloadAttempt, WantedItem
from movieclaw_matcher.smart import SmartPolicy


@pytest.mark.parametrize(
    "resolution,source,upgraded,reached",
    [
        ("1080p", "WEB-DL", False, False),
        ("2160p", "WEB-DL", True, False),
        ("2160p", "Blu-ray", True, True),
        ("2160p", None, False, False),
    ],
)
async def test_real_import_verification_protects_old_and_stops_only_at_both_targets(
    db, tmp_path, resolution, source, upgraded, reached
):
    library, item_id, sub_id, wanted_id, root, old_file = await _seed(db, tmp_path)
    async with db.session() as session:
        sub = await session.get(Subscription, sub_id)
        sub.selection_mode = "smart"
        sub.rule_set_id = None
        sub.smart_policy = SmartPolicy(kind="tv", profile_revision=1, source="blu-ray").model_dump(
            mode="json"
        )
        await session.commit()
    await _add_upgrade_delivery(
        db,
        sub_id,
        item_id,
        library.id,
        root,
        claimed_quality={"resolution": "2160p", "media_source": source or "Blu-ray"},
        probed={"resolution": resolution, "media_source": source, "bit_rate": 6_000_000},
    )
    async with db.session() as session:
        await close_fulfilled_wanted(session, item_id)
        row = await session.get(WantedItem, wanted_id)
        assert (row.info_hash == "new1") == upgraded
        assert bool((row.selection_state or {}).get("target_reached")) == reached
        if not upgraded:
            assert old_file.exists() and old_file.read_bytes() == b"old"
        attempts = (
            (
                await session.execute(
                    select(SubscriptionDownloadAttempt).where(
                        SubscriptionDownloadAttempt.info_hash == "new1"
                    )
                )
            )
            .scalars()
            .all()
        )
        assert len(attempts) == 1
        if reached:
            assert attempts[0].status == "imported"
            await close_fulfilled_wanted(session, item_id)
            assert row.selection_state["target_reached"]

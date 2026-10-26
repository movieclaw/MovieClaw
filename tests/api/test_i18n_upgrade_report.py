"""Upgrade reports change presentation by reader, while classification stays identical."""

import re

from sqlmodel import select

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.quality_labels import quality_reference, upgrade_target_reference
from movieclaw_api.i18n.stored import render_value, stored_message
from movieclaw_api.services.subscription.upgrade import run_upgrade_round
from movieclaw_db.models import (
    SubscriptionActivity,
    SubscriptionDownloadAttempt,
    WantedStatus,
    utcnow,
)
from movieclaw_matcher import QualitySnapshot, RuleSetSpec, quality_label, upgrade_target_label
from movieclaw_matcher.smart import SmartPolicy

from . import test_upgrade_run as upgrades

db = upgrades.db
kicked = upgrades.kicked


def test_quality_references_preserve_all_chinese_label_shapes_and_snapshot_data():
    spec = RuleSetSpec(
        upgrade_source="blu-ray",
        resolutions=["2160p", "1080p"],
        cutoff_resolution="1080p",
        hdr_levels=["DV"],
        video_codecs=["x265"],
        platforms=["netflix"],
        upgrade_ladder=["resolution", "source", "hdr", "video_codec", "platform"],
    )
    snapshots = [
        QualitySnapshot(),
        QualitySnapshot(resolution="1080p", media_source="Disc"),
        QualitySnapshot(resolution="1080p", media_source="user-lowest"),
        QualitySnapshot(resolution="1080p", media_source="Blu-ray", remux=True),
        QualitySnapshot(
            resolution="2160p",
            media_source="WEB-DL",
            hdr=["DV"],
            video_codec="x265",
            platforms=["netflix"],
        ),
    ]
    for snapshot in snapshots:
        original = snapshot.model_dump()
        message = quality_reference(snapshot, spec)
        with use_locale("zh-Hans"):
            assert render_value(message) == quality_label(snapshot, spec)
        with use_locale("en"):
            assert not re.search(r"[\u3400-\u9fff]", render_value(message))
        assert snapshot.model_dump() == original
    for target in (
        spec,
        RuleSetSpec(),
        SmartPolicy(kind="movie", profile_revision=1, source="blu-ray"),
    ):
        with use_locale("zh-Hans"):
            assert render_value(upgrade_target_reference(target)) == upgrade_target_label(target)


async def test_report_five_states_and_activity_follow_the_reader(db, kicked):
    library_id, item_id, sub_id, _ = await upgrades._seed(
        db,
        spec={"upgrade_source": "blu-ray"},
        episodes=tuple((1, number) for number in range(1, 6)),
    )
    async with db.session() as session:
        for number in (1, 2, 3, 5):
            session.add(upgrades._file(library_id, item_id, 1, number))
        await session.commit()
        await upgrades._add_wanted(session, sub_id, item_id, 1, 1, quality=upgrades._WEBDL)
        await upgrades._add_wanted(
            session,
            sub_id,
            item_id,
            1,
            2,
            quality={"resolution": "1080p", "media_source": "Blu-ray"},
        )
        await upgrades._add_wanted(session, sub_id, item_id, 1, 3, quality={})
        await upgrades._add_wanted(session, sub_id, item_id, 1, 4, status=WantedStatus.WANTED)
        await upgrades._add_wanted(session, sub_id, item_id, 1, 5, quality=upgrades._WEBDL)
        session.add(
            SubscriptionDownloadAttempt(
                subscription_id=sub_id,
                info_hash="a" * 40,
                purpose="upgrade",
                units=[[1, 5]],
                last_progress_at=utcnow(),
            )
        )
        await session.commit()
        with use_locale("en"):
            english = await run_upgrade_round(session, sub_id)
            assert english["target_label"] == "1080p Blu-ray"
            assert not re.search(r"[\u3400-\u9fff]", english["summary"])
            assert english["counts"] == {
                "upgradable": 1,
                "at_cutoff": 1,
                "in_flight": 1,
                "not_comparable": 1,
                "missing": 1,
            }
            events = list(
                (
                    await session.execute(
                        select(SubscriptionActivity).where(
                            SubscriptionActivity.subscription_id == sub_id
                        )
                    )
                ).scalars()
            )
            event = next(item for item in events if item.payload.get("reason") == "upgrade_run")
            rendered = stored_message(event.message, event.message_key, event.message_params)
            assert "1080p Blu-ray" in rendered
            assert not re.search(r"[\u3400-\u9fff]", rendered)
            assert "1080p 蓝光" in event.message
        with use_locale("zh-Hans"):
            chinese = await run_upgrade_round(session, sub_id)
            assert chinese["target_label"] == "1080p 蓝光"
            assert (
                chinese["summary"]
                == "1 个单元可洗版，已排入立即搜索；1 个已在洗版中；1 个已达目标；"
                "1 个无法确认当前版本档位；1 个缺失将照常下载"
            )
        assert chinese["counts"] == english["counts"]
        assert [
            (item["season_number"], item["episode_number"], item["state"])
            for item in english["units"]
        ] == [
            (item["season_number"], item["episode_number"], item["state"])
            for item in chinese["units"]
        ]

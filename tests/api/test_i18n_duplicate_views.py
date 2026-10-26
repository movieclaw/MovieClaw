"""Duplicate readers translate presentation after grouping, without changing stored identities."""

from copy import deepcopy
from pathlib import Path

import pytest
from sqlalchemy import text

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import localize_fields, reference
from movieclaw_api.services.acquisition_origin import manual_download_origin, subscription_origin
from movieclaw_api.services.library.duplicates import _reason_text
from movieclaw_api.services.library.origin import scan_origin, watch_import_origin
from movieclaw_db.models import LibraryFile
from movieclaw_db.models.import_watch import ImportWatch
from movieclaw_db.models.manual_download_intent import ManualDownloadIntent

from . import test_library_duplicates as dup
from .test_library_origin import _attempt

client = dup.client
db = dup.db


async def _stored(database):
    async with database.session() as session:
        return [
            (await session.execute(text(query))).all()
            for query in (
                "SELECT id,file_path,origin,kept_at,state,trash_context "
                "FROM library_file ORDER BY id",
                "SELECT * FROM library_duplicate_unit ORDER BY id",
            )
        ]


def _files(view):
    return {
        f["id"]: f
        for it in view["items"]
        for s in it["seasons"]
        for u in s["units"]
        for f in u["files"]
    }


@pytest.mark.asyncio
async def test_views_preserve_raw_signatures_storage_and_actual_file_choice(client, db, tmp_path):
    ids = await dup._seed(db, tmp_path)
    async with db.session() as session:
        for file_id in (ids["jm_a"], ids["jm_b"]):
            row = await session.get(LibraryFile, file_id)
            row.origin = subscription_origin(
                _attempt(purpose="upgrade", manual=True),
                item_title="作者片名",
                downloader_name="Author downloader",
                strategy="hardlink",
            )
        row = await session.get(LibraryFile, ids["jm_c"])
        row.origin = {"kind": "author", "label": "作者原文", "detail": "Do not translate me"}
        original = Path(row.file_path)
        original_bytes = original.read_bytes()
        await session.commit()
    await dup._scan(db)
    before = await _stored(db)
    views = [
        (
            await client.get(
                "/api/v1/libraries/duplicate-files", headers={"Accept-Language": locale}
            )
        ).json()["data"]
        for locale in ("en", "zh-Hans", "en")
    ]
    assert views[0] == views[2]
    assert await _stored(db) == before
    en, zh = _files(views[0]), _files(views[1])
    assert views[0]["tiers"][0]["label"] == "Safe to clean"
    assert views[1]["tiers"][0]["label"] == "可以放心清理"
    for fid in en:
        for key in ("version_key", "quality_key", "origin_key", "suggested", "kept_at"):
            assert en[fid][key] == zh[fid][key]
    assert en[ids["jm_a"]]["origin"]["label"] == (
        "Subscription “作者片名”: upgrade delivery (manually selected)"
    )
    assert en[ids["jm_a"]]["origin"]["detail"].endswith("Imported using a hard link")
    assert en[ids["jm_c"]]["origin"] == zh[ids["jm_c"]]["origin"]
    assert any(f["suggest_reason"] and "tier" in f["suggest_reason"] for f in en.values())
    for language, duplicate_files in (("en", en), ("zh-Hans", zh)):
        detail = await client.get(
            f"/api/v1/libraries/{ids['movie_lib']}/items/{ids['jm']}",
            headers={"Accept-Language": language},
        )
        assert detail.status_code == 200, detail.text
        for file in detail.json()["data"]["files"]:
            assert file["origin"] == duplicate_files[file["id"]]["origin"]
    assert await _stored(db) == before
    # An English reader sends the original file ID back to the real cleanup path.
    result = await client.post(
        "/api/v1/libraries/duplicate-files/resolve",
        headers={"Accept-Language": "en"},
        json={
            "media_item_id": ids["jm"],
            "season_number": 0,
            "episode_number": 0,
            "keep_file_id": ids["jm_a"],
        },
    )
    assert result.status_code == 200, result.text
    assert result.json()["data"]["done"] == 2
    assert not original.exists()
    stale = await client.post(
        "/api/v1/libraries/duplicate-files/resolve",
        headers={"Accept-Language": "en"},
        json={
            "media_item_id": ids["jm"],
            "season_number": 0,
            "episode_number": 0,
            "keep_file_id": ids["jm_a"],
        },
    )
    assert stale.status_code == 404
    assert "This unit no longer has duplicate files" in stale.json()["message"]
    async with db.session() as session:
        gone = await session.get(LibraryFile, ids["jm_c"])
        assert Path(gone.file_path).read_bytes() == original_bytes
        assert gone.trash_context["note"].startswith("重复清理：")
        assert gone.trash_context["note_ref"]["message_key"].startswith("library.recycle.")


def test_new_origin_projection_preserves_chinese_and_unknown_values():
    snapshots = [
        scan_origin(trigger) for trigger in ("manual", "watch", "scheduled", "Author trigger")
    ] + [
        watch_import_origin(ImportWatch(source_path=" /Author folder ", strategy="copy")),
        manual_download_origin(
            ManualDownloadIntent(
                info_hash="a" * 40,
                media_item_id=1,
                library_id=1,
                site_id=" author-site ",
                download_name=" Author torrent ",
            ),
            torrent_title=None,
            downloader_name=" Author downloader ",
            strategy="hardlink",
        ),
        manual_download_origin(
            ManualDownloadIntent(info_hash="b" * 40, media_item_id=1, library_id=1),
            torrent_title=None,
            downloader_name=None,
            strategy=None,
        ),
    ]
    before = deepcopy(snapshots)
    for snapshot in snapshots:
        with use_locale("zh-Hans"):
            projected = localize_fields(snapshot)
        assert {k: projected[k] for k in ("kind", "label", "detail")} == {
            k: snapshot[k] for k in ("kind", "label", "detail")
        }
        with use_locale("en"):
            projected = localize_fields(snapshot)
        assert projected["label"] != snapshot["label"]
    assert snapshots == before
    with use_locale("en"):
        assert localize_fields(snapshots[3])["detail"] == "Found by Author trigger"
        assert localize_fields(snapshots[-1])["detail"] is None
        custom = {"kind": "scan", "label": "存量扫描发现（非本系统入库）", "detail": "作者原文"}
        assert localize_fields(custom) == custom


def test_all_owned_suggestion_reasons_and_failed_actions_preserve_source():
    from movieclaw_api.api.routes.library_duplicates import _result
    from movieclaw_api.i18n.stored import stored_message
    from movieclaw_api.services.library.duplicates import ResolveOutcome

    for basis in ("ladder", "bitrate", "origin", "naming", "fallback"):
        for partial in (False, True):
            source = _reason_text(basis, partial)
            with use_locale("zh-Hans"):
                assert stored_message(source) == source
            with use_locale("en"):
                assert stored_message(source) != source
                assert stored_message("Author diagnostic") == "Author diagnostic"
    outcome = ResolveOutcome(failed=[(1, "作者文件.mkv", "移入回收站失败：Author reason")])
    outcome.failure_refs[1] = reference("library.duplicates.recycleFailed", detail="Author reason")
    source = deepcopy(outcome)
    with use_locale("en"):
        assert (
            _result(outcome).failed[0].error == "Could not move to the recycle bin: Author reason"
        )
    with use_locale("zh-Hans"):
        assert _result(outcome).failed[0].error == outcome.failed[0][2]
    assert outcome == source

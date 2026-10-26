"""Recycle snapshots render per reader while file operations and group identities stay stable."""

import copy
from pathlib import Path
from types import SimpleNamespace

import pytest
from sqlalchemy import text

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import reference, render_value
from movieclaw_api.services.library.duplicates import DupFile, _note, _note_reference
from movieclaw_api.services.library.recycle import recycle_file
from movieclaw_db.models import LibraryFile

from . import test_library_recycle_bin as recycle_fixture

client = recycle_fixture.client
db = recycle_fixture.db
_seed = recycle_fixture._seed


async def _raw_contexts(database):
    async with database.session() as session:
        return (
            await session.execute(
                text("SELECT id,file_path,trash_context FROM library_file ORDER BY id")
            )
        ).all()


@pytest.mark.asyncio
async def test_real_recycle_and_failed_restore_keep_neutral_snapshots(client, db, tmp_path):  # noqa: F811
    ids = await _seed(db, tmp_path)
    restored = await client.post(
        "/api/v1/libraries/trashed-files/restore", json={"ids": [ids["old_movie"]]}
    )
    assert restored.json()["data"]["done"] == 1
    note = "洗版替换：1080p WEB-DL → 2160p Remux"
    note_ref = reference("library.recycle.noteUpgraded", old="1080p WEB-DL", new="2160p Remux")
    async with db.session() as session:
        row = await session.get(LibraryFile, ids["old_movie"])
        original = Path(row.file_path)
        original_bytes = original.read_bytes()
        outcome = await recycle_file(
            session,
            row,
            reason="upgrade_replaced",
            note=note,
            note_ref=note_ref,
            trigger={
                "kind": "subscription",
                "id": 1,
                "label": "《九门》订阅洗版",
                "label_ref": reference("library.recycle.triggerTitle", title="九门"),
            },
        )
        assert outcome == "moved_to_trash"
        note_ref["params"]["old"] = "Caller mutation"
        await session.commit()
        assert row.trash_context["note_ref"]["params"]["old"] == "1080p WEB-DL"
        assert row.trash_context["note"] == note
        current = Path(row.file_path)
        assert not original.exists() and current.read_bytes() == original_bytes
    before = await _raw_contexts(db)
    views = [
        (
            await client.get("/api/v1/libraries/trashed-files", headers={"Accept-Language": locale})
        ).json()["data"]
        for locale in ("en", "zh-Hans", "en")
    ]
    assert views[0] == views[2]

    def movie(view):
        return next(item for item in view["items"] if item["media_item"]["id"] == ids["movie"])

    assert movie(views[0])["note"] == "Replaced by an upgrade: 1080p WEB-DL → 2160p Remux"
    assert movie(views[1])["note"] == note
    assert movie(views[0])["trigger_label"] == "Subscription upgrade for “九门”"
    assert movie(views[1])["trigger_label"] == "《九门》订阅洗版"
    assert (
        movie(views[0])["media_item"]["title"] == movie(views[1])["media_item"]["title"] == "九门"
    )
    assert await _raw_contexts(db) == before
    assert current.read_bytes() == original_bytes

    original.write_bytes(b"Keep the conflicting file unchanged")
    failure = await client.post(
        "/api/v1/libraries/trashed-files/restore",
        json={"ids": [ids["old_movie"]]},
        headers={"Accept-Language": "en"},
    )
    assert failure.json()["data"]["done"] == 0
    message = failure.json()["data"]["failed"][0]["error"]
    assert message.startswith("Could not restore:")
    assert original.read_bytes() == b"Keep the conflicting file unchanged"
    before = await _raw_contexts(db)
    for locale, prefix in [
        ("en", "Could not restore:"),
        ("zh-Hans", "恢复失败："),
        ("en", "Could not restore:"),
    ]:
        view = (
            await client.get("/api/v1/libraries/trashed-files", headers={"Accept-Language": locale})
        ).json()["data"]
        assert movie(view)["files"][0]["last_error"].startswith(prefix)
    assert await _raw_contexts(db) == before
    async with db.session() as session:
        row = await session.get(LibraryFile, ids["old_movie"])
        assert row.trash_context["last_error"].startswith("恢复失败：")
        assert row.trash_context["last_error_ref"] == reference("library.recycle.restoreFailed")
    original.unlink()
    response = await client.post(
        "/api/v1/libraries/trashed-files/restore", json={"ids": [ids["old_movie"]]}
    )
    assert response.json()["data"]["done"] == 1
    assert original.read_bytes() == original_bytes and not current.exists()
    async with db.session() as session:
        assert (await session.get(LibraryFile, ids["old_movie"])).trash_context is None


@pytest.mark.asyncio
async def test_translated_notes_and_tiers_do_not_merge_raw_group_keys(
    client, db, tmp_path, monkeypatch
):  # noqa: F811
    import movieclaw_api.i18n as i18n

    ids = await _seed(db, tmp_path)
    async with db.session() as session:
        row = await session.get(LibraryFile, ids["new_movie"])
        await recycle_file(
            session,
            row,
            reason="manual",
            trigger={"kind": "member", "label": "作者原名"},
            note="第一原文",
            note_ref={"message_text": "第一原文", "message_localized": {"en": "Same note"}},
        )
        row = await session.get(LibraryFile, ids["old_movie"])
        row.resolution = row.media_source = None
        row.trash_context = {
            **row.trash_context,
            "note": "第二原文",
            "note_ref": {"message_text": "第二原文", "message_localized": {"en": "Same note"}},
        }
        await session.commit()
    original = i18n.messages
    english = {**original("en"), "library.recycle.unknownSpec": "2160p Remux"}
    monkeypatch.setattr(
        i18n, "messages", lambda locale: english if locale == "en" else original(locale)
    )
    before = await _raw_contexts(db)
    views = [
        (
            await client.get("/api/v1/libraries/trashed-files", headers={"Accept-Language": locale})
        ).json()["data"]
        for locale in ("en", "zh-Hans", "en")
    ]
    assert views[0] == views[2]
    for view in views:
        movie = next(item for item in view["items"] if item["media_item"]["id"] == ids["movie"])
        assert movie["note"] is None
        assert movie["quality"]["tiers"] == {"2160p Remux": 1, "未知规格": 1}
    movie = next(item for item in views[0]["items"] if item["media_item"]["id"] == ids["movie"])
    assert set(movie["quality"]["tier_labels"].values()) == {"2160p Remux"}
    assert [file["note"] for file in movie["files"]] == ["Same note", "Same note"]
    assert await _raw_contexts(db) == before


def test_duplicate_note_references_preserve_chinese_quality_and_unknown_author_names():
    for resolution, source, hdr in [
        (None, None, None),
        ("1080p", None, "DV"),
        (None, "WEB-DL", None),
        ("2160p", "Remux", "HDR10"),
    ]:
        row = SimpleNamespace(
            file_path="/fixture/作者名称.mkv", resolution=resolution, media_source=source, hdr=hdr
        )
        label = " ".join(part for part in (resolution, source) if part) or "未知规格"
        label += f" {hdr}" if hdr else ""
        keep = DupFile(row, label, {}, "fixture")
        gone = copy.deepcopy(keep)
        for bucket in ("identical", "versions"):
            ref = _note_reference(keep, gone, bucket)
            with use_locale("zh-Hans"):
                assert render_value(ref) == _note(keep, gone, bucket)
            with use_locale("en"):
                assert "作者名称.mkv" in render_value(ref)
                assert "未知规格" not in render_value(ref)


def test_unknown_snapshot_references_keep_the_original_author_text():
    from movieclaw_api.api.routes.library_recycle import _snapshot_text

    context = {
        "note": "作者原文",
        "note_ref": {"message_key": "future.author.reason", "params": {}},
    }
    before = copy.deepcopy(context)
    for locale in ("en", "zh-Hans", "en"):
        with use_locale(locale):
            assert _snapshot_text(context, "note") == "作者原文"
            assert _snapshot_text(context, "last_error") is None
    assert context == before

"""Watch-import conclusions keep their Chinese source text and render in the reader's language."""

from __future__ import annotations

import pytest

import movieclaw_api.services.library.ingest as ingest_mod
from movieclaw_api.api.routes.import_watch import IngestEntryView
from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.stored import localize_fields
from movieclaw_db.models import IngestEntry, IngestStatus
from movieclaw_media.models import MediaKind

from .test_library_ingest_review import (
    _FAKE_SPEC,
    _make_item,
    _make_library,
    _make_rule,
    _records,
    _stub_media_library,
    _sweep,
)
from .test_library_ingest_review import db as _review_db

db = _review_db  # 复用台账测试的迁移库夹具


def _view(row: IngestEntry, locale: str) -> str | None:
    with use_locale(locale):
        return IngestEntryView.from_model(row).message


@pytest.mark.asyncio
async def test_pending_then_claimed_conclusions_follow_the_reader(db, tmp_path, monkeypatch):
    root, watch = tmp_path / "movies", tmp_path / "watch"
    watch.mkdir()
    library_id = await _make_library(db, root=root)
    rule_id = await _make_rule(db, library_id=library_id, source=watch)
    await _make_item(db, title="认领电影", year=2021)
    monkeypatch.setattr(ingest_mod, "probe_media", lambda p: _FAKE_SPEC)
    _stub_media_library(monkeypatch)

    async def identify_none(session, kind, watch_root, main, spec):
        return None

    monkeypatch.setattr(ingest_mod, "_identify", identify_none)
    entry = watch / "obscure-release-x264"
    entry.mkdir()
    (entry / "video.mkv").write_bytes(b"x")
    await _sweep(db, rule_id, times=2)
    [row] = await _records(db)

    assert row.status == IngestStatus.PENDING
    # 中文原文照旧落库：旧版本回滚与历史标记匹配都靠它
    assert row.message.startswith("无法自动识别「obscure-release-x264」对应的影视条目")
    assert _view(row, "zh-Hans") == row.message
    assert _view(row, "en").startswith("Couldn’t identify “obscure-release-x264” automatically.")

    async with db.session() as session:
        row = await ingest_mod.claim_entry(session, row.id, 300, execute_inline=True)
    assert row.status == IngestStatus.IMPORTED
    assert row.message.startswith("已识别为《认领电影》，硬链接 1 个文件到 ")
    assert _view(row, "en").startswith("Identified as “认领电影”. Hardlinked 1 file to ")


@pytest.mark.asyncio
async def test_partial_season_pack_keeps_parser_gap_marker(db, tmp_path, monkeypatch):
    root, watch = tmp_path / "shows", tmp_path / "watch"
    watch.mkdir()
    library_id = await _make_library(db, kind=MediaKind.TV, root=root)
    rule_id = await _make_rule(db, library_id=library_id, source=watch)
    item = await _make_item(db, kind=MediaKind.TV, title="某剧", year=2022)
    monkeypatch.setattr(ingest_mod, "probe_media", lambda p: _FAKE_SPEC)

    async def identify(session, kind, watch_root, main, spec):
        return item

    monkeypatch.setattr(ingest_mod, "_identify", identify)
    entry = watch / "Some.Show.S01.1080p"
    entry.mkdir()
    (entry / "Some.Show.S01E01.1080p.mkv").write_bytes(b"x" * 10)
    (entry / "Some.Show.S01E00.1080p.mkv").write_bytes(b"y")
    await _sweep(db, rule_id, times=2)
    [row] = await _records(db)

    assert row.status == IngestStatus.IMPORTED
    assert "「Some.Show.S01E00.1080p.mkv」是第 0 集（先导/特辑），暂不自动入库" in row.message
    english = _view(row, "en")
    assert english.startswith("Identified as “某剧”. Hardlinked 1 file to ")
    assert english.endswith(
        "; Episode 0 (pilot or special) won’t be imported automatically: "
        "“Some.Show.S01E00.1080p.mkv”"
    )


def test_legacy_conclusions_without_reference_stay_readable():
    row = IngestEntry(
        id=1,
        entry_path="/watch/x",
        fingerprint="f",
        status=IngestStatus.SKIPPED,
        message="条目中没有视频文件，已跳过",
    )
    # 旧记录只有中文：能反查目录的整句按读者语言给，查不到的原样给
    assert _view(row, "en") == "No video files in the item. Skipped."
    row.message = "旧版本的自由文本"
    assert _view(row, "en") == "旧版本的自由文本"


def test_job_texts_from_conclusions_render_per_reader():
    ref = ingest_mod._summary(
        [
            ingest_mod.reference("library.ingest.noEpisode", name="a.mkv"),
            ingest_mod.reference("library.ingest.dupSkipped", count=2),
        ]
    )
    row = IngestEntry(entry_path="/w/x", fingerprint="f", status=IngestStatus.PENDING)
    ingest_mod._set_conclusion(row, ref)
    assert row.message == "「a.mkv」解析不出集号，未入库；2 个文件在库中已有同档或更高版本，跳过"
    assert ingest_mod._has_parser_gap(row)
    progress = ingest_mod._entry_text(row, "library.ingest.blocked.review")
    with use_locale("en"):
        assert localize_fields(progress)["message"] == (
            "Couldn’t parse an episode number from “a.mkv”; not imported; "
            "Skipped 2 files with the same or a better version already in the library"
        )

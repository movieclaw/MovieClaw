"""字幕描述从台账到决策、API 的透传；标题不参与轨引用与默认策略。"""

from dataclasses import asdict

import pytest

from movieclaw_api.schemas.playback import SubtitlePlanView
from movieclaw_db.models import FileSource, LibraryFile
from movieclaw_playback.decide import plan_subtitles
from movieclaw_playback.profile import media_profile_from_file


@pytest.mark.parametrize(
    "title",
    [
        None,
        "",
        " \t\n\u3000",
        "国配简体特效",
        "简英 · 修订版",
        "🎬عربي日本語" * 200,
        '<img src=x onerror="alert(1)">',
    ],
)
def test_subtitle_metadata_survives_the_playback_boundary(title):
    file = LibraryFile(
        id=1,
        library_id=1,
        file_path="/m/film.mkv",
        size_bytes=1,
        source=FileSource.SCANNED,
        subtitle_streams=[
            {"codec": "hdmv_pgs_subtitle", "language": "chi", "title": title, "forced": True},
            {"codec": "ass", "language": "chi", "title": title, "default": True},
            {"codec": "dvd_subtitle", "language": "chi", "title": title},
        ],
        external_subtitles=[
            {
                "filename": "film.ai-chs.srt",
                "format": "srt",
                "language": "chs",
                "title": "ai-chs",
                "forced": True,
            }
        ],
    )
    plans = plan_subtitles(media_profile_from_file(file))
    views = [SubtitlePlanView(**asdict(plan)).model_dump() for plan in plans]
    assert [view["track_ref"] for view in views] == [
        "embedded:0",
        "embedded:1",
        "external:film.ai-chs.srt",
    ]
    assert [view["title"] for view in views] == [title, title, "ai-chs"]
    assert [view["is_forced"] for view in views] == [True, False, True]
    assert [view["is_ai"] for view in views] == [False, False, True]
    assert sum(view["is_default"] for view in views) == 1


def test_old_subtitle_inventory_without_metadata_still_plans():
    file = LibraryFile(
        library_id=1,
        file_path="/m/film.mkv",
        size_bytes=1,
        source=FileSource.SCANNED,
        subtitle_streams=[{"codec": "subrip"}],
        external_subtitles=[],
    )
    (plan,) = plan_subtitles(media_profile_from_file(file))
    assert plan.track_ref == "embedded:0"
    assert plan.title is None
    assert plan.is_forced is False

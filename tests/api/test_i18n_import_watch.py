"""Import rule destinations render at the DTO boundary, preserving machine values."""

from copy import deepcopy

import pytest

from movieclaw_api.api.routes.import_watch import ImportWatchView
from movieclaw_api.i18n import use_locale
from movieclaw_db.models import ImportWatch


@pytest.mark.parametrize(
    "kind,english,chinese",
    [("movie", "Movie", "电影"), ("tv", "Series", "剧集"), ("video", "Other", "其他")],
)
@pytest.mark.parametrize("custom", [True, False])
def test_rule_destination_uses_reader_locale_without_mutating_the_rule(
    kind, english, chinese, custom
):
    row = ImportWatch(
        id=7,
        source_path="/original/source",
        strategy="hardlink",
        kind=kind,
        target_path="/original/target" if custom else None,
    )
    before = deepcopy(row.model_dump())
    for locale, label in [("en", english), ("zh-Hans", chinese), ("en", english)]:
        with use_locale(locale):
            view = ImportWatchView.from_model(row, library_name=None)
        expected = (
            (
                f"Custom folder ({label} · /original/target)"
                if custom
                else f"Automatic routing ({label})"
            )
            if locale == "en"
            else (f"自定义目录（{label} · /original/target）" if custom else f"自动路由（{label}）")
        )
        assert view.target_label == expected
        assert view.kind == kind and view.strategy == "hardlink" and view.id == 7
        assert row.model_dump() == before


def test_library_destination_keeps_the_original_user_name():
    row = ImportWatch(id=8, source_path="/original/source", strategy="copy", library_id=12)
    for locale in ["en", "zh-Hans", "en"]:
        with use_locale(locale):
            assert (
                ImportWatchView.from_model(row, library_name="原始自定义库名").target_label
                == "原始自定义库名"
            )

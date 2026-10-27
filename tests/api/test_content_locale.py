"""看到的跟界面语言，写下来的跟媒体库语言（docs/design/content-locale.md）。"""

from __future__ import annotations

from types import SimpleNamespace
from typing import Any

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.content import (
    display_genres,
    display_overview,
    display_title,
    in_reader_language,
    reader_language,
)
from movieclaw_db.models import MediaItem
from movieclaw_db.models.media_item import MediaSource
from movieclaw_media import (
    MediaCard,
    MediaDetail,
    MediaFacts,
    MediaKind,
    MediaVideo,
)

# -- 读者语言与显示选择 -------------------------------------------------------


def test_reader_language_follows_interface_locale() -> None:
    with use_locale("zh-Hans"):
        assert reader_language() == "zh-CN"
    with use_locale("en"):
        assert reader_language() == "en-US"


def test_display_title_and_overview_pick_reader_translation_or_fall_back() -> None:
    item = SimpleNamespace(title="人生切割术", title_translations={"en-US": "Severance"})
    legacy = SimpleNamespace(title="人生切割术", title_translations=None)  # 存量未刮过
    with use_locale("en"):
        assert display_title(item) == "Severance"
        assert display_title(legacy) == "人生切割术"
        assert display_overview({"en-US": "Mark leads..."}, "马克……") == "Mark leads..."
        assert display_overview({}, "马克……") == "马克……"
    with use_locale("zh-Hans"):
        # 主语言那份从不存进字典：中文读者看中文库永远走原列
        assert display_title(item) == "人生切割术"
        assert display_overview({"en-US": "Mark leads..."}, "马克……") == "马克……"


def test_logo_is_dropped_only_when_the_title_is_shown_in_the_reader_language() -> None:
    translated = SimpleNamespace(title="阿甘正传", title_translations={"en-US": "Forrest Gump"})
    legacy = SimpleNamespace(title="醉梦", title_translations=None)  # 还没刷新出译名
    with use_locale("en"):
        assert in_reader_language(translated)
        assert not in_reader_language(legacy)  # 文字片名也是中文，Logo 照旧
    with use_locale("zh-Hans"):
        assert not in_reader_language(translated)  # 主语言那份从不存，中文读者照旧


def test_display_genres_translate_only_across_language_families() -> None:
    names, ids = ["科幻", "Sci-Fi & Fantasy"], [878, 10765]
    with use_locale("zh-Hans"):
        # 同语种：库内名字逐字原样（哪怕 TMDB 中文类型表里混着英文）
        assert display_genres("tv", names, ids, "zh-CN") == names
    with use_locale("en"):
        assert display_genres("tv", names, [10765], "zh-CN") == ["Sci-Fi & Fantasy"]
        assert display_genres("movie", ["科幻"], [878], "zh-CN") == ["Science Fiction"]
        # NFO 吸收、没有 ID 的原样显示
        assert display_genres("movie", ["自定义"], [], "zh-CN") == ["自定义"]
        assert display_genres("movie", ["科幻"], [878], "") == ["科幻"]


# -- 召回词：中文库逐字不变，英文库补上中文名 ----------------------------------


def _item(**kw: Any) -> MediaItem:
    return MediaItem(kind="movie", source=MediaSource.TMDB, aliases=[], **kw)


def test_recall_keywords_unchanged_for_chinese_library() -> None:
    from movieclaw_api.services.subscription.wanted_search import recall_keywords

    item = _item(
        title="恶人传",
        original_title="악인전",
        english_title="The Gangster, the Cop, the Devil",
        title_translations={"en-US": "The Gangster, the Cop, the Devil"},
    )
    assert recall_keywords(item) == ["The Gangster, the Cop, the Devil", "恶人传", "악인전"]


def test_recall_keywords_include_chinese_name_for_english_library() -> None:
    from movieclaw_api.services.subscription.wanted_search import recall_keywords

    item = _item(
        title="The Gangster, the Cop, the Devil",
        original_title="악인전",
        english_title="The Gangster, the Cop, the Devil",
        title_translations={"zh-CN": "恶人传"},
    )
    assert recall_keywords(item) == ["The Gangster, the Cop, the Devil", "恶人传", "악인전"]


def test_recall_keywords_stay_at_three_for_other_library_languages() -> None:
    from movieclaw_api.services.subscription.wanted_search import recall_keywords

    item = _item(
        title="悪人伝",
        original_title="악인전",
        english_title="The Gangster, the Cop, the Devil",
        title_translations={"zh-CN": "恶人传", "en-US": "The Gangster, the Cop, the Devil"},
    )
    assert recall_keywords(item) == ["The Gangster, the Cop, the Devil", "恶人传", "悪人伝"]


# -- 豆瓣收敛固定用中文 --------------------------------------------------------


class _RecordingTmdb:
    def __init__(self) -> None:
        self.calls: list[tuple[str, dict]] = []

    async def get(self, path: str, params: dict | None = None) -> dict:
        self.calls.append((path, dict(params or {})))
        return {"results": []}


async def test_douban_resolution_searches_in_chinese_whatever_the_library_language() -> None:
    from movieclaw_api.services.media_library import MediaLibraryService

    client = _RecordingTmdb()
    service = MediaLibraryService(None, client, languages=["en-US"])  # type: ignore[arg-type]
    await service.resolve_douban(MediaKind.MOVIE, "恶人传", year=2019)

    assert client.calls
    assert {params["language"] for _path, params in client.calls} == {"zh-CN"}


# -- 发现页：每种读者语言一份服务 ------------------------------------------------


def test_discover_service_is_bound_per_reader_language(monkeypatch) -> None:
    from movieclaw_api.services import media_discover

    real = media_discover.get_settings()
    monkeypatch.setattr(
        media_discover,
        "get_settings",
        lambda: real.model_copy(update={"tmdb_api_key": "0123456789abcdef0123456789abcdef"}),
    )
    media_discover.reset_media_service()
    try:
        with use_locale("en"):
            english = media_discover.get_media_service()
            assert media_discover.get_media_service() is english
        with use_locale("zh-Hans"):
            chinese = media_discover.get_media_service()
        assert chinese is not english
        assert english._language == "en-US"
        assert chinese._language == "zh-CN"
    finally:
        media_discover.reset_media_service()


# -- 发现页详情的代码类标签 ------------------------------------------------------


def _detail() -> MediaDetail:
    card = MediaCard(
        id="95396",
        type=MediaKind.TV,
        title="Severance",
        original_title="Severance",
        year=2022,
        rating=8.4,
        poster_url="https://image.tmdb.org/t/p/w500/p.jpg",
    )
    return MediaDetail(
        card=card,
        facts=MediaFacts(
            country="US / DK",
            language="en",
            country_codes=["US", "DK"],
            language_code="en",
        ),
        videos=[
            MediaVideo(
                key="k",
                name="",
                kind="Trailer",
                thumbnail_url="t",
                embed_url="e",
                watch_url="w",
            )
        ],
    )


def test_discover_detail_labels_follow_reader_and_leave_cache_untouched() -> None:
    from movieclaw_api.services.title_discovery import title_details_from_legacy
    from movieclaw_media import MediaSource as Provider

    detail = _detail()
    for locale, country, language, kind in (
        ("en", "United States / Denmark", "English", "Trailer"),
        ("zh-Hans", "美国 / 丹麦", "英语", "预告片"),
    ):
        with use_locale(locale):
            view = title_details_from_legacy(detail, provider=Provider.TMDB)
        assert view.metadata.country == country
        assert view.metadata.language == language
        assert view.videos[0].kind == kind
        assert view.videos[0].name == kind  # 无名视频用类型名兜底
    assert detail.videos[0].kind == "Trailer"  # 缓存里的对象没被改写


def test_douban_detail_facts_pass_through() -> None:
    from movieclaw_api.services.title_discovery import title_details_from_legacy
    from movieclaw_media import MediaSource as Provider

    detail = _detail()
    detail.facts = MediaFacts(country="中国大陆", language="汉语普通话")
    with use_locale("en"):
        view = title_details_from_legacy(detail, provider=Provider.DOUBAN)
    assert view.metadata.country == "中国大陆"
    assert view.metadata.language == "汉语普通话"

"""内容语言：看到的跟界面语言，写下来的跟媒体库语言（docs/design/content-locale.md）。

媒体库原列（``media_item.title``、``media_metadata.overview``…）是主语言，写 NFO、
起文件夹名、给 Jellyfin 都读它；给人看的视图经这里按读者语言挑一份。主语言那一份
从不存进译文字典，所以读者语言与主语言同语种时字典里没有这一项，走原列。
"""

from collections.abc import Sequence
from typing import Any

from movieclaw_api.i18n import current_locale

#: 界面语言 → TMDB 语言标签；刮削时存下的译文语言与它对齐
#: （movieclaw_media.library.CONTENT_LANGUAGES）
READER_TMDB_LANGUAGE = {"zh-Hans": "zh-CN", "en": "en-US"}


def reader_language() -> str:
    """当前读者界面语言对应的 TMDB 语言标签。"""
    return READER_TMDB_LANGUAGE.get(current_locale.get(), "zh-CN")


def same_family(a: str | None, b: str | None) -> bool:
    return bool(a and b) and a.split("-")[0] == b.split("-")[0]  # type: ignore[union-attr]


def display_title(item: Any) -> str:
    """媒体库片名：读者语言的译名，没有就是主语言原列。"""
    return (getattr(item, "title_translations", None) or {}).get(reader_language()) or item.title


def display_overview(translations: dict | None, overview: str | None) -> str | None:
    """媒体库简介：``media_metadata.overview_translations`` 里读者语言的那份，没有回落原列。"""
    return (translations or {}).get(reader_language()) or overview


def in_reader_language(item: Any) -> bool:
    """条目有读者语言的片名、正以那门语言显示（读者与库语言不同语种且有译名）。

    这时库语言写的片名 Logo、宣传语就不给了——各端本来就有「没有 Logo 显示文字片名」
    的分支（content-locale.md §4.3）。还没有译名的条目照旧给：文字片名也是库语言，
    换掉 Logo 只会更难看。
    """
    return bool((getattr(item, "title_translations", None) or {}).get(reader_language()))


def display_genres(
    kind: str, names: Sequence[str], genre_ids: Sequence[int], scrape_language: str | None
) -> list[str]:
    """类型名：库内存的是刮削语言的名字，读者是另一语种时按 genre ID 出读者语言的名字。

    NFO 吸收来的、没有 ID 的条目原样显示。
    """
    from movieclaw_api.i18n.media_labels import genre_label

    if genre_ids and scrape_language and not same_family(scrape_language, reader_language()):
        return [genre_label(kind, genre_id) for genre_id in genre_ids]
    return [str(name) for name in names]

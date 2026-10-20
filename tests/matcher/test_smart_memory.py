from datetime import datetime, timedelta

from movieclaw_enrich.models import TorrentAttrs
from movieclaw_matcher import QualitySnapshot, TorrentCandidate
from movieclaw_matcher.smart import SmartPolicy, SmartPreferences, decide, watchable
from movieclaw_matcher.smart_memory import (
    QualityHabit,
    QualityOverride,
    SmartFacts,
    SmartMemory,
    habit_key,
    language_key,
    parse_scope,
    resolve,
)

NOW = datetime(2026, 10, 21, 12)
PREFS = SmartPreferences(wait_seconds=86400)
OPPENHEIMER = SmartFacts(kind="movie", title="奥本海默", language="en", region="US")
REPLY_1988 = SmartFacts(kind="tv", title="请回答1988", language="ko", region="KR", network="tvN")
SQUID = SmartFacts(kind="tv", title="鱿鱼游戏", language="ko", region="KR", network="Netflix")


def candidate(name, subs=(), audio=(), resolution="2160p", source="WEB-DL", published=None):
    return TorrentCandidate(
        site_id="s",
        torrent_id=name,
        title=name,
        subtitle="",
        attrs=TorrentAttrs(
            resolution=resolution,
            media_source=source,
            release_group="G",
            subtitle_languages=list(subs),
            audio_languages=list(audio),
        ),
        seeders=5,
        publish_time=published,
    )


def test_language_keys_map_tmdb_codes():
    assert language_key("en") == "en"
    assert language_key("cn") == "yue"  # TMDB 把粤语记作 cn
    assert language_key("zh") == "zh"
    assert language_key("xx") is None and language_key(None) is None


def test_first_foreign_language_asks_once_with_safe_default():
    first = resolve(PREFS, OPPENHEIMER, SmartMemory())
    assert first.watchable_languages == ("zh",)
    assert first.subtitle_line == "英语 · 只下带中文字幕的"
    assert first.question.prompt == "这是英语片，要中文字幕吗？"
    assert first.question.understood_label == "不用，我看得懂英语"

    said_subs = SmartMemory().with_language("en", False, source_title="奥本海默", at=NOW)
    again = resolve(PREFS, OPPENHEIMER, said_subs)
    assert again.question is None and again.watchable_languages == ("zh",)

    said_understood = SmartMemory().with_language("en", True, source_title="奥本海默", at=NOW)
    understood = resolve(PREFS, OPPENHEIMER, said_understood)
    assert understood.question is None
    assert understood.watchable_languages == ()
    assert understood.subtitle_line == "英语 · 不需要字幕"


def test_new_language_asks_again_and_accepts_any_understood_language():
    memory = SmartMemory().with_language("en", True, source_title="奥本海默", at=NOW)
    frieren = SmartFacts(kind="tv", title="葬送的芙莉莲", language="ja", region="JP")
    result = resolve(PREFS, frieren, memory)
    assert result.watchable_languages == ("zh", "en")
    assert result.subtitle_line == "日语 · 只下带中文或英语字幕的"
    assert result.question.prompt == "这是日语片，要中文或英语字幕吗？"
    cantonese = resolve(PREFS, SmartFacts(kind="movie", title="无间道", language="yue"), memory)
    assert cantonese.question.prompt == "这是粤语片，要中文或英语字幕吗？"


def test_chinese_and_unknown_language_add_no_requirement_and_no_line():
    chinese = resolve(PREFS, SmartFacts(kind="tv", title="狂飙", language="zh"), SmartMemory())
    unknown = resolve(PREFS, SmartFacts(kind="movie", title="无声", language=None), SmartMemory())
    for result in (chinese, unknown):
        assert result.watchable_languages == ()
        assert result.subtitle_line is None and result.question is None


def test_watchable_accepts_subtitles_or_audio_in_any_understood_language():
    policy = SmartPolicy(kind="movie", profile_revision=1, watchable_languages=("zh", "en"))
    assert watchable(candidate("a", subs=["zh-Hans"]), policy)
    assert watchable(candidate("b", subs=["zh"]), policy)
    assert watchable(candidate("c", audio=["cmn"]), policy)  # 国语配音
    assert watchable(candidate("d", subs=["en"]), policy)
    assert not watchable(candidate("e"), policy)  # 未声明按看不懂
    assert not watchable(candidate("f", subs=["ja"], audio=["ja"]), policy)
    assert watchable(candidate("g"), SmartPolicy(kind="movie", profile_revision=1))


def test_raw_only_waits_never_auto_downloads_and_force_releases_it():
    policy = SmartPolicy(
        kind="movie", profile_revision=1, wait_seconds=86400, watchable_languages=("zh",)
    )
    raws = [candidate("raw1"), candidate("raw2", resolution="1080p")]
    waiting = decide(policy, raws, now=NOW)
    assert waiting.action == "wait" and waiting.reason == "awaiting_subtitles"
    assert waiting.state.subtitle_blocked == 2
    assert waiting.state.candidate_key == "s/raw1"
    assert waiting.next_at == NOW + timedelta(days=1)

    expired = decide(policy, raws, now=NOW + timedelta(days=2), state=waiting.state)
    assert expired.action == "no_candidate" and expired.reason == "deadline_awaiting_subtitles"
    assert expired.state.deadline == waiting.state.deadline  # 不重新计时

    forced = waiting.state.model_copy(update={"forced_candidate": "s/raw1"})
    picked = decide(policy, raws, now=NOW + timedelta(hours=1), state=forced)
    assert picked.action == "download" and picked.candidate_key == "s/raw1"
    assert picked.reason == "manual_download"


def test_subbed_version_wins_and_late_subbed_version_downloads_at_once():
    policy = SmartPolicy(
        kind="movie", profile_revision=1, wait_seconds=86400, watchable_languages=("zh",)
    )
    subbed = candidate("subbed", subs=["zh"], resolution="1080p")
    result = decide(policy, [candidate("raw4k"), subbed], now=NOW)
    assert result.state.candidate_key == "s/subbed"
    assert result.state.subtitle_blocked == 1
    waited = decide(policy, [candidate("raw4k")], now=NOW)
    late = decide(
        policy, [candidate("raw4k"), subbed], now=NOW + timedelta(days=2), state=waited.state
    )
    assert late.action == "download" and late.candidate_key == "s/subbed"


def test_upgrade_never_trades_subtitles_for_resolution():
    policy = SmartPolicy(
        kind="movie", profile_revision=1, source="web-dl", watchable_languages=("zh",)
    )
    current = QualitySnapshot(
        resolution="1080p",
        media_source="WEB-DL",
        resolution_verified=True,
        source_evidence="consistent_declaration",
    )
    result = decide(policy, [candidate("raw4k")], now=NOW, current=current)
    assert result.action != "download"
    upgraded = decide(policy, [candidate("sub4k", subs=["zh-Hans"])], now=NOW, current=current)
    assert upgraded.action == "download" and upgraded.reason == "quality_upgrade"


def test_quality_layers_follow_fixed_order_and_explain_themselves():
    memory = SmartMemory(
        habits=[
            QualityHabit(
                scope="region", value="KR", kind="tv", resolution="1080p", source_title="请回答1988"
            ),
            QualityHabit(
                scope="network",
                value="Netflix",
                kind="tv",
                resolution="2160p",
                source_title="怪奇物语",
            ),
            QualityHabit(scope="kind", value="tv", kind="tv", source="blu-ray"),
        ]
    ).with_language("ko", False, source_title="请回答1988", at=NOW)
    korean = resolve(PREFS, REPLY_1988, memory)
    assert korean.quality_label == "优先 1080p 蓝光"
    assert korean.quality_note == "按「韩国的剧」的习惯 · 按「所有剧集」的习惯"
    assert korean.quality_shadow is None
    squid = resolve(PREFS, SQUID, memory)
    assert squid.resolution == "2160p"
    assert squid.quality_note.startswith("按「Netflix 的剧」的习惯")
    assert squid.quality_shadow == "「韩国的剧」是 1080p"
    movie = resolve(PREFS, OPPENHEIMER, memory)
    assert movie.quality_label == "优先 4K WEB-DL" and movie.quality_note is None

    only = resolve(PREFS, REPLY_1988, memory, override=QualityOverride(resolution="2160p"))
    assert only.resolution == "2160p" and only.quality_note.startswith("这部单独设置")
    series = QualityOverride(source="remux", origin="series", series_title="沙丘")
    dune2 = resolve(
        PREFS,
        SmartFacts(kind="movie", title="沙丘2", language="en", region="US", series_key="tmdb:1"),
        SmartMemory(),
        series=series,
    )
    assert dune2.quality_label == "优先 4K Remux" and dune2.quality_note == "按《沙丘》的设置"


def test_scope_options_come_from_the_work_itself():
    labels = [o.label for o in resolve(PREFS, REPLY_1988, SmartMemory()).scope_options]
    assert labels == ["只这部", "所有剧集", "韩国的剧", "tvN 的剧"]
    movie = [o.label for o in resolve(PREFS, OPPENHEIMER, SmartMemory()).scope_options]
    assert movie == ["只这部", "所有电影", "美国的电影"]  # 电影没有播出平台
    assert parse_scope(habit_key("region", "KR", "tv"), REPLY_1988) == ("region", "KR")
    assert parse_scope(habit_key("region", "US", "tv"), REPLY_1988) is None

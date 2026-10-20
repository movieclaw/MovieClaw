"""智能订阅记忆的作品夹具：API 测试与各端模拟器验收共用同一份假 TMDB。

覆盖设计里的每种情况：英语、粤语、日语、韩语与中文作品；同一地区不同平台的剧；
有系列的电影。数据只取 TMDB 详情里记忆真正用到的字段。
"""

from __future__ import annotations

from datetime import timedelta

from movieclaw_db.models.base import utcnow

_AIRED = (utcnow().date() - timedelta(days=20)).isoformat()


def _movie(tmdb_id, title, original, language, country, *, collection=None):
    return {
        "id": tmdb_id,
        "title": title,
        "original_title": original,
        "original_language": language,
        "release_date": "2023-07-21",
        "status": "Released",
        "production_countries": [{"iso_3166_1": country}],
        "production_companies": [{"name": "Studio"}],
        "belongs_to_collection": collection,
        "external_ids": {},
        "alternative_titles": {"titles": []},
        "translations": {"translations": []},
        "poster_path": "/lab.jpg",
    }


def _show(tmdb_id, name, original, language, country, network):
    return {
        "id": tmdb_id,
        "name": name,
        "original_name": original,
        "original_language": language,
        "origin_country": [country],
        "networks": [{"name": network}],
        "first_air_date": "2020-03-12",
        "status": "Ended",
        "external_ids": {},
        "alternative_titles": {"results": []},
        "translations": {"translations": []},
        "seasons": [{"season_number": 1}],
        "poster_path": "/lab.jpg",
    }


DUNE = {"id": 9001, "name": "沙丘（系列）"}

MOVIES = {
    701: _movie(701, "奥本海默", "Oppenheimer", "en", "US"),
    702: _movie(702, "无间道", "無間道", "cn", "HK"),
    703: _movie(703, "沙丘", "Dune", "en", "US", collection=DUNE),
    704: _movie(704, "沙丘：第二部", "Dune: Part Two", "en", "US", collection=DUNE),
    705: _movie(705, "消失的她", "消失的她", "zh", "CN"),
    706: _movie(706, "芭比", "Barbie", "en", "US"),
}
SHOWS = {
    801: _show(801, "请回答1988", "응답하라 1988", "ko", "KR", "tvN"),
    802: _show(802, "机智的医生生活", "슬기로운 의사생활", "ko", "KR", "tvN"),
    803: _show(803, "鱿鱼游戏", "오징어 게임", "ko", "KR", "Netflix"),
    804: _show(804, "绝命毒师", "Breaking Bad", "en", "US", "AMC"),
    805: _show(805, "葬送的芙莉莲", "葬送のフリーレン", "ja", "JP", "Nippon TV"),
    806: _show(806, "黑暗荣耀", "더 글로리", "ko", "KR", "Netflix"),
}

ROUTES: dict[str, dict] = {
    "/3/genre/tv/list": {"genres": []},
    "/3/genre/movie/list": {"genres": []},
}
for _id, _data in MOVIES.items():
    ROUTES[f"/3/movie/{_id}"] = _data
for _id, _data in SHOWS.items():
    ROUTES[f"/3/tv/{_id}"] = _data
    ROUTES[f"/3/tv/{_id}/season/1"] = {
        "name": "第 1 季",
        "air_date": "2020-03-12",
        "episodes": [
            {"episode_number": 1, "name": "E1", "air_date": _AIRED},
            {"episode_number": 2, "name": "E2", "air_date": _AIRED},
        ],
    }
ROUTES["/3/search/multi"] = {
    "results": [
        *({**m, "media_type": "movie"} for m in MOVIES.values()),
        *({**s, "media_type": "tv"} for s in SHOWS.values()),
    ]
}

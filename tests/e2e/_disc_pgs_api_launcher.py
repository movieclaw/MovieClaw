"""原盘 PGS 浏览器端到端专用的后端启动器：在 ``_api_launcher`` 之上让假 TMDB 多认两部片，每张盘
各是一部电影（认不出的原盘不进条目列表，放不了）。其余全是真代码。
"""

from __future__ import annotations

import runpy
from pathlib import Path

import _fake_tmdb

_MOVIES = {"单剪辑原盘": 301, "读得慢的原盘": 302}

for _title, _tmdb_id in _MOVIES.items():
    _fake_tmdb.ROUTES[f"/3/movie/{_tmdb_id}"] = {
        **_fake_tmdb.ROUTES["/3/movie/300"],
        "id": _tmdb_id,
        "title": _title,
    }

_search_known = _fake_tmdb._search


def _search(kind: str, query: str) -> list[dict]:
    for title, tmdb_id in _MOVIES.items():
        if kind == "movie" and title in query:
            return [{"id": tmdb_id, "title": title, "release_date": "2020-05-01"}]
    return _search_known(kind, query)


_fake_tmdb._search = _search

runpy.run_path(str(Path(__file__).with_name("_api_launcher.py")), run_name="__main__")

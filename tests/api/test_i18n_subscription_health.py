"""Pipeline explanations vary by reader; status, repairs and paths do not."""

import copy
import re

import pytest

from movieclaw_api.i18n import use_locale
from movieclaw_api.services.subscription.health import pipeline_health
from movieclaw_db.models import ImportWatch

from . import test_subscription_health as health
from . import test_subscription_routing as routing

client = routing.client
db = health.db


def _facts(value):
    if isinstance(value, list):
        return [_facts(item) for item in value]
    if isinstance(value, dict):
        return {
            key: _facts(item)
            for key, item in value.items()
            if key not in {"label", "detail", "title", "why", "steps", "fix_label", "narrative"}
        }
    return value


def test_empty_pipeline_api_follows_request_language(client):
    original = None
    for locale in ("en", "zh-Hans", "en"):
        response = client.get(
            "/api/v1/subscriptions/automation-readiness", headers={"Accept-Language": locale}
        )
        assert response.status_code == 200, response.text
        data = response.json()["data"]
        if original is None:
            original = _facts(data)
        assert _facts(data) == original
        assert [issue["key"] for issue in data["issues"]] == ["sites", "downloader"]
        if locale == "en":
            assert not re.search(r"[\u3400-\u9fff]", str(data))
            assert data["issues"][1]["title"] == "No active default downloader"
        else:
            assert data["site_check"]["detail"] == "没有可用的资源站点——订阅搜不到任何资源"
            assert data["issues"][1]["title"] == "没有可用的默认下载器"


@pytest.mark.asyncio
async def test_mapping_and_watch_repairs_keep_the_same_facts(db, tmp_path, monkeypatch):
    movie = await health._make_library(db, name="我的电影库", root=tmp_path / "movies")
    await health._make_library(db, name="我的剧集库", kind="tv", root=tmp_path / "shows")
    await health._make_downloader(db, mappings=[{"local": "/elsewhere", "remote": "/downloads"}])
    await health._make_site(db)
    watch = tmp_path / "watch"
    watch.mkdir()
    staging = tmp_path / "staging"
    staging.mkdir()
    monkeypatch.setattr(
        "movieclaw_api.services.subscription.health._watched_dirs", lambda: frozenset({str(watch)})
    )
    for with_watch in (False, True):
        async with db.session() as session:
            if with_watch:
                session.add(
                    ImportWatch(
                        source_path=str(watch),
                        target_path=str(staging),
                        strategy="hardlink",
                        library_id=movie,
                    )
                )
                await session.commit()
            original = None
            for locale in ("zh-Hans", "en", "zh-Hans"):
                with use_locale(locale):
                    data = await pipeline_health(session)
                facts = _facts(data)
                if original is None:
                    original = copy.deepcopy(facts)
                assert facts == original
                mapping = next(issue for issue in data["issues"] if issue["key"] == "mapping")
                assert len(mapping["options"]) == 2
                assert mapping["options"][0]["fix_params"]["suggest_mapping"] == str(tmp_path)
                text = str(data).replace("我的电影库", "").replace("我的剧集库", "")
                if locale == "en":
                    assert not re.search(r"[\u3400-\u9fff]", text)
                    assert data["site_check"]["detail"] == "1 active site connected"
                else:
                    assert data["site_check"]["detail"] == "已接入 1 个可用站点"
                library = next(row for row in data["libraries"] if row["library_id"] == movie)
                assert library["mode"] == ("watch" if with_watch else "inplace")
                if with_watch:
                    assert str(staging) in library["narrative"]
                    assert health._check(library, "transfer_disk")["status"] == "ok"
                    assert health._check(library, "watch_active")["status"] == "ok"


def test_hardlink_checks_translate_each_outcome_without_changing_status(monkeypatch):
    from types import SimpleNamespace

    from movieclaw_api.services.subscription.health import _check_transfer
    from movieclaw_db.models import Library

    library = Library(name="原始库名", kind="movie", root_paths=["/library"])
    rule = ImportWatch(source_path="/source", library_id=1, strategy="hardlink")
    for outcome, expected in (("same", "ok"), ("different", "error"), ("unavailable", "warn")):

        def stat(path, *, outcome=outcome):
            if outcome == "unavailable":
                raise OSError("offline")
            return SimpleNamespace(st_dev=1 if path == "/source" or outcome == "same" else 2)

        with monkeypatch.context() as patch:
            patch.setattr("movieclaw_api.services.subscription.health.os.stat", stat)
            for locale in ("en", "zh-Hans", "en"):
                with use_locale(locale):
                    checks = _check_transfer(rule, library, frozenset({"/source"}))
                assert [check.status for check in checks] == [expected, "ok"]
                if locale == "en":
                    text = str(checks).replace("原始库名", "")
                    assert not re.search(r"[\u3400-\u9fff]", text)
                else:
                    assert checks[0].label == "硬链接同盘"

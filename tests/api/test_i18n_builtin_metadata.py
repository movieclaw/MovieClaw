"""Built-in metadata and group labels are request projections; plugin identities stay neutral."""

import inspect
import re

from movieclaw_api.i18n import use_locale
from movieclaw_api.plugins.manifest import BUILTIN_GROUPS, BUILTIN_MANIFEST
from movieclaw_api.plugins.presentation import BUILTIN_MESSAGE_KEYS, builtin_text, group_labels
from movieclaw_api.plugins.scheduling import app_update_startup_check

from .test_plugin_detail import app_env, start  # noqa: F401


def test_owned_metadata_matches_defaults_and_preserves_unknown_authors():
    declarations = {entry.id: entry.plugin for entry in BUILTIN_MANIFEST}
    declarations[app_update_startup_check.name] = app_update_startup_check
    assert set(BUILTIN_MESSAGE_KEYS) == set(declarations)
    for entry_id, declared in declarations.items():
        doc = inspect.getdoc(inspect.unwrap(declared.apply)) or ""
        description = " ".join(
            line.strip() for line in doc.split("\n\n", 1)[0].splitlines()
        ).strip()
        with use_locale("zh-Hans"):
            assert builtin_text(entry_id, "title", "") == declared.title
            assert builtin_text(entry_id, "description", "") == description
        with use_locale("en"):
            assert not re.search(r"[\u3400-\u9fff]", builtin_text(entry_id, "title", ""))
            assert not re.search(r"[\u3400-\u9fff]", builtin_text(entry_id, "description", ""))
            assert builtin_text("author.unknown", "title", "作者原名") == "作者原名"
        assert declarations[entry_id].title == declared.title
    with use_locale("zh-Hans"):
        assert group_labels() == {name: name for name, _ in BUILTIN_GROUPS}


def test_http_metadata_changes_only_display_fields_and_group_ids_stay_original(app_env):  # noqa: F811
    with start() as client:
        before = [(value["id"], value["title"]) for value in client.app.state.kernel.snapshot()]
        responses = []
        for locale in ("en", "zh-Hans", "en"):
            response = client.get("/api/v1/app/plugins", headers={"Accept-Language": locale})
            assert response.status_code == 200, response.text
            responses.append(response.json()["data"])
        english, chinese, again = responses
        assert english["group_labels"] == again["group_labels"]
        assert english["groups"] == chinese["groups"] == list(chinese["group_labels"])
        assert english["group_labels"]["基础"] == "Core"
        en = {value["id"]: value for value in english["plugins"]}
        zh = {value["id"]: value for value in chinese["plugins"]}
        assert en["core.database"]["title"] == "Database"
        assert zh["core.database"]["title"] == "数据库"
        assert en["app-update.startup-check"]["title"] == "Startup update check"
        assert zh["app-update.startup-check"]["title"] == "启动后检查更新"
        assert en["acme-detail"]["title"] == zh["acme-detail"]["title"] == "详情示例"
        assert en["weixin-channel"]["title"] == "WeChat channel"
        assert all(value["group"] == zh[key]["group"] for key, value in en.items())
        assert [
            (value["id"], value["title"]) for value in client.app.state.kernel.snapshot()
        ] == before
        details = client.get(
            "/api/v1/app/plugins/core.database", headers={"Accept-Language": "en"}
        ).json()["data"]
        assert details["description"].startswith("Opens the application database")


def test_removed_official_plugin_uses_reader_metadata_and_keeps_switch_records(app_env):  # noqa: F811
    from movieclaw_api.core.config import get_settings
    from movieclaw_api.services.plugin_switches import read_switches

    with start() as client:
        removed = client.delete("/api/v1/app/plugins/telegram-channel/bundled")
        assert removed.status_code == 200, removed.text
        state = read_switches(get_settings())
        result = []
        for locale in ("en", "zh-Hans", "en"):
            response = client.get("/api/v1/app/plugins", headers={"Accept-Language": locale})
            assert response.status_code == 200, response.text
            result.append(response.json()["data"]["removed"])
            assert read_switches(get_settings()) == state
        assert result[0] == result[2]
        assert result[0][0]["title"] == "Telegram channel"
        assert result[1][0]["title"] == "Telegram 通道"
        assert result[0][0]["description"].startswith("Connect a bot")
        restored = client.post("/api/v1/app/plugins/telegram-channel/bundled/restore")
        assert restored.status_code == 200, restored.text


def test_feature_defaults_match_their_catalog_sources():
    """功能卡的中文是回滚默认值：须与目录键同文，英文须有译文。"""
    from movieclaw_api.i18n import messages
    from movieclaw_api.plugins.features import FEATURES

    chinese, english = messages("zh-Hans"), messages("en")
    for feature in FEATURES:
        assert feature.title_key and chinese[feature.title_key] == feature.title
        assert feature.description_key
        assert chinese[feature.description_key] == feature.description
        assert english[feature.title_key] and english[feature.description_key]

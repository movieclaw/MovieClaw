"""Upload/install a real plugin, then read the same cached metadata in two languages."""

import io
import json
import zipfile

from . import test_plugin_web as web
from . import test_theme_packages as themes

data_dir = web.data_dir


def test_installed_web_metadata_and_document_follow_each_request(data_dir):
    manifest = web.MANIFEST.format(version=1).replace(
        'title = "看板插件"',
        'title = "看板插件"\ntitle_localized = { en = "Board plugin" }\n'
        'description = "看板说明"\ndescription_localized = { en = "Board description" }',
    )
    content = io.BytesIO()
    with zipfile.ZipFile(content, "w") as archive:
        archive.writestr("movieclaw-plugin.toml", manifest)
        archive.writestr(
            "web/index.html", '<!doctype html><html lang="zh"><title>Board</title></html>'
        )
        archive.writestr(
            "web/manifest.webmanifest",
            json.dumps(
                {
                    **web.WEBMANIFEST,
                    "name_localized": {"en": {"value": "Weekly board"}},
                    "short_name_localized": {"en": "Board"},
                    "shortcuts": [
                        {
                            "name": "下载统计",
                            "name_localized": {"en": "Downloads"},
                            "url": "downloads",
                        }
                    ],
                }
            ),
        )
    client, _ = web.start()
    with client:
        client.headers["Accept-Language"] = "en"
        preview = web.upload(client, content.getvalue()).json()["data"]
        assert preview["title"] == "Board plugin"
        assert preview["web"]["name"] == "Weekly board"
        approved = web.approve(client, "1.0.0", allow_web=True)
        assert approved.status_code == 200, approved.text
        from movieclaw_api.core.config import get_settings
        from movieclaw_api.plugins.packages import MANIFEST, version_dir

        source = version_dir(get_settings(), "acme-web", "1.0.0") / MANIFEST
        original = source.read_bytes()
        english_detail = client.get("/api/v1/app/plugins/acme-web").json()["data"]
        assert english_detail["description"] == "Board description"
        assert english_detail["plugin"]["title"] == "Board plugin"
        english = web.apps(client)["acme-web"]
        assert english["name"] == "Weekly board"
        assert [entry["label"] for entry in english["entries"]] == ["Board", "Downloads"]
        url = "/api/v1/plugins/acme-web/web/"
        page = client.get(url)
        assert 'lang="en"' in page.text
        assert client.get(url, headers={"If-None-Match": page.headers["etag"]}).status_code == 304
        client.headers["Accept-Language"] = "zh-Hans"
        chinese_detail = client.get("/api/v1/app/plugins/acme-web").json()["data"]
        assert chinese_detail["description"] == "看板说明"
        assert web.apps(client)["acme-web"]["name"] == "本周看板"
        chinese = client.get(url, headers={"If-None-Match": page.headers["etag"]})
        assert chinese.status_code == 200
        assert 'lang="zh-Hans"' in chinese.text
        assert chinese.headers["etag"] != page.headers["etag"]
        assert "Accept-Language" in chinese.headers["vary"]
        installed = client.get("/api/v1/app/plugins/packages").json()["data"]["installed"]
        assert installed[0]["title"] == "看板插件"
        client.headers["Accept-Language"] = "en"
        assert client.get("/api/v1/app/plugins/acme-web").json()["data"] == english_detail
        assert source.read_bytes() == original
        installed = client.get("/api/v1/app/plugins/packages").json()["data"]["installed"]
        assert installed[0]["title"] == "Board plugin"


def test_installed_theme_metadata_is_not_cached_in_first_readers_language(data_dir):
    files = themes.theme_files(with_js=False, layout="panel")
    files["movieclaw-plugin.toml"] = files["movieclaw-plugin.toml"].replace(
        'description = "测试主题"',
        'description = "测试主题"\ndescription_localized = { en = "Test theme" }',
    )
    client, _ = web.start()
    with client:
        uploaded = themes.upload(client, themes.zipped(files))
        assert uploaded.status_code == 200, uploaded.text
        approved = client.post(
            "/api/v1/app/plugins/packages/acme-theme/approve",
            json={
                "version": "1.0.0",
                "operations": [],
            },
        )
        assert approved.status_code == 200, approved.text
        for language, expected in (
            ("en", "Test theme"),
            ("zh-Hans", "测试主题"),
            ("en", "Test theme"),
        ):
            rows = client.get("/api/v1/ui/themes", headers={"Accept-Language": language}).json()[
                "data"
            ]
            assert next(row for row in rows if row["id"] == "acme-theme")["description"] == expected

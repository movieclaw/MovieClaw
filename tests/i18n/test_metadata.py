from concurrent.futures import ThreadPoolExecutor

from movieclaw_api.i18n import use_locale
from movieclaw_api.i18n.metadata import localized_html, localized_schema, localized_text


def test_metadata_is_request_local_and_does_not_modify_schema_or_values():
    schema = {
        "type": "object",
        "title": "设置",
        "title_localized": {"en": "Settings"},
        "properties": {
            "token": {
                "title": "令牌",
                "title_localized": {"en-US": {"value": "Token", "dir": "ltr"}},
                "default": {"title": "用户内容", "title_localized": {"en": "Do not replace"}},
                "enum": ["中文值"],
                "minLength": 8,
                "writeOnly": True,
            }
        },
        "$defs": {
            "nested": {"description": "说明", "description_localized": {"en": "Description"}}
        },
    }

    def read(locale):
        with use_locale(locale):
            return localized_schema(schema)

    with ThreadPoolExecutor() as pool:
        english, chinese = list(pool.map(read, ["en", "zh-Hans"]))
    assert english["title"] == "Settings"
    assert chinese["title"] == schema["title"] == "设置"
    assert english["properties"]["token"]["title"] == "Token"
    assert english["properties"]["token"]["default"] == schema["properties"]["token"]["default"]
    assert english["properties"]["token"]["enum"] == ["中文值"]
    assert english["properties"]["token"]["minLength"] == 8
    assert english["properties"]["token"]["writeOnly"] is True
    assert english["$defs"]["nested"]["description"] == "Description"
    with use_locale("en"):
        assert localized_text("Original", {"en-US": "Regional", "en": "Exact"}) == "Exact"
        assert localized_text("Original", {"ja": "Japanese"}) == "Original"


def test_html_language_does_not_rewrite_script_or_comment_content():
    script = '<script>const sample = "<html lang=zh>";</script>'
    source = (
        '<!doctype html><!-- <html> --><html lang="zh" class="app"><head>'
        + script
        + "</head></html>"
    )
    with use_locale("en"):
        result = localized_html(source)
        assert '<html class="app" lang="en">' in result
        assert script in result
        assert "<!-- <html> -->" in result
        assert localized_html("<!doctype html><title>Plugin</title>") == (
            '<!doctype html><html lang="en"><title>Plugin</title></html>'
        )

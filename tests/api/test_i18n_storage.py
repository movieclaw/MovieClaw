"""Storage display follows the reader while the shared snapshot and files stay unchanged."""

import asyncio
import time
from dataclasses import asdict

import pytest

from movieclaw_api.i18n import use_locale
from movieclaw_api.services.storage import registry, service

from . import test_storage as storage

client = storage.client
data_root = storage.data_root


def test_cached_directory_descriptions_follow_each_reader(client, data_root):
    storage._write(data_root / "cache/images/user-image", 37)
    storage._poll_usage(client)
    original = asdict(service._snapshot)
    views = []
    for language in ("en", "zh-Hans", "en"):
        response = client.get("/api/v1/app/storage", headers={"Accept-Language": language})
        assert response.status_code == 200
        views.append(response.json()["data"])
        assert asdict(service._snapshot) == original
    assert views[0] == views[2]
    assert views[1]["usage"] == original
    for en, zh in zip(views[0]["usage"]["dirs"], views[1]["usage"]["dirs"], strict=True):
        for field in ("title", "summary", "description"):
            assert en[field] != zh[field]
            assert not any("\u3400" <= char <= "\u9fff" for char in en[field])
        assert {k: v for k, v in en.items() if k not in ("title", "summary", "description")} == {
            k: v for k, v in zh.items() if k not in ("title", "summary", "description")
        }
    assert (data_root / "cache/images/user-image").read_bytes() == b"x" * 37


@pytest.mark.parametrize(
    ("key", "mode", "english", "chinese"),
    [
        ("uploads", "all", "Uploaded files", "上传文件"),
        ("metadata.images", "all", "Scraped image assets", "刮削图片资产"),
        ("cache.images", "orphans", "Image cache", "图片缓存"),
    ],
)
def test_cleanup_refusals_use_localized_directory_names(client, key, mode, english, chinese):
    for language, expected in (("en", english), ("zh-Hans", chinese)):
        response = client.post(
            f"/api/v1/app/storage/{key}/clean",
            json={"mode": mode},
            headers={"Accept-Language": language},
        )
        assert response.status_code == 400
        assert expected in response.json()["message"]


def test_failed_refresh_keeps_snapshot_and_localizes_error_on_read(client, monkeypatch):
    storage._poll_usage(client)
    original = asdict(service._snapshot)

    def fail():
        raise OSError("raw disk error 原始原因")

    monkeypatch.setattr(service, "compute_usage", fail)
    client.get("/api/v1/app/storage?refresh=1", headers={"Accept-Language": "en"})
    deadline = time.monotonic() + 5
    while service._task is not None:
        assert time.monotonic() < deadline
        time.sleep(0.01)
    errors = []
    for language in ("en", "zh-Hans", "en"):
        response = client.get("/api/v1/app/storage", headers={"Accept-Language": language})
        state = response.json()["data"]
        assert state["usage"] is not None and not state["computing"]
        assert "raw disk error 原始原因" in state["error"]
        errors.append(state["error"])
        assert asdict(service._snapshot) == original
    assert errors[0] == errors[2] != errors[1]
    assert errors[1] == "统计数据目录占用失败：raw disk error 原始原因"


def test_unknown_registration_text_and_cleanup_facts_remain_raw(data_root):
    with use_locale("en"):
        assert registry.directory_text("third.party", "title", "用户原始名称") == "用户原始名称"
        storage._write(data_root / "cache/images/cache", 23)
        result = asyncio.run(service.clean("cache.images", "all"))
    assert asdict(result) == {
        "key": "cache.images",
        "mode": "all",
        "removed": 1,
        "skipped_busy": 0,
        "freed_bytes": 23,
    }


@pytest.mark.parametrize("field", ["title", "summary", "description"])
def test_every_registered_directory_text_has_an_identical_catalog_source(field):
    """登记表里的中文是回滚默认值：每条都必须有同文目录键，读取时才真的按读者语言渲染。"""
    import re

    from movieclaw_api.i18n import messages

    chinese, english = messages("zh-Hans"), messages("en")
    for directory in registry.DATA_DIRS:
        identity = "".join(part.title() for part in re.split(r"[._-]", directory.key))
        key = f"settings.storage.directories.{identity[:1].lower()}{identity[1:]}{field.title()}"
        assert chinese.get(key) == getattr(directory, field), key
        assert english.get(key), key
        with use_locale("en"):
            assert registry.directory_text(directory.key, field, "") == english[key]

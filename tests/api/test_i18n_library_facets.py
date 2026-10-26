"""Facet names and relaxation suggestions use each reader's language, with stable counts/IDs."""

import re

from . import test_auth as auth
from . import test_library_filter as filtering

client = auth.client


def test_facets_and_relaxation_translate_without_changing_the_filter(client):
    from movieclaw_db.engine import get_database

    auth._bootstrap(client)

    async def seed():
        async with get_database().session() as session:
            library_id, _ = await filtering._seed(session)
            await session.commit()
            return library_id

    library_id = client.portal.call(seed)
    signatures = []
    for locale in ("en", "zh-Hans", "en"):
        headers = {"Accept-Language": locale}
        response = client.get(
            f"/api/v1/libraries/{library_id}/facets?g=16&c=JP&tier=all", headers=headers
        )
        assert response.status_code == 200, response.text
        data = response.json()["data"]
        labels = {
            group: {v["value"]: v["label"] for v in data[group]}
            for group in ("genres", "countries", "decades", "watch", "stock")
        }
        assert labels["genres"]["16"] == ("Animation" if locale == "en" else "动画")
        assert labels["countries"]["JP"] == ("Japan" if locale == "en" else "日本")
        assert labels["decades"]["earlier"] == ("Earlier" if locale == "en" else "更早")
        assert labels["watch"]["unwatched"] == ("Unwatched" if locale == "en" else "未看")
        assert labels["stock"]["missing"] == ("Files missing" if locale == "en" else "文件失联")
        signatures.append(
            {
                key: [(v["value"], v["count"]) for v in values]
                if isinstance(values, list)
                else values
                for key, values in data.items()
            }
        )
        response = client.get(f"/api/v1/libraries/{library_id}/relax?g=16&c=US", headers=headers)
        assert response.status_code == 200, response.text
        suggestions = response.json()["data"]["suggestions"]
        assert suggestions
        if locale == "en":
            assert not re.search(r"[\u3400-\u9fff]", str(labels))
            assert not re.search(r"[\u3400-\u9fff]", str(suggestions))
        else:
            assert any(row["label"] in {"动画", "美国"} for row in suggestions)
    assert signatures[0] == signatures[1] == signatures[2]


def test_builtin_collection_name_translates_and_custom_names_remain_original(client):
    from movieclaw_api.services.library.collections import ensure_builtin_collections
    from movieclaw_db.engine import get_database
    from movieclaw_db.models import Collection

    auth._bootstrap(client)

    async def seed():
        async with get_database().session() as session:
            library_id, ids = await filtering._seed(session)
            await ensure_builtin_collections(session, library_id)
            await session.commit()
            return library_id, ids["千与千寻"]

    library_id, item_id = client.portal.call(seed)
    response = client.post(
        "/api/v1/playback/marks", json={"media_item_id": item_id, "favorite": True}
    )
    assert response.status_code == 200, response.text
    for locale in ("en", "zh-Hans", "en"):
        response = client.get(
            f"/api/v1/collections?library_id={library_id}", headers={"Accept-Language": locale}
        )
        assert response.status_code == 200, response.text
        row = next(r for r in response.json()["data"] if r["kind"] == "builtin")
        assert row["name"] == ("My favorites" if locale == "en" else "我的收藏")
        assert row["item_count"] == 1
    collection_id = row["id"]

    async def stored_name():
        async with get_database().session() as session:
            return (await session.get(Collection, collection_id)).name

    assert client.portal.call(stored_name) == "我的收藏"
    response = client.put(f"/api/v1/collections/{collection_id}", json={"name": "我的自定义名称"})
    assert response.status_code == 200, response.text
    for locale in ("en", "zh-Hans"):
        response = client.get(
            f"/api/v1/collections/{collection_id}", headers={"Accept-Language": locale}
        )
        assert response.json()["data"]["name"] == "我的自定义名称"


def test_facet_catalog_covers_dynamic_dimension_keys():
    from movieclaw_api.i18n import messages
    from movieclaw_api.i18n.media_labels import country_label
    from movieclaw_api.services.library.items import _DIM_MESSAGE_KEYS

    for locale in ("en", "zh-Hans"):
        assert set(_DIM_MESSAGE_KEYS.values()) <= messages(locale).keys()
    assert country_label("ZZ") == "ZZ"

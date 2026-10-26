"""Gallery response labels follow the reader without rewriting artwork or metadata."""

from . import test_auth as auth
from . import test_library_filter as filtering

client = auth.client


def test_library_collection_and_favorites_gallery_labels_follow_the_reader(client):
    from sqlmodel import select

    from movieclaw_db.engine import get_database
    from movieclaw_db.models import Library, LibraryFile, MediaItem, MediaMetadata

    auth._bootstrap(client)

    async def seed():
        async with get_database().session() as session:
            library_id, ids = await filtering._seed(session)
            item_id = ids["千与千寻"]
            library = await session.get(Library, library_id)
            library.extract_chapter_images = True
            metadata = await session.get(MediaMetadata, item_id)
            metadata.poster_file = "poster.jpg"
            metadata.backdrop_file = "fanart.jpg"
            file = (
                await session.execute(
                    select(LibraryFile).where(LibraryFile.media_item_id == item_id)
                )
            ).scalar_one()
            file.duration_seconds = 120
            file.chapters = [
                {"start_ms": 0, "end_ms": 60_000, "title": "自定义章名"},
                {"start_ms": 60_000, "end_ms": None, "title": None},
            ]
            file.chapter_images = [
                {"start_ms": 0, "image": "first.jpg"},
                {"start_ms": 60_000, "image": "second.jpg"},
            ]
            await session.commit()
            return library_id, item_id

    library_id, item_id = client.portal.call(seed)
    collection = client.post(
        "/api/v1/collections",
        json={"name": "用户自定义合集", "library_id": library_id, "item_ids": [item_id]},
    ).json()["data"]
    assert (
        client.post(
            "/api/v1/playback/marks", json={"media_item_id": item_id, "favorite": True}
        ).status_code
        == 200
    )
    signatures = []
    for locale in ("en", "zh-Hans", "en"):
        headers = {"Accept-Language": locale}
        for path in (
            f"/libraries/{library_id}/gallery",
            f"/collections/{collection['id']}/gallery",
            "/playback/favorites/gallery",
        ):
            response = client.get(f"/api/v1{path}", headers=headers)
            assert response.status_code == 200, response.text
            group = next(g for g in response.json()["data"] if g["media_item_id"] == item_id)
            assert group["title"] == "千与千寻"
            assert [image["label"] for image in group["images"]] == (
                ["Poster", "Backdrop", "自定义章名", "Chapter 2"]
                if locale == "en"
                else ["海报", "剧照", "自定义章名", "章节 2"]
            )
            signatures.append(
                [{k: v for k, v in i.items() if k != "label"} for i in group["images"]]
            )
    assert all(signature == signatures[0] for signature in signatures)

    async def stored():
        async with get_database().session() as session:
            item = await session.get(MediaItem, item_id)
            file = (
                await session.execute(
                    select(LibraryFile).where(LibraryFile.media_item_id == item_id)
                )
            ).scalar_one()
            return item.title, file.chapters

    title, chapters = client.portal.call(stored)
    assert title == "千与千寻"
    assert [chapter["title"] for chapter in chapters] == ["自定义章名", None]


def test_episode_gallery_label_keeps_the_episode_name():
    from movieclaw_api.i18n import t, use_locale

    for locale, expected in (("en", "Episode 2 · 自定义集名"), ("zh-Hans", "第 2 集 · 自定义集名")):
        with use_locale(locale):
            assert (
                t("library.gallery.episode", episode=2, name="yes", title="自定义集名") == expected
            )

"""图片本地优先与本地图片画质（docs/design/image-sizing.md §4.2 / §7 / §8）。

- 演职员头像随刮削落本地，同一个人跨条目只存一份；接口优先给本地地址（断网可用）；
- 画质预设（原图 / 标准 / 节省空间 / 自定义）决定四个档位，界面选中的档按设置反推；
- 磁盘估算、订阅卡片与推送配图优先用本地资产。
"""

from __future__ import annotations

from io import BytesIO
from pathlib import Path

import pytest
import pytest_asyncio
from PIL import Image

from movieclaw_api.core.config import get_settings
from movieclaw_api.services.scrape_config import reset_scrape_config
from movieclaw_api.settings import MetadataScrapeSetting
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.migrations import run_migrations
from movieclaw_db.models import (
    MediaItem,
    MediaItemPerson,
    MediaMetadata,
    Person,
)


@pytest_asyncio.fixture
async def db(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'local-first.db'}")
    monkeypatch.setenv("METADATA_DIR", str(tmp_path / "metadata"))
    monkeypatch.setenv("PEOPLE_IMAGES_DIR", str(tmp_path / "metadata" / "people"))
    get_settings.cache_clear()
    reset_scrape_config()
    init_db(get_settings().database_url, echo=False)
    await run_migrations()
    yield get_database()
    await dispose_db()
    reset_scrape_config()
    get_settings.cache_clear()


def _apply_setting(**fields) -> MetadataScrapeSetting:
    import movieclaw_api.services.scrape_config as cfg

    setting = MetadataScrapeSetting(**fields)
    cfg._current_scrape = setting
    return setting


def _jpeg() -> bytes:
    buffer = BytesIO()
    Image.new("RGB", (40, 60), "#335577").save(buffer, "JPEG")
    return buffer.getvalue()


class _Proxy:
    def __init__(self) -> None:
        self.urls: list[str] = []

    async def fetch(self, url: str, *, accept: str | None = None):
        self.urls.append(url)
        return _jpeg(), "image/jpeg"


async def _movie_with_cast(session, *, tmdb_id: int, cast: list[str], director: str | None):
    item = MediaItem(kind="movie", tmdb_id=tmdb_id, title=f"片{tmdb_id}", original_title="M")
    session.add(item)
    await session.flush()
    session.add(
        MediaMetadata(
            media_item_id=item.id,
            cast=[{"name": f"演员{p}", "profile_path": p} for p in cast],
        )
    )
    if director:
        person = Person(tmdb_person_id=hash(director) % 100000, name="导演", profile_path=director)
        session.add(person)
        await session.flush()
        session.add(
            MediaItemPerson(media_item_id=item.id, person_id=person.id, department="director")
        )
    await session.commit()
    return item.id


@pytest.mark.asyncio
async def test_avatars_download_once_per_person_and_serve_locally(db, monkeypatch):
    """两部片共用一位演员：头像只下一次、只存一份；接口给本地地址。"""
    from movieclaw_api.services.media_scrape import AssetTally, download_item_assets
    from movieclaw_api.services.people_images import avatar_url, people_root

    _apply_setting()
    async with db.session() as session:
        first = await _movie_with_cast(
            session, tmdb_id=1, cast=["/aa1.jpg", "/bb2.jpg"], director="/dd9.jpg"
        )
        second = await _movie_with_cast(session, tmdb_id=2, cast=["/aa1.jpg"], director=None)
    proxy = _Proxy()
    monkeypatch.setattr("movieclaw_api.services.image_proxy.get_image_proxy", lambda: proxy)

    tally = AssetTally()
    await download_item_assets(first, tally=tally)
    assert sorted(u.rsplit("/", 1)[-1] for u in proxy.urls) == ["aa1.jpg", "bb2.jpg", "dd9.jpg"]
    assert (tally.planned, tally.downloaded) == (3, 3)  # 头像也算进「下载图片 x / y」
    assert (people_root() / "original" / "aa" / "aa1.jpg").is_file()

    proxy.urls.clear()
    again = AssetTally()
    await download_item_assets(second, tally=again)
    assert proxy.urls == []  # 同一个人：沿用第一部下好的那份
    assert (again.planned, again.reused) == (1, 1)

    assert avatar_url("/aa1.jpg") == "/images/people/original/aa/aa1.jpg"
    # NFO 里吸收来的 TMDB 头像地址也换算成本地
    assert (
        avatar_url("https://image.tmdb.org/t/p/w300/aa1.jpg")
        == "/images/people/original/aa/aa1.jpg"
    )
    # 本地没有的：图床兜底（当前头像档位）
    assert avatar_url("/zz0.jpg").endswith("/original/zz0.jpg")


@pytest.mark.asyncio
async def test_person_route_serves_with_width(db, tmp_path):
    from movieclaw_api.api.routes.images import get_person_avatar
    from movieclaw_api.services.people_images import people_root

    target = people_root() / "original" / "aa" / "aa1.jpg"
    target.parent.mkdir(parents=True)
    Image.new("RGB", (2000, 3000), "#224466").save(target, "JPEG")
    whole = await get_person_avatar("original/aa/aa1.jpg", w=None, _principal=None)
    assert Path(whole.path) == target
    small = await get_person_avatar("original/aa/aa1.jpg", w=300, _principal=None)
    with Image.open(small.path) as image:
        assert image.width == 360  # 300 向上取到 360 档
    from movieclaw_api.exceptions import NotFoundException

    with pytest.raises(NotFoundException):
        await get_person_avatar("../../../etc/passwd", w=None, _principal=None)


def test_quality_presets_drive_sizes_and_inferred_choice(monkeypatch):
    from movieclaw_api.services.scrape_config import (
        effective_asset_sizes,
        effective_image_quality,
        effective_profile_size,
    )

    get_settings.cache_clear()
    setting = _apply_setting()
    # 默认：原图（没选过、档位都没设、环境变量也是默认）
    assert effective_asset_sizes(setting) == ("original", "original", "original")
    assert effective_image_quality(setting) == "original"
    standard = _apply_setting(image_quality="standard")
    assert effective_asset_sizes(standard) == ("w780", "original", "original")
    assert effective_profile_size(standard) == "h632"
    compact = _apply_setting(image_quality="compact", poster_size="original")
    # 选了预设就按预设，自定义字段不生效
    assert effective_asset_sizes(compact) == ("w500", "w1280", "w300")
    custom = _apply_setting(image_quality="custom", still_size="w300")
    assert effective_asset_sizes(custom) == ("original", "original", "w300")
    # 老配置（没选过画质、显式存过档位）：界面落在「自定义」
    legacy = _apply_setting(still_size="w300")
    assert effective_image_quality(legacy) == "custom"
    # 环境变量把档位改成了标准那一套：界面认作「标准」
    monkeypatch.setenv("TMDB_POSTER_SIZE", "w780")
    monkeypatch.setenv("TMDB_PROFILE_SIZE", "h632")
    get_settings.cache_clear()
    assert effective_image_quality(_apply_setting()) == "standard"
    get_settings.cache_clear()


@pytest.mark.asyncio
async def test_storage_estimate_orders_presets(db):
    from movieclaw_api.services.image_estimate import estimate_image_storage

    _apply_setting()
    async with db.session() as session:
        await _movie_with_cast(session, tmdb_id=5, cast=["/a1.jpg", "/a2.jpg"], director="/d1.jpg")
        item = await session.get(MediaItem, 1)
        item.poster_path = "/p.jpg"
        item.backdrop_path = "/b.jpg"
        session.add(item)
        await session.commit()
        estimate = await estimate_image_storage(session)
    assert estimate["counts"]["people"] == 3
    assert estimate["counts"]["posters"] == 1
    presets = estimate["presets"]
    assert presets["original"] > presets["standard"] > presets["compact"] > 0
    assert estimate["current_quality"] == "original"
    assert estimate["current_bytes"] == presets["original"]


@pytest.mark.asyncio
async def test_media_brief_prefers_local_assets(db):
    from movieclaw_api.schemas.subscription import MediaBrief

    _apply_setting()
    item = MediaItem(
        id=7, kind="movie", tmdb_id=7, title="片", original_title="M", poster_path="/p.jpg"
    )
    remote = MediaBrief.from_model(item)
    assert remote.poster_url and remote.poster_url.endswith("/original/p.jpg")
    local = MediaBrief.from_model(item, ("7/poster.jpg", None, None))
    assert local.poster_url and local.poster_url.startswith("/images/assets/7/poster.jpg?v=")


@pytest.mark.asyncio
async def test_push_image_prefers_local_asset(db, tmp_path):
    from movieclaw_api.services.channel_push import local_push_image, tmdb_push_image_url
    from movieclaw_api.services.media_scrape import assets_root

    async with db.session() as session:
        item = MediaItem(
            kind="movie", tmdb_id=9, title="片", original_title="M", backdrop_path="/bd.jpg"
        )
        session.add(item)
        await session.flush()
        session.add(MediaMetadata(media_item_id=item.id, backdrop_file=f"{item.id}/backdrop.jpg"))
        await session.commit()
        item_id = item.id
    asset = assets_root() / str(item_id) / "backdrop.jpg"
    asset.parent.mkdir(parents=True)
    asset.write_bytes(_jpeg())

    url = tmdb_push_image_url("/bd.jpg", None)
    assert url is not None
    local = await local_push_image(url)
    assert local is not None and local.resolve() == asset.resolve()
    assert await local_push_image(tmdb_push_image_url("/other.jpg", None) or "") is None

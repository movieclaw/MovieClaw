"""官方 Kotlin SDK 的解码契约（#1185）。

jellyfin-sdk-kotlin 生成的模型里，**没有默认值的属性缺键就抛 SerializationException**，
枚举收到未知值同样致命，整条响应作废，界面上只剩一句 "Deserialization failed"
（Flow 等基于这个 SDK 的客户端）。服务端返回 200、客户端打不开，日志里看不出问题。

这里走真实 HTTP，把线上常见的数据形态（工作室、章节、外挂/内封/图形字幕、strm 多版本）
喂给各个出口，再按 SDK 的必填表逐层校验。必填表只认模型有没有默认值：多余的键 SDK 会
忽略，可空的键缺了也没事，所以另有用例守住「可空字段照旧省略」，别用假值把未知填成事实。
"""

from __future__ import annotations

import asyncio
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from jellyfin.helpers import jf_login
from movieclaw_api.core.config import get_settings
from movieclaw_db.engine import dispose_db, get_database, init_db
from movieclaw_db.models import Library, LibraryFile, MediaItem, MediaMetadata
from movieclaw_jellyfin.ids import (
    decode_guid,
    episode_guid,
    item_guid,
    library_guid,
    person_guid,
    season_guid,
)

# jellyfin-sdk-kotlin v1.9.4 的 jellyfin-model/.../kotlin-generated 模型里无默认值的属性，
# 只收本层会输出的类型。升级对照时重新摘一遍即可（IsOriginal 是 1.9 新增）。
SDK_REQUIRED: dict[str, frozenset[str]] = {
    "BaseItemDto": frozenset({"Id", "Type"}),
    "MediaSourceInfo": frozenset(
        {
            "Protocol",
            "Type",
            "IsRemote",
            "ReadAtNativeFramerate",
            "IgnoreDts",
            "IgnoreIndex",
            "GenPtsInput",
            "SupportsTranscoding",
            "SupportsDirectStream",
            "SupportsDirectPlay",
            "IsInfiniteStream",
            "RequiresOpening",
            "RequiresClosing",
            "RequiresLooping",
            "SupportsProbing",
            "TranscodingSubProtocol",
            "HasSegments",
        }
    ),
    "MediaStream": frozenset(
        {
            "IsInterlaced",
            "IsDefault",
            "IsForced",
            "IsHearingImpaired",
            "IsOriginal",
            "Type",
            "Index",
            "IsExternal",
            "IsTextSubtitleStream",
            "SupportsExternalStream",
        }
    ),
    "ChapterInfo": frozenset({"StartPositionTicks", "ImageDateModified"}),
    "NameGuidPair": frozenset({"Id"}),
    "BaseItemPerson": frozenset({"Id"}),
    "UserItemDataDto": frozenset(
        {"PlaybackPositionTicks", "PlayCount", "IsFavorite", "Played", "Key", "ItemId"}
    ),
    "SearchHint": frozenset({"ItemId", "Id", "Name", "Type", "Artists"}),
}
# MediaStreamProtocol 的全部成员。这个字段无默认值，coerceInputValues 也救不回未知值。
STREAM_PROTOCOLS = {"http", "hls"}
# MediaSourceInfo.Bitrate / MediaStream.BitRate 是 Int?，超范围的数字同样解码失败
INT32_MAX = 2**31 - 1
# ffprobe 给蓝光 ISO 报过的真实离谱值（那个文件实际约 93 Mbps）
ISO_BOGUS_BIT_RATE = 45_750_061_748

FULL_FIELDS = "MediaSources,MediaStreams,Studios,Chapters,People"
MIN_DATE = "0001-01-01T00:00:00.0000000Z"


def _missing(model: str, value: dict, where: str) -> list[str]:
    absent = SDK_REQUIRED[model] - value.keys()
    return [f"{where}: {model} 缺 {sorted(absent)}"] if absent else []


def _source_problems(source: dict, where: str) -> list[str]:
    problems = _missing("MediaSourceInfo", source, where)
    if source.get("TranscodingSubProtocol") not in STREAM_PROTOCOLS:
        problems.append(f"{where}: TranscodingSubProtocol={source.get('TranscodingSubProtocol')!r}")
    if source.get("Bitrate", 0) > INT32_MAX:
        problems.append(f"{where}: Bitrate={source['Bitrate']} 超出 Int")
    for i, stream in enumerate(source.get("MediaStreams", [])):
        problems += _missing("MediaStream", stream, f"{where}.MediaStreams[{i}]")
        if stream.get("BitRate", 0) > INT32_MAX:
            problems.append(f"{where}.MediaStreams[{i}]: BitRate={stream['BitRate']} 超出 Int")
    return problems


def _item_problems(dto: dict, where: str = "$") -> list[str]:
    """按 SDK 模型的嵌套关系校验一个 BaseItemDto，把所有缺口一次报全。"""
    problems = _missing("BaseItemDto", dto, where)
    for i, source in enumerate(dto.get("MediaSources", [])):
        problems += _source_problems(source, f"{where}.MediaSources[{i}]")
    nested = {
        "MediaStreams": "MediaStream",
        "Chapters": "ChapterInfo",
        "Studios": "NameGuidPair",
        "People": "BaseItemPerson",
    }
    for key, model in nested.items():
        for i, row in enumerate(dto.get(key, [])):
            problems += _missing(model, row, f"{where}.{key}[{i}]")
    if "UserData" in dto:
        problems += _missing("UserItemDataDto", dto["UserData"], f"{where}.UserData")
    return problems


@pytest.fixture
def rich(seeded: dict) -> dict:
    """在 seeded 上补齐线上常见的数据：工作室、章节（有图/无图）、外挂/内封/图形字幕。"""

    async def _go() -> None:
        init_db(get_settings().database_url, echo=False)
        async with get_database().session() as session:
            for library in (await session.execute(select(Library))).scalars():
                library.extract_chapter_images = True
            items = {row.id: row for row in (await session.execute(select(MediaItem))).scalars()}
            for meta in (await session.execute(select(MediaMetadata))).scalars():
                is_movie = items[meta.media_item_id].kind == "movie"
                meta.studios = ["Legendary Pictures", "Syncopy"] if is_movie else ["AMC"]
            chapters = [
                {"start_ms": 0, "end_ms": 600_000, "title": "Opening"},
                {"start_ms": 600_000, "end_ms": None, "title": None},
            ]
            for row in (await session.execute(select(LibraryFile))).scalars():
                if row.file_path.endswith(".strm"):
                    continue
                row.chapters = chapters
                if Path(row.file_path).name == "S01E02.mkv":
                    row.bit_rate = ISO_BOGUS_BIT_RATE
                if Path(row.file_path).name == "Inception.2010.2160p.mkv":
                    row.chapter_images = [{"start_ms": 600_000, "image": "chapters/1.jpg"}]
                    row.external_subtitles = [
                        {
                            "filename": "Inception.chs.srt",
                            "format": "srt",
                            "language": "chi",
                            "title": None,
                            "default": True,
                            "forced": False,
                            "sdh": True,
                        }
                    ]
                    row.subtitle_streams = [
                        *(row.subtitle_streams or []),
                        {
                            "codec": "hdmv_pgs_subtitle",
                            "language": "eng",
                            "title": None,
                            "forced": False,
                            "default": False,
                        },
                    ]
            await session.commit()
        await dispose_db()

    asyncio.run(_go())
    return seeded


@pytest.fixture
def client(rich: dict, client: TestClient) -> TestClient:
    """覆盖 conftest 的同名夹具：rich 排在前面，保证先改库、再起应用。"""
    return client


@pytest.fixture
def auth(client: TestClient) -> dict[str, str]:
    return {"ApiKey": jf_login(client)}


def _get(client: TestClient, auth: dict[str, str], url: str, **params: str) -> dict:
    resp = client.get(url, params={**auth, **params})
    assert resp.status_code == 200, resp.text
    return resp.json()


def test_movie_detail_satisfies_sdk(client: TestClient, rich: dict, auth: dict[str, str]) -> None:
    dto = _get(client, auth, f"/Items/{item_guid(rich['movie'])}")
    # 先确认这些数据真的出现了，否则空列表会让校验自然通过
    assert dto["Studios"] and dto["Chapters"] and dto["People"] and dto["MediaStreams"]
    assert len(dto["MediaSources"]) == 2  # 本地文件 + strm
    assert _item_problems(dto) == []


def test_series_detail_satisfies_sdk(client: TestClient, rich: dict, auth: dict[str, str]) -> None:
    """剧集详情没有 MediaSources，单靠 Studios[].Id 缺失就打不开（issue 里的老友记）。"""
    dto = _get(client, auth, f"/Items/{item_guid(rich['show'])}")
    assert dto["Studios"] and "MediaSources" not in dto
    assert _item_problems(dto) == []


def test_season_and_episode_detail_satisfy_sdk(
    client: TestClient, rich: dict, auth: dict[str, str]
) -> None:
    season = _get(client, auth, f"/Items/{season_guid(rich['show'], 1)}")
    assert _item_problems(season) == []

    episode = _get(client, auth, f"/Items/{episode_guid(rich['show'], 1, 1)}")
    assert episode["MediaSources"] and episode["Chapters"]
    assert _item_problems(episode) == []


def test_lists_with_requested_fields_satisfy_sdk(
    client: TestClient, rich: dict, auth: dict[str, str]
) -> None:
    """列表默认不带这些字段，客户端点名要时才出，同样不能缺。"""
    movie = item_guid(rich["movie"])
    show = item_guid(rich["show"])
    episode = episode_guid(rich["show"], 1, 1)
    source_id = _get(client, auth, f"/Items/{movie}")["MediaSources"][0]["Id"]

    # 造出「继续看」和「下一集」的内容：空结果校验不到任何东西
    stopped = client.post(
        "/Sessions/Playing/Stopped",
        params=auth,
        json={"ItemId": movie, "MediaSourceId": source_id, "PositionTicks": 6_000_000_000},
    )
    assert stopped.status_code == 204, stopped.text
    assert client.post(f"/UserPlayedItems/{episode}", params=auth).status_code == 200

    pages = {
        "电影库": ("/Items", {"parentId": library_guid(rich["movie_lib"])}),
        "剧集库": ("/Items", {"parentId": library_guid(rich["tv_lib"])}),
        "分集": (f"/Shows/{show}/Episodes", {}),
        "继续看": ("/UserItems/Resume", {}),
        "下一集": ("/Shows/NextUp", {}),
    }
    for name, (url, params) in pages.items():
        items = _get(client, auth, url, fields=FULL_FIELDS, **params)["Items"]
        assert items, f"{name} 为空，校验不到东西"
        for i, dto in enumerate(items):
            assert _item_problems(dto, f"{name}[{i}]") == []

    latest = client.get("/Items/Latest", params={**auth, "fields": FULL_FIELDS}).json()
    assert latest
    for i, dto in enumerate(latest):
        assert _item_problems(dto, f"最新[{i}]") == []


@pytest.mark.parametrize("kind", ["movie", "episode"])
def test_playback_info_satisfies_sdk(
    client: TestClient, rich: dict, auth: dict[str, str], kind: str
) -> None:
    """详情页能开还不够，起播前的 PlaybackInfo 解不出来一样放不了。"""
    guid = item_guid(rich["movie"]) if kind == "movie" else episode_guid(rich["show"], 1, 1)
    resp = client.post(f"/Items/{guid}/PlaybackInfo", params=auth, json={})
    assert resp.status_code == 200, resp.text
    sources = resp.json()["MediaSources"]
    assert sources
    for i, source in enumerate(sources):
        assert _source_problems(source, f"$.MediaSources[{i}]") == []


def test_search_hints_satisfy_sdk(client: TestClient, rich: dict, auth: dict[str, str]) -> None:
    """Artists 对我们没有意义，但它是 SDK 里无默认值的列表，真 Jellyfin 也恒输出空数组。"""
    for term, expected_type in (("盗梦", "Movie"), ("诺兰", "Person")):
        hints = _get(client, auth, "/Search/Hints", searchTerm=term)["SearchHints"]
        assert any(hint["Type"] == expected_type for hint in hints)
        for i, hint in enumerate(hints):
            assert _missing("SearchHint", hint, f"$.SearchHints[{i}]") == []


def test_stream_flags_report_real_subtitle_delivery(
    client: TestClient, rich: dict, auth: dict[str, str]
) -> None:
    """五个布尔不是一律 false：文本字幕要如实报，图形字幕和音视频才是 false。"""
    dto = _get(client, auth, f"/Items/{item_guid(rich['movie'])}")
    by_codec = {stream.get("Codec"): stream for stream in dto["MediaSources"][0]["MediaStreams"]}

    for codec in ("hevc", "aac", "hdmv_pgs_subtitle"):
        assert by_codec[codec]["IsTextSubtitleStream"] is False
        assert by_codec[codec]["SupportsExternalStream"] is False

    embedded_text = next(
        stream
        for stream in dto["MediaSources"][0]["MediaStreams"]
        if stream["Type"] == "Subtitle" and stream["Codec"] == "subrip" and not stream["IsExternal"]
    )
    assert embedded_text["IsTextSubtitleStream"] is True
    assert embedded_text["SupportsExternalStream"] is True

    external = next(s for s in dto["MediaSources"][0]["MediaStreams"] if s["IsExternal"])
    assert external["IsTextSubtitleStream"] is True
    assert external["SupportsExternalStream"] is True
    assert external["IsHearingImpaired"] is True  # 台账里的事实不能被默认值盖掉

    assert by_codec["hevc"]["IsInterlaced"] is False
    assert by_codec["hevc"]["IsOriginal"] is False


def test_chapter_image_date_uses_min_value_without_image(
    client: TestClient, rich: dict, auth: dict[str, str]
) -> None:
    chapters = _get(client, auth, f"/Items/{item_guid(rich['movie'])}")["Chapters"]
    assert "ImageTag" not in chapters[0]
    assert chapters[0]["ImageDateModified"] == MIN_DATE  # 真 Jellyfin 无图时的 DateTime.MinValue
    assert chapters[1]["ImageTag"]
    assert chapters[1]["ImageDateModified"] != MIN_DATE


def test_bit_rate_beyond_int32_is_reported_as_unknown(
    client: TestClient, rich: dict, auth: dict[str, str]
) -> None:
    """协议里码率是 32 位 int，一个离谱值能让整页列表解码失败：超范围按未知省略，正常值不动。"""
    bogus = _get(client, auth, f"/Items/{episode_guid(rich['show'], 1, 2)}")["MediaSources"][0]
    assert "Bitrate" not in bogus
    assert all("BitRate" not in stream for stream in bogus["MediaStreams"])

    movie = _get(client, auth, f"/Items/{item_guid(rich['movie'])}")["MediaSources"][0]
    assert movie["Bitrate"] == 25_000_000
    assert next(s for s in movie["MediaStreams"] if s["Type"] == "Video")["BitRate"] == 25_000_000


def test_studio_ids_are_stable_and_never_break_routes(
    client: TestClient, rich: dict, auth: dict[str, str]
) -> None:
    """工作室没有实体：GUID 由名字派生、同名恒同；客户端拿它来请求时是 404，不能是 500。"""
    movie = _get(client, auth, f"/Items/{item_guid(rich['movie'])}")
    studios = {row["Name"]: row["Id"] for row in movie["Studios"]}
    assert len(set(studios.values())) == 2
    again = _get(client, auth, f"/Items/{item_guid(rich['movie'])}")["Studios"]
    assert {row["Name"]: row["Id"] for row in again} == studios

    # Legendary Pictures 的 md5 首字节高位为 1：载荷取满 64 位时这里会 OverflowError
    studio = studios["Legendary Pictures"]
    assert decode_guid(studio) is not None
    assert client.get(f"/Items/{studio}", params=auth).status_code == 404
    assert client.get(f"/Items/{studio}/Images/Primary", params=auth).status_code == 404
    assert client.get("/Items", params={**auth, "parentId": studio}).status_code == 404
    assert client.post(f"/Items/{studio}/PlaybackInfo", params=auth, json={}).status_code == 404
    assert client.post(f"/UserFavoriteItems/{studio}", params=auth).status_code == 404
    assert client.post(f"/UserPlayedItems/{studio}", params=auth).status_code == 404


def test_nullable_fields_stay_omitted(client: TestClient, rich: dict, auth: dict[str, str]) -> None:
    """可空字段缺了 SDK 不报错，别为了「看着齐」用假值填：0 个子项、-1 字幕都是错误的事实。"""
    series = _get(client, auth, "/Items", parentId=library_guid(rich["tv_lib"]))["Items"][0]
    assert "ChildCount" not in series and "RecursiveItemCount" not in series

    movie = _get(client, auth, f"/Items/{item_guid(rich['movie'])}")
    local, strm = movie["MediaSources"]
    # -1 是「用户明确不要字幕」（docs/design/jellyfin-compat.md 6.2），浏览态没有这个语义
    assert "DefaultSubtitleStreamIndex" not in local
    # strm 没探测过：未知就是未知，不是 0
    assert "Size" not in strm and "Bitrate" not in strm

    # 这些字段官方模型里根本没有
    for key in ("IsMissing", "IsUnaired", "LockedData", "SupportsSync", "VideoRange"):
        assert key not in movie

    person = _get(client, auth, f"/Items/{person_guid(rich['dicaprio'])}")
    assert "ChildCount" not in person

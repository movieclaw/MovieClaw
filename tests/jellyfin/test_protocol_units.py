"""协议基元单测：GUID 编解码、Authorization 头状态机、进度阈值规则。"""

from __future__ import annotations

from movieclaw_jellyfin.authhdr import parse_authorization_header
from movieclaw_jellyfin.ids import (
    EntityKind,
    decode_guid,
    episode_guid,
    item_guid,
    library_guid,
    media_source_guid,
    normalize_guid,
    season_guid,
    studio_guid,
)
from movieclaw_playback.progress import resolve_progress


class TestGuidCodec:
    def test_roundtrip_all_kinds(self) -> None:
        cases = [
            (library_guid(3), EntityKind.LIBRARY, 3, 0, 0),
            (item_guid(42), EntityKind.ITEM, 42, 0, 0),
            (season_guid(42, 2), EntityKind.SEASON, 42, 2, 0),
            (episode_guid(42, 2, 13), EntityKind.EPISODE, 42, 2, 13),
            (media_source_guid(7), EntityKind.MEDIA_SOURCE, 7, 0, 0),
        ]
        for guid, kind, entity_id, season, episode in cases:
            assert len(guid) == 32 and guid == guid.lower()
            ref = decode_guid(guid)
            assert ref is not None
            assert (ref.kind, ref.entity_id, ref.season, ref.episode) == (
                kind,
                entity_id,
                season,
                episode,
            )

    def test_studio_guid_derives_from_name_and_fits_sqlite_integer(self) -> None:
        assert studio_guid("Marvel Studios") == studio_guid("  marvel studios ")
        assert studio_guid("NBC") != studio_guid("HBO")
        # 这些名字的 md5 首字节高位为 1：载荷取满 8 字节会超出 SQLite 的有符号整数范围
        for name in ("Legendary Pictures", "A24", "Universal Pictures"):
            ref = decode_guid(studio_guid(name))
            assert ref is not None
            assert ref.kind is EntityKind.STUDIO
            assert ref.entity_id < 2**63

    def test_accepts_dashed_and_uppercase(self) -> None:
        guid = episode_guid(5, 1, 2)
        dashed = f"{guid[:8]}-{guid[8:12]}-{guid[12:16]}-{guid[16:20]}-{guid[20:]}"
        assert decode_guid(dashed.upper()) == decode_guid(guid)

    def test_rejects_foreign_guid(self) -> None:
        # 魔数不匹配（随机 GUID）→ None（调用方 404）
        assert decode_guid("a" * 32) is None
        assert normalize_guid("not-a-guid") is None


class TestAuthorizationHeader:
    def test_standard_header(self) -> None:
        info = parse_authorization_header(
            'MediaBrowser Client="Infuse", Device="Apple TV", '
            'DeviceId="abc-123", Version="8.2", Token="deadbeef"'
        )
        assert info is not None
        assert info.client == "Infuse"
        assert info.device == "Apple TV"
        assert info.device_id == "abc-123"
        assert info.version == "8.2"
        assert info.token == "deadbeef"
        assert info.has_identity

    def test_comma_inside_quotes(self) -> None:
        info = parse_authorization_header('MediaBrowser Device="Living, Room", Client=x')
        assert info is not None
        assert info.device == "Living, Room"
        assert info.client == "x"

    def test_url_decoded_values(self) -> None:
        info = parse_authorization_header('MediaBrowser Device="Apple%20TV", Client=a')
        assert info is not None and info.device == "Apple TV"

    def test_keys_case_sensitive(self) -> None:
        info = parse_authorization_header('MediaBrowser client="x", DeviceId="y"')
        assert info is not None
        assert info.client == ""  # 小写 client 不被识别（对齐 Jellyfin）
        assert info.device_id == "y"

    def test_scheme_case_insensitive_and_emby(self) -> None:
        assert parse_authorization_header('mediabrowser Token="t"').token == "t"
        assert parse_authorization_header('Emby Token="t"').token == "t"

    def test_header_without_space_is_invalid(self) -> None:
        assert parse_authorization_header("MediaBrowser") is None
        assert parse_authorization_header("Bearer abc") is None


class TestProgressRules:
    RUNTIME = 60 * 60 * 1000  # 1 小时

    def test_below_min_pct_resets_position_keeps_played(self) -> None:
        out = resolve_progress(self.RUNTIME // 100, self.RUNTIME, currently_played=True)
        assert out.position_ms == 0 and out.played is True
        out = resolve_progress(self.RUNTIME // 100, self.RUNTIME, currently_played=False)
        assert out.position_ms == 0 and out.played is False

    def test_above_max_pct_marks_played(self) -> None:
        out = resolve_progress(int(self.RUNTIME * 0.95), self.RUNTIME, currently_played=False)
        assert out.position_ms == 0 and out.played is True

    def test_near_end_marks_played(self) -> None:
        out = resolve_progress(self.RUNTIME - 500, self.RUNTIME, currently_played=False)
        assert out.played is True

    def test_middle_records_resume_point(self) -> None:
        pos = self.RUNTIME // 2
        out = resolve_progress(pos, self.RUNTIME, currently_played=False)
        assert out.position_ms == pos and out.played is False

    def test_short_video_middle_marks_played(self) -> None:
        # 5 分钟以内短片：过了开头直接算看完（不是"未开始"）
        runtime = 200 * 1000
        out = resolve_progress(runtime // 2, runtime, currently_played=False)
        assert out.position_ms == 0 and out.played is True

    def test_no_runtime_marks_played(self) -> None:
        out = resolve_progress(1234, None, currently_played=False)
        assert out.played is True

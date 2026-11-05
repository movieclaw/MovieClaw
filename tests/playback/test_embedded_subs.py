"""内封字幕轨抽取测试（docs/design/web-player.md §6.2）。

PT 片源的字幕绝大多数是内封的，只服务外挂等于对大部分片子没字幕——所以这条
路径的正确性直接决定「能不能看」。

格式判定与缓存新鲜度是纯逻辑，进 CI 默认门禁；真抽取标 ``integration``，
用 ffmpeg 合成带字幕的样本，验证 **ASS 保住样式、文本轨转 SRT**。
"""

from __future__ import annotations

import asyncio
import shutil
import subprocess
from pathlib import Path

import pytest
from disc_fixture import Clip, make_bdmv, mpls_bytes, sup_events, sup_presentations

# 抽取本体住在中性的 media_extract（播放器与 AI 字幕生成共用同一份产物，
# issue #432）；embedded_subs 只剩播放侧的包装与内嵌字体。进程替身因此分两处：
# 字幕抽取打 media_extract，字体抽取打 embedded_subs。
import movieclaw_api.services.media_extract as media_extract
from movieclaw_api.services.library.bluray import DISC_PLAYLIST_VERSION
from movieclaw_api.services.playback.embedded_subs import (
    embedded_subtitle_format,
    embedded_track_codec,
    extract_embedded_subtitle,
    extract_embedded_subtitle_async,
)
from movieclaw_db.models import FileSource, FileState, LibraryFile


def make_file(tmp_path: Path, streams: list[dict] | None, *, path: Path | None = None):
    return LibraryFile(
        id=7,
        library_id=1,
        media_item_id=1,
        file_path=str(path or (tmp_path / "movie.mkv")),
        size_bytes=1,
        source=FileSource.SCANNED,
        state=FileState.IN_PLACE,
        container="mkv",
        subtitle_streams=streams,
    )


# ---------------------------------------------------------------------------
# 格式判定：ASS 保原样，文本转 SRT，图形轨一律拒绝
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("codec", ["ass", "ssa", "ASS"])
def test_ass_tracks_keep_their_format(codec):
    """转成 VTT 就丢掉特效与排版，番剧字幕直接崩。"""
    assert embedded_subtitle_format(codec) == "ass"


@pytest.mark.parametrize("codec", ["subrip", "srt", "mov_text", "text", "webvtt"])
def test_text_tracks_normalize_to_srt(codec):
    assert embedded_subtitle_format(codec) == "srt"


@pytest.mark.parametrize("codec", ["hdmv_pgs_subtitle", "pgssub", "PGS"])
def test_pgs_tracks_extract_as_sup(codec):
    """蓝光位图轨抽成 .sup 交前端 libbitsub 渲染（Jellyfin 10.9+ 同路）。"""
    assert embedded_subtitle_format(codec) == "sup"


@pytest.mark.parametrize("codec", ["dvd_subtitle", "", None, "xyz"])
def test_unknown_tracks_are_refused(codec):
    """宁可少一条轨也不烧录——烧录会把任何档位拖进全转码。"""
    assert embedded_subtitle_format(codec) is None


# ---------------------------------------------------------------------------
# 轨定位：数组下标即 ffmpeg 的 0:s:<k>
# ---------------------------------------------------------------------------


def test_track_codec_comes_from_the_ledger(tmp_path):
    file = make_file(tmp_path, [{"codec": "ass"}, {"codec": "subrip"}])
    assert embedded_track_codec(file, 0) == "ass"
    assert embedded_track_codec(file, 1) == "subrip"


@pytest.mark.parametrize("index", [-1, 2, 99])
def test_out_of_range_track_is_none(tmp_path, index):
    file = make_file(tmp_path, [{"codec": "ass"}, {"codec": "subrip"}])
    assert embedded_track_codec(file, index) is None


def test_unprobed_file_has_no_tracks(tmp_path):
    """subtitle_streams=None 表示没探测过，不能当成「没有字幕」。"""
    assert embedded_track_codec(make_file(tmp_path, None), 0) is None


def test_malformed_ledger_entry_does_not_crash(tmp_path):
    file = make_file(tmp_path, ["不是字典", {"codec": "ass"}])
    assert embedded_track_codec(file, 0) is None
    assert embedded_track_codec(file, 1) == "ass"


def test_unsupported_track_never_touches_ffmpeg(tmp_path, monkeypatch):
    """格式判定要在起进程之前完成——VobSub 轨不该白白读一遍整个容器。"""
    called = []
    monkeypatch.setattr(
        "movieclaw_api.services.media_extract.subprocess.Popen",
        lambda *a, **k: called.append(a),
    )
    file = make_file(tmp_path, [{"codec": "dvd_subtitle"}])
    assert extract_embedded_subtitle(file, 0) is None
    assert called == []


def test_missing_video_file_is_none(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    file = make_file(tmp_path, [{"codec": "subrip"}], path=tmp_path / "gone.mkv")
    assert extract_embedded_subtitle(file, 0) is None


@pytest.mark.asyncio
async def test_async_extraction_cancels_ffmpeg_and_removes_partial_file(tmp_path, monkeypatch):
    """播放器放弃字幕请求时，PGS 抽取进程和临时文件都必须回收（宽限期过后，这里设成 0）。"""
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(media_extract, "_ABANDON_GRACE_SECONDS", 0)
    video = tmp_path / "movie.mkv"
    video.write_bytes(b"source")
    file = make_file(tmp_path, [{"codec": "hdmv_pgs_subtitle"}], path=video)

    started = asyncio.Event()
    killed = asyncio.Event()
    commands: list[tuple[tuple[object, ...], dict[str, object]]] = []

    class HangingProcess:
        pid = 12345
        returncode: int | None = None

        async def communicate(self):
            started.set()
            await killed.wait()
            self.returncode = -15
            return b"", b""

    process = HangingProcess()

    async def fake_create_subprocess_exec(*argv, **kwargs):
        commands.append((argv, kwargs))
        return process

    def fake_signal(_pid, _sig):
        process.returncode = -15
        killed.set()

    monkeypatch.setattr(media_extract.shutil, "which", lambda _name: "/fake/ffmpeg")
    monkeypatch.setattr(
        media_extract.asyncio, "create_subprocess_exec", fake_create_subprocess_exec
    )
    monkeypatch.setattr(media_extract, "_signal_process_group", fake_signal)

    pending = asyncio.create_task(extract_embedded_subtitle_async(file, 0))
    await started.wait()
    pending.cancel()
    with pytest.raises(asyncio.CancelledError):
        await pending

    await asyncio.wait_for(killed.wait(), timeout=1)
    for _ in range(3):
        await asyncio.sleep(0)
    cache = tmp_path / "data" / "cache" / "playback-subs"
    leftovers = list(cache.glob("*")) if cache.exists() else []
    assert leftovers == []
    assert commands and "-nostdin" in commands[0][0]


# ---------------------------------------------------------------------------
# 真抽取
# ---------------------------------------------------------------------------

integration = pytest.mark.skipif(
    shutil.which("ffmpeg") is None, reason="需要系统 ffmpeg"
)


def _run(argv: list[str]) -> None:
    proc = subprocess.run(argv, capture_output=True, timeout=180)
    assert proc.returncode == 0, proc.stderr.decode(errors="replace")[-1500:]


@pytest.fixture
def video_with_subs(tmp_path):
    """合成一个内封 ASS + 内封 SRT 双字幕轨的 MKV。"""
    ass = tmp_path / "styled.ass"
    ass.write_text(
        "[Script Info]\nScriptType: v4.00+\n\n"
        "[V4+ Styles]\n"
        "Format: Name, Fontname, Fontsize, PrimaryColour\n"
        "Style: Karaoke,Arial,72,&H00FF00FF\n\n"
        "[Events]\n"
        "Format: Layer, Start, End, Style, Text\n"
        "Dialogue: 0,0:00:00.50,0:00:03.00,Karaoke,{\\pos(320,240)}特效字幕\n",
        encoding="utf-8",
    )
    srt = tmp_path / "plain.srt"
    srt.write_text("1\n00:00:00,500 --> 00:00:03,000\n纯文本字幕\n\n", encoding="utf-8")
    video = tmp_path / "movie.mkv"
    _run([
        "ffmpeg", "-v", "error",
        "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=10:duration=4",
        "-i", str(ass), "-i", str(srt),
        "-map", "0:v", "-map", "1:s", "-map", "2:s",
        "-c:v", "libx264", "-preset", "ultrafast",
        "-c:s:0", "ass", "-c:s:1", "srt",
        "-y", str(video),
    ])
    return video


@integration
@pytest.mark.integration
def test_extracts_ass_track_preserving_styles(tmp_path, monkeypatch, video_with_subs):
    """ASS 必须原样 copy 出来——样式段和定位标签都得在，否则 JASSUB 渲染出的
    就是一行没有排版的白字。"""
    monkeypatch.chdir(tmp_path)
    file = make_file(tmp_path, [{"codec": "ass"}, {"codec": "subrip"}], path=video_with_subs)
    ref = extract_embedded_subtitle(file, 0)
    assert ref is not None and ref.format == "ass"
    text = ref.path.read_text(encoding="utf-8")
    assert "[V4+ Styles]" in text
    assert "Karaoke" in text
    assert "\\pos(320,240)" in text
    assert "特效字幕" in text


@integration
@pytest.mark.integration
def test_extracts_text_track_as_srt(tmp_path, monkeypatch, video_with_subs):
    monkeypatch.chdir(tmp_path)
    file = make_file(tmp_path, [{"codec": "ass"}, {"codec": "subrip"}], path=video_with_subs)
    ref = extract_embedded_subtitle(file, 1)
    assert ref is not None and ref.format == "srt"
    text = ref.path.read_text(encoding="utf-8")
    assert "纯文本字幕" in text
    assert "-->" in text


@integration
@pytest.mark.integration
def test_second_call_reuses_the_cache(tmp_path, monkeypatch, video_with_subs):
    """抽取要通读整个容器，不能每次点开字幕都重来一遍。"""
    monkeypatch.chdir(tmp_path)
    file = make_file(tmp_path, [{"codec": "ass"}], path=video_with_subs)
    first = extract_embedded_subtitle(file, 0)
    assert first is not None
    stamp = first.path.stat().st_mtime_ns

    calls = []
    real_popen = subprocess.Popen
    monkeypatch.setattr(
        "movieclaw_api.services.media_extract.subprocess.Popen",
        lambda *a, **k: (calls.append(a), real_popen(*a, **k))[1],
    )
    second = extract_embedded_subtitle(file, 0)
    assert second is not None and second.path == first.path
    assert calls == [], "命中缓存却又起了一次 ffmpeg"
    assert second.path.stat().st_mtime_ns == stamp


@integration
@pytest.mark.integration
def test_failed_extraction_leaves_no_partial_file(tmp_path, monkeypatch, video_with_subs):
    """失败留下的非空残片会被下次的新鲜度判断误认成成功产物。"""
    monkeypatch.chdir(tmp_path)
    # 台账说有第 3 条轨，实际没有——ffmpeg 会以非零码退出
    file = make_file(
        tmp_path,
        [{"codec": "ass"}, {"codec": "subrip"}, {"codec": "subrip"}],
        path=video_with_subs,
    )
    assert extract_embedded_subtitle(file, 2) is None
    cache = tmp_path / "data" / "cache" / "playback-subs"
    leftovers = list(cache.glob("*")) if cache.exists() else []
    assert leftovers == [], f"留下了残片：{leftovers}"


# ---------------------------------------------------------------------------
# 内嵌字体：ASS 特效字幕的另一半
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("SourceHanSans.ttf", "SourceHanSans.ttf"),
        ("Font Name.otf", "Font Name.otf"),
        ("字体.ttf", "字体.ttf"),
        # 文件名来自媒体文件本体，是不可信输入——只取 basename
        ("../../etc/passwd.ttf", "passwd.ttf"),
        ("/abs/evil.ttf", "evil.ttf"),
        ("..\\\\windows\\\\evil.ttf", None),  # 反斜杠不在白名单里
        ("script.sh", None),  # 不是字体扩展名
        ("payload.ttf.sh", None),
        ("", None),
        ("x" * 200 + ".ttf", None),  # 超长
    ],
)
def test_font_name_sanitizing(raw, expected):
    from movieclaw_api.services.playback.embedded_subs import safe_font_name

    assert safe_font_name(raw) == expected


def test_font_extraction_without_ffmpeg_is_empty(tmp_path, monkeypatch):
    from movieclaw_api.services.playback.embedded_subs import extract_embedded_fonts

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(
        "movieclaw_api.services.playback.embedded_subs.shutil.which", lambda _n: None
    )
    assert extract_embedded_fonts(make_file(tmp_path, None)) == []


@integration
@pytest.mark.integration
def test_extracts_attached_fonts(tmp_path, monkeypatch):
    """番剧的 ASS 把字体作为附件放在 MKV 里；不抽出来字幕会回退成默认字体。"""
    from movieclaw_api.services.playback.embedded_subs import (
        extract_embedded_fonts,
        font_cache_dir,
    )

    system_font = next(Path("/usr/share/fonts").rglob("*.ttf"), None)
    if system_font is None:
        pytest.skip("本机没有可用作附件的 ttf 字体")

    video = tmp_path / "anime.mkv"
    _run([
        "ffmpeg", "-v", "error",
        "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=10:duration=2",
        "-attach", str(system_font),
        "-metadata:s:t:0", "mimetype=application/x-truetype-font",
        "-map", "0:v", "-c:v", "libx264", "-preset", "ultrafast",
        "-y", str(video),
    ])
    monkeypatch.chdir(tmp_path)
    file = make_file(tmp_path, [{"codec": "ass"}], path=video)
    names = extract_embedded_fonts(file)
    assert names == [system_font.name]
    dumped = font_cache_dir(file.id) / names[0]
    assert dumped.is_file()
    # 抽出来的必须是有效字体，否则 JASSUB 加载会静默失败
    assert dumped.read_bytes()[:4] in (b"\x00\x01\x00\x00", b"OTTO", b"true", b"ttcf")


@integration
@pytest.mark.integration
def test_second_font_extraction_reuses_cache(tmp_path, monkeypatch):
    from movieclaw_api.services.playback.embedded_subs import extract_embedded_fonts

    system_font = next(Path("/usr/share/fonts").rglob("*.ttf"), None)
    if system_font is None:
        pytest.skip("本机没有可用作附件的 ttf 字体")
    video = tmp_path / "anime.mkv"
    _run([
        "ffmpeg", "-v", "error",
        "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=10:duration=2",
        "-attach", str(system_font),
        "-metadata:s:t:0", "mimetype=application/x-truetype-font",
        "-map", "0:v", "-c:v", "libx264", "-preset", "ultrafast",
        "-y", str(video),
    ])
    monkeypatch.chdir(tmp_path)
    file = make_file(tmp_path, [{"codec": "ass"}], path=video)
    assert extract_embedded_fonts(file)

    calls = []
    monkeypatch.setattr(
        "movieclaw_api.services.playback.embedded_subs.subprocess.run",
        lambda *a, **k: calls.append(a),
    )
    assert extract_embedded_fonts(file)
    assert calls == [], "命中缓存却又读了一遍容器"


@integration
@pytest.mark.integration
def test_video_without_attachments_is_remembered(tmp_path, monkeypatch):
    """没有字体的片子也要记住结论，否则每次点开 ASS 都白读一遍整个容器。"""
    from movieclaw_api.services.playback.embedded_subs import extract_embedded_fonts

    video = tmp_path / "plain.mkv"
    _run([
        "ffmpeg", "-v", "error",
        "-f", "lavfi", "-i", "testsrc2=size=160x120:rate=10:duration=2",
        "-c:v", "libx264", "-preset", "ultrafast", "-y", str(video),
    ])
    monkeypatch.chdir(tmp_path)
    file = make_file(tmp_path, [{"codec": "ass"}], path=video)
    assert extract_embedded_fonts(file) == []

    calls = []
    monkeypatch.setattr(
        "movieclaw_api.services.playback.embedded_subs.subprocess.run",
        lambda *a, **k: calls.append(a),
    )
    assert extract_embedded_fonts(file) == []
    assert calls == []


@pytest.fixture
def video_with_pgs(tmp_path):
    """合成带真 PGS 位图轨的 MKV。ffmpeg 没有 PGS 编码器，字幕流由
    pgs_sup 按段格式手工拼出，muxer 只做流拷贝。"""
    from pgs_sup import make_sup

    sup = tmp_path / "sample.sup"
    sup.write_bytes(make_sup())
    video = tmp_path / "pgs-movie.mkv"
    _run([
        "ffmpeg", "-v", "error",
        "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=10:duration=6",
        "-f", "sup", "-i", str(sup),
        "-map", "0:v", "-map", "1:s",
        "-c:v", "libx264", "-preset", "ultrafast",
        "-c:s", "copy",
        "-y", str(video),
    ])
    return video


@integration
@pytest.mark.integration
def test_extracts_pgs_track_as_binary_sup(tmp_path, monkeypatch, video_with_pgs):
    """PGS 轨抽成 .sup：二进制原样拷贝，段魔数在、ffprobe 认得出。"""
    monkeypatch.chdir(tmp_path)
    file = make_file(tmp_path, [{"codec": "hdmv_pgs_subtitle"}], path=video_with_pgs)
    ref = extract_embedded_subtitle(file, 0)
    assert ref is not None and ref.format == "sup"
    raw = ref.path.read_bytes()
    assert raw.startswith(b"PG"), "sup 段魔数丢失——不是合法的 HDMV PGS 流"
    assert len(raw) > 100
    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-f", "sup", "-show_streams", str(ref.path)],
        capture_output=True, timeout=60,
    )
    assert b"hdmv_pgs_subtitle" in probe.stdout


# ---------------------------------------------------------------------------
# 原盘：真 m2ts、真 PGS、真 ffmpeg。时间轴是这里要守的东西（disc-playback.md §8）
# ---------------------------------------------------------------------------


def _disc_row(disc: Path, clips: list, subtitle_tracks: int, *, file_id: int = 7) -> LibraryFile:
    file = make_file(
        disc,
        [{"codec": "hdmv_pgs_subtitle"} for _ in range(subtitle_tracks)],
        path=disc,
    )
    file.id = file_id
    file.container = "bluray"
    file.disc_playlist = {
        "version": DISC_PLAYLIST_VERSION,
        "name": "00001.mpls",
        "clips": [{"id": c.clip_id, "in": c.in_time, "out": c.out_time} for c in clips],
    }
    return file


#: 夹具的音频比视频早约 20 毫秒开始，视频会话的零点也在它那里，两边一起后移：对齐看的是这个量级
_TIMELINE_TOLERANCE = 0.05


@integration
@pytest.mark.integration
@pytest.mark.asyncio
async def test_disc_subtitles_land_on_the_playlist_timeline(tmp_path, monkeypatch):
    """多剪辑：第二段接在第一段后面，只算 IN/OUT 之内；PTS 基准是什么都不影响结果。"""
    monkeypatch.chdir(tmp_path)
    clips = [
        Clip("00001", 8, 100.0, [[{"start_s": 2, "end_s": 4}], [{"start_s": 5, "end_s": 6}]]),
        Clip(
            "00002",
            20,
            500.0,
            [
                [
                    {"start_s": 2, "end_s": 3},  # IN 之前
                    {"start_s": 7, "end_s": 9},  # 播放列表 8 + (7-5) = 10～12
                    {"start_s": 17, "end_s": 19},  # OUT 之后
                ],
                [{"start_s": 8, "end_s": 10}],  # 播放列表 11～13
            ],
            in_s=5,
            out_s=15,
        ),
    ]
    disc = make_bdmv(tmp_path / "disc", clips)
    file = _disc_row(disc, clips, 2)

    first = await extract_embedded_subtitle_async(file, 0)
    assert first is not None and first.format == "sup"
    assert sup_presentations(first.path.read_bytes()) == pytest.approx(
        [2, 4, 10, 12], abs=_TIMELINE_TOLERANCE
    )
    # 第二条轨在同一趟里抽好了，不用再读一遍
    second = media_extract.cached_track(file, 1)
    assert second is not None
    assert sup_presentations(second.path.read_bytes()) == pytest.approx(
        [5, 6, 11, 13], abs=_TIMELINE_TOLERANCE
    )
    assert list((tmp_path / "data" / "cache" / "playback-subs").glob(".read-*")) == []


@integration
@pytest.mark.integration
@pytest.mark.asyncio
async def test_single_clip_disc_uses_playlist_time(tmp_path, monkeypatch):
    """单剪辑也走 concat：播放列表只用一截时按播放列表时间，不按剪辑时间。"""
    monkeypatch.chdir(tmp_path)
    clips = [Clip("00007", 12, 300.0, [[{"start_s": 6, "end_s": 8}]], in_s=4, out_s=10)]
    disc = make_bdmv(tmp_path / "disc", clips)

    track = await extract_embedded_subtitle_async(_disc_row(disc, clips, 1), 0)

    assert track is not None
    assert sup_presentations(track.path.read_bytes()) == pytest.approx(
        [2, 4], abs=_TIMELINE_TOLERANCE
    )


@integration
@pytest.mark.integration
@pytest.mark.asyncio
async def test_subtitle_cut_by_in_or_out_is_cleared_at_the_trim(tmp_path, monkeypatch):
    """字幕跨过播放列表的 IN/OUT 时，concat 只留切点内侧的包。

    清屏包落在 OUT 之后会被丢掉，不在切点补一个空显示集的话，这条字幕会一直挂到
    下一条出现。显示包落在 IN 之前同样被丢掉，切点内侧若只剩清屏，就只留这个清屏，
    不凭空补一条已经看不到的字幕。
    """
    monkeypatch.chdir(tmp_path)
    clips = [
        # 5–8 秒的字幕，播放列表只用到 6 秒：显示留下，清屏在 OUT 之外
        Clip("00001", 10, 100.0, [[{"start_s": 5, "end_s": 8}]], out_s=6),
        Clip(
            "00002",
            12,
            200.0,
            [[
                {"start_s": 0.5, "end_s": 3},  # IN=1 之前出现，清屏落在窗口里
                {"start_s": 8, "end_s": 10},  # 整段都在窗口里，接在全片第 13 秒
            ]],
            in_s=1,
        ),
    ]
    disc = make_bdmv(tmp_path / "disc", clips)

    track = await extract_embedded_subtitle_async(_disc_row(disc, clips, 1), 0)

    assert track is not None
    events = sup_events(track.path.read_bytes())
    # 第一段在 6 秒被裁掉清屏，这里补一个空显示集。第二段从 IN=1 起：0.5 秒那条只剩
    # 8 秒的清屏，8–10 秒那条落在 13–15 秒，显示和清屏都还在。
    assert [when for when, _objects in events] == pytest.approx(
        [5, 6, 8, 13, 15], abs=_TIMELINE_TOLERANCE
    )
    assert [objects for _when, objects in events] == [1, 0, 0, 1, 0]


@integration
@pytest.mark.integration
@pytest.mark.asyncio
async def test_disc_clips_with_fewer_tracks_do_not_shift_the_others(tmp_path, monkeypatch):
    """真盘的后面几段常常轨更少（《阿凡达：水之道》13 条与 7 条交替，片尾还有只带视频的一小段）。

    ``0:s:<k>`` 按第一段的流表解析，后面的段按序号对上：少的是末尾的轨，不能串到别的轨上。
    """
    monkeypatch.chdir(tmp_path)
    clips = [
        Clip("00001", 6, 100.0, [[{"start_s": 1, "end_s": 2}], [{"start_s": 3, "end_s": 4}]]),
        Clip("00002", 6, 200.0, [[{"start_s": 1, "end_s": 2}]]),
        Clip("00003", 2, 300.0, [], has_audio=False),
        Clip("00004", 6, 400.0, [[{"start_s": 1, "end_s": 2}], [{"start_s": 3, "end_s": 4}]]),
    ]
    disc = make_bdmv(tmp_path / "disc", clips)
    file = _disc_row(disc, clips, 2)

    first = await extract_embedded_subtitle_async(file, 0)
    assert first is not None
    assert sup_presentations(first.path.read_bytes()) == pytest.approx(
        [1, 2, 7, 8, 15, 16], abs=_TIMELINE_TOLERANCE
    )
    second = media_extract.cached_track(file, 1)
    assert second is not None
    assert sup_presentations(second.path.read_bytes()) == pytest.approx(
        [3, 4, 17, 18], abs=_TIMELINE_TOLERANCE
    )


@integration
@pytest.mark.integration
@pytest.mark.asyncio
async def test_bluray_image_subtitles_come_from_inside_the_image(tmp_path, monkeypatch):
    """蓝光镜像：ffmpeg 经 subfile 区间读盘内 m2ts，时间轴与原盘目录同一口径。"""
    from tests.api.test_reels_disc_index import _UdfBuilder

    from movieclaw_api.services.playback import iso_source

    monkeypatch.chdir(tmp_path)
    iso_source.clear_cache()
    clips = [
        Clip("00001", 6, 100.0, [[{"start_s": 2, "end_s": 3}]]),
        Clip("00002", 6, 200.0, [[{"start_s": 3, "end_s": 4}]], in_s=1),
    ]
    disc = make_bdmv(tmp_path / "disc", clips)
    streams = disc / "BDMV" / "STREAM"
    image = tmp_path / "movie.iso"
    image.write_bytes(
        _UdfBuilder(metadata=False).build(
            {
                "BDMV": {
                    "PLAYLIST": {"00001.mpls": mpls_bytes(clips)},
                    "CLIPINF": {},
                    "STREAM": {
                        f"{c.clip_id}.m2ts": (streams / f"{c.clip_id}.m2ts").read_bytes()
                        for c in clips
                    },
                }
            }
        )
    )
    shutil.rmtree(disc)
    file = make_file(tmp_path, [{"codec": "hdmv_pgs_subtitle"}], path=image)
    file.container = "iso"

    track = await extract_embedded_subtitle_async(file, 0)

    assert track is not None
    assert sup_presentations(track.path.read_bytes()) == pytest.approx(
        [2, 3, 8, 9], abs=_TIMELINE_TOLERANCE
    )

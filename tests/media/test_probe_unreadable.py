"""ffprobe 失败分性质（issue #1006）：「内容不可识别」与环境故障分开。

用真实 ffmpeg 造一个小 mkv，再把头部抹成全零复刻线上坏种——只有确定性的
「字节不是可识别的媒体」才算 unreadable；文件不存在等其他失败不算。
"""

from __future__ import annotations

import shutil
import subprocess

import pytest

from movieclaw_api.services import media_probe

pytestmark = pytest.mark.skipif(
    shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None,
    reason="需要 ffmpeg/ffprobe",
)


def _make_mkv(path):
    subprocess.run(
        [
            "ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=64x64:rate=5",
            "-t", "1", "-c:v", "mpeg4", "-y", str(path),
        ],
        check=True,
    )  # fmt: skip


def test_zeroed_header_is_unreadable_and_good_file_clears_it(tmp_path):
    video = tmp_path / "ep.mkv"
    _make_mkv(video)
    assert media_probe.probe_media(video) is not None
    assert not media_probe.probe_found_unreadable(video)

    data = bytearray(video.read_bytes())
    data[:4096] = bytes(min(4096, len(data)))  # 抹掉 EBML 头，大小不变
    video.write_bytes(bytes(data))
    assert media_probe.probe_media(video) is None
    assert media_probe.probe_found_unreadable(video)

    _make_mkv(video)  # 换源：探测成功即清除结论
    assert media_probe.probe_media(video) is not None
    assert not media_probe.probe_found_unreadable(video)


def test_missing_file_is_not_unreadable(tmp_path):
    ghost = tmp_path / "gone.mkv"
    assert media_probe.probe_media(ghost) is None
    assert not media_probe.probe_found_unreadable(ghost)

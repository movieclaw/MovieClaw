"""ffmpeg 安装：资产挑选、SHA256 校验、装新清旧——全部用注入的假下载，不触网。"""

from __future__ import annotations

import hashlib
import io
import json
import zipfile

import pytest
from movieclaw_transcoder_app import ffmpeg_install


def make_release(zip_bytes: bytes, *, version: str = "8.1.3-1") -> ffmpeg_install.FFmpegRelease:
    return ffmpeg_install.FFmpegRelease(
        version=version,
        url="https://example.com/jellyfin-ffmpeg.zip",
        digest=hashlib.sha256(zip_bytes).hexdigest(),
        size=len(zip_bytes),
    )


def make_zip(entries: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as bundle:
        for name, content in entries.items():
            bundle.writestr(name, content)
    return buffer.getvalue()


FLAT_ZIP = make_zip({"ffmpeg.exe": b"MZ ffmpeg", "ffprobe.exe": b"MZ ffprobe"})


class Downloads:
    """记录下载调用的注入点；每次返回同一份字节流。"""

    def __init__(self, payload: bytes):
        self.payload = payload
        self.urls: list[str] = []

    def __call__(self, url: str):
        self.urls.append(url)
        return io.BytesIO(self.payload)


class TestLatestRelease:
    def test_picks_the_win64_asset_and_digest(self):
        view = {
            "assets": [
                {
                    "name": "jellyfin-ffmpeg_8.1.3-1_portable_linux64-gpl.tar.xz",
                    "digest": "sha256:aa",
                },
                {
                    "name": "jellyfin-ffmpeg_8.1.3-1_portable_win64-clang-gpl.zip",
                    "digest": "sha256:" + "ab" * 32,
                    "size": 68_034_152,
                    "browser_download_url": "https://example.com/win64.zip",
                },
                {
                    "name": "jellyfin-ffmpeg_8.1.3-1_portable_winarm64-clang-gpl.zip",
                    "digest": "sha256:cc",
                },
            ]
        }
        release = ffmpeg_install.latest_release(fetch_json=lambda _url: view)
        assert release.version == "8.1.3-1"
        assert release.digest == "ab" * 32
        assert release.size == 68_034_152
        assert release.url == "https://example.com/win64.zip"

    def test_no_win64_asset_is_an_error(self):
        view = {"assets": [{"name": "jellyfin-ffmpeg_8.1.3-1_portable_macarm64-gpl.tar.xz"}]}
        with pytest.raises(ffmpeg_install.FfmpegInstallError):
            ffmpeg_install.latest_release(fetch_json=lambda _url: view)

    def test_missing_digest_is_refused(self):
        view = {"assets": [{"name": "jellyfin-ffmpeg_8.1.3-1_portable_win64-clang-gpl.zip"}]}
        with pytest.raises(ffmpeg_install.FfmpegInstallError):
            ffmpeg_install.latest_release(fetch_json=lambda _url: view)

    def test_unexpected_response_shape_is_an_error(self):
        with pytest.raises(ffmpeg_install.FfmpegInstallError):
            ffmpeg_install.latest_release(fetch_json=lambda _url: {"assets": "nope"})


class TestInstall:
    def test_downloads_verifies_and_marks(self, tmp_path):
        downloads = Downloads(FLAT_ZIP)
        progress: list[tuple[int, int]] = []

        ffmpeg = ffmpeg_install.install(
            make_release(FLAT_ZIP),
            tmp_path,
            progress=lambda done, total: progress.append((done, total)),
            open_stream=downloads,
        )

        assert ffmpeg == tmp_path / "8.1.3-1" / "ffmpeg.exe"
        assert ffmpeg.read_bytes() == b"MZ ffmpeg"
        marker = json.loads((tmp_path / "8.1.3-1" / ffmpeg_install.MARKER_NAME).read_text())
        assert marker["version"] == "8.1.3-1"
        assert marker["digest"] == hashlib.sha256(FLAT_ZIP).hexdigest()
        assert downloads.urls == ["https://example.com/jellyfin-ffmpeg.zip"]
        assert progress[-1] == (len(FLAT_ZIP), len(FLAT_ZIP))
        assert not list(tmp_path.glob(".*.zip"))  # 临时文件清掉了

    def test_second_install_of_the_same_version_does_not_download_again(self, tmp_path):
        release = make_release(FLAT_ZIP)
        downloads = Downloads(FLAT_ZIP)
        ffmpeg_install.install(release, tmp_path, open_stream=downloads)

        again = ffmpeg_install.install(release, tmp_path, open_stream=downloads)

        assert again == tmp_path / "8.1.3-1" / "ffmpeg.exe"
        assert downloads.urls == ["https://example.com/jellyfin-ffmpeg.zip"]  # 只下载过一次

    def test_a_digest_mismatch_discards_the_download(self, tmp_path):
        release = ffmpeg_install.FFmpegRelease(
            version="8.1.3-1",
            url="https://example.com/win64.zip",
            digest="00" * 32,
            size=len(FLAT_ZIP),
        )
        with pytest.raises(ffmpeg_install.FfmpegInstallError):
            ffmpeg_install.install(release, tmp_path, open_stream=Downloads(FLAT_ZIP))

        assert not (tmp_path / "8.1.3-1").exists()
        assert installed_nothing(tmp_path)

    def test_a_zip_without_ffmpeg_is_an_error(self, tmp_path):
        broken = make_zip({"readme.txt": b"nothing here"})
        with pytest.raises(ffmpeg_install.FfmpegInstallError):
            ffmpeg_install.install(make_release(broken), tmp_path, open_stream=Downloads(broken))
        assert not (tmp_path / "8.1.3-1").exists()  # 残缺目录也清掉了

    def test_nested_zip_layout_is_found(self, tmp_path):
        nested = make_zip({"jellyfin/ffmpeg.exe": b"MZ", "jellyfin/ffprobe.exe": b"MZ"})
        ffmpeg = ffmpeg_install.install(
            make_release(nested), tmp_path, open_stream=Downloads(nested)
        )
        assert ffmpeg == tmp_path / "8.1.3-1" / "jellyfin" / "ffmpeg.exe"

    def test_installing_a_new_version_removes_the_old_one(self, tmp_path):
        ffmpeg_install.install(make_release(FLAT_ZIP), tmp_path, open_stream=Downloads(FLAT_ZIP))
        newer = make_zip({"ffmpeg.exe": b"MZ new"})
        ffmpeg = ffmpeg_install.install(
            make_release(newer, version="8.2.0"), tmp_path, open_stream=Downloads(newer)
        )

        assert ffmpeg == tmp_path / "8.2.0" / "ffmpeg.exe"
        assert [path.name for path in tmp_path.iterdir() if path.is_dir()] == ["8.2.0"]


class TestInstalled:
    def test_finds_a_previous_install(self, tmp_path):
        ffmpeg_install.install(make_release(FLAT_ZIP), tmp_path, open_stream=Downloads(FLAT_ZIP))
        assert ffmpeg_install.installed(tmp_path) == tmp_path / "8.1.3-1" / "ffmpeg.exe"

    def test_empty_root_is_none(self, tmp_path):
        assert ffmpeg_install.installed(tmp_path) is None
        assert ffmpeg_install.installed(tmp_path / "missing") is None


def installed_nothing(root) -> bool:
    return ffmpeg_install.installed(root) is None

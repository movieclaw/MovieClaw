"""发行清单契约：真实版本、不同芯片、旧包复用及空附件。"""

import hashlib
import importlib.util
import json
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "build-download-manifest.py"
spec = importlib.util.spec_from_file_location("download_manifest", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def binary(cpu):
    return struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 0, 0, 0, 0)


class DownloadManifestTest(unittest.TestCase):
    def archive(self, directory, name, cpu=0x0100000C):
        archive = directory / name
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr(
                "MovieClaw.app/Contents/Info.plist",
                plistlib.dumps(
                    {
                        "CFBundleIdentifier": "io.movieclaw.app",
                        "CFBundleExecutable": "MovieClaw",
                        "CFBundleShortVersionString": "0.5.0",
                        "CFBundleVersion": "202610051230",
                        "LSMinimumSystemVersion": "26.0",
                    }
                ),
            )
            z.writestr("MovieClaw.app/Contents/MacOS/MovieClaw", binary(cpu))
        return archive

    @patch.object(module, "verification", return_value=(True, True))
    def test_real_version_and_chip_ignore_filename_and_server_tag(self, _verify):
        with tempfile.TemporaryDirectory() as tmp:
            # 文件名故意写 arm64，实际是 Intel；不能根据名称猜测。
            archive = self.archive(Path(tmp), "MovieClaw-macos-arm64.zip", 0x01000007)
            entry = module.describe(archive)
            self.assertEqual((entry["version"], entry["arch"]), ("0.5.0", "x86_64"))
            self.assertEqual(entry["minimumSystemVersion"], "26.0")
            self.assertEqual(entry["size"], archive.stat().st_size)
            self.assertEqual(len(entry["sha256"]), 64)
            self.assertTrue(entry["signed"] and entry["notarized"])

    def test_universal_and_unsupported_binary(self):
        fat = struct.pack(">2I", 0xCAFEBABE, 2)
        fat += struct.pack(">5I", 0x0100000C, 0, 48, 32, 0)
        fat += struct.pack(">5I", 0x01000007, 0, 80, 32, 0)
        self.assertEqual(module.architecture(fat), "universal")
        self.assertEqual(module.architecture(binary(0x0100000C)), "arm64")
        with self.assertRaises(ValueError):
            module.architecture(b"not a Mach-O")

    def test_cli_empty_and_carried_archive_keep_actual_version(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            command = [sys.executable, str(SCRIPT), "--directory", tmp, "--tag"]
            subprocess.run([*command, "v1.0.0"], check=True, capture_output=True)
            self.assertEqual(json.loads((directory / "downloads.json").read_text())["packages"], [])
            self.archive(directory, "MovieClaw-macos-arm64.zip")
            subprocess.run([*command, "v1.1.0"], check=True, capture_output=True)
            manifest = json.loads((directory / "downloads.json").read_text())
            self.assertEqual(manifest["release"], "v1.1.0")
            self.assertEqual(manifest["packages"][0]["version"], "0.5.0")

    def test_android_carry_preserves_version_and_rejects_changed_apk(self):
        with tempfile.TemporaryDirectory() as tmp:
            apk = Path(tmp) / "MovieClaw-Android-arm64.apk"
            apk.write_bytes(b"previously verified signed APK")
            entry = {
                "product": "android", "applicationId": "io.movieclaw.android",
                "version": "0.1.0", "build": "30000001", "minimumSdk": 26,
                "arch": "arm64", "asset": apk.name, "signed": True,
                "certificateSha256": "a" * 64,
                "size": apk.stat().st_size,
                "sha256": hashlib.sha256(apk.read_bytes()).hexdigest(),
            }
            apk.with_suffix(".json").write_text(json.dumps(entry))
            for tag in ("v0.33.0", "v0.34.0"):
                subprocess.run(
                    [sys.executable, str(SCRIPT), "--directory", tmp, "--tag", tag],
                    check=True, capture_output=True,
                )
                manifest = json.loads((Path(tmp) / "downloads.json").read_text())
                self.assertEqual(manifest["packages"], [entry])
                self.assertEqual(manifest["release"], tag)
            apk.write_bytes(b"replaced APK")
            with self.assertRaises(ValueError):
                module.describe_android(apk)

    def test_android_tv_is_a_separate_package_next_to_the_phone_app(self):
        with tempfile.TemporaryDirectory() as tmp:
            entries = []
            for name, product, application_id, arch in (
                ("MovieClaw-Android-arm64.apk", "android", "io.movieclaw.android", "arm64"),
                ("MovieClaw-AndroidTV.apk", "androidtv", "io.movieclaw.androidtv", "arm"),
            ):
                apk = Path(tmp) / name
                apk.write_bytes(name.encode())
                entry = {
                    "product": product, "applicationId": application_id,
                    "version": "0.1.0", "build": "1", "minimumSdk": 23, "arch": arch,
                    "asset": name, "signed": True, "certificateSha256": "a" * 64,
                    "size": apk.stat().st_size,
                    "sha256": hashlib.sha256(apk.read_bytes()).hexdigest(),
                }
                apk.with_suffix(".json").write_text(json.dumps(entry))
                entries.append(entry)
            subprocess.run(
                [sys.executable, str(SCRIPT), "--directory", tmp, "--tag", "v0.34.0"],
                check=True, capture_output=True,
            )
            manifest = json.loads((Path(tmp) / "downloads.json").read_text())
            self.assertEqual(manifest["packages"], entries)
            # TV 的元数据换成手机版的 App 身份：拒绝
            tv = Path(tmp) / "MovieClaw-AndroidTV.json"
            tv.write_text(json.dumps({**entries[1], "applicationId": "io.movieclaw.android"}))
            with self.assertRaises(ValueError):
                module.describe_android(
                    Path(tmp) / "MovieClaw-AndroidTV.apk",
                    "androidtv", "io.movieclaw.androidtv", "arm",
                )

    def test_android_requires_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            apk = Path(tmp) / "MovieClaw-Android-arm64.apk"
            apk.write_bytes(b"APK")
            with self.assertRaises(FileNotFoundError):
                module.describe_android(apk)


if __name__ == "__main__":
    unittest.main()

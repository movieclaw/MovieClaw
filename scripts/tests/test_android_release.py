"""正式 APK 打包检查：读取实际工具输出、拒绝调试包和缺失的播放器依赖。"""

import importlib.util
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

SCRIPT = (
    Path(__file__).resolve().parents[2]
    / "apps/android/scripts/build-release-metadata.py"
)
spec = importlib.util.spec_from_file_location("android_release", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

BADGING = (
    "package: name='io.movieclaw.android' versionCode='30000001' versionName='0.1.0'\n"
    "minSdkVersion:'26'\nnative-code: 'arm64-v8a'\n"
)
SIGNATURE = "Signer #1 certificate SHA-256 digest: " + "a" * 64


class AndroidReleaseTest(unittest.TestCase):
    def apk(self, directory, *, omit=""):
        apk = Path(directory) / "MovieClaw-Android-arm64.apk"
        libraries = (
            "movieclaw_jni", "mp2", "c++_shared", "avcodec", "avformat", "avfilter",
            "avutil", "swscale", "swresample", "avdevice",
        )
        with zipfile.ZipFile(apk, "w") as archive:
            for library in libraries:
                if library != omit:
                    archive.writestr(f"lib/arm64-v8a/lib{library}.so", b"native library")
        return apk

    def test_signed_apk_metadata_uses_embedded_version(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(
            module.subprocess, "check_output", side_effect=[BADGING, SIGNATURE]
        ):
            apk = self.apk(tmp)
            entry = module.describe(apk, "aapt2", "apksigner")
            self.assertEqual((entry["version"], entry["build"]), ("0.1.0", "30000001"))
            self.assertEqual(entry["minimumSdk"], 26)
            self.assertEqual(entry["certificateSha256"], "a" * 64)
            self.assertTrue(entry["signed"])

    def test_missing_mpv_dependency_is_not_a_publishable_package(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(
            module.subprocess, "check_output", return_value=BADGING
        ), self.assertRaisesRegex(ValueError, "libavcodec.so"):
            module.describe(self.apk(tmp, omit="avcodec"), "aapt2", "apksigner")

    def test_debug_build_and_debug_certificate_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            apk = self.apk(tmp)
            for output in (
                [BADGING + "application-debuggable\n"],
                [BADGING, SIGNATURE + "\nSigner #1 certificate DN: CN=Android Debug"],
            ):
                with patch.object(
                    module.subprocess, "check_output", side_effect=output
                ), self.assertRaises(ValueError):
                    module.describe(apk, "aapt2", "apksigner")

    def test_invalid_signature_fails_packaging(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(
            module.subprocess, "check_output",
            side_effect=[BADGING, subprocess.CalledProcessError(1, "apksigner")],
        ), self.assertRaises(subprocess.CalledProcessError):
            module.describe(self.apk(tmp), "aapt2", "apksigner")


if __name__ == "__main__":
    unittest.main()

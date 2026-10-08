"""Android TV 正式 APK 打包检查：两种架构的 FFmpeg / libass 都要在，拒绝调试包与调试证书。"""

import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "apps/android-tv/scripts/build-release-metadata.py"
spec = importlib.util.spec_from_file_location("android_tv_release", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

BADGING = (
    "package: name='io.movieclaw.androidtv' versionCode='1' versionName='0.1.0'\n"
    "sdkVersion:'23'\nnative-code: 'arm64-v8a' 'armeabi-v7a'\n"
)
# minSdk 23 的包带 v1 + v2 签名，apksigner 按方案逐行列出
SIGNATURE = (
    "V1 Signer: certificate SHA-256 digest: {0}\nV2 Signer: certificate SHA-256 digest: {0}"
).format("b" * 64)


class AndroidTvReleaseTest(unittest.TestCase):
    def apk(self, directory, *, omit=("", "")):
        apk = Path(directory) / "MovieClaw-AndroidTV.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            for abi in module.ABIS:
                for library in module.REQUIRED_LIBRARIES:
                    if (abi, library) != omit:
                        archive.writestr(f"lib/{abi}/{library}", b"native library")
        return apk

    def test_signed_apk_metadata(self):
        with (
            tempfile.TemporaryDirectory() as tmp,
            patch.object(module.subprocess, "check_output", side_effect=[BADGING, SIGNATURE]),
        ):
            entry = module.describe(self.apk(tmp), "aapt2", "apksigner")
        self.assertEqual(
            (entry["product"], entry["applicationId"], entry["version"], entry["build"]),
            ("androidtv", "io.movieclaw.androidtv", "0.1.0", "1"),
        )
        self.assertEqual((entry["arch"], entry["abis"]), ("arm", ["arm64-v8a", "armeabi-v7a"]))
        self.assertEqual(entry["minimumSdk"], 23)
        self.assertEqual(entry["certificateSha256"], "b" * 64)

    def test_32_bit_build_without_ffmpeg_is_not_publishable(self):
        with (
            tempfile.TemporaryDirectory() as tmp,
            patch.object(module.subprocess, "check_output", return_value=BADGING),
            self.assertRaisesRegex(ValueError, "armeabi-v7a.*libavcodec.so"),
        ):
            apk = self.apk(tmp, omit=("armeabi-v7a", "libavcodec.so"))
            module.describe(apk, "aapt2", "apksigner")

    def test_phone_app_debug_build_and_debug_certificate_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            apk = self.apk(tmp)
            for output in (
                [BADGING.replace("androidtv", "android", 1)],
                [BADGING + "application-debuggable\n"],
                [BADGING, SIGNATURE + "\nSigner #1 certificate DN: CN=Android Debug"],
                [BADGING, "Verified using v1 scheme: true"],
            ):
                with (
                    patch.object(module.subprocess, "check_output", side_effect=output),
                    self.assertRaises(ValueError),
                ):
                    module.describe(apk, "aapt2", "apksigner")


if __name__ == "__main__":
    unittest.main()

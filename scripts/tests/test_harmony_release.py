"""Harmony release package validation and actual metadata CLI integration."""

import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "apps/harmonyos/scripts/release/metadata.py"
spec = importlib.util.spec_from_file_location("harmony_release", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class HarmonyReleaseTest(unittest.TestCase):
    def hap(self, folder, *, debug=False, missing=None):
        path = Path(folder) / "input.hap"
        app = {
            "bundleName": module.BUNDLE,
            "debug": debug,
            "buildMode": "debug" if debug else "release",
            "versionName": "1.0.0",
            "versionCode": 1000000,
            "minAPIVersion": 60101024,
        }
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("module.json", json.dumps({"app": app}))
            for name in ["mpv", "movieclaw_mpv", "movieclaw_z"]:
                if name != missing:
                    archive.writestr(f"libs/arm64-v8a/lib{name}.so", b"library fixture")
        return path

    def profile(self):
        return {
            "type": "release",
            "issuer": "Huawei",
            "bundle-info": {"bundle-name": module.BUNDLE},
            "validity": {"not-before": 0, "not-after": time.time() + 3600},
        }

    def signing_env(self):
        return {
            name: "test-only"
            for name in [
                "HARMONY_KEYSTORE_PATH",
                "HARMONY_CERT_PATH",
                "HARMONY_PROFILE_PATH",
                "HARMONY_KEY_ALIAS",
                "HARMONY_KEY_PASSWORD",
                "HARMONY_KEYSTORE_PASSWORD",
                "JAVA_HOME",
            ]
        }

    def fake_signer(self, profile):
        def call(command):
            if "sign-app" in command:
                source = Path(command[command.index("-inFile") + 1])
                Path(command[command.index("-outFile") + 1]).write_bytes(source.read_bytes())
            if command[:2] == ["openssl", "cms"]:
                return json.dumps(profile).encode()
            return b"certificate fixture"

        return call

    def test_workflow_configuration_gate_before_download_or_signing(self):
        workflow = (ROOT / ".github/workflows/harmony-release.yml").read_text()
        validator = textwrap.dedent(
            workflow.split("python3 - <<'PY'\n", 1)[1].split("\n          PY", 1)[0]
        )
        base = {
            "RELEASE_TAG": "harmony-v1.0.0",
            "BUILD_ONLY": "true",
            "HARMONY_TOOLS_URL": "https://example.invalid/tools.zip",
            "HARMONY_TOOLS_SHA256": "a" * 64,
        }
        for change, success in [
            ({}, True),
            ({"BUILD_ONLY": "false"}, False),
            ({"HARMONY_TOOLS_SHA256": ""}, False),
            ({"RELEASE_TAG": "harmony-v1.0.1"}, False),
        ]:
            with self.subTest(change):
                result = subprocess.run(
                    [sys.executable, "-c", validator],
                    cwd=ROOT,
                    env={**base, **change},
                    capture_output=True,
                )
                self.assertEqual(result.returncode == 0, success)

    def test_debug_and_missing_native_libraries_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, "debug"):
                module.inspect(self.hap(tmp, debug=True))
            for name in ["mpv", "movieclaw_mpv", "movieclaw_z"]:
                with self.subTest(name), self.assertRaisesRegex(ValueError, "library"):
                    module.inspect(self.hap(tmp, missing=name))

    def test_real_cli_inspects_hap_and_rejects_debug(self):
        with tempfile.TemporaryDirectory() as tmp:
            hap = self.hap(tmp)
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "inspect", str(hap)],
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertEqual(json.loads(result.stdout)["versionName"], "1.0.0")
            self.hap(tmp, debug=True)
            self.assertNotEqual(
                subprocess.run(
                    [sys.executable, str(SCRIPT), "inspect", str(hap)], capture_output=True
                ).returncode,
                0,
            )

    def test_verified_profile_binds_release_metadata_to_actual_hap(self):
        with (
            tempfile.TemporaryDirectory() as tmp,
            patch.dict(os.environ, self.signing_env()),
            patch.object(module, "run", side_effect=self.fake_signer(self.profile())) as run,
        ):
            out = Path(tmp) / "out"
            module.sign(self.hap(tmp), Path(tmp), out)
            entry = json.loads((out / "MovieClaw-HarmonyOS.json").read_text())
            self.assertEqual(
                entry["sha256"], hashlib.sha256((out / module.ASSET).read_bytes()).hexdigest()
            )
            self.assertTrue(any("verify-app" in args.args[0] for args in run.call_args_list))
            self.assertTrue(entry["signed"])
            self.assertEqual(entry["product"], "harmony")
            subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts/build-download-manifest.py"),
                    "--tag",
                    "harmony-v1.0.0",
                    "--directory",
                    str(out),
                ],
                check=True,
                capture_output=True,
            )
            manifest = json.loads((out / "downloads.json").read_text())
            self.assertEqual(manifest["packages"][0]["version"], "1.0.0")
            # Public download metadata must reject a different tag or modified payload.
            for tag, tamper in [("harmony-v1.0.1", False), ("harmony-v1.0.0", True)]:
                if tamper:
                    with (out / module.ASSET).open("ab") as stream:
                        stream.write(b"tampered")
                result = subprocess.run(
                    [
                        sys.executable,
                        str(ROOT / "scripts/build-download-manifest.py"),
                        "--tag",
                        tag,
                        "--directory",
                        str(out),
                    ],
                    capture_output=True,
                )
                self.assertNotEqual(result.returncode, 0)

    def test_invalid_profile_or_failed_verification_never_creates_publishable_metadata(self):
        profiles = []
        for key, value in [
            ("type", "debug"),
            ("issuer", "pki_internal"),
            ("bundle-info", {"bundle-name": "other"}),
            ("validity", {"not-before": 0, "not-after": 1}),
        ]:
            profiles.append({**self.profile(), key: value})
        for profile in profiles:
            with (
                self.subTest(profile),
                tempfile.TemporaryDirectory() as tmp,
                patch.dict(os.environ, self.signing_env()),
                patch.object(module, "run", side_effect=self.fake_signer(profile)),
                self.assertRaises(ValueError),
            ):
                module.sign(self.hap(tmp), Path(tmp), Path(tmp) / "out")
        with (
            tempfile.TemporaryDirectory() as tmp,
            patch.dict(os.environ, {}, clear=True),
            self.assertRaisesRegex(ValueError, "Missing signing"),
        ):
            module.sign(self.hap(tmp), Path(tmp), Path(tmp) / "out")


if __name__ == "__main__":
    unittest.main()

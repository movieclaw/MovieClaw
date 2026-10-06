import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("prepare_project", ROOT / "scripts/prepare-project.py")
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)


class EngineDependencyTests(unittest.TestCase):
    def setUp(self):
        self.lock = json.loads((ROOT / "Package.resolved").read_text())
        pins = {pin["identity"]: pin for pin in self.lock["pins"]}
        engine = pins["aetherengine"]
        self.project = {"packages": {
            "AetherEngine": {"url": engine["location"], "revision": engine["state"]["revision"]},
            "FFmpegBuild": {"exactVersion": pins["ffmpegbuild"]["state"]["version"]},
        }}

    def test_accepts_committed_lock(self):
        prepare.check_lock(self.project, self.lock)

    def test_rejects_unresolved_engine_upgrade(self):
        self.project["packages"]["AetherEngine"]["revision"] = "0" * 40
        with self.assertRaisesRegex(ValueError, "pin differs"):
            prepare.check_lock(self.project, self.lock)

    def test_rejects_wrong_fork(self):
        self.project["packages"]["AetherEngine"]["url"] = "https://github.com/another/AetherEngine"
        with self.assertRaisesRegex(ValueError, "pin differs"):
            prepare.check_lock(self.project, self.lock)

    def test_rejects_floating_revision(self):
        for revision in ("main", "7.28.0", "4114e9b9"):
            with self.subTest(revision=revision):
                self.project["packages"]["AetherEngine"]["revision"] = revision
                with self.assertRaisesRegex(ValueError, "full commit SHA"):
                    prepare.check_lock(self.project, self.lock)

    def test_rejects_missing_engine_pin(self):
        self.lock["pins"] = [p for p in self.lock["pins"] if p["identity"] != "aetherengine"]
        with self.assertRaisesRegex(ValueError, "pin differs"):
            prepare.check_lock(self.project, self.lock)

    def test_rejects_unpinned_transitive_dependency(self):
        self.lock["pins"][0]["state"]["revision"] = "main"
        with self.assertRaises(ValueError):
            prepare.check_lock(self.project, self.lock)

    def test_rejects_mismatched_ffmpeg_embedding(self):
        self.project["packages"]["FFmpegBuild"]["exactVersion"] = "3.5.0"
        with self.assertRaisesRegex(ValueError, "FFmpegBuild version"):
            prepare.check_lock(self.project, self.lock)


if __name__ == "__main__":
    unittest.main()

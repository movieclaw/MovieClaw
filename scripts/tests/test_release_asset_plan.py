"""用真实 git 历史走发版附件的首次构建、改动重编和旧包沿用流程。"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "release-asset-plan.sh"


class ReleaseAssetPlanTest(unittest.TestCase):
    def test_android_build_carry_and_force_rebuild(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts").mkdir()
            shutil.copy(SCRIPT, root / "scripts/release-asset-plan.sh")
            android = root / "apps/android"
            android.mkdir(parents=True)
            (android / "version.properties").write_text("versionName=0.1.0\nversionCode=30000001\n")

            def git(*args):
                subprocess.run(
                    ["git", "-c", "user.name=Release Test", "-c", "user.email=test@example.invalid",
                     "-c", "commit.gpgsign=false", *args],
                    cwd=root, check=True, capture_output=True,
                )

            git("init", "-q")
            git("add", ".")
            git("commit", "-qm", "Android 0.1.0")
            git("tag", "v0.33.0")
            (root / "server.txt").write_text("server-only change")
            git("add", ".")
            git("commit", "-qm", "Server release")
            (root / "bin").mkdir()
            gh = root / "bin/gh"
            gh.write_text('#!/bin/sh\nprintf "%s\\n" "${RELEASE_TEST_INFO:-false true}"\n')
            gh.chmod(0o755)
            env = {
                **os.environ, "PATH": f"{root / 'bin'}:{os.environ['PATH']}",
                "RELEASE_TAG": "v0.34.0", "TARGET_SHA": "HEAD", "FORCE_REBUILD": "false",
            }

            def plan(**changes):
                result = subprocess.run(
                    ["bash", str(root / "scripts/release-asset-plan.sh"),
                     "MovieClaw-Android-arm64.apk", "apps/android"],
                    env={**env, **changes}, check=True, capture_output=True, text=True,
                )
                return dict(line.split("=", 1) for line in result.stdout.splitlines())

            self.assertEqual(plan(), {"mode": "carry", "from": "v0.33.0"})
            self.assertEqual(plan(FORCE_REBUILD="true")["mode"], "build")
            self.assertEqual(plan(RELEASE_TEST_INFO="false false")["mode"], "build")
            self.assertEqual(plan(RELEASE_TEST_INFO="true true")["mode"], "build")
            (android / "version.properties").write_text("versionName=0.1.1\nversionCode=30000002\n")
            git("add", ".")
            git("commit", "-qm", "Android 0.1.1")
            self.assertEqual(plan()["mode"], "build")


if __name__ == "__main__":
    unittest.main()

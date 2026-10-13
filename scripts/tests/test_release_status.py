"""发版前的改动提示：读各产品版本号、找上次发布的 tag、给出建议。"""

import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "release-status.py"
spec = importlib.util.spec_from_file_location("release_status", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ReleaseStatusTest(unittest.TestCase):
    def test_reads_each_kind_of_version_file(self):
        cases = {
            "pyproject.toml": '[project]\nname = "x"\nversion = "0.38.0"\n',
            "apps/apple/project.yml": 'settings:\n  base:\n    MARKETING_VERSION: "0.7.1"\n',
            "apps/android/version.properties": "# 注释\nversionName=0.3.2\nversionCode=30000006\n",
            "apps/desktop/src-tauri/Cargo.toml": '[package]\nname = "d"\nversion = "0.1.0"\n',
            "macos/MovieClawTranscoder/Resources/Info.plist": (
                '<?xml version="1.0"?><plist version="1.0"><dict>'
                "<key>CFBundleShortVersionString</key><string>0.34.0</string></dict></plist>"
            ),
        }
        versions = {f: module.version_in(text, f) for f, text in cases.items()}
        self.assertEqual(list(versions.values()), ["0.38.0", "0.7.1", "0.3.2", "0.1.0", "0.34.0"])

    def test_last_tag_is_the_highest_stable_tag_of_that_product(self):
        tags = ["v0.9.0", "v0.10.0", "v0.11.0-beta.1", "android-v0.3.10", "android-v0.3.9",
                "androidtv-v0.4.0", "torrent-ner-v3"]
        self.assertEqual(module.last_tag("v", tags), "v0.10.0")
        self.assertEqual(module.last_tag("android-v", tags), "android-v0.3.10")
        self.assertIsNone(module.last_tag("ios-v", tags))

    def test_verdict(self):
        self.assertEqual(module.verdict("0.3.1", "0.3.1", 0), "无改动，不用发")
        self.assertEqual(module.verdict("0.3.1", "0.3.1", 4), "有改动，但版本号还没递增")
        self.assertEqual(module.verdict("0.3.1", "0.3.2", 4), "有改动，版本号已递增，可以发")
        self.assertEqual(module.verdict(None, "0.1.0", 0), "从未单独发布")

    def test_every_product_reads_its_version_from_this_repository(self):
        tags = module.git("tag", "--list").split()
        for product in module.PRODUCTS:
            with self.subTest(product.name):
                self.assertIsNotNone(module.status(product, "HEAD", tags)["version"])


if __name__ == "__main__":
    unittest.main()

"""服务器 Release 正文：changelog 原文 + 中英各一节自动生成的客户端版本。"""

import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "build-release-body.py"
spec = importlib.util.spec_from_file_location("release_body", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

CHANGELOG = (
    "## v0.38.0: Theme\n\nSummary.\n\n### Fixed\n\n- A fix.\n"
    "\n---\n\n## 简体中文\n\n## v0.38.0：主题\n\n摘要。\n\n### 修复\n\n- 一条修复。\n"
)
DOWNLOADS = {"packages": [
    {"product": "mac", "version": "0.7.0", "asset": "MovieClaw-macos-arm64.zip"},
    {"product": "transcoder", "version": "0.33.0", "asset": "MovieClawTranscoder-macos-arm64.zip"},
]}
INFO = {"updated": ["server", "iphone", "mac"]}


def release(tag, published_at="2026-10-20T00:00:00Z", **extra):
    return {"tag": tag, "draft": False, "prerelease": False, "published_at": published_at,
            "assets": [], **extra}


class ReleaseBodyTest(unittest.TestCase):
    def body(self, releases, tag="v0.38.0", changelog=CHANGELOG, downloads=DOWNLOADS, info=INFO):
        return module.build(tag, changelog, "0.7.0", downloads, info, releases, "o/r")

    def test_sections_follow_each_language(self):
        server = release("v0.38.0", assets=["MovieClaw-iOS-unsigned.ipa"])
        body = self.body([
            server, release("android-v0.3.2", "2026-10-15T00:00:00Z"),
            release("macos-v0.7.1", "2026-10-14T00:00:00Z"),
        ])
        en, zh = body.split(module.SEPARATOR)
        self.assertIn("### Apps", en)
        self.assertIn(
            "- **iPhone, iPad and Apple TV 0.7.0**: changed in this release. The unsigned IPA", en
        )
        self.assertIn("- **Mac transcoder 0.33.0**: no changes in this release.", en)
        self.assertIn(
            "- **Android 0.3.2**: released separately, "
            "[download](https://github.com/o/r/releases/tag/android-v0.3.2).", en,
        )
        self.assertTrue(zh.rstrip().endswith("[下载](https://github.com/o/r/releases/tag/android-v0.3.2)。"))
        self.assertIn(
            "- **Mac 0.7.1**：单独发布，"
            "[下载](https://github.com/o/r/releases/tag/macos-v0.7.1)。", zh
        )
        self.assertNotIn("MovieClaw-macos-arm64.zip", body)
        self.assertNotIn("客户端", en)
        # changelog 原文一字不动
        self.assertTrue(body.startswith(CHANGELOG.split(module.SEPARATOR)[0].rstrip("\n")))

    def test_separate_clients_use_latest_release_at_publish_time(self):
        releases = [
            release("v0.38.0", "2026-10-20T00:00:00Z"),
            release("android-v0.3.10", "2026-10-18T00:00:00Z"),
            release("android-v0.3.9", "2026-10-19T00:00:00Z"),
            release("android-v0.4.0", "2026-10-25T00:00:00Z"),  # 本版之后才发
            release("androidtv-v0.3.0", "2026-10-19T00:00:00Z", prerelease=True),
            release("desktop-v1.0.5", None, draft=True),
            release("desktop-v1.0.4", "2026-10-13T00:00:00Z"),
        ]
        body = self.body(releases)
        self.assertIn("**Android 0.3.10**", body)
        self.assertNotIn("0.4.0", body)
        self.assertNotIn("Android TV", body)
        self.assertIn("**Windows 1.0.4**", body)
        # 草稿状态的服务器版本取现在：之后发的客户端也算
        releases[0] = release("v0.38.0", None, draft=True)
        self.assertIn("**Android 0.4.0**", self.body(releases))

    def test_missing_data_omits_lines(self):
        body = self.body([release("v0.38.0")], downloads=None, info=None)
        self.assertIn("- **iPhone, iPad and Apple TV 0.7.0**.", body)
        self.assertNotIn("Mac transcoder", body)
        self.assertNotIn("released separately", body)

    def test_earlier_releases_keep_their_changelog(self):
        old = CHANGELOG.replace("0.38.0", "0.37.0")
        self.assertEqual(self.body([release("v0.37.0")], tag="v0.37.0", changelog=old), old)


if __name__ == "__main__":
    unittest.main()

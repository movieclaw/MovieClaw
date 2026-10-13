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
URL = "https://github.com/o/r/releases/tag/"


def release(tag, published_at="2026-10-10T00:00:00Z", **extra):
    return {"tag": tag, "draft": False, "prerelease": False, "published_at": published_at, **extra}


def releases(*extra):
    return [
        release("v0.37.0", "2026-10-13T00:00:00Z"),
        release("v0.38.0", "2026-10-20T00:00:00Z"),
        release("ios-v0.7.0"), release("tvos-v0.7.0"), release("macos-v0.7.0"),
        release("transcoder-v0.33.0"), release("android-v0.3.1"), release("androidtv-v0.2.2"),
        release("desktop-v1.0.4"),
        *extra,
    ]


class ReleaseBodyTest(unittest.TestCase):
    def body(self, items, tag="v0.38.0", changelog=CHANGELOG):
        return module.build(tag, changelog, items, "o/r")

    def test_every_app_listed_in_order_with_new_ones_marked(self):
        body = self.body(releases(
            release("android-v0.3.2", "2026-10-15T00:00:00Z"),
            release("macos-v0.7.1", "2026-10-16T00:00:00Z"),
        ))
        en, zh = body.split(module.SEPARATOR)
        # changelog 原文一字不动，生成的一节在每种语言的末尾
        self.assertTrue(en.startswith(CHANGELOG.split(module.SEPARATOR)[0].rstrip("\n")))
        self.assertIn(
            f"New since v0.37.0: [Mac 0.7.1]({URL}macos-v0.7.1), "
            f"[Android 0.3.2]({URL}android-v0.3.2). Each app has its own release notes.", en,
        )
        self.assertIn(f"自 v0.37.0 以来新发布：[Mac 0.7.1]({URL}macos-v0.7.1)、", zh)
        names = [line.split("**")[1] for line in en.splitlines() if line.startswith("- **")]
        self.assertEqual(names, [
            "iPhone & iPad 0.7.0", "Apple TV 0.7.0", "Mac 0.7.1", "Mac transcoder 0.33.0",
            "Android 0.3.2", "Android TV 0.2.2", "Windows 1.0.4",
        ])
        self.assertIn(
            f"- **iPhone & iPad 0.7.0**: TestFlight, or the [unsigned IPA]({URL}ios-v0.7.0) "
            "for sideloading.", en,
        )
        self.assertIn(f"- **Apple TV 0.7.0**: TestFlight ([release notes]({URL}tvos-v0.7.0)).", en)
        self.assertIn(f"- **Mac 0.7.1** (new): [download]({URL}macos-v0.7.1).", en)
        self.assertIn(f"- **Mac 转码器 0.33.0**：[下载]({URL}transcoder-v0.33.0)。", zh)
        self.assertIn(f"- **Android 0.3.2**（新）：[下载]({URL}android-v0.3.2)。", zh)
        self.assertNotIn("客户端", en)

    def test_no_new_apps_says_so(self):
        body = self.body(releases())
        self.assertIn("No app updates since v0.37.0.", body)
        self.assertIn("自 v0.37.0 以来各 App 没有新版本。", body)
        self.assertNotIn("(new)", body)

    def test_snapshot_at_publish_time_ignores_later_drafts_and_prereleases(self):
        items = releases(
            release("android-v0.4.0", "2026-10-25T00:00:00Z"),  # 本版之后才发
            release("androidtv-v0.3.0", "2026-10-19T00:00:00Z", prerelease=True),
            release("desktop-v1.0.5", None, draft=True),
            release("android-v0.3.10", "2026-10-18T00:00:00Z"),
        )
        body = self.body(items)
        self.assertIn("**Android 0.3.10** (new)", body)
        self.assertNotIn("0.4.0", body)
        self.assertIn("**Android TV 0.2.2**", body)
        self.assertIn("**Windows 1.0.4**", body)
        # 服务器版本还是草稿时取现在：之后发的客户端也算
        items[1] = release("v0.38.0", None, draft=True)
        self.assertIn("**Android 0.4.0** (new)", self.body(items))

    def test_first_release_of_an_app_is_listed_but_not_new(self):
        # Apple TV 的第一个独立发布记录在 v0.37.0 之后才出现（如拆分时补建的）
        items = [r for r in releases() if r["tag"] != "tvos-v0.7.0"]
        items.append(release("tvos-v0.7.0", "2026-10-15T00:00:00Z"))
        body = self.body(items)
        self.assertIn("- **Apple TV 0.7.0**: TestFlight", body)
        self.assertIn("No app updates since v0.37.0.", body)

    def test_without_any_app_release_the_changelog_is_unchanged(self):
        items = [release("v0.37.0"), release("v0.38.0", "2026-10-20T00:00:00Z")]
        self.assertEqual(self.body(items), CHANGELOG)

    def test_earlier_releases_keep_their_changelog(self):
        old = CHANGELOG.replace("0.38.0", "0.37.0")
        self.assertEqual(self.body(releases(), tag="v0.37.0", changelog=old), old)


if __name__ == "__main__":
    unittest.main()

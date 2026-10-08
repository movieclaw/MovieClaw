"""版本信息清单契约：说明按语言拆分、格式不对就报错，镜像与客户端更新按真实数据判断。"""

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "build-release-info.py"
spec = importlib.util.spec_from_file_location("release_info", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

CHANGELOG = """## v0.40.0: Watch together

Invite family to a shared room.

> ✅ No Docker image update is required.

### Highlights

- **Rooms**: Start one from any title.

---

## 简体中文

## v0.40.0：一起看

邀请家人一起看片。

> ✅ 本版无需更新 Docker 镜像。

### 本版亮点

- **放映室**：从任意影片发起。
"""


def release(tag, **digests):
    return {"tag": tag, "assets": [{"name": name, "digest": digest} for name, digest in digests.items()]}


class ReleaseInfoTest(unittest.TestCase):
    def test_notes_split_by_language(self):
        info = module.build("v0.40.0", 19, "v0.39.0", 19, [release("v0.40.0")], CHANGELOG)
        self.assertEqual(info["notes"]["en"]["title"], "Watch together")
        self.assertEqual(info["notes"]["en"]["summary"], "Invite family to a shared room.")
        self.assertTrue(info["notes"]["en"]["body"].startswith("> ✅ No Docker image update"))
        self.assertNotIn("简体中文", info["notes"]["en"]["body"])
        self.assertEqual(info["notes"]["zh"]["title"], "一起看")
        self.assertEqual(info["notes"]["zh"]["summary"], "邀请家人一起看片。")
        self.assertTrue(info["notes"]["zh"]["body"].endswith("从任意影片发起。"))

    def test_malformed_notes_fail(self):
        broken = {
            "版本号不符": CHANGELOG.replace("## v0.40.0: Watch", "## v0.39.0: Watch"),
            "缺中文": CHANGELOG.split("---")[0],
            "没有摘要": CHANGELOG.replace("Invite family to a shared room.\n\n", ""),
            "标题后没空行": CHANGELOG.replace("together\n\n", "together\n"),
        }
        for name, text in broken.items():
            with self.subTest(name), self.assertRaises(ValueError):
                module.notes(text, "0.40.0")

    def test_summary_keeps_its_line_breaks(self):
        text = CHANGELOG.replace("邀请家人一起看片。\n", "邀请家人一起看片。\n也能各看各的。\n")
        self.assertEqual(module.notes(text, "0.40.0")["zh"]["summary"], "邀请家人一起看片。\n也能各看各的。")

    def test_notes_absent_until_changelog_merged(self):
        info = module.build("v0.40.0", 19, "v0.39.0", 19, [release("v0.40.0")], None)
        self.assertIsNone(info["notes"])

    def test_image_update_follows_runtime_version(self):
        self.assertFalse(module.build("v0.40.0", 19, "v0.39.0", 19, [release("v0.40.0")], None)["imageUpdate"])
        self.assertTrue(module.build("v0.40.0", 20, "v0.39.0", 19, [release("v0.40.0")], None)["imageUpdate"])

    def test_carried_clients_are_not_updated(self):
        releases = [
            release("v0.39.0", **{"MovieClawTranscoder-macos-arm64.zip": "sha256:a", "MovieClaw-macos-arm64.zip": "sha256:b"}),
            release("v0.40.0", **{
                "MovieClawTranscoder-macos-arm64.zip": "sha256:a",  # 沿用
                "MovieClaw-macos-arm64.zip": "sha256:c",  # 重新构建
                "MovieClaw-Android-arm64.apk": "sha256:d",  # 上一版没有
                "manifest.json": "sha256:e",
            }),
        ]
        self.assertEqual(module.updated("v0.40.0", "v0.39.0", releases), ["server", "mac", "android"])

    def test_missing_previous_release_counts_as_rebuilt(self):
        releases = [release("v0.40.0", **{"MovieClaw-iOS-unsigned.ipa": "sha256:a"})]
        self.assertEqual(module.updated("v0.40.0", "v0.39.0", releases), ["server", "iphone"])

    def test_published_changelogs_follow_the_format(self):
        # 仓库里所有还有 Release 的版本说明（v0.28.0 起）都必须能拆开。
        for path in sorted((ROOT / "docs" / "changelog").glob("v*.md")):
            version = path.stem.removeprefix("v")
            if tuple(map(int, version.split("."))) < (0, 28, 0):
                continue
            with self.subTest(path.name):
                module.notes(path.read_text(encoding="utf-8"), version)


if __name__ == "__main__":
    unittest.main()

package io.movieclaw.core.update

import io.movieclaw.core.model.generated.ClientReleaseView
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class UpdatePolicyTest {
    private val release = ClientReleaseView(product = "android", version = "0.4.0", build = 30000007, certificateSha256 = "18042F")

    @Test fun `newer means a higher versionCode`() {
        assertTrue(UpdatePolicy.isNewer(release, 30000006))
        assertFalse(UpdatePolicy.isNewer(release, 30000007))
        assertFalse(UpdatePolicy.isNewer(release, 30000008))
    }

    @Test fun `auto check at most once a day, and again if the clock went backwards`() {
        val day = UpdatePolicy.AUTO_CHECK_INTERVAL_MS
        assertTrue(UpdatePolicy.shouldAutoCheck(0, 1_000))
        assertFalse(UpdatePolicy.shouldAutoCheck(1_000, 1_000 + day - 1))
        assertTrue(UpdatePolicy.shouldAutoCheck(1_000, 1_000 + day))
        assertTrue(UpdatePolicy.shouldAutoCheck(5_000, 1_000))
    }

    @Test fun `a skipped version is not prompted again, a newer one is`() {
        assertFalse(UpdatePolicy.shouldPrompt(release, 30000006, skippedBuild = 30000007))
        assertTrue(UpdatePolicy.shouldPrompt(release, 30000006, skippedBuild = 30000005))
        assertTrue(UpdatePolicy.shouldPrompt(release, 30000006, skippedBuild = null))
    }

    @Test fun `signature comparison ignores case and colons, unknown stays unknown`() {
        assertEquals(true, UpdatePolicy.signatureMatches(release, "18:04:2f"))
        assertEquals(false, UpdatePolicy.signatureMatches(release, "abcdef"))
        assertNull(UpdatePolicy.signatureMatches(release, null))
        assertNull(UpdatePolicy.signatureMatches(release.copy(certificateSha256 = null), "18042f"))
    }

    @Test fun `changelog summary drops markdown headings and fences`() {
        val text = "## Android 0.4.0: One player\n\nThe phone app now plays…\n```\ncode\n```\n> ✅ Works with 0.28.0"
        assertEquals("Android 0.4.0: One player\nThe phone app now plays…\ncode\n✅ Works with 0.28.0", UpdatePolicy.summary(text))
        // 长段落按字数截断
        assertEquals("a".repeat(200) + "…", UpdatePolicy.summary("a".repeat(500)))
    }

    @Test fun `changelog summary shows only the Chinese section`() {
        val text = "## Android 0.5.0: Updates\n\nEnglish intro.\n\n---\n\n## 简体中文\n\n## Android 0.5.0：自动更新\n\n中文介绍。\n\n---\n\n验证范围"
        assertEquals("Android 0.5.0：自动更新\n中文介绍。", UpdatePolicy.summary(text))
    }

    @Test fun `an old server without the endpoint asks to update the server`() {
        assertEquals(
            "连接官网（GitHub）失败，改走你的服务器也没成：这台服务器的 MovieClaw 版本还不支持代查 App 更新，请检查网络能否访问 GitHub，或先更新服务器",
            UpdatePolicy.errorText(UpdateCheckException(java.io.IOException("timeout"), io.movieclaw.core.network.ApiException(404, "NOT_FOUND", "Not Found"))),
        )
        assertEquals("无法连接 GitHub", UpdatePolicy.errorText(io.movieclaw.core.network.ApiException(400, "BAD_REQUEST", "无法连接 GitHub")))
    }
}

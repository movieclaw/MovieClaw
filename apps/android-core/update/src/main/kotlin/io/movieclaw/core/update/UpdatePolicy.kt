package io.movieclaw.core.update

import io.movieclaw.core.model.generated.ClientReleaseView
import io.movieclaw.core.network.ApiException

/** 有没有新版、要不要自动弹（纯函数，单测直接覆盖） */
object UpdatePolicy {
    /** 自动检查的间隔：每次启动都问会刷光服务器的 GitHub 配额，一天一次够了 */
    const val AUTO_CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000L

    fun isNewer(release: ClientReleaseView, currentBuild: Long): Boolean = release.build > currentBuild

    fun shouldAutoCheck(lastCheckedAt: Long, now: Long): Boolean =
        lastCheckedAt <= 0 || now - lastCheckedAt >= AUTO_CHECK_INTERVAL_MS || now < lastCheckedAt

    /** 自动检查只在「比本机新、而且不是用户说过跳过的那一版」时弹；手动检查不看跳过 */
    fun shouldPrompt(release: ClientReleaseView, currentBuild: Long, skippedBuild: Long?): Boolean =
        isNewer(release, currentBuild) && release.build != skippedBuild

    /**
     * 新版的签名证书和本机这份是不是同一张：不同就没法覆盖安装（系统会拒），得先卸载。
     * 发布信息里没有证书指纹、或本机读不出来时返回 null（不拦，交给系统判断）。
     */
    fun signatureMatches(release: ClientReleaseView, installedCertSha256: String?): Boolean? {
        val expected = release.certificateSha256?.normalizedHex() ?: return null
        val actual = installedCertSha256?.normalizedHex() ?: return null
        return expected == actual
    }

    /**
     * Release 正文开头（Markdown 去掉标题符号），弹窗里放得下：最多几行、几百字，超出加省略号。
     * 正文英文在前、中文在后：有「## 简体中文」时只取它之后、到下一个单独一行的 `---` 为止
     */
    fun summary(changelog: String, maxLines: Int = 4, maxChars: Int = 200): String {
        val lines = changelog.lines()
        val zh = lines.indexOfFirst { it.trim() == "## 简体中文" }
        val section = if (zh < 0) lines else lines.drop(zh + 1).takeWhile { it.trim() != "---" }
        val text = section.asSequence()
            .map { it.trim().trimStart('#', '>', ' ').trim() }
            .filter { it.isNotEmpty() && !it.startsWith("```") }
            .take(maxLines)
            .joinToString("\n")
        return if (text.length > maxChars) text.take(maxChars).trimEnd() + "…" else text
    }

    /** 检查 / 下载失败给人看的话：官网和服务器都试过时两边原因都说；老服务器没有这个接口（404）时说清楚是要先更新服务器 */
    fun errorText(error: Throwable): String = when (error) {
        is UpdateCheckException -> {
            val what = if (error.downloading) "下载" else "连接"
            "${what}官网（GitHub）失败，改走你的服务器也没成：" + serverText(error.server)
        }
        else -> serverText(error)
    }

    private fun serverText(error: Throwable): String = when {
        error is ApiException && error.status == 404 -> "这台服务器的 MovieClaw 版本还不支持代查 App 更新，请检查网络能否访问 GitHub，或先更新服务器"
        else -> error.message ?: "检查更新失败"
    }

    private fun String.normalizedHex() = lowercase().replace(":", "").trim()
}

/** 官网与服务器两条路都失败（[official] 官网的原因，[server] 服务器的原因） */
class UpdateCheckException(val official: Throwable, val server: Throwable, val downloading: Boolean = false) :
    java.io.IOException(server.message, server)

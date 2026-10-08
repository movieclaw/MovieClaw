package io.movieclaw.android.core.network

import java.net.URI

/**
 * 解析「地址栏文本」为服务器 origin,规则与 iOS 端 ServerAddress 一致:
 * 默认补 http://、丢弃路径与查询参数、去掉默认端口(80/443)。
 */
object ServerAddress {

    data class Normalized(
        val origin: String,
        val apiBase: String,
        val host: String,
        val port: Int,
    )

    fun normalize(raw: String): Normalized? {
        var text = raw.trim()
        if (text.isEmpty()) return null
        if (!text.startsWith("http://", ignoreCase = true) && !text.startsWith("https://", ignoreCase = true)) {
            text = "http://$text"
        }
        val uri = try {
            URI(text)
        } catch (_: Exception) {
            return null
        }
        val host = uri.host?.trim().orEmpty()
        if (host.isEmpty()) return null
        val scheme = (uri.scheme ?: "http").lowercase()
        val port = when {
            uri.port > 0 -> uri.port
            scheme == "https" -> 443
            else -> 80
        }
        val isDefault = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
        val origin = if (isDefault) "$scheme://$host" else "$scheme://$host:$port"
        return Normalized(origin = origin, apiBase = "$origin/api/v1", host = host, port = port)
    }
}

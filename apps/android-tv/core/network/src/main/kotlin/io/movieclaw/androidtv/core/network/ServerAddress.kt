package io.movieclaw.androidtv.core.network

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** 一台服务器的地址。[origin] 不带路径，如 `http://192.168.1.10:3000`。 */
data class ServerAddress(val origin: HttpUrl) {
    val apiBase: HttpUrl get() = origin.newBuilder().addPathSegments("api/v1").build()

    /** 服务端给的相对地址（`/api/v1/...`、`/images/...`）→ 绝对地址。 */
    fun resolve(path: String): HttpUrl? = origin.resolve(path)

    override fun toString(): String = origin.toString().trimEnd('/')

    /** 给人看的地址：去掉协议（`192.168.1.10:3000`）。错误文案、谁在看的小字用 */
    val displayString: String get() = toString().substringAfter("://")

    /** 主机加端口 */
    val hostLabel: String get() = if (origin.port == HttpUrl.defaultPort(origin.scheme)) origin.host else "${origin.host}:${origin.port}"

    companion object {
        /** 人手填的地址：可以不带 http://、可以带尾斜杠或 /api/v1。填错返回 null。 */
        fun parse(input: String): ServerAddress? {
            var text = input.trim().trimEnd('/')
            if (text.isEmpty()) return null
            if (!text.contains("://")) text = "http://$text"
            text = text.removeSuffix("/api/v1")
            val url = text.toHttpUrlOrNull()?.takeIf { it.scheme == "http" || it.scheme == "https" } ?: return null
            return ServerAddress(url.newBuilder().encodedPath("/").query(null).fragment(null).username("").password("").build())
        }
    }
}

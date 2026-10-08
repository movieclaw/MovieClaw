package io.movieclaw.androidtv.core.network

import okhttp3.HttpUrl

/**
 * 图片地址（docs/design/image-sizing.md）：远程图走服务端代理，本地图补 `/api/v1`，
 * 再按宽度阶梯取一档（与后端 `WIDTH_LADDER` 相同；不给 `w` 就是原图）。
 */
object ImageUrls {
    val WIDTH_LADDER = intArrayOf(160, 240, 360, 480, 720, 960, 1280, 1920, 2560, 3840)

    fun build(server: ServerAddress, raw: String?, widthPx: Int? = null): HttpUrl? {
        val path = raw?.trim()?.replace('\\', '/')?.takeIf { it.isNotEmpty() } ?: return null
        val base = when {
            path.startsWith("http://") || path.startsWith("https://") ->
                server.apiBase.newBuilder().addPathSegments("images/proxy").addQueryParameter("url", path).build()
            path.startsWith("/api/") -> server.resolve(path)
            else -> server.resolve("/api/v1/" + path.trimStart('/'))
        } ?: return null
        val width = widthPx?.let(::snap) ?: return base
        return base.newBuilder().setQueryParameter("w", width.toString()).build()
    }

    /** 向上取到阶梯里的一档，超过最大一档就用最大一档。 */
    fun snap(widthPx: Int): Int = WIDTH_LADDER.firstOrNull { it >= widthPx } ?: WIDTH_LADDER.last()
}

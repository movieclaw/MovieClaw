package io.movieclaw.androidtv.system

import android.content.Intent

/** 深链（TVDeepLink）：「继续观看」点进来直接续播；`item` 打开条目详情 */
sealed interface DeepLink {
    data class Play(val mediaItemId: Long, val season: Long?, val episode: Long?) : DeepLink
    data class Item(val libraryId: Long, val itemId: Long) : DeepLink

    companion object {
        fun from(intent: Intent?): DeepLink? {
            val uri = intent?.data?.takeIf { it.scheme == "movieclaw" } ?: return null
            val segments = uri.pathSegments
            return when (uri.host) {
                "play" -> segments.firstOrNull()?.toLongOrNull()?.let {
                    Play(it, uri.getQueryParameter("season")?.toLongOrNull(), uri.getQueryParameter("episode")?.toLongOrNull())
                }
                "item" -> {
                    val lib = segments.getOrNull(0)?.toLongOrNull()
                    val id = segments.getOrNull(1)?.toLongOrNull()
                    if (lib != null && id != null) Item(lib, id) else null
                }
                else -> null
            }
        }
    }
}

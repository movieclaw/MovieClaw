package io.movieclaw.androidtv.core.session

import io.movieclaw.androidtv.core.model.generated.LibrarySearchHit

/** 搜索页（TVSearchView）的纯逻辑：翻页合并、卡片下的说明 */
object SearchResults {
    /** 翻页只追加：按作品 ID 去重，已有的保持原位（不随后台索引刷新换序） */
    fun merge(existing: List<LibrarySearchHit>, page: List<LibrarySearchHit>): List<LibrarySearchHit> {
        val seen = existing.mapTo(HashSet()) { it.item.mediaItemId }
        return existing + page.filter { seen.add(it.item.mediaItemId) }
    }

    fun kindName(kind: String): String? = when (kind) {
        "movie" -> "电影"
        "tv" -> "剧集"
        "video" -> "视频"
        else -> null
    }

    /** 「2014 · 电影」；缺哪项省哪项 */
    fun subtitle(hit: LibrarySearchHit): String =
        listOfNotNull(hit.item.year?.toString(), kindName(hit.item.kind)).joinToString(" · ")

    /** 点开条目用哪个库：条目自带的优先，否则取命中的第一个库；都没有就不能打开 */
    fun libraryId(hit: LibrarySearchHit): Long? = hit.item.libraryId ?: hit.libraryIds.firstOrNull()

    /** 命中原因用人像图标（人物带出的作品）还是放大镜（名称类命中） */
    fun matchedByPerson(hit: LibrarySearchHit): Boolean = hit.match.personId != null
}

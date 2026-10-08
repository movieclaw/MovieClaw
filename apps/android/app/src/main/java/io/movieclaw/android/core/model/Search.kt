package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.contentOrNull

/* ---------------- 站点(种子)搜索 ---------------- */

/** 一级分类(服务端 TorrentCategory 枚举) */
enum class TorrentCategory(val id: String, val label: String) {
    MOVIE("movie", "电影"),
    TV("tv", "剧集"),
    DOCUMENTARY("documentary", "纪录片"),
    ANIME("anime", "动画"),
    MUSIC("music", "音乐"),
    GAME("game", "游戏"),
    AV("av", "其他视频"),
    OTHER("other", "其他"),
    ;

    companion object {
        fun of(id: String?): TorrentCategory? = entries.firstOrNull { it.id == id }
    }
}

/** 搜索结果里的一条种子(字段对齐 movieclaw_tracker.models.TorrentListItem + TorrentHit) */
@Serializable
data class TorrentHit(
    val torrentId: String = "",
    val title: String = "",
    val subtitle: String = "",
    val category: String? = null,
    val size: String? = null,
    val sizeBytes: Long = 0,
    val seeders: Int = 0,
    val leechers: Int = 0,
    val snatched: Int = 0,
    val uploadTime: String? = null,
    val uploader: String = "",
    val posterUrl: String? = null,
    val free: Boolean = false,
    val downloadVolumeFactor: Float = 1f,
    val uploadVolumeFactor: Float = 1f,
    val hitAndRun: Boolean? = null,
    val detailUrl: String? = null,
    val downloadUrl: String? = null,
    val siteId: String = "",
    val siteName: String = "",
    /** 站点声明的分类名（展示用） */
    val siteCategoryName: String? = null,
    /** 数据扩充层推导的结构化属性：下载落点弹窗的「这是哪部作品」靠它拿身份 */
    val attrs: TorrentAttrs? = null,
)

/**
 * 数据扩充层从标题/副标题推导的结构化属性（服务端 `movieclaw_enrich.TorrentAttrs`）。
 * 全部可空/可为空表：**提取不到就保持空值，绝不猜测**。这里只声明 App 用得到的字段，
 * 其余靠全局 `ignoreUnknownKeys` 忽略。
 */
@Serializable
data class TorrentAttrs(
    /** "movie" / "tv" / null（无法确定） */
    val mediaType: String? = null,
    val titlesZh: List<String> = emptyList(),
    val titlesEn: List<String> = emptyList(),
    val year: Int? = null,
    val seasons: List<Int> = emptyList(),
    val episodes: List<Int> = emptyList(),
    val episodesTotal: Int? = null,
    val complete: Boolean? = null,
    val resolution: String? = null,
    val videoCodec: String? = null,
    val mediaSource: String? = null,
    val remux: Boolean = false,
)

/* ---------------- 站点搜索 SSE 事件载荷 ---------------- */

@Serializable
data class SearchStreamSite(val siteId: String = "", val siteName: String = "")

@Serializable
data class SearchStreamStart(
    val keyword: String = "",
    val label: String? = null,
    val categories: List<String> = emptyList(),
    val page: Int = 1,
    val sites: List<SearchStreamSite> = emptyList(),
)

@Serializable
data class SiteStreamResult(
    val siteId: String = "",
    val siteName: String = "",
    val count: Int = 0,
    val elapsedMs: Int = 0,
    val items: List<TorrentHit> = emptyList(),
)

@Serializable
data class SiteStreamError(
    val siteId: String = "",
    val siteName: String = "",
    val error: String = "",
    val elapsedMs: Int = 0,
)

@Serializable
data class SiteSearchStatus(
    val siteId: String = "",
    val siteName: String = "",
    val count: Int = 0,
    val error: String? = null,
)

@Serializable
data class SearchStreamDone(
    val total: Int = 0,
    val elapsedMs: Int = 0,
    val sites: List<SiteSearchStatus> = emptyList(),
)

/* ---------------- 标题搜索(TMDB/豆瓣) ---------------- */

/** 标题搜索结果条目(字段对齐服务端 schemas/discover.py DiscoveredTitleView) */
@Serializable
data class DiscoveredTitle(
    /** 服务端给出的稳定引用(tmdb:movie:123 / douban:456),订阅与详情原样消费 */
    val titleRef: String = "",
    val provider: String = "",
    val externalId: String = "",
    val mediaType: String? = null,
    val title: String = "",
    val originalTitle: String = "",
    val releaseYear: Int? = null,
    val providerRating: Float = 0f,
    val genres: List<String> = emptyList(),
    val extentLabel: String = "",
    val overview: String = "",
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    /** 非空 = 本库已入库(海报显示「已入库」缎带,iOS 同款语义) */
    val libraryStatus: MediaLibraryStatus? = null,
)

@Serializable
data class MediaLibraryStatus(
    val mediaItemId: Long = 0,
    val libraryCount: Int = 0,
    val fileCount: Int = 0,
)

@Serializable
data class TitleSearchView(
    val query: String = "",
    val titles: List<DiscoveredTitle> = emptyList(),
    val historyId: Long? = null,
)

@Serializable
data class TitleSearchRequest(
    val query: String,
    val provider: String = "all",
    val saveHistory: Boolean = true,
)

/* ---------------- 库内搜索 ---------------- */

@Serializable
data class LibrarySearchGroup(
    val libraryId: Long,
    val libraryName: String = "",
    val kind: String = "movie",
    val items: List<LibraryItemView> = emptyList(),
)

/* ---------------- 搜索历史 ---------------- */

@Serializable
data class SearchHistoryItem(
    val id: Long,
    val keyword: String = "",
    val vertical: String = "torrents",
    val label: String? = null,
    val categories: List<String> = emptyList(),
    val siteIds: List<String> = emptyList(),
    val searchCount: Int = 0,
    val lastSearchedAt: String? = null,
    val hasSnapshot: Boolean = false,
)

/* ---------------- 下载提交 ---------------- */

@Serializable
data class DownloadSubmitRequest(
    val siteId: String,
    val downloadUrl: String,
    val torrentId: String? = null,
    val libraryId: Long? = null,
    val title: String? = null,
    val year: Int? = null,
    val subtitle: String? = null,
    val autoRoute: Boolean = false,
    val mediaKind: String? = null,
    val tmdbId: Int? = null,
    /** 手选保存目录（movieclaw 视角）；成员不许带（服务端 403） */
    val savePath: String? = null,
    /** 指定下载器；缺省走默认下载器。成员不许带（服务端 403） */
    val downloaderId: Long? = null,
    /** 种子分类：**带上即表示记住本次保存位置**，只有勾了「记住本次选择」才带 */
    val category: String? = null,
)

/* ---------------- 通知中心 ---------------- */

@Serializable
data class Notice(
    val id: Long,
    val severity: String = "info",
    val source: String = "",
    val title: String = "",
    val message: String = "",
    /** 事项的附加上下文：`group_key` / `grouped_under` 决定它是否被目录级根因告警收编（见 visibleNotices） */
    val payload: kotlinx.serialization.json.JsonObject? = null,
    val createdAt: String? = null,
    val updatedAt: String? = null,
)

/**
 * 只列该露出来的待处理事项（网页 `notice-center.tsx` / iOS `NoticeCenterView.visible` 同口径）：
 * 目录级根因告警（`payload.group_key`）存在时，被它收编的单种子告警（`payload.grouped_under`
 * 指向那个 key）折叠不显示——用户看到的是一条「这个目录 movieclaw 看不到」，而不是 16 条
 * 「《某剧》无法入库」。
 */
fun visibleNotices(notices: List<Notice>): List<Notice> {
    fun str(n: Notice, key: String): String? =
        n.payload?.get(key)?.let { (it as? kotlinx.serialization.json.JsonPrimitive)?.contentOrNull }
            ?.takeIf { it.isNotEmpty() }
    val groupKeys = notices.mapNotNull { str(it, "group_key") }.toSet()
    return notices.filter { notice ->
        val parent = str(notice, "grouped_under") ?: return@filter true
        parent !in groupKeys
    }
}

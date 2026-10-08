package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

@Serializable
data class LibraryItemView(
    val mediaItemId: Long,
    val kind: String = "movie",
    val libraryId: Long? = null,
    val source: String = "tmdb",
    val title: String,
    val year: Int? = null,
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    val primaryAspect: Float = 0.6667f,
    val rating: Float? = null,
    val fileCount: Int = 0,
    val totalSizeBytes: Long = 0,
    val seasons: List<Int> = emptyList(),
    val episodeCount: Int? = null,
    /** 去重的介质规格标签（如 `["2160p","1080p"]`）；探测不到为空。搜索结果格的库存概况用它 */
    val resolutions: List<String> = emptyList(),
    val missingCount: Int? = null,
    val isFavorite: Boolean = false,
)

/**
 * 本地刮削（NFO）的一位演员。
 *
 * 字段名与服务端 `ActorView` 对齐：头像是 **`thumb_url`**（不是 `avatar_url`——
 * 之前按后者解析，头像永远解析不出来，演职员一排全成了首字占位）。
 */
@Serializable
data class ActorView(
    val name: String? = null,
    val role: String? = null,
    val thumbUrl: String? = null,
    /** TMDB 影人 ID；有值时那一格可以链到人物页 */
    val tmdbPersonId: Int? = null,
)

/** 库内人物关系表中的一位导演（服务端 `DirectorView`，带头像） */
@Serializable
data class DirectorView(
    val name: String = "",
    val thumbUrl: String? = null,
    val tmdbPersonId: Int? = null,
)

@Serializable
data class LocalMetaView(
    val plot: String? = null,
    val rating: Float? = null,
    val runtimeMinutes: Int? = null,
    val genres: List<String> = emptyList(),
    /** NFO 里写的导演姓名（老条目可能只有这个，没有人物关系与头像） */
    val directors: List<String> = emptyList(),
    /** 库内人物关系表的导演（带头像）；为空时退回 [directors] 的姓名占位 */
    val directorCredits: List<DirectorView> = emptyList(),
    val actors: List<ActorView> = emptyList(),
    val source: String? = null,
)

@Serializable
data class AudioStreamView(
    val codec: String? = null,
    val channels: Int? = null,
    val channelLayout: String? = null,
    val language: String? = null,
    val title: String? = null,
    val default: Boolean = false,
)

@Serializable
data class SubtitleStreamView(
    val codec: String? = null,
    val language: String? = null,
    val title: String? = null,
    val forced: Boolean = false,
    val default: Boolean = false,
    val external: Boolean = false,
    val fileName: String? = null,
)

/**
 * 「不经用户操作时会放哪条音轨/字幕」及原因（服务端 `track_defaults`，与起播同一口径：
 * 本集记着的 > 沿用同剧上一集 > 默认轨策略）。详情页据此标默认，并让用户知道为什么。
 */
@Serializable
data class TrackDefaultsView(
    val audioTrack: String? = null,
    val audioReason: String = "",
    val audioNote: String = "",
    val subtitleTrack: String? = null,
    val subtitleReason: String = "",
    val subtitleNote: String = "",
)

/** 文件来源快照（服务端 `FileOriginView`）：这个文件是怎么进库的 */
@Serializable
data class FileOriginView(
    /** subscription / manual_download / watch_import / scan */
    val kind: String = "",
    /** 一句话：订阅《九门》自动投递 / 手动下载 / 监听目录自动识别入库 / 存量扫描发现 */
    val label: String = "",
    /** 第二行：站点 · 种子标题 · 下载器 · 搬运方式 */
    val detail: String? = null,
)

@Serializable
data class LibraryFileView(
    val id: Long,
    val fileName: String,
    val filePath: String? = null,
    val sizeBytes: Long = 0,
    val container: String? = null,
    val resolution: String? = null,
    val videoCodec: String? = null,
    val hdr: String? = null,
    val durationSeconds: Long? = null,
    val bitRate: Long? = null,
    val frameRate: Float? = null,
    /** 视频轨探测：色深 / 色彩空间（详情页文件区展开态显示；null = 尚未探测） */
    val bitDepth: Int? = null,
    val colorSpace: String? = null,
    /** 片源标注：原盘（Disc）/ user-lowest（最低档，人工标注）等 */
    val mediaSource: String? = null,
    /** 片源是人工标注的（真值来自文件扫描之外的判断） */
    val mediaSourceManual: Boolean = false,
    val seasonNumber: Int = 0,
    val episodeNumber: Int = 0,
    val state: String = "in_place",
    /** 文件当前不在磁盘（missing 标记）：台账还在、文件没了 */
    val missing: Boolean = false,
    /** 待回收：预计自动清理时间；null = 做种保护中（不自动清理） */
    val purgeAfter: String? = null,
    val trashNote: String? = null,
    /** 来源快照：这个文件是怎么进库的 */
    val origin: FileOriginView? = null,
    /** 多版本：用户「留下这个版本」的时间（留下后不再列为重复文件） */
    val keptAt: String? = null,
    val addedAt: String? = null,
    val audioStreams: List<AudioStreamView>? = null,
    val subtitleStreams: List<SubtitleStreamView> = emptyList(),
    /** null = 原盘或尚未探测轨道（界面退回按片源默认旗标显示） */
    val playbackDefaults: TrackDefaultsView? = null,
)

/** 删除文件的结果（服务端 `ItemDeleteResultView`）：实际从磁盘删掉的路径、台账行数、释放字节与错误 */
@Serializable
data class ItemDeleteResultView(
    val removedPaths: List<String> = emptyList(),
    val rowsDeleted: Int = 0,
    val freedBytes: Long = 0,
    val errors: List<String> = emptyList(),
)

@Serializable
data class LibraryItemDetailView(
    val mediaItemId: Long,
    val kind: String = "movie",
    val source: String = "tmdb",
    val title: String,
    val originalTitle: String? = null,
    val year: Int? = null,
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    /** 片名 Logo（透明底 PNG；本地资产 > TMDB 图床）。没有时前端显示文字片名 */
    val logoUrl: String? = null,
    val primaryAspect: Float = 0.6667f,
    val localMeta: LocalMetaView? = null,
    val files: List<LibraryFileView> = emptyList(),
    val fileCount: Int = 0,
    val totalSizeBytes: Long = 0,
    val seasons: List<Int> = emptyList(),
    val seriesName: String? = null,
)

@Serializable
data class EpisodeView(
    val episodeNumber: Int,
    val name: String? = null,
    val overview: String? = null,
    val airDate: String? = null,
    val stillUrl: String? = null,
    val owned: Boolean = false,
    val fileIds: List<Long> = emptyList(),
    val positionMs: Long = 0,
    val played: Boolean = false,
    val progressPercent: Int? = null,
)

@Serializable
data class SeasonEpisodesView(
    val seasonNumber: Int = 0,
    val episodes: List<EpisodeView> = emptyList(),
)

/* ---------------- 筛选面板与跳转索引(P2) ---------------- */

/** 筛选面板里的一个候选值(count 已按「其他维度」算好) */
@Serializable
data class FacetValue(
    val value: String = "",
    val label: String = "",
    val count: Int = 0,
)

@Serializable
data class LibraryFacets(
    val total: Int = 0,
    val genres: List<FacetValue> = emptyList(),
    val countries: List<FacetValue> = emptyList(),
    val decades: List<FacetValue> = emptyList(),
    val watch: List<FacetValue> = emptyList(),
    val ratings: List<FacetValue> = emptyList(),
    val runtimes: List<FacetValue> = emptyList(),
    val languages: List<FacetValue> = emptyList(),
    val resolutions: List<FacetValue> = emptyList(),
    val hdr: List<FacetValue> = emptyList(),
    val stock: List<FacetValue> = emptyList(),
)

/** 海报墙跳转索引:首字母档(A-Z / #)与该档第一格在排序中的位置 */
@Serializable
data class LibraryIndexEntry(
    val initial: String = "",
    val count: Int = 0,
    val offset: Int = 0,
)

/**
 * 按类型的跨库墙概况（`GET /libraries/kinds/{kind}`）：「全部电影」这一行由哪些库
 * 组成、共几部（同一部片跨库只算一部）。口径在服务端：观看者可见 ∩ 该类型 ∩
 * 没勾「从首页排除」。
 */
@Serializable
data class LibraryKindSummaryView(
    /** movie / tv / video（照片库不做跨库墙） */
    val kind: String = "movie",
    val libraryIds: List<Long> = emptyList(),
    val itemCount: Int = 0,
)

/** 媒体库筛选条件(与服务端 /items 的查询参数一一对应) */
data class LibraryFilter(
    val genres: Set<String> = emptySet(),
    val countries: Set<String> = emptySet(),
    val decades: Set<String> = emptySet(),
    val watch: Set<String> = emptySet(),
    /** 评分下限(单值:接口就是 gte 语义) */
    val ratingGte: Float? = null,
    val runtimes: Set<String> = emptySet(),
    val languages: Set<String> = emptySet(),
    val resolutions: Set<String> = emptySet(),
    /** null = 不限;true = 只看 HDR;false = 只看 SDR */
    val hdr: Boolean? = null,
    val stock: Set<String> = emptySet(),
    val sort: String = "title",
    val order: String? = null,
) {
    val activeCount: Int
        get() = genres.size + countries.size + decades.size + watch.size +
            runtimes.size + languages.size + resolutions.size + stock.size +
            (if (ratingGte != null) 1 else 0) + (if (hdr != null) 1 else 0)

    fun isEmpty(): Boolean = activeCount == 0

    fun cleared(): LibraryFilter = LibraryFilter(sort = sort, order = order)
}

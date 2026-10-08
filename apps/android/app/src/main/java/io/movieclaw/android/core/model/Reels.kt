package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/* ══════════ 刷片 / 片段（docs/design/reels.md） ══════════ */

@Serializable
data class ReelEpisodeView(
    val season: Int = 0,
    val episode: Int = 0,
    val name: String? = null,
    val overview: String? = null,
)

@Serializable
data class ReelPersonView(
    val name: String = "",
    /** TMDB 影人 ID（打开人物页用）；只有姓名时为空 */
    val tmdbPersonId: Int? = null,
    val avatarUrl: String? = null,
)

/** 这一条属于哪部片（展示用） */
@Serializable
data class ReelTitleView(
    val mediaItemId: Long = 0,
    /** 这一条的文件所在的媒体库（分享要用） */
    val libraryId: Long = 0,
    /** movie / tv / video */
    val kind: String = "movie",
    val name: String = "",
    val year: Int? = null,
    val rating: Float? = null,
    /** 片长；剧集是这一集的时长 */
    val runtimeMinutes: Int? = null,
    val genres: List<String> = emptyList(),
    val tagline: String? = null,
    val overview: String? = null,
    /** 本人收藏了没有（电影 / 整剧） */
    val favorite: Boolean = false,
    /** 本人看过没有（电影看整部，剧集看这一集） */
    val played: Boolean = false,
    /** 看了一半时的进度（1~99，同「继续观看」口径）；没看过、已看完为空 */
    val progressPercent: Int? = null,
    /** 电影是导演、剧集是主创，最多两位 */
    val directors: List<ReelPersonView> = emptyList(),
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    val logoUrl: String? = null,
    val episode: ReelEpisodeView? = null,
)

/** 放原片的哪一段（原片时间轴，与怎么放无关） */
@Serializable
data class ReelSegmentView(
    val fileId: Long = 0,
    /** 起点（落在关键帧上） */
    val startMs: Long = 0,
    /** 终点（落在两句对白之间） */
    val endMs: Long = 0,
    /** 原片总长（剧集是这一集） */
    val durationMs: Long? = null,
    /** 挑法：bitrate 码率最高段 / chapter 章节起点 / position 固定位置 */
    val method: String = "",
)

@Serializable
data class ReelByteRangeView(
    val offset: Long = 0,
    val length: Long = 0,
    /** head 文件头 / index 索引 / start 起点后约 4 秒 */
    val purpose: String = "",
)

@Serializable
data class ReelSubtitleView(
    val ordinal: Int = 0,
    val language: String? = null,
    val title: String? = null,
    val codec: String? = null,
    /** 只含这一段（前后各留几秒）的字幕文件地址（相对路径，含令牌）；时间戳是文件时间 */
    val url: String? = null,
    /** url 那份字幕的格式：srt / ass */
    val format: String? = null,
)

/** 怎么放这一条（一期 mode=seek：从原片中间起播） */
@Serializable
data class ReelPlayView(
    val mode: String = "seek",
    /** 原片取流地址（相对路径，含令牌） */
    val streamUrl: String? = null,
    val sizeBytes: Long? = null,
    /**
     * 光盘的交付方式（服务端 v0.32 起「大图预告」与「片段」也放开原盘 / 镜像 / DVD / TS / AVI）：
     * `image` = 光盘镜像（stream_url 是镜像原字节，盘内结构本机读，同正片）；
     * `folder` = 原盘目录（BDMV / VIDEO_TS，按目录清单逐个文件取）；null = 普通文件
     */
    val disc: String? = null,
    /** 起播音轨的同类型序号（embedded:<k>）；光盘镜像服务端读不出盘内轨，为 null */
    val audioOrdinal: Int? = null,
    /** 要显示的中文字幕；null 不开 */
    val subtitle: ReelSubtitleView? = null,
    /** 上一条播放期间应预取的字节范围（本期未用，保留解码） */
    val prefetch: List<ReelByteRangeView> = emptyList(),
)

@Serializable
data class ReelItemView(
    /** 片段标识（事件上报用）：文件 + 起点 */
    val id: String = "",
    val title: ReelTitleView = ReelTitleView(),
    /** 封面：起点那一帧；没有时是剧照 */
    val coverUrl: String? = null,
    val segment: ReelSegmentView = ReelSegmentView(),
    val play: ReelPlayView = ReelPlayView(),
)

@Serializable
data class ReelFeedView(
    /** 这次刷片的随机种子，翻页时原样带回 */
    val seed: Long = 0,
    val nextOffset: Int = 0,
    val hasMore: Boolean = false,
    val items: List<ReelItemView> = emptyList(),
)

/** 筛选菜单的候选值与计数（每维计数排除本维自身条件；为 0 的档 UI 置灰） */
@Serializable
data class ReelFacetsView(
    /** 当前条件下能刷到几部 */
    val total: Int = 0,
    /**
     * 类型 / 地区 / 年代 / 评分 / 片长这几维是否可用。
     * False = 当前池子是「其他」（没有 TMDB 档案），只剩观看状态可筛，UI 收起那几个菜单
     */
    val filterable: Boolean = true,
    /** 电影 / 剧集 / 其他；空 = 没有可切换的类型，不画这一行 */
    val kinds: List<FacetValue> = emptyList(),
    val genres: List<FacetValue> = emptyList(),
    val countries: List<FacetValue> = emptyList(),
    val decades: List<FacetValue> = emptyList(),
    val ratings: List<FacetValue> = emptyList(),
    val runtimes: List<FacetValue> = emptyList(),
    /** 观看状态：只有「没看过」一项 */
    val watch: List<FacetValue> = emptyList(),
)

/* ---------------- 事件上报 ---------------- */

@Serializable
data class ReelEventView(
    val reelId: String,
    /** impression / first_frame / leave / complete / fullscreen / detail / fail */
    val kind: String,
    val mode: String = "seek",
    val mediaItemId: Long? = null,
    val fileId: Long? = null,
    val positionMs: Long? = null,
    val watchedMs: Long? = null,
    val waitMs: Long? = null,
    val detail: String? = null,
)

@Serializable
data class ReelEventBatch(val events: List<ReelEventView>)

@Serializable
data class ReelEventResult(val accepted: Int = 0)

/* ---------------- 刷片筛选（本机记忆 + 请求参数的唯一来源） ---------------- */

/**
 * 刷片的筛选条件。与服务端 `GET /reels` 的参数一一对应（维内 OR、维间 AND）：
 * 维度沿用媒体库筛选的取值口径（类型是 TMDB genre id、地区是国家码、年代/片长是档名、
 * 评分是下限），外加刷片特有的 `kind`（电影 / 剧集 / 其他）。
 */
data class ReelFilter(
    /** movie / tv / video；null = 电影 + 剧集（服务端默认） */
    val kind: String? = null,
    val genres: String? = null,
    val countries: String? = null,
    val decades: String? = null,
    val ratingGte: Float? = null,
    val runtimes: String? = null,
    /** 只看没看过的（"unwatched"）；null = 不限 */
    val watch: String? = null,
) {
    val activeCount: Int
        get() = listOf(
            kind != null, genres != null, countries != null, decades != null,
            ratingGte != null, runtimes != null, watch != null,
        ).count { it }

    /** 顶栏筛选键的文字：没条件「全部」、一个条件写它的值、多个写「已筛选 N 项」 */
    fun summary(labels: List<String>): String = when {
        activeCount == 0 -> "全部"
        activeCount == 1 -> labels.firstOrNull() ?: "已筛选 1 项"
        else -> "已筛选 $activeCount 项"
    }
}

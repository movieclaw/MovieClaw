package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/**
 * 媒体库详情页右上角「⋯」菜单（iOS `LibraryItemDetailView.actionsMenu`）用到的服务端模型。
 *
 * 命名沿用全局 SnakeCase 映射（见 `NetworkModule.json`），字段名与服务端 schema 一致：
 * `/libraries/{library_id}/items/{media_item_id}` 下的 refresh-metadata、chapter-images、
 * reidentification(s)、artwork 三个端点、transfer 三个端点，以及 `DELETE /playback/history`。
 */

/* ---------------- 受理类作业（刷新元数据 / 重新生成章节） ---------------- */

/**
 * 受理回执（`POST .../metadata/refresh`、`POST .../chapter-images` 的 `data`）。
 * 两个接口都是 202 + `{started, job_id, created}`；失败原因在信封 `message` 里。
 */
@Serializable
data class ItemJobView(
    val started: Boolean = false,
    val jobId: String? = null,
    val created: Boolean = false,
)

/** `DELETE /playback/history?scope=item` 的 `data`（给人看的 message 在信封上） */
@Serializable
data class HistoryClearView(
    val deletedStates: Int = 0,
    val deletedMetrics: Int = 0,
)

/* ---------------- 修正识别结果 ---------------- */

/** 重新识别预览里的「当前身份」与候选作品（服务端 `ReviewItemView`） */
@Serializable
data class ReviewItemView(
    val mediaItemId: Long = 0,
    val tmdbId: Long? = null,
    val title: String = "",
    val year: Int? = null,
    val posterUrl: String? = null,
)

/** 识别不出时的候选（服务端 `UnidentifiedCandidateView`）：`reasons` 是「凭什么这么认」的逐条依据 */
@Serializable
data class UnidentifiedCandidateView(
    val tmdbId: Long = 0,
    val title: String = "",
    val year: Int? = null,
    val episodeCount: Int? = null,
    val reasons: List<String> = emptyList(),
)

/** 一组文件重走识别链后的结论（服务端 `ReidentifyOutcomeView`） */
@Serializable
data class ReidentifyOutcomeView(
    val mediaItemId: Long? = null,
    val tmdbId: Long? = null,
    val title: String? = null,
    val year: Int? = null,
    val posterUrl: String? = null,
    /** 识别来源（name_parse / tmdb / nfo…），文案映射见 iOS `reidentifySourceLabels` */
    val source: String? = null,
    /** 结论与当前身份一致（这时不给「改挂到这里」） */
    val sameAsCurrent: Boolean = false,
    val reason: String? = null,
    /** 失败码（`no_match` / `tmdb_unreachable`…） */
    val code: String? = null,
    val candidates: List<UnidentifiedCandidateView> = emptyList(),
)

/** 按「该挂到哪部作品」分好组的文件（服务端 `ReidentifyGroupView`） */
@Serializable
data class ReidentifyGroupView(
    val key: String = "",
    val outcome: ReidentifyOutcomeView = ReidentifyOutcomeView(),
    val fileIds: List<Long> = emptyList(),
    val fileCount: Int = 0,
    val totalSizeBytes: Long = 0,
    val sampleNames: List<String> = emptyList(),
)

/** `POST .../reidentification-preview` 的 `data`（服务端 `ReidentifyPreviewView`） */
@Serializable
data class ReidentifyPreviewView(
    val current: ReviewItemView = ReviewItemView(),
    /** 本库是电影库还是剧集库（决定「另行搜一部」的收窄类型） */
    val movie: Boolean = true,
    val groups: List<ReidentifyGroupView> = emptyList(),
    val outcome: ReidentifyOutcomeView = ReidentifyOutcomeView(),
    /** 已从磁盘消失、没实体可识别的文件数 */
    val skippedMissing: Int = 0,
    /** 身份已被人工钉住（扫描不再翻案） */
    val pinnedIdentity: Boolean = false,
    /** TMDB 不可达（网络问题，不是识别问题） */
    val unreachable: Boolean = false,
    /** 「都不对，自己搜…」用的搜索词 */
    val searchSeed: String = "",
)

/**
 * 「改挂到这里」：整组文件一次挂到同一个 TMDB 条目（服务端 `ClaimBatchPayload`，
 * 路径不带库 id）。季号默认不指定——每个文件沿用扫描时解析出的季集号。
 */
@Serializable
data class ClaimBatchPayload(
    val fileIds: List<Long>,
    /** Discover 返回的稳定引用，如 `tmdb:tv:1396` */
    val titleRef: String,
    val seasonNumber: Int? = null,
)

/** 「标为非独立作品」：摘掉身份锚并忽略，不动磁盘（服务端 `DetachPayload`） */
@Serializable
data class DetachPayload(
    val fileIds: List<Long>,
)

/** `POST .../reidentifications` 的 `data`（服务端 `ReidentifyResultView`） */
@Serializable
data class ReidentifyResultView(
    val total: Int = 0,
    val identified: Int = 0,
    val unidentified: Int = 0,
    val skippedMissing: Int = 0,
    val keptOnError: Int = 0,
    val changed: Boolean = false,
    /** 改挂成了另一部作品：返回新条目 id，页面要换过去 */
    val newMediaItemId: Long? = null,
    val newTitle: String? = null,
    val pinnedIdentity: Boolean = false,
    val message: String = "",
)

/* ---------------- 更换图片 ---------------- */

/** 一张候选图（服务端 `ArtworkCandidateView`）；`filePath` 是选中时回传的值，`previewUrl` 是缩略图 */
@Serializable
data class ArtworkCandidateView(
    val filePath: String = "",
    val previewUrl: String = "",
    val width: Int? = null,
    val height: Int? = null,
    val language: String? = null,
    val voteAverage: Float? = null,
    val voteCount: Int? = null,
    /** tmdb / fanart */
    val source: String = "tmdb",
    val likes: Int? = null,
    val unlisted: Boolean = false,
)

/** `GET .../artwork/candidates` 的 `data`（服务端 `ArtworkCandidatesView`） */
@Serializable
data class ArtworkCandidatesView(
    val posters: List<ArtworkCandidateView> = emptyList(),
    val backdrops: List<ArtworkCandidateView> = emptyList(),
    val logos: List<ArtworkCandidateView> = emptyList(),
    val currentPoster: String? = null,
    val currentBackdrop: String? = null,
    val currentLogo: String? = null,
    /** 当前这张是不是用户手选的（手选的不会被刷新元数据覆盖） */
    val posterLocked: Boolean = false,
    val backdropLocked: Boolean = false,
    val logoLocked: Boolean = false,
    /** 图床状态：ok / not_configured / invalid / error / none（背景图少了多半是它） */
    val fanart: String = "none",
)

/** `POST .../artwork/select` 的请求体（服务端 `ArtworkSelectPayload`）；`filePath = null` = 恢复自动选图 */
@Serializable
data class ArtworkSelectPayload(
    val kind: String,
    val filePath: String? = null,
)

/** `POST .../artwork/select` 的 `data` */
@Serializable
data class ArtworkLockView(val locked: Boolean = false)

/* ---------------- 转移到其他媒体库 ---------------- */

@Serializable
data class TransferMoveView(
    val sourcePath: String = "",
    val targetPath: String = "",
    val isDir: Boolean = false,
    val sizeBytes: Long = 0,
    val fileCount: Int = 0,
)

@Serializable
data class TransferSkipView(
    val filePath: String = "",
    val reason: String = "",
)

/** `GET .../transfer-preview?target_library_id=` 的 `data`（服务端 `TransferPreviewView`） */
@Serializable
data class TransferPreviewView(
    val targetLibraryId: Long = 0,
    val targetLibraryName: String = "",
    val targetRoot: String = "",
    val moves: List<TransferMoveView> = emptyList(),
    val skips: List<TransferSkipView> = emptyList(),
    val totalBytes: Long = 0,
    val missingCount: Int = 0,
    /** 跨盘转移要完整复制（耗时取决于体积与盘速） */
    val crossDevice: Boolean = false,
    /** 挡住转移的原因（如目标库没有根路径），非空时不让提交 */
    val blocked: List<String> = emptyList(),
)

/** `POST .../transfers` 的请求体（服务端 `TransferPayload`） */
@Serializable
data class TransferPayload(val targetLibraryId: Long)

/** `POST .../transfers` 的 `data`（服务端 `TransferStartView`） */
@Serializable
data class TransferStartView(
    val started: Boolean = false,
    val message: String = "",
    val jobId: String? = null,
    val created: Boolean = false,
)

/** `GET /libraries/{library_id}/item-transfer-status` 的 `data`（服务端 `TransferStatusView`） */
@Serializable
data class TransferStatusView(
    val running: Boolean = false,
    val mediaItemId: Long? = null,
    val title: String? = null,
    val targetLibraryId: Long? = null,
    val processed: Int = 0,
    val total: Int = 0,
    val finishedAt: String? = null,
    val targetLibraryName: String? = null,
    val movedPaths: List<String> = emptyList(),
    val filesRelocated: Int = 0,
    val bytesMoved: Long = 0,
    val removedDirs: Int = 0,
    /** 订阅跟着搬到了目标库 */
    val subscriptionMoved: Boolean = false,
    val movedItems: Int = 0,
    val skippedItems: Int = 0,
    val failedItems: Int = 0,
    val skips: List<String> = emptyList(),
    val errors: List<String> = emptyList(),
)

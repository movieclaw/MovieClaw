package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/**
 * 创建 / 更新媒体库的请求体（v0.31 `LibraryPayload`；服务端契约字段全平）。
 *
 * `kind` / `source` 仅创建时生效（创建后不可改，服务端更新时忽略）。
 * 其余可选字段一律「不传 = 不改动」——更新时只带用户真正动过的字段。
 */
@Serializable
data class LibraryPayload(
    /** 库的展示名（全局唯一） */
    val name: String,
    /** 内容形态：movie / tv / video */
    val kind: String = "movie",
    /** 身份来源：tmdb / local；不传按形态默认（movie、tv → tmdb，video → local） */
    val source: String? = null,
    /** 根路径列表（绝对路径），第一个为主根——新入库落在这里 */
    val rootPaths: List<String> = emptyList(),
    /** 缺图时是否从视频抓帧生成缩略图（网络挂载库抓帧等于全量下载，可关） */
    val generateThumbnails: Boolean? = null,
    /** 是否生成并展示视频章节 */
    val extractChapterImages: Boolean? = null,
    /** 是否识别剧集的片头片尾（只对剧集库起作用） */
    val detectMediaSegments: Boolean? = null,
    /** 是否从首页「最近添加」等汇总里排除该库 */
    val excludeFromHome: Boolean? = null,
    /** 是否按作品系列自动生成合集（《哈利·波特》这种） */
    val autoSeriesCollections: Boolean? = null,
    /** 可见范围：everyone / selected */
    val accessMode: String? = null,
    /** 显式授权的成员 id（整体覆盖式；不传 = 不改动） */
    val memberIds: List<Long>? = null,
    /** 扫描后自动清理已确认丢失的库存记录（不可恢复） */
    val autoClearMissing: Boolean? = null,
    /** 是否启用实时文件监控（SMB/NFS 网络挂载建议关闭） */
    val realtimeWatch: Boolean? = null,
)

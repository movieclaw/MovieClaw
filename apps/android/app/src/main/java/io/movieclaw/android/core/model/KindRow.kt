package io.movieclaw.android.core.model

/** 首页的一条按类型跨库行（「全部电影 · 最近添加」）：放 core/model 是因为整页快照要序列化它 */
@kotlinx.serialization.Serializable
data class KindRow(
    val kind: String,
    val label: String,
    val total: Int,
    val libraryCount: Int,
    val items: List<LibraryItemView> = emptyList(),
)

package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/*
 * 资源搜索的分类栏预设（设置 → 资源站点 → 搜索分类；服务端 `SearchTabItem`）：
 * 内置分类（不可删，可隐藏、可排序）与自定义分类（命名的「分类组合 × 站点组合」）统一混排。
 * 「全部」固定在首位，不在列表里。保存是整体覆盖式（PUT /search/presets）。
 */

@Serializable
data class SearchTabView(
    /** category / preset */
    val type: String = "category",
    val id: String = "",
    val visible: Boolean = true,
    /** 仅自定义分类 */
    val name: String? = null,
    val categories: List<String> = emptyList(),
    val siteIds: List<String> = emptyList(),
    val posterMode: Boolean = false,
    val skipHistory: Boolean = false,
)

@Serializable
data class SearchPresetsView(val presets: List<SearchTabView> = emptyList())

/** 整体覆盖保存：按类型只写服务端认得的字段（Pydantic 判别联合） */
@Serializable
data class SearchPresetsPayload(val presets: List<JsonObject>)

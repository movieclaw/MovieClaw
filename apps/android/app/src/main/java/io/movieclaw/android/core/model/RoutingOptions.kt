package io.movieclaw.android.core.model

import kotlinx.serialization.Serializable

/*
 * 收藏范围 / 规则组适用范围的选项表（GET /libraries/routing-options，同 Web `RoutingOptions`）：
 * 类型按作品类型分电影/剧集两套；区域用国家码，预设是常用地区组合。
 */

@Serializable
data class GenreOption(val id: Int = 0, val label: String = "")

@Serializable
data class RegionPreset(
    val key: String = "",
    val label: String = "",
    val countries: List<String> = emptyList(),
)

@Serializable
data class RoutingOptionsView(
    val movieGenres: List<GenreOption> = emptyList(),
    val tvGenres: List<GenreOption> = emptyList(),
    val regionPresets: List<RegionPreset> = emptyList(),
    /** 国家码 → 中文名（映射外的少见国家直接显示码） */
    val countryNames: Map<String, String> = emptyMap(),
)

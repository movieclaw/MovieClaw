package io.movieclaw.android.feature.subscriptions

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonPrimitive

/**
 * 规则组规格（`GET /rule-sets` 的 `spec`）与它的**中文摘要**。
 *
 * 口径照抄网页 `components/rule-sets-panel.tsx: specSummary(spec)`——文案、顺序、
 * 连接符都一致，**不做任何我自己发明的措辞**。订阅弹层里「资源规则」那一行的第二行
 * 就是这个摘要（实测网页：`2160p > 1080p · 做种 ≥ 1`）。
 *
 * 只解析摘要用得到的字段；网页里还有平台 / 制作组 / HDR 等分支，字段缺失时整条芯片
 * 不出现（与网页 `if (…?.length)` 的判断一致），不会退化成半截文案。
 */
@Serializable
data class RuleSetSpec(
    val resolutions: List<String> = emptyList(),
    val mediaSources: List<String> = emptyList(),
    val videoCodecs: List<String> = emptyList(),
    val freeOnly: Boolean = false,
    val minSeeders: Int? = null,
    val sizeMinMb: Int? = null,
    val sizeMaxMb: Int? = null,
    val excludeHr: Boolean = false,
    val hrUnknownPolicy: String? = null,
    val releaseGroupsAllow: List<String> = emptyList(),
    val releaseGroupsBlock: List<String> = emptyList(),
)

/** 网页 `METTIA_SOURCE_OPTIONS` 的中文名（同值域） */
private val MEDIA_SOURCE_LABELS = mapOf(
    "remux" to "Remux",
    "blu-ray" to "蓝光",
    "web-dl" to "WEB-DL",
    "rip" to "Rip 类",
    "tv" to "电视录制类",
)

/** 网页 `CODEC_FAMILIES`：同一族的写法在摘要里塌缩成一个标签 */
private val CODEC_FAMILIES = listOf(
    "H.265" to listOf("x265", "H.265", "HEVC"),
    "H.264" to listOf("x264", "H.264", "AVC"),
    "AV1" to listOf("AV1"),
)

/**
 * spec → 人话芯片列表（空 = 全不限）。**顺序与文案与网页逐行一致**：
 * 分辨率 → 片源 → 洗版目标 → 编码 → 仅免费 → 做种 → 体积 → 排除 H&R → 制作组名单。
 */
fun specSummary(spec: RuleSetSpec): List<String> {
    val chips = mutableListOf<String>()
    if (spec.resolutions.isNotEmpty()) chips += spec.resolutions.joinToString(" > ")
    if (spec.mediaSources.isNotEmpty()) {
        chips += spec.mediaSources.joinToString(" > ") { MEDIA_SOURCE_LABELS[it] ?: it }
    }
    if (spec.videoCodecs.isNotEmpty()) {
        val rest = spec.videoCodecs.toMutableSet()
        val labels = mutableListOf<String>()
        CODEC_FAMILIES.forEach { (label, values) ->
            if (values.any { it in rest }) {
                labels += label
                values.forEach { rest.remove(it) }
            }
        }
        labels += rest
        chips += labels.joinToString("/")
    }
    if (spec.freeOnly) chips += "仅免费"
    spec.minSeeders?.let { chips += "做种 ≥ $it" }
    if (spec.sizeMinMb != null || spec.sizeMaxMb != null) {
        val min = spec.sizeMinMb?.toString().orEmpty()
        val max = spec.sizeMaxMb?.toString().orEmpty()
        chips += when {
            min.isNotEmpty() && max.isNotEmpty() -> "单集 $min–$max" + "MB"
            min.isNotEmpty() -> "单集 ≥ $min" + "MB"
            else -> "单集 ≤ $max" + "MB"
        }
    }
    if (spec.excludeHr) {
        chips += if (spec.hrUnknownPolicy == "strict") "排除 H&R（未知也排）" else "排除 H&R"
    }
    if (spec.releaseGroupsAllow.isNotEmpty()) chips += "制作组白名单 ${spec.releaseGroupsAllow.size} 个"
    if (spec.releaseGroupsBlock.isNotEmpty()) chips += "制作组黑名单 ${spec.releaseGroupsBlock.size} 个"
    return chips
}

/** 从 `JsonObject` 读 spec（字段缺失即默认值，与网页的可选判断同口径） */
fun parseRuleSetSpec(raw: JsonObject?): RuleSetSpec {
    if (raw == null) return RuleSetSpec()
    fun strs(key: String): List<String> =
        (raw[key] as? kotlinx.serialization.json.JsonArray)
            ?.mapNotNull { it.jsonPrimitive.contentOrNull } ?: emptyList()
    fun int(key: String): Int? = raw[key]?.jsonPrimitive?.intOrNull
    fun bool(key: String): Boolean = raw[key]?.jsonPrimitive?.contentOrNull == "true"
    return RuleSetSpec(
        resolutions = strs("resolutions"),
        mediaSources = strs("media_sources"),
        videoCodecs = strs("video_codecs"),
        freeOnly = bool("free_only"),
        minSeeders = int("min_seeders"),
        sizeMinMb = int("size_min_mb"),
        sizeMaxMb = int("size_max_mb"),
        excludeHr = bool("exclude_hr"),
        hrUnknownPolicy = raw["hr_unknown_policy"]?.jsonPrimitive?.contentOrNull,
        releaseGroupsAllow = strs("release_groups_allow"),
        releaseGroupsBlock = strs("release_groups_block"),
    )
}

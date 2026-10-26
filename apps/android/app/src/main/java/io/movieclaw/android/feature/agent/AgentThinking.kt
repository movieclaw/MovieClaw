package io.movieclaw.android.feature.agent

import io.movieclaw.android.core.model.LlmModelOption

/**
 * 思维链档位的词汇表与展示文案（逐条对齐 iOS `AgentThinking`）：
 * 服务端菜单里只有词汇表内的值有意义，顺序固定；nil = 默认（不发送思考参数）。
 */
internal object AgentThinking {

    private val order = listOf("off", "minimal", "low", "medium", "high", "xhigh", "max")
    private val labels = mapOf(
        "off" to "关",
        "minimal" to "最少",
        "low" to "低",
        "medium" to "中",
        "high" to "高",
        "xhigh" to "超高",
        "max" to "最高",
    )

    /** 服务端菜单 → 按词汇表排序的刻度（词汇表外的值丢弃） */
    fun stops(levels: List<String>): List<String> = order.filter { levels.contains(it) }

    fun label(value: String?): String = if (value == null) "默认" else labels[value] ?: value

    /** 按 ref 找选项（等于 iOS `AgentCatalog.resolve`）：nil = 默认项 */
    fun resolve(options: List<LlmModelOption>, ref: String?): LlmModelOption? =
        if (ref == null) options.firstOrNull { it.isDefault } else options.firstOrNull { it.ref == ref }
}

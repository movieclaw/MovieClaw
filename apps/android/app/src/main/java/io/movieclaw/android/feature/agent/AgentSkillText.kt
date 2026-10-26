package io.movieclaw.android.feature.agent

/**
 * `/skill:名字` 占位符的解析与还原（逐条对齐 iOS `AgentSkillText`）。
 *
 * 发送时服务端把占位符**展开成技能正文**存进轨迹，所以读轨迹的 user 消息要先还原回 token 形态
 * （[toTokenForm]），气泡再把 token 画成 chip、正文只留用户自己的话（[parseTokens]）。
 */
internal object AgentSkillText {

    private val tokenRegex = Regex("""(?:^|(?<=\s))/skill:([A-Za-z0-9._-]+)""")
    private val blockRegex = Regex("""^<skill name="([^"]*)" location="[^"]*">\n[\s\S]*?\n</skill>\n*""")

    /** 插入输入框的占位符（尾随空格便于继续输入） */
    fun token(name: String) = "/skill:$name "

    /**
     * 拆出技能名（首现序去重）与剩余原文。
     *
     * [allow] = 已知技能名（小写）。传入时只拆名单内的 token——服务端只展开已知技能，
     * 拼错的 token 原样留给模型解释，气泡不能把它画成「已调用」的 chip。
     */
    fun parseTokens(text: String, allow: Set<String>? = null): Pair<List<String>, String> {
        val names = mutableListOf<String>()
        val seen = mutableSetOf<String>()
        val lines = text.split("\n").map { line ->
            val out = StringBuilder()
            var cursor = 0
            var touched = false
            tokenRegex.findAll(line).forEach { m ->
                val name = m.groupValues[1]
                val key = name.lowercase()
                if (allow != null && key !in allow) return@forEach
                touched = true
                if (seen.add(key)) names += name
                out.append(line, cursor, m.range.first)
                cursor = m.range.last + 1
            }
            if (!touched) {
                line
            } else {
                (out.toString() + line.substring(cursor)).replace(Regex("[ \t]+"), " ").trim()
            }
        }
        val kept = lines.filterIndexed { i, l -> l.isNotEmpty() || (i > 0 && i < lines.size - 1) }
        return names to kept.joinToString("\n")
    }

    /** 服务端已展开的 user 消息 → token 形态 `/skill:a /skill:b 用户原文`；非展开消息原样返回 */
    fun toTokenForm(text: String): String {
        val names = mutableListOf<String>()
        var rest = text
        while (true) {
            val m = blockRegex.find(rest) ?: break
            names += m.groupValues[1]
            rest = rest.removeRange(m.range)
        }
        if (names.isEmpty()) return text
        return (names.joinToString(" ") { "/skill:$it" } + " " + rest.trim()).trim()
    }
}

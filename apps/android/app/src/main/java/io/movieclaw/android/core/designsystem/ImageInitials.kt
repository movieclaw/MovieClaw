package io.movieclaw.android.core.designsystem

/**
 * 无图时的首字兜底（照 iOS `LibraryItemDetailView.initials(of:)` / 网页 `cast-row initialsOf`）：
 * 中日韩取首字；拉丁名单词取前两个字母、多词取首尾单词首字母，统一大写。
 * 之前各页各写 `name.take(1)`，拉丁名只剩一个字母，看着像缺字。
 */
object ImageInitials {
    fun of(name: String): String {
        val trimmed = name.trim()
        val first = trimmed.firstOrNull() ?: return "?"
        val isCjk = trimmed.unicodeScalars().any { v ->
            (v in 0x3400..0x9FFF) || (v in 0x3040..0x30FF) || (v in 0xAC00..0xD7AF)
        }
        if (isCjk) return first.toString()
        val words = trimmed.split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (words.isEmpty()) return "?"
        if (words.size == 1) return words[0].take(2).uppercase()
        return (words.first().take(1) + words.last().take(1)).uppercase()
    }

    private fun String.unicodeScalars(): Sequence<Int> = asSequence().map { it.code }
}

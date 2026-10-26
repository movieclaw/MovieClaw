package io.movieclaw.android.feature.agent

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * `/skill:名字` 占位符解析（与 iOS `AgentSkillText` 同语义）：
 * 气泡画 chip 靠它，拼错的 token 必须原样留给模型（不能画成「已调用」）。
 */
class AgentSkillTextTest {

    @Test
    fun `拆分 token 与正文`() {
        val (names, text) = AgentSkillText.parseTokens("/skill:recommend 帮我找几部片子")
        assertEquals(listOf("recommend"), names)
        assertEquals("帮我找几部片子", text)
    }

    @Test
    fun `未知技能保留字面文本`() {
        val (names, text) = AgentSkillText.parseTokens("/skill:typo 帮我找片", allow = setOf("recommend"))
        assertEquals(emptyList<String>(), names)
        assertEquals("/skill:typo 帮我找片", text)
    }

    @Test
    fun `已知技能大小写不敏感且去重`() {
        val (names, text) = AgentSkillText.parseTokens(
            "/skill:Recommend /skill:recommend 找片",
            allow = setOf("recommend"),
        )
        assertEquals(listOf("Recommend"), names)
        assertEquals("找片", text)
    }

    @Test
    fun `句中的 token 也能拆且不吞空格`() {
        val (names, text) = AgentSkillText.parseTokens("先 /skill:recommend 再挑")
        assertEquals(listOf("recommend"), names)
        assertEquals("先 再挑", text)
    }

    @Test
    fun `服务端展开的技能正文还原成 token 形态`() {
        val expanded = "<skill name=\"recommend\" location=\"/srv/skills/recommend\">\n正文正文\n</skill>\n用户原话"
        assertEquals("/skill:recommend 用户原话", AgentSkillText.toTokenForm(expanded))
    }

    @Test
    fun `没有展开块时原样返回`() {
        assertEquals("普通提问", AgentSkillText.toTokenForm("普通提问"))
    }
}

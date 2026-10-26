package io.movieclaw.android.feature.agent

import io.movieclaw.android.core.model.LlmModelOption
import org.junit.Assert.assertEquals
import org.junit.Test

/** 选择校验（对齐 iOS `AgentComposerPrefs.reconciled`）：模型下线、档位无效、清单为空三种情况。 */
class AgentComposerPrefsTest {

    private val flash = LlmModelOption(ref = "flash", label = "flash", thinkingLevels = listOf("low", "high"))
    private val pro = LlmModelOption(ref = "pro", label = "pro", isDefault = true, thinkingLevels = listOf("low", "medium", "high"))

    @Test
    fun `模型还在清单里时保留档位`() {
        val out = AgentComposerPrefs.reconcile(
            AgentComposerPrefs.Choice("pro", "medium"),
            listOf(pro, flash),
        )
        assertEquals(AgentComposerPrefs.Choice("pro", "medium"), out)
    }

    @Test
    fun `模型下线则模型与档位一起丢弃`() {
        val out = AgentComposerPrefs.reconcile(
            AgentComposerPrefs.Choice("gone", "high"),
            listOf(pro, flash),
        )
        assertEquals(AgentComposerPrefs.Choice(null, null), out)
    }

    @Test
    fun `档位不在该模型菜单里则只丢档位`() {
        val out = AgentComposerPrefs.reconcile(
            AgentComposerPrefs.Choice("flash", "medium"),
            listOf(pro, flash),
        )
        assertEquals(AgentComposerPrefs.Choice("flash", null), out)
    }

    @Test
    fun `清单为空时原样返回`() {
        val choice = AgentComposerPrefs.Choice("pro", "high")
        assertEquals(choice, AgentComposerPrefs.reconcile(choice, emptyList()))
    }
}

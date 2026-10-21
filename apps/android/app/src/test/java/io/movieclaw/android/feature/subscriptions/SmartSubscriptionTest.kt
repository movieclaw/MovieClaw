package io.movieclaw.android.feature.subscriptions

import io.movieclaw.android.core.model.MediaBrief
import io.movieclaw.android.core.model.PrepareView
import io.movieclaw.android.core.model.SmartPlanView
import io.movieclaw.android.core.model.SmartQuestionView
import io.movieclaw.android.core.model.SmartScopeOptionView
import io.movieclaw.android.core.model.SubscriptionCreateRequest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNamingStrategy
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** 智能订阅记忆的客户端规则：与 Web smart-plan-card、iOS SmartChoice 同口径。 */
class SmartSubscriptionTest {
    private val plan = SmartPlanView(
        configured = true,
        profileRevision = 1,
        memoryRevision = 3,
        resolution = "2160p",
        source = "web-dl",
        subtitleLanguage = "ko",
        subtitleLanguageLabel = "韩语",
        subtitleLine = "韩语 · 只下带中文字幕的",
        question = SmartQuestionView("ko", "这是韩语片，要中文字幕吗？", "要，只下带中文字幕的", "不用，我看得懂韩语"),
        scopeOptions = listOf(SmartScopeOptionView("only", "只这部"), SmartScopeOptionView("region:tv:KR", "韩国的剧")),
        canEdit = true,
    )

    @Test
    fun unansweredQuestionSendsTheDefaultSoItIsNotAskedAgain() {
        val fields = smartFields(plan, SmartChoice())
        assertEquals("subtitles", fields.language)
        assertNull(fields.resolution)
        assertNull(fields.scope)
        assertEquals(3L, fields.memoryRevision)
    }

    @Test
    fun onlyChangedQualityIsSentWithItsScope() {
        val fields = smartFields(plan, SmartChoice(resolution = "1080p", source = "web-dl", scope = "region:tv:KR"))
        assertEquals("1080p", fields.resolution)
        assertNull(fields.source)
        assertEquals("region:tv:KR", fields.scope)
        assertTrue(SmartChoice(resolution = "1080p").qualityChanged(plan))
        assertFalse(SmartChoice(resolution = "2160p").qualityChanged(plan))
    }

    @Test
    fun membersNeverSendMemoryChanges() {
        val fields = smartFields(plan.copy(canEdit = false), SmartChoice(language = "understood", resolution = "1080p"))
        assertEquals(SmartFields(null, null, null, null, null), fields)
    }

    @Test
    fun awaitingSubtitlesIsShownAndOtherStatesKeepTheirMilestones() {
        val awaiting = buildJsonObject { put("reason", "awaiting_subtitles"); put("candidate_key", "s/1"); put("subtitle_blocked", 2) }
        assertEquals("等字幕" to "已有 2 个原版，在等带字幕的版本", smartPresentation(awaiting, "wanted"))
        val expired = buildJsonObject { put("reason", "deadline_awaiting_subtitles"); put("candidate_key", "s/1") }
        assertEquals("等字幕", smartPresentation(expired, "wanted")?.first)
        assertNull(smartPresentation(awaiting, "grabbed"))
        assertNull(smartPresentation(buildJsonObject { put("reason", "deadline_no_candidate") }, "wanted"))
    }

    @Test
    fun smartModeNeedsSavedSettingsBeforeSubmitting() {
        val media = MediaBrief(kind = "movie", tmdbId = 701, title = "奥本海默")
        val unset = SubscribeViewModel.UiState(preview = PrepareView(status = "ready", media = media, smart = SmartPlanView(canEdit = true)))
        assertEquals("请先完成智能设置", submitBlockReason(unset))
        val member = unset.copy(preview = unset.preview!!.copy(smart = SmartPlanView()))
        assertEquals("请管理员先完成智能设置，或选择规则模式", submitBlockReason(member))
        assertNull(submitBlockReason(unset.copy(selectionMode = "rules")))
        assertNull(submitBlockReason(unset.copy(preview = unset.preview!!.copy(smart = plan))))
        // 旧服务端没有智能摘要：不拦，提交走规则模式
        assertNull(submitBlockReason(unset.copy(preview = unset.preview!!.copy(smart = null))))
    }

    @Test
    fun createRequestOmitsSmartFieldsInRulesModeAndSendsThemInSmartMode() {
        val json = Json { encodeDefaults = true; explicitNulls = false; namingStrategy = JsonNamingStrategy.SnakeCase }
        val rules = json.encodeToString(SubscriptionCreateRequest.serializer(), SubscriptionCreateRequest(titleRef = "tmdb:movie:705", selectionMode = "rules"))
        assertFalse(rules.contains("smart_"))
        val smart = json.encodeToString(
            SubscriptionCreateRequest.serializer(),
            SubscriptionCreateRequest(titleRef = "tmdb:movie:701", selectionMode = "smart", smartProfileRevision = 1, smartLanguageAnswer = "subtitles", smartMemoryRevision = 0),
        )
        assertTrue(smart, smart.contains("\"smart_language_answer\":\"subtitles\""))
        assertTrue(smart, smart.contains("\"smart_memory_revision\":0"))
        assertFalse(smart, smart.contains("rule_set_id"))
    }

    @Test
    fun deadlinesAreShownInLocalTime() {
        val shanghai = java.time.ZoneId.of("Asia/Shanghai")
        assertEquals("10-22 07:37", localTimeText("2026-10-21T23:37:00", shanghai))
        assertEquals("10-22 07:37", localTimeText("2026-10-21T23:37:00+00:00", shanghai))
    }
}

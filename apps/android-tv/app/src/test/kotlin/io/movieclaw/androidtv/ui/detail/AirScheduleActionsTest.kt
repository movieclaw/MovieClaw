package io.movieclaw.androidtv.ui.detail

import io.movieclaw.core.model.generated.MediaBrief
import io.movieclaw.core.model.generated.PrepareView
import io.movieclaw.core.model.generated.SeasonOverview
import io.movieclaw.core.model.generated.SmartPlanView
import io.movieclaw.core.model.generated.SubscriptionCreateView
import io.movieclaw.core.network.ApiException
import io.movieclaw.core.network.ApiTransport
import io.movieclaw.core.network.generated.McApi
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 「订阅追更」撞上智能设置 409 后要重读 title-preview，换掉摘要和版本号再等用户确认。
 * 季和续订保持打开时的那份（同手机订阅弹层）。不要拿旧版本自动重试。
 */
class AirScheduleActionsTest {
    @Test
    fun smartVersionConflictRefreshesTheDraftBeforeTheNextConfirm() = runBlocking {
        val transport = Script(mode = Script.Mode.Conflict)
        val actions = AirScheduleActions(McApi(transport))
        actions.beginSubscribe(42)
        val opened = actions.stage as AirSubscribeStage.Confirming
        assertEquals(listOf(1L), opened.draft.seasons)
        assertEquals(3L, opened.draft.smart?.profileRevision)

        assertFalse(actions.confirmSubscribe(3))
        val refreshed = actions.stage as AirSubscribeStage.Confirming
        assertEquals("季是打开时确认的范围，不随新预检改", listOf(1L), refreshed.draft.seasons)
        assertTrue(refreshed.draft.followFuture)
        assertEquals(4L, refreshed.draft.smart?.profileRevision)
        assertEquals(10L, refreshed.draft.smart?.memoryRevision)
        assertEquals(listOf("优先 1080p WEB-DL"), refreshed.draft.quality)
        assertEquals("智能设置已在别处更新，请重新确认", actions.message?.text)
        assertTrue(actions.message!!.isError)
        assertEquals(listOf("tmdb:tv:42", "tmdb:tv:42"), transport.previews)
        assertEquals(listOf(3L to 9L), transport.creates)
        assertEquals(listOf(3L), transport.libraries)

        assertTrue(actions.confirmSubscribe(3))
        assertTrue(actions.stage is AirSubscribeStage.Idle)
        assertFalse(actions.message!!.isError)
        assertEquals("第二次确认带新版本，不再提交打开时的 3", listOf(3L to 9L, 4L to 10L), transport.creates)
        assertEquals(2, transport.previews.size)
    }

    @Test
    fun otherCreateFailuresKeepTheOldDraft() = runBlocking {
        val transport = Script(mode = Script.Mode.ServerError)
        val actions = AirScheduleActions(McApi(transport))
        actions.beginSubscribe(42)
        assertFalse(actions.confirmSubscribe(3))
        val draft = (actions.stage as AirSubscribeStage.Confirming).draft
        assertEquals(3L, draft.smart?.profileRevision)
        assertEquals(listOf(1L), draft.seasons)
        assertEquals("不是版本冲突就不要重读预检", 1, transport.previews.size)
        assertEquals("服务器出错了", actions.message?.text)
    }

    @Test
    fun failedRefreshKeepsTheDraftThatWasConfirmed() = runBlocking {
        val transport = Script(mode = Script.Mode.RefreshFails)
        val actions = AirScheduleActions(McApi(transport))
        actions.beginSubscribe(42)
        assertFalse(actions.confirmSubscribe(3))
        val draft = (actions.stage as AirSubscribeStage.Confirming).draft
        assertEquals("预检没读到就不换成新版本", 3L, draft.smart?.profileRevision)
        assertEquals(listOf("优先 4K WEB-DL"), draft.quality)
        assertEquals("智能设置已在别处更新，请重新确认", actions.message?.text)
        assertEquals(listOf(3L to 9L), transport.creates)
    }
}

/** 假服务端：第一次创建可以 409，随后的 title-preview 给出新版本（另一端刚改完设置） */
private class Script(private val mode: Mode) : ApiTransport {
    enum class Mode { Conflict, ServerError, RefreshFails }

    var profile = 3L
    var memory = 9L
    var quality = "优先 4K WEB-DL"
    var suggested = 1L
    val previews = mutableListOf<String>()
    val creates = mutableListOf<Pair<Long, Long>>()
    val libraries = mutableListOf<Long>()

    private fun prepare() = PrepareView(
        status = "ready",
        media = MediaBrief(mediaItemId = 7, kind = "tv", tmdbId = 42, title = "长街夜行", originalTitle = "Long Street", status = "Returning Series"),
        seasons = listOf(SeasonOverview(seasonNumber = suggested, name = "季", airedCount = 10, ownedCount = 1)),
        suggestedSeasons = listOf(suggested),
        smart = SmartPlanView(configured = true, profileRevision = profile, memoryRevision = memory, canEdit = true, qualityLabel = quality),
    )

    @Suppress("UNCHECKED_CAST")
    override suspend fun <T> send(
        method: String, path: String, query: List<Pair<String, String>>, body: JsonElement?,
        response: KSerializer<T>, enveloped: Boolean,
    ): T {
        when (path) {
            "/subscriptions/title-preview" -> {
                if (mode == Mode.RefreshFails && previews.isNotEmpty()) throw ApiException(500, "INTERNAL", "预检失败")
                previews += body.string("title_ref")
                return prepare() as T
            }
            "/subscriptions" -> {
                creates += body.long("smart_profile_revision") to body.long("smart_memory_revision")
                libraries += body.long("library_id")
                if (mode == Mode.ServerError) throw ApiException(500, "INTERNAL", "服务器出错了")
                if (creates.size == 1) {
                    // 另一端刚改完设置：这次拒绝，下一次预检给出新版本
                    profile = 4
                    memory = 10
                    quality = "优先 1080p WEB-DL"
                    suggested = 2
                    throw ApiException(409, "SMART_VERSION_CONFLICT", "智能设置已在别处更新，请重新确认")
                }
                return SubscriptionCreateView() as T
            }
            else -> error("unexpected $method $path")
        }
    }

    private fun JsonElement?.string(name: String) = (this as? JsonObject)?.get(name)?.jsonPrimitive?.content ?: ""

    private fun JsonElement?.long(name: String) = (this as? JsonObject)?.get(name)?.jsonPrimitive?.long
        ?: error("missing $name")
}

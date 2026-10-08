package io.movieclaw.android.core.playback

import io.movieclaw.android.core.AppScopes

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import io.movieclaw.android.core.model.PlaybackMetricPayload
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.BuildInfo
import java.io.File
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json

private val Context.qoeStore by preferencesDataStore(name = "mc_qoe")

/**
 * 播放 QoE(iOS PlaybackRecord / playback-qoe 的对应物):
 *   每次播放尝试记录启动耗时、seek、重缓冲、丢帧等;
 *   报告先落盘(队列),尽力上报 `POST /playback/metrics`;
 *   用 active.json 心跳标记异常退出(崩溃/被杀),下次启动补一份 abnormal_exit 报告。
 * 服务端只做统计,不上报也不影响播放 —— 因此全程 best-effort。
 */
@Singleton
class PlaybackQoe @Inject constructor(
    @ApplicationContext private val context: Context,
    private val apiFactory: ApiFactory,
    private val json: Json,
) {

    private val scope = AppScopes.io("PlaybackQoe")

    /** 一次播放尝试的累计数据 */
    class Attempt(
        val id: String,
        val origin: String,
        val mediaItemId: Long,
        val seasonNumber: Int,
        val episodeNumber: Int,
        val engine: String,
        val tier: Int,
        val degradedFrom: Int?,
        val fileId: Long?,
        val hwBackend: String?,
        val startedAtMs: Long,
    ) {
        var firstFrameMs: Long? = null
        var seekCount: Int = 0
        var rebufferCount: Int = 0
        var rebufferMs: Long = 0
        var playedMs: Long = 0
        var positionMs: Long = 0
        var watchedEnding: Boolean = false
        var errorKind: String = ""
        var errorCategory: String = ""
    }

    fun begin(
        origin: String,
        mediaItemId: Long,
        seasonNumber: Int,
        episodeNumber: Int,
        engine: String,
        tier: Int,
        degradedFrom: Int?,
        fileId: Long?,
        hwBackend: String?,
    ): Attempt {
        val attempt = Attempt(
            id = UUID.randomUUID().toString(),
            origin = origin,
            mediaItemId = mediaItemId,
            seasonNumber = seasonNumber,
            episodeNumber = episodeNumber,
            engine = engine,
            tier = tier,
            degradedFrom = degradedFrom,
            fileId = fileId,
            hwBackend = hwBackend,
            startedAtMs = System.currentTimeMillis(),
        )
        // 心跳:异常退出时靠它把这次尝试捞回来(异步落盘,不阻塞起播)
        val marker = ActiveMarker(
            id = attempt.id,
            origin = attempt.origin,
            mediaItemId = attempt.mediaItemId,
            seasonNumber = attempt.seasonNumber,
            episodeNumber = attempt.episodeNumber,
            engine = attempt.engine,
            tier = attempt.tier,
            startedAtMs = attempt.startedAtMs,
        )
        scope.launch { context.qoeStore.edit { it[KEY_ACTIVE] = json.encodeToString(marker) } }
        return attempt
    }

    fun noteFirstFrame(attempt: Attempt) {
        if (attempt.firstFrameMs == null) {
            attempt.firstFrameMs = System.currentTimeMillis() - attempt.startedAtMs
        }
    }

    fun noteSeek(attempt: Attempt) {
        attempt.seekCount++
    }

    fun noteBuffering(attempt: Attempt, buffering: Boolean) {
        if (buffering) {
            // 一次连续缓冲只算一次
            val second = (System.currentTimeMillis() - attempt.startedAtMs) / 1000
            if (lastBufferingSecond != second) {
                attempt.rebufferCount++
                lastBufferingSecond = second
            }
            attempt.rebufferMs += 1_000
        }
    }

    private var lastBufferingSecond = -1L

    fun noteProgress(attempt: Attempt, positionMs: Long, durationMs: Long) {
        attempt.positionMs = positionMs
        if (durationMs > 0 && positionMs >= durationMs * 0.92) attempt.watchedEnding = true
        attempt.playedMs = System.currentTimeMillis() - attempt.startedAtMs
    }

    fun noteError(attempt: Attempt, kind: String, category: String) {
        attempt.errorKind = kind
        attempt.errorCategory = category
    }

    /** 正常收尾:判定结果并上报(落盘队列 + 尽力发送) */
    fun finish(attempt: Attempt, forcedOutcome: String? = null) {
        val outcome = forcedOutcome ?: when {
            attempt.errorKind.isNotEmpty() -> "failed"
            attempt.firstFrameMs == null -> "exit_before_start"
            attempt.watchedEnding -> "watched"
            else -> "exited"
        }
        val libraryId = runCatching { android.net.Uri.parse(attempt.origin).host }.getOrNull()
        val payload = PlaybackMetricPayload(
            tier = attempt.tier,
            degradedFrom = attempt.degradedFrom,
            engine = attempt.engine,
            hwBackend = attempt.hwBackend.orEmpty(),
            rebufferMs = attempt.rebufferMs,
            rebufferCount = attempt.rebufferCount,
            seekCount = attempt.seekCount,
            watchedMs = attempt.playedMs,
            attemptId = attempt.id,
            outcome = outcome,
            mediaItemId = attempt.mediaItemId,
            seasonNumber = attempt.seasonNumber,
            episodeNumber = attempt.episodeNumber,
            client = "android",
            networkClass = try {
                PlaybackNetwork.of(libraryId).id
            } catch (_: Exception) {
                ""
            },
            appVersion = BuildInfo.APP_VERSION,
            firstFrameMs = attempt.firstFrameMs?.toInt(),
            playingMs = attempt.playedMs.toInt(),
            errorKind = attempt.errorKind,
            errorCategory = attempt.errorCategory,
        )
        scope.launch { context.qoeStore.edit { it.remove(KEY_ACTIVE) } }
        enqueueAndSend(attempt.origin, payload)
    }

    /** 桌面端一样的「异常退出补报」:启动时发现残留的 active.json 就补一份报告 */
    fun recoverAbnormalExit() {
        scope.launch {
            val raw = context.qoeStore.data.first()[KEY_ACTIVE] ?: return@launch
            val active = runCatching { json.decodeFromString<ActiveMarker>(raw) }.getOrNull() ?: return@launch
            context.qoeStore.edit { it.remove(KEY_ACTIVE) }
            // 只补最近 24 小时内的,避免陈年残留反复上报
            if (System.currentTimeMillis() - active.startedAtMs > 24 * 3600_000L) return@launch
            val payload = PlaybackMetricPayload(
                tier = active.tier,
                engine = active.engine,
                attemptId = active.id,
                outcome = "abnormal_exit",
                mediaItemId = active.mediaItemId,
                seasonNumber = active.seasonNumber,
                episodeNumber = active.episodeNumber,
                client = "android",
                appVersion = BuildInfo.APP_VERSION,
            )
            enqueueAndSend(active.origin, payload)
        }
    }

    /**
     * 启动时冲刷未发出去的队列。注意这是在**冷启动**跑的，会话令牌可能还没恢复好，
     * 所以第一条就 401 时直接收工：队列整条重放会在一次启动里刷出十几条
     * `401 POST /api/v1/playback/metrics`（实机日志抓到过），白耗电还把日志刷满。
     * 剩下的等登录之后再冲（登录成功会再调一次本方法）。
     */
    fun flushPending() {
        scope.launch {
            val dir = queueDir()
            val files = dir.listFiles()?.takeIf { it.isNotEmpty() } ?: return@launch
            for (file in files) {
                val entry = runCatching {
                    json.decodeFromString<QueuedReport>(file.readText())
                }.getOrNull() ?: run {
                    file.delete()
                    continue
                }
                when (send(entry.origin, entry.payload)) {
                    // 4xx = 这条报告永远发不出去（iOS PlaybackReportQueue 对 400..<500 直接删）
                    SendResult.DROP -> file.delete()
                    SendResult.OK -> file.delete()
                    SendResult.UNAUTH -> return@launch
                    SendResult.RETRY -> Unit
                }
            }
            // 超过 7 天的报告直接丢弃(iOS 同样保留 7 天)
            files.filter { System.currentTimeMillis() - it.lastModified() > 7 * 24 * 3600_000L }
                .forEach { it.delete() }
        }
    }

    private fun enqueueAndSend(origin: String, payload: PlaybackMetricPayload) {
        scope.launch {
            val file = File(queueDir(), "report-${payload.attemptId ?: UUID.randomUUID()}.json")
            runCatching {
                file.writeText(json.encodeToString(QueuedReport(origin, payload)))
            }
            when (send(origin, payload)) {
                SendResult.OK, SendResult.DROP -> runCatching { file.delete() }
                // 401（还没登录）与网络失败都留着文件，下次再发
                SendResult.UNAUTH, SendResult.RETRY -> Unit
            }
        }
    }

    private enum class SendResult { OK, DROP, UNAUTH, RETRY }

    /**
     * OK = 已上报；DROP = 服务端明确拒绝（4xx），重发也不会成功；UNAUTH = 401，等登录后再发；
     * RETRY = 网络/5xx，留着下次。
     */
    private suspend fun send(origin: String, payload: PlaybackMetricPayload): SendResult =
        try {
            apiFactory.forOrigin(origin).reportMetrics(payload)
            SendResult.OK
        } catch (e: retrofit2.HttpException) {
            when (e.code()) {
                401 -> SendResult.UNAUTH
                in 400..499 -> SendResult.DROP
                else -> SendResult.RETRY
            }
        } catch (e: Exception) {
            SendResult.RETRY
        }

    private fun queueDir(): File = File(context.filesDir, "playback-reports").apply { mkdirs() }


    @kotlinx.serialization.Serializable
    private data class ActiveMarker(
        val id: String,
        val origin: String,
        val mediaItemId: Long,
        val seasonNumber: Int,
        val episodeNumber: Int,
        val engine: String,
        val tier: Int,
        val startedAtMs: Long,
    )

    @kotlinx.serialization.Serializable
    private data class QueuedReport(val origin: String, val payload: PlaybackMetricPayload)

    private companion object {
        val KEY_ACTIVE = stringPreferencesKey("active_attempt")
    }
}

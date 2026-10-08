package io.movieclaw.android.core.network

import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.coroutineContext
import kotlin.math.min
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.isActive
import okhttp3.Request
import okhttp3.Response
import okhttp3.sse.EventSource
import okhttp3.sse.EventSourceListener
import okhttp3.sse.EventSources

data class SseEvent(val name: String, val data: String, val id: String?)

/**
 * SSE 客户端(实时通道,独立连接池防被图片请求饿死):
 * 断线自动重连并回传 Last-Event-ID(服务端据此续传),终止事件出现后正常收尾不重连。
 * 消费方:/search/torrents/stream(站点搜索)、后续的 /jobs/stream、/sessions/{id}/events。
 */
@Singleton
class EventStream @Inject constructor(
    @LiveChannel private val client: okhttp3.OkHttpClient,
    private val sessionRepository: SessionRepository,
    private val apiFactory: ApiFactory,
) {

    fun reliableEvents(
        path: String,
        terminalEvents: Set<String> = DEFAULT_TERMINAL,
    ): Flow<SseEvent> = flow {
        val origin = sessionRepository.ui.value.origin
            ?: throw ApiException("NO_SERVER", "尚未连接服务器")
        val identity = sessionRepository.requestIdentity(origin)
        val boundClient = identityClient(client, identity)
        val base = apiFactory.apiBaseOf(origin) ?: "$origin/api/v1"
        var lastEventId: String? = null
        var attempt = 0
        while (coroutineContext.isActive) {
            if (!sessionRepository.isCurrentIdentity(identity)) {
                throw ApiException("SESSION_CHANGED", "账号已切换，实时连接已结束")
            }
            var finished = false
            var failure: Throwable? = null
            // catch 放在 emit 上游：界面处理/解码抛错不能当网络错误重放，也不能吞取消。
            streamOnce(boundClient, base, path, lastEventId, terminalEvents)
                .catch { error ->
                    if (error is CancellationException) throw error
                    failure = error
                }.collect { event ->
                    if (!sessionRepository.isCurrentIdentity(identity)) {
                        throw ApiException("SESSION_CHANGED", "账号已切换，实时连接已结束")
                    }
                    emit(event)
                    event.id?.let { lastEventId = it }
                    if (event.name in terminalEvents) finished = true
                }
            if (finished) return@flow
            attempt++
            if (attempt > MAX_ATTEMPTS) {
                throw (failure ?: ApiException("SSE_INCOMPLETE", "实时连接结束但没有完成事件，请重试"))
            }
            delay(backoffMs(attempt))
        }
    }

    /** 单次连接绑定服务器与身份；重连不会跳到另一个账号。 */
    internal fun streamOnce(
        client: okhttp3.OkHttpClient,
        base: String,
        path: String,
        lastEventId: String?,
        terminalEvents: Set<String>,
    ): Flow<SseEvent> = callbackFlow {
        val request = Request.Builder()
            .url(base.trimEnd('/') + "/" + path.trimStart('/'))
            .header("Accept", "text/event-stream")
            .apply { lastEventId?.let { header("Last-Event-ID", it) } }
            .build()
        val listener = object : EventSourceListener() {
            override fun onEvent(eventSource: EventSource, id: String?, type: String?, data: String) {
                val event = SseEvent(name = type ?: "message", data = data, id = id)
                if (trySend(event).isFailure) {
                    // 有界缓冲满即断线，从最后已处理的 id 续传，禁止静默丢字/终态。
                    close(ApiException("SSE_BACKPRESSURE", "实时事件过快，正在恢复连接"))
                    eventSource.cancel()
                } else if (event.name in terminalEvents) {
                    close()
                    eventSource.cancel()
                }
            }

            override fun onClosed(eventSource: EventSource) { close() }

            override fun onFailure(eventSource: EventSource, t: Throwable?, response: Response?) {
                close(t ?: ApiException("SSE_FAILED", "实时连接中断(HTTP ${response?.code})"))
            }
        }
        val source = EventSources.createFactory(client).newEventSource(request, listener)
        awaitClose { source.cancel() }
    }

    private fun backoffMs(attempt: Int): Long =
        min(MAX_BACKOFF_MS, BASE_BACKOFF_MS * (1L shl min(attempt, 5)))

    private companion object {
        const val BASE_BACKOFF_MS = 1_000L
        const val MAX_BACKOFF_MS = 30_000L
        const val MAX_ATTEMPTS = 5
        val DEFAULT_TERMINAL = setOf("done", "agent_done", "agent_error", "agent_cancelled")
    }
}

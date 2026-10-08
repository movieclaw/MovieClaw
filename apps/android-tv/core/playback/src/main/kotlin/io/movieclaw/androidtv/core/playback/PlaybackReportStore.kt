package io.movieclaw.androidtv.core.playback

import io.movieclaw.androidtv.core.model.McJson
import io.movieclaw.androidtv.core.model.generated.PlaybackMetricPayload
import kotlinx.serialization.builtins.ListSerializer
import java.io.File

/**
 * 播放记录的本机暂存（docs/design/playback-qoe.md §2）：
 *
 * - **正在播放**：播放中每 10 秒存一份快照（单独一个小文件，原子替换；不写进偏好存储——那会把整个偏好文件连同
 *   登录凭证每 10 秒重写一遍）。正常离开时删掉；下次打开播放器还在，说明上次闪退 / 被系统杀了，按「异常退出」
 *   补报（附上崩溃栈，如果有）。
 * - **待发**：离开时的收尾记录先进队列再发，发成功才删；断网时留到下次补发（最多 20 条，偏好存储，只在离开时写）。
 * - **崩溃栈**：进程崩溃那一刻同步写一个小文件。
 *
 * [dir] 为 null（单测之外不会）时只有队列可用。
 */
class PlaybackReportStore(private val prefs: PrefsStore, private val dir: File?) {
    private val runningFile get() = dir?.let { File(it, RUNNING_FILE) }
    private val crashFile get() = dir?.let { File(it, CRASH_FILE) }

    fun saveRunning(payload: PlaybackMetricPayload) {
        val target = runningFile ?: return
        val temp = File(target.parentFile, "$RUNNING_FILE.tmp")
        temp.writeText(McJson.encodeToString(PlaybackMetricPayload.serializer(), payload))
        temp.renameTo(target)
    }

    fun clearRunning() {
        runningFile?.delete()
    }

    /** 上次没收尾的那次播放，改成「异常退出」；崩溃栈接在日志尾巴后面 */
    fun takeAbnormal(): PlaybackMetricPayload? {
        val file = runningFile?.takeIf { it.exists() } ?: return null
        val text = runCatching { file.readText() }.getOrNull()
        file.delete()
        if (text == null) return null
        val saved = runCatching { McJson.decodeFromString(PlaybackMetricPayload.serializer(), text) }.getOrNull() ?: return null
        val crash = crashFile?.takeIf { it.exists() }?.let { file ->
            runCatching { file.readText() }.getOrNull().also { file.delete() }
        }
        val tail = listOfNotNull(saved.logTail, crash?.let { "—— 崩溃 ——\n$it" }).joinToString("\n").takeLast(MAX_TAIL)
        return saved.copy(outcome = "abnormal_exit", logTail = tail.ifEmpty { null })
    }

    fun enqueue(payload: PlaybackMetricPayload) {
        val queue = (queued() + payload).takeLast(MAX_QUEUE)
        prefs.putString(KEY_QUEUE, McJson.encodeToString(QUEUE, queue))
    }

    fun queued(): List<PlaybackMetricPayload> =
        prefs.string(KEY_QUEUE)?.let { runCatching { McJson.decodeFromString(QUEUE, it) }.getOrNull() }.orEmpty()

    fun remove(attemptId: String?) {
        val rest = queued().filterNot { it.attemptId == attemptId }
        prefs.putString(KEY_QUEUE, if (rest.isEmpty()) null else McJson.encodeToString(QUEUE, rest))
    }

    companion object {
        private const val RUNNING_FILE = "playback-running.json"
        private const val KEY_QUEUE = "qoe.queue"
        private const val MAX_QUEUE = 20
        private const val MAX_TAIL = 32 * 1024
        private val QUEUE = ListSerializer(PlaybackMetricPayload.serializer())
        const val CRASH_FILE = "playback-crash.txt"

        /** 进程崩溃时调用（未捕获异常处理器里）：同步写崩溃栈 + 引擎日志尾巴 */
        fun recordCrash(dir: File, error: Throwable) {
            runCatching {
                File(dir, CRASH_FILE).writeText((error.stackTraceToString().take(16 * 1024) + "\n" + EngineLog.tail()).takeLast(MAX_TAIL))
            }
        }
    }
}

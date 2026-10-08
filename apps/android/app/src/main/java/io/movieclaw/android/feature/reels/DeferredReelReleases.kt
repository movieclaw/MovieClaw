package io.movieclaw.android.feature.reels

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * 延后释放只让开滑动动画，不转移资源所有权。调用与 scope 取消都在主线程。
 * completion 回调也覆盖「协程还没执行就被取消」，离页则同步冲刷全部资源。
 */
internal class DeferredReelReleases<T>(
    private val scope: CoroutineScope,
    private val release: (T) -> Unit,
) {
    private val pending = mutableMapOf<T, Job>()

    fun defer(resource: T) {
        val job = scope.launch(start = CoroutineStart.LAZY) { delay(500) }
        pending[resource] = job
        job.invokeOnCompletion {
            if (pending[resource] === job) {
                pending.remove(resource)
                release(resource)
            }
        }
        job.start()
    }

    fun flush() {
        val resources = pending.toMap()
        pending.clear()
        resources.forEach { (resource, job) ->
            release(resource)
            job.cancel()
        }
    }
}

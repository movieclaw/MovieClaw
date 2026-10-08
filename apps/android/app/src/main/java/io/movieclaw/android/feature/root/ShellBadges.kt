package io.movieclaw.android.feature.root

import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.Info
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.TabDot
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * 底栏页签状态点（iOS `ShellBadges` 的对应物，口径同 Web `glass-tab-bar` 的 `pickActivityDot`）：
 *
 *  · **活动页签**：有需要处理的任务 → 红；有人在看 → 绿；只有进行中的任务 → 蓝；都没有不显示
 *    （按优先级只表达当前最该被看见的一件事）；
 *  · **「我的」页签**：有可用更新（新应用版本 / 新识别模型）→ 蓝点。
 *
 * 数据由这里**在前台轮询**（活动 30 秒、更新 600 秒——更新与 iOS 的 10 分钟同值），走
 * 通用通道；失败保留上次结果、下一轮自愈。活动页自己那份更密（SSE + 8 秒），这份只管点，
 * 逻辑复用同一份派生（`deriveTaskActivity`，全站只此一处）。
 */
@Singleton
class ShellBadges @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
) {
    private val _activityDot = MutableStateFlow<TabDot?>(null)
    val activityDot: StateFlow<TabDot?> = _activityDot.asStateFlow()

    private val _moreDot = MutableStateFlow<TabDot?>(null)
    val moreDot: StateFlow<TabDot?> = _moreDot.asStateFlow()

    /** 前台常驻轮询：调用方用 `repeatOnLifecycle(RESUMED)` 包住，退后台自动停、回前台立刻刷一次 */
    suspend fun runForegroundPolling() {
        coroutineScope {
            launch {
                refreshActivity()
                // 换账号 / 换服务器时立刻按新身份重算，其余时候 30 秒一轮
                while (true) {
                    delay(30_000)
                    refreshActivity()
                }
            }
            launch {
                refreshUpdate()
                while (true) {
                    delay(600_000)
                    refreshUpdate()
                }
            }
        }
    }

    private suspend fun refreshActivity() {
        val origin = repository.ui.value.origin ?: return
        val api = runCatching { apiFactory.forOrigin(origin) }.getOrNull() ?: return
        val jobs = runCatching { api.jobs().dataOrThrow().items }.getOrNull() ?: return
        val downloads = runCatching { api.downloadTasks().dataOrThrow().items }.getOrDefault(emptyList())
        val activity = io.movieclaw.android.feature.activity.deriveTaskActivity(downloads, jobs)
        val live = runCatching { api.playbackActivity().dataOrThrow().sessions.size }.getOrDefault(0)
        _activityDot.value = when {
            activity.attentionTotal > 0 -> TabDot(Danger, "有需要处理的任务")
            live > 0 -> TabDot(Success, "有人正在观看")
            activity.activeTotal > 0 -> TabDot(Info, "有任务进行中")
            else -> null
        }
    }

    private suspend fun refreshUpdate() {
        val origin = repository.ui.value.origin ?: return
        val api = runCatching { apiFactory.forOrigin(origin) }.getOrNull() ?: return
        val pending = runCatching { api.pendingUpdate().dataOrThrow() }.getOrNull() ?: return
        _moreDot.value = if (pending.appVersion != null || pending.modelTag != null) {
            TabDot(Info, "有可用更新")
        } else {
            null
        }
    }
}

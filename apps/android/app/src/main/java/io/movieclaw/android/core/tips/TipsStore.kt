package io.movieclaw.android.core.tips

import io.movieclaw.android.core.model.InvalidateTipRequest
import io.movieclaw.android.core.model.TipRecordView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * 使用提示的安卓端引擎（docs/design/tips.md，对标 iOS `TipsStore`）：状态在服务端、每个账号一份，
 * 规则与文案写在用到提示的页面里。
 *
 * 判定同 Web / iOS：快照拉回来之前不出任何提示；已作废的永不出现。上报一律先改本地、再以服务端
 * 返回的那一行为准；网络失败静默（提示不是关键功能），旧服务器没有接口时提示就不出现。
 * 事件计数规则、展示次数上限、同屏排队与频率节流，等有提示用得上时再加。
 *
 * 单例跨账号存活，所以快照记着属于谁（服务器地址 + 用户名，同媒体库首页快照）：换了账号就重新拉。
 */
@Singleton
class TipsStore @Inject constructor(
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
) {
    private data class Snapshot(val owner: String, val records: Map<String, TipRecordView>)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val snapshot = MutableStateFlow<Snapshot?>(null)
    private var loadingOwner: String? = null

    private fun owner(): String? {
        val origin = repository.ui.value.origin ?: return null
        return "$origin|${repository.ui.value.session?.username.orEmpty()}"
    }

    /** 以当前账号拉一次快照（已经拉到、或正在拉就什么都不做；失败下次用到时再拉） */
    fun ensureLoaded() {
        val owner = owner() ?: return
        if (snapshot.value?.owner == owner || loadingOwner == owner) return
        val origin = repository.ui.value.origin ?: return
        loadingOwner = owner
        scope.launch {
            val state = runCatching { apiFactory.forOrigin(origin).tipsState().dataOrThrow() }.getOrNull()
            if (loadingOwner == owner) loadingOwner = null
            if (state != null && owner() == owner) snapshot.value = Snapshot(owner, state.tips.associateBy { it.tipId })
        }
    }

    /** 这条提示现在能不能出现（页面自己的规则另外判） */
    fun eligible(tip: String): Flow<Boolean> = snapshot.map { snap ->
        snap != null && snap.owner == owner() && snap.records[tip]?.invalidatedAt == null
    }

    /** 提示上屏一次 */
    fun recordDisplay(tip: String) {
        val origin = repository.ui.value.origin ?: return
        edit(tip) { it.copy(displayCount = it.displayCount + 1) }
        scope.launch {
            runCatching { apiFactory.forOrigin(origin).recordTipDisplay(tip).dataOrThrow() }.getOrNull()
                ?.let { row -> edit(tip) { row } }
        }
    }

    /** 作废：`action_performed` 用过了提示说的功能，`closed` 用户关掉 */
    fun invalidate(tip: String, reason: String) {
        val origin = repository.ui.value.origin ?: return
        if (snapshot.value?.records?.get(tip)?.invalidatedAt != null) return
        edit(tip) { it.copy(invalidatedAt = java.time.Instant.now().toString(), invalidatedReason = reason) }
        scope.launch {
            runCatching { apiFactory.forOrigin(origin).invalidateTip(tip, InvalidateTipRequest(reason)).dataOrThrow() }.getOrNull()
                ?.let { row -> edit(tip) { row } }
        }
    }

    private fun edit(tip: String, change: (TipRecordView) -> TipRecordView) {
        snapshot.update { snap ->
            snap ?: return@update null
            snap.copy(records = snap.records + (tip to change(snap.records[tip] ?: TipRecordView(tipId = tip))))
        }
    }
}

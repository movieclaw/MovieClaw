package io.movieclaw.android.feature.subscriptions

import io.movieclaw.android.core.designsystem.FeedbackTone
import io.movieclaw.android.core.designsystem.McNotice
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.model.FollowFutureRequest
import io.movieclaw.android.core.model.PipelineHealth
import io.movieclaw.android.core.model.SubscriptionCreateRequest
import io.movieclaw.android.core.model.SubscriptionView
import io.movieclaw.android.core.model.TodayArrival
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

@HiltViewModel
class SubscriptionsViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val sessionRepository: SessionRepository,
) : ViewModel() {

    data class UiState(
        val loading: Boolean = true,
        val error: String? = null,
        val notice: McNotice? = null,
        val readiness: PipelineHealth? = null,
        val arrivals: List<TodayArrival> = emptyList(),
        val subscriptions: List<SubscriptionView> = emptyList(),
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    val origin: String? get() = sessionRepository.ui.value.origin

    init {
        load()
    }

    fun consumeNotice() = _ui.update { it.copy(notice = null) }

    fun load() {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            _ui.update { it.copy(loading = true, error = null) }
            val api = apiFactory.forOrigin(origin)
            val readiness = runCatching { api.automationReadiness().dataOrThrow() }.getOrNull()
            val arrivals = runCatching { api.todayArrivals().dataOrThrow() }.getOrDefault(emptyList())
            runCatching { api.subscriptions().dataOrThrow() }
                .onSuccess { list ->
                    _ui.update {
                        it.copy(
                            loading = false,
                            readiness = readiness,
                            arrivals = arrivals,
                            subscriptions = list,
                        )
                    }
                }
                .onFailure { e -> _ui.update { it.copy(loading = false, error = friendlyMessage(e)) } }
        }
    }

    fun toggleFollowFuture(subscription: SubscriptionView) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            val next = !subscription.followFuture
            runCatching {
                apiFactory.forOrigin(origin)
                    .setFollowFuture(subscription.id, FollowFutureRequest(next))
                    .dataOrThrow()
            }
                .onSuccess {
                    _ui.update { state ->
                        state.copy(
                            subscriptions = state.subscriptions.map {
                                if (it.id == subscription.id) it.copy(followFuture = next) else it
                            },
                            notice = McNotice(if (next) "已开启自动追更" else "已关闭自动追更", FeedbackTone.Success),
                        )
                    }
                }
                .onFailure { e -> _ui.update { it.copy(notice = McNotice(friendlyMessage(e), FeedbackTone.Error)) } }
        }
    }

    fun delete(subscription: SubscriptionView) {
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).deleteSubscription(subscription.id).dataOrThrow() }
                .onSuccess {
                    _ui.update { state ->
                        state.copy(
                            subscriptions = state.subscriptions.filterNot { it.id == subscription.id },
                            notice = McNotice("已取消订阅:${subscription.media.title}", FeedbackTone.Success),
                        )
                    }
                }
                .onFailure { e -> _ui.update { it.copy(notice = McNotice(friendlyMessage(e), FeedbackTone.Error)) } }
        }
    }
}

/** 订阅流程(标题预览 → 选季 → 创建) */
@HiltViewModel
class SubscribeViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val sessionRepository: SessionRepository,
    savedStateHandle: androidx.lifecycle.SavedStateHandle,
) : ViewModel() {

    /** 导航参数里的 ref（订阅弹层现在是浮层、不再是导航目标，这里可能是空的） */
    private val navTitleRef: String = savedStateHandle.get<String>("titleRef").orEmpty()

    /**
     * **当前正在预检的作品**：宿主模式下由 [prepare] 传入，create() 必须用它。
     * 以前 create() 直接用导航参数，宿主模式下那是空串 → POST /subscriptions 422
     * （title_ref 至少要 1 个字符，实机日志抓到）。
     */
    private var currentRef: String = navTitleRef

    data class UiState(
        val loading: Boolean = true,
        val error: String? = null,
        val preview: io.movieclaw.android.core.model.PrepareView? = null,
        val selectedSeasons: Set<Int> = emptySet(),
        val followFuture: Boolean = false,
        val creating: Boolean = false,
        val created: Boolean = false,
        /** 已有订阅（弹层进管理态）：这是那条订阅本身 */
        val existing: io.movieclaw.android.core.model.SubscriptionView? = null,
        /** 可选规则组（网页弹层里也有这一项） */
        val ruleSets: List<io.movieclaw.android.core.model.RuleSetView> = emptyList(),
        /** 可选入库目标库；null = 按默认库路由 */
        val libraries: List<io.movieclaw.android.core.model.LibraryView> = emptyList(),
        val ruleSetId: Long? = null,
        val libraryId: Long? = null,
        /** 投递路由预检（管理员）：抽屉里的「自动选库：…」与预警都来自它 */
        val routing: io.movieclaw.android.core.model.DispatchPreviewView? = null,
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    val origin: String? get() = sessionRepository.ui.value.origin

    init {
        prepare(navTitleRef)
    }

    /** 预检某个作品（宿主模式下会换 ref 重新预检；同一个 VM 实例被不同作品复用） */
    fun prepare(ref: String) {
        if (ref.isBlank()) return
        // 宿主模式下这个 VM 是**共享实例**（弹层不再是导航目标，hiltViewModel 落在 Activity 上）：
        // 换片时必须把上一条的预检结果整份清掉——不清的话，先打开一条**已订阅**的，
        // 再打开未订阅的，画面上还是上一条的管理态（用户报的"两个抽屉打开是一样的"）。
        // 每次都整份重置再预检：
        //  · `created` 必须清——订阅成功后它停在 true，下次打开会被
        //    `LaunchedEffect(state.created) { onCreated() }` 立刻关掉，表现为"点了不弹抽屉"；
        //  · 订阅状态也可能在别处被改过（取消/新建），复用旧结果会显示过期的"该片已在订阅中"。
        // 抽屉现在有种子数据，打开瞬间就有标题行，重拉没有观感代价。
        _ui.value = UiState(loading = true)
        currentRef = ref
        viewModelScope.launch {
            val origin = origin
            if (origin == null) {
                _ui.update { it.copy(loading = false, error = "尚未连接服务器") }
                return@launch
            }
            runCatching {
                apiFactory.forOrigin(origin).titlePreview(
                    io.movieclaw.android.core.model.TitlePreviewRequest(ref)
                ).dataOrThrow()
            }
                .onSuccess { preview ->
                    _ui.update {
                        it.copy(
                            loading = false,
                            preview = preview,
                            selectedSeasons = preview.suggestedSeasons.toSet(),
                            followFuture = preview.media?.kind == "tv",
                        )
                    }
                    // 已经订阅过：把订阅本体也取回来，弹层切成管理态（iOS：已订阅也打开弹层，
                    // 由弹层管理态接手），而不是再让你"创建"一遍
                    loadRouting()

                    // 规则组与目标库**只有超管能选**（`GET /rule-sets` 是 require_admin；成员
                    // 创建订阅时这两项由服务端按系统默认路由决定，见 member-permissions-v2 §3.7）。
                    // 之前这里不带权限就拉，成员每次打开弹层都白吃一个 403。
                    val canManage = io.movieclaw.android.core.session.Permissions
                        .of(sessionRepository.ui.value.session).canManageSubscriptions
                    if (canManage) {
                        runCatching { apiFactory.forOrigin(origin).ruleSets().dataOrThrow() }
                            .onSuccess { list ->
                                android.util.Log.i("McSubs", "规则组 ${list.size} 条")
                                _ui.update { it.copy(ruleSets = list) }
                            }
                            .onFailure { android.util.Log.w("McSubs", "规则组拉取失败", it) }
                        runCatching { apiFactory.forOrigin(origin).libraries().dataOrThrow() }
                            .onSuccess { list ->
                                val usable = list.filter { l -> l.viewerAccess }
                                android.util.Log.i("McSubs", "媒体库 ${list.size} 个（可用 ${usable.size}）")
                                _ui.update { it.copy(libraries = usable) }
                            }
                            .onFailure { android.util.Log.w("McSubs", "媒体库拉取失败", it) }
                    }
                    preview.existingSubscriptionId?.let { id ->
                        runCatching {
                            apiFactory.forOrigin(origin).subscription(id).dataOrThrow()
                        }.onSuccess { s -> _ui.update { it.copy(existing = s) } }
                    }
                }
                .onFailure { e -> _ui.update { it.copy(loading = false, error = friendlyMessage(e)) } }
        }
    }

    fun toggleSeason(season: Int) {
        _ui.update { state ->
            val next = state.selectedSeasons.toMutableSet()
            if (!next.add(season)) next.remove(season)
            state.copy(selectedSeasons = next)
        }
    }

    fun setFollowFuture(value: Boolean) = _ui.update { it.copy(followFuture = value) }

    fun setRuleSet(id: Long?) {
        _ui.update { it.copy(ruleSetId = id) }
        loadRouting()
    }

    fun setLibrary(id: Long?) {
        _ui.update { it.copy(libraryId = id) }
        loadRouting()
    }

    /**
     * 投递路由预检（`GET /subscriptions/download-routing-preview`，管理员）：
     * 选库/选组后即时回答"下载会落到哪、能不能自动入库"。非管理员会 403，静默跳过——
     * 这两行提示本来只对管理员有意义（网页端也是管理员才显示）。
     */
    private fun loadRouting() {
        val preview = _ui.value.preview ?: return
        val kind = preview.media?.kind ?: return
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching {
                apiFactory.forOrigin(origin).downloadRoutingPreview(
                    kind = kind,
                    libraryId = _ui.value.libraryId,
                    tmdbId = preview.media?.tmdbId,
                    title = preview.media?.title,
                    year = preview.media?.year,
                ).dataOrThrow()
            }.onSuccess { routing ->
                android.util.Log.i("McSubs", "投递预检 ok=${routing.ok} 库=${routing.libraryName} 理由=${routing.routeReason}")
                // 预检解析出的目标库：用户没选过就按它预选（route_reason 会说明为什么）
                _ui.update { it.copy(routing = routing, libraryId = it.libraryId ?: routing.libraryId) }
            }.onFailure {
                // 403（非管理员）与网络失败都不该让弹层报错：预检只是锦上添花
                android.util.Log.i("McSubs", "投递预检跳过：${it.message}")
            }
        }
    }

    /** 管理态里取消订阅：成功后关掉弹层（列表页由变更信号自动重拉） */
    fun cancelExisting(onDone: () -> Unit) {
        val id = _ui.value.existing?.id ?: return
        viewModelScope.launch {
            val origin = origin ?: return@launch
            runCatching { apiFactory.forOrigin(origin).deleteSubscription(id) }
                .onSuccess {
                    // 先按 id 摘除（服务端列表有极短延迟，光重拉会把卡片画回「已订阅」），
                    // 再发变更信号让索引重拉校回真相
                    removeSubscriptionFromIndex(id)
                    SubscriptionEvents.notifyChanged()
                    onDone()
                }
                .onFailure { e -> _ui.update { it.copy(error = friendlyMessage(e)) } }
        }
    }

    fun create() {
        val state = _ui.value
        if (state.creating) return
        _ui.update { it.copy(creating = true) }
        viewModelScope.launch {
            val origin = origin ?: return@launch
            // 成员不带规则组与目标库：服务端对成员一律按系统默认路由决定这两项
            // （member-permissions-v2 §3.7；即便带上也会被忽略，不如不带）
            val canManage = io.movieclaw.android.core.session.Permissions
                .of(sessionRepository.ui.value.session).canManageSubscriptions
            runCatching {
                apiFactory.forOrigin(origin).createSubscription(
                    SubscriptionCreateRequest(
                        titleRef = currentRef,
                        selectedSeasons = state.selectedSeasons.sorted(),
                        followFuture = state.followFuture,
                        ruleSetId = state.ruleSetId.takeIf { canManage },
                        libraryId = state.libraryId.takeIf { canManage },
                    )
                ).dataOrThrow()
            }
                .onSuccess {
                    _ui.update { it.copy(creating = false, created = true) }
                    SubscriptionEvents.notifyChanged()
                }
                .onFailure { e ->
                    // 客户端异常（序列化 / 参数）不走 HTTP 拦截器，日志里看不到——这里补一条
                    android.util.Log.w("McSubs", "订阅创建失败：${e::class.java.simpleName} ${e.message}", e)
                    _ui.update { it.copy(creating = false, error = friendlyMessage(e)) }
                }
        }
    }
}

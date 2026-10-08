package io.movieclaw.android.core.session

import io.movieclaw.android.core.model.SessionView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * 搜索分区的可用性快照（Web `SearchAccess` 的对应物）。
 *
 * - [canMedia] 影视：对应「订阅」能力；
 * - [canTorrent] 站点资源：对应「资源搜索」能力；
 * - [canLibrary] 媒体库：对应可见库白名单（成员要探测一次才知道）；
 * - [ready] 判定是否已出结论，未就绪时入口先不露（媒体库那一格要等探测）。
 */
data class SearchAccess(
    val canMedia: Boolean = false,
    val canTorrent: Boolean = false,
    val canLibrary: Boolean = false,
    val ready: Boolean = false,
) {
    /** 搜索入口（顶栏放大镜）是否露出：任一分区可用即可 */
    val canOpenSearch: Boolean get() = canMedia || canTorrent || canLibrary
}

/** 当前账号的搜索分区，由 `MovieClawRoot` 注入（成员那份要异步探测，故用变化的 CompositionLocal） */
val LocalSearchAccess = androidx.compose.runtime.compositionLocalOf { SearchAccess() }

/**
 * 搜索入口的权限快照（同 Web `lib/search-access.ts` / iOS `SearchAccess`）。
 *
 * 三个分区各有各的口径：
 * - 影视：对应「订阅」能力，能订阅才需要查影视条目；
 * - 站点资源：对应「资源搜索」能力；
 * - 媒体库：对应可见库白名单，**要查一次可见库才知道**（成员可能一个库都看不到）。
 *
 * 入口露出用 [SearchAccess.canOpenSearch]：任一分区可用即可 —— 默认成员（能订阅）、
 * 儿童账号（只有可见库）都能进来搜媒体库，不再只看资源搜索开关。
 */
@Singleton
class SearchAccessRepository @Inject constructor(
    private val apiFactory: ApiFactory,
    private val sessions: SessionRepository,
) {

    private val _state = MutableStateFlow(SearchAccess())
    val state: StateFlow<SearchAccess> = _state.asStateFlow()

    /** 探测结论按账号记：换账号（用户名变了）必须重探，不能复用 */
    private var probedUsername: String? = null
    private var probedAtMs = 0L
    private var lastProbe: Boolean? = null
    private var probing = false

    /**
     * 按当前会话重算分区。会话变化时调用（`MovieClawRoot` 收集会话流）。
     *
     * 成员多一次 `GET /libraries`（服务端只返回可见库）；同一账号 30 秒内不重探，
     * 失败**不推翻**上一次结论（网络抖一下不该把入口藏掉），也从不当成「就绪的 false」
     * 之外的任何结论——没有可用分区时搜索页自己显示空态。
     */
    suspend fun sync(session: SessionView? = sessions.ui.value.session) {
        if (session == null) {
            _state.value = SearchAccess()
            probedUsername = null
            probedAtMs = 0L
            return
        }
        val permissions = Permissions.of(session)
        if (permissions.isAdmin) {
            // 超管恒有媒体库分区，第一帧就在，不闪
            _state.value = SearchAccess(canMedia = true, canTorrent = true, canLibrary = true, ready = true)
            probedUsername = null
            probedAtMs = 0L
            return
        }
        val known = if (probedUsername == session.username) lastProbe else null
        _state.value = SearchAccess(
            canMedia = permissions.canSubscribe,
            canTorrent = permissions.canSearch,
            canLibrary = known == true,
            ready = known != null,
        )
        val now = System.currentTimeMillis()
        if (probing) return
        if (known != null && now - probedAtMs <= PROBE_TTL_MS) return
        val origin = sessions.ui.value.origin ?: return
        probing = true
        try {
            val result = runCatching {
                apiFactory.forOrigin(origin).libraries().dataOrThrow()
            }
            val available = result.getOrNull()?.isNotEmpty()
                // 失败沿用上一次结论；从没成功过才算「没有可见库」
                ?: (known ?: false)
            probedUsername = session.username
            probedAtMs = System.currentTimeMillis()
            lastProbe = available
            _state.value = _state.value.copy(
                canLibrary = available,
                ready = true,
            )
        } finally {
            probing = false
        }
    }

    private companion object {
        /** 结论有效期：超管调整可见库后，成员这边不至于长期拿着旧结论 */
        const val PROBE_TTL_MS = 30_000L
    }
}

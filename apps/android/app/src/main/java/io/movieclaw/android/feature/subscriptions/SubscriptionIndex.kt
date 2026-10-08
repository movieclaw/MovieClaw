package io.movieclaw.android.feature.subscriptions

import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.model.SubscriptionView
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * 全站订阅状态索引（iOS `SubscriptionIndex` / 网页 `SubscribeEntryProvider` 的对应物）。
 *
 * 海报卡片散落在发现页、详情页、搜索结果、影人页等多层页面里，「这部片订阅了没有」
 * 不该由每张卡片各自去问后端——这里统一拉一次 `GET /subscriptions` 建查表索引，
 * 卡片与按钮按 `tmdb_id` / `douban_id` O(1) 判断。
 *
 * **为什么必须有它**：发现页的 hero 与卡片以前是拿「是否已入库」当「是否已订阅」用的，
 * 于是库里已有的片（哪怕从没订阅过）都显示「已订阅 · 追踪中」——用户报的正是这个。
 * 入库与订阅是两件事，前者看 `library_status`，后者只能看订阅本身。
 *
 * 匹配口径与网页一致：TMDB 来源按 `tmdb_id`（带类型时用它消歧，电影与剧集是两个独立号段）；
 * 豆瓣来源按 `douban_id`。从 TMDB 入口建立、未关联豆瓣 ID 的订阅匹配不到豆瓣卡片——
 * 已知限制，不按标题猜。
 */
@Singleton
class SubscriptionIndex @Inject constructor(
    private val apiFactory: ApiFactory,
    private val sessionRepository: SessionRepository,
) {

    private val _byKey = MutableStateFlow<Map<String, SubscriptionView>>(emptyMap())

    /** key → 订阅；页面 collect 它来驱动重组（内容变了才会重建卡片） */
    val byKey: StateFlow<Map<String, SubscriptionView>> = _byKey.asStateFlow()

    private var loadedAtMs = 0L
    private var loading = false

    /**
     * 代次：`invalidate()` 会自增。**拉取结果只在代次未变时写回**——
     * 否则"取消订阅前就发出的那次拉取"会把旧清单又写回去，卡片恢复成「已订阅」
     * （实机反馈：取消后清空了一瞬间又被顶回来）。
     */
    private var generation = 0

    /** 距上次成功拉取超过 [maxAgeMs] 就重拉（默认 30 秒，iOS 同值） */
    suspend fun ensureLoaded(maxAgeMs: Long = 30_000) {
        if (loading) return
        val now = System.currentTimeMillis()
        if (now - loadedAtMs < maxAgeMs) return
        loading = true
        val startedGeneration = generation
        try {
            val origin = sessionRepository.ui.value.origin ?: return
            runCatching { apiFactory.forOrigin(origin).subscriptions().dataOrThrow() }
                .onSuccess { list ->
                    if (startedGeneration != generation) {
                        // 这次拉取是"作废之前"发出的，结果已经过期，丢掉
                        android.util.Log.i("McSubs", "订阅索引：丢弃过期结果（${list.size} 条）")
                        return@onSuccess
                    }
                    _byKey.value = buildIndex(list)
                    loadedAtMs = System.currentTimeMillis()
                    android.util.Log.i("McSubs", "订阅索引已更新：${list.size} 条")
                }
            // 失败不覆盖已有数据：状态降级为「都未订阅」，不影响订阅入口本身
        } finally {
            loading = false
        }
    }

    /**
     * 订阅数据在别处被改动（新建 / 取消）后调用。
     *
     * **同时清空查表**：卡片上的「已订阅」立刻消失，随后重拉的数据把它校回真相。
     * 只把时间戳清零的话，重拉回来之前卡片会一直挂着旧状态（用户报"取消后不刷新"）。
     */
    fun invalidate() {
        loadedAtMs = 0L
        generation++
        _byKey.value = emptyMap()
        android.util.Log.i("McSubs", "订阅索引已作废并清空（代次 $generation）")
    }

    /**
     * 取消订阅成功后**精确摘掉这一条**。
     *
     * 为什么不只靠重拉：实机日志显示，DELETE 刚成功时 `GET /subscriptions` 返回的清单
     * **还带着刚删掉的那条**（服务端侧有极短的可见性延迟），重拉会把卡片又画回「已订阅」，
     * 只有切界面再拉一次才对。这里直接按 id 摘除，随后那次重拉只负责校回真相。
     */
    fun remove(subscriptionId: Long) {
        val kept = _byKey.value.filterValues { it.id != subscriptionId }
        if (kept.size != _byKey.value.size) {
            _byKey.value = kept
            android.util.Log.i("McSubs", "订阅索引已摘除 #$subscriptionId（剩 ${kept.size} 条）")
        }
    }

    /**
     * 查这部作品有没有订阅。[source] 为 `tmdb` / `douban`（发现页的 provider），
     * [kind] 为 `movie` / `tv`（可空，缺类型时仅按 ID 匹配）。
     */
    /**
     * 在**调用方手里的那份 map**上查订阅。
     *
     * 组合里必须用这个版本：`byKey.value` 读的是 StateFlow 的当前值，**不是 Compose 的
     * 快照读取**，所以卡片用它查表时不会订阅状态 —— 索引更新了卡片也不会重组
     * （用户报的"订阅后不立马显示、取消后不立马消失"，切界面才变）。调用方把
     * `collectAsStateWithLifecycle()` 收下来的 map 传进来，读取就发生在组合里。
     */
    fun findIn(map: Map<String, SubscriptionView>, source: String?, externalId: String?, kind: String?): SubscriptionView? {
        if (externalId.isNullOrBlank()) return null
        return if (source == "douban") {
            map["douban:$externalId"]
        } else {
            (kind?.let { map["tmdb:$it:$externalId"] }) ?: map["tmdb:$externalId"]
        }
    }

    fun find(source: String?, externalId: String?, kind: String?): SubscriptionView? {
        if (externalId.isNullOrBlank()) return null
        val map = _byKey.value
        return if (source == "douban") {
            map["douban:$externalId"]
        } else {
            (kind?.let { map["tmdb:$it:$externalId"] }) ?: map["tmdb:$externalId"]
        }
    }

    private fun buildIndex(list: List<SubscriptionView>): Map<String, SubscriptionView> {
        val out = HashMap<String, SubscriptionView>(list.size * 2)
        list.forEach { s ->
            // 注意：取消订阅后服务端不再返回这一行，索引随之清掉——不需要额外过滤
            val id = s.media.tmdbId ?: return@forEach
            out["tmdb:${s.media.kind}:$id"] = s
            out.putIfAbsent("tmdb:$id", s)
        }
        return out
    }
}

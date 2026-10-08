package io.movieclaw.android.feature.search

import io.movieclaw.android.core.AppScopes

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

private val Context.searchModeStore by preferencesDataStore(name = "mc_search_mode")

/**
 * 搜索页**上次停留的分区**（存本机）——对应 Web 的 `movieclaw.search-palette-state`
 * 与 iOS 的 `@AppStorage("movieclaw.search-palette-state")`。
 *
 * 两端都是这个口径：进搜索时按**来源页签**预选分区（发现 / 订阅 → 影视，媒体库 → 媒体库，
 * 活动 → 资源），「我的」进来则沿用上次停留的分区；预选出来的分区本身也记下来。
 * 只决定打开时停在哪，不改写用户记过的资源分类。
 */
@Singleton
class SearchModeMemory @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val key = stringPreferencesKey("last_mode")
    private val scope = AppScopes.io("SearchModeMemory")

    private val _mode = MutableStateFlow<SearchMode?>(null)

    /** 上次停留的分区；还没读过盘时为 null（调用方按资源起步） */
    val mode: StateFlow<SearchMode?> = _mode.asStateFlow()

    private var loaded = false

    /** 冷启动读一次（幂等） */
    fun ensureLoaded(onReady: (SearchMode?) -> Unit = {}) {
        if (loaded) { onReady(_mode.value); return }
        scope.launch {
            val raw = runCatching { context.searchModeStore.data.first()[key] }.getOrNull()
            val parsed = SearchMode.entries.firstOrNull { it.name == raw }
            _mode.value = parsed
            loaded = true
            onReady(parsed)
        }
    }

    fun remember(mode: SearchMode) {
        _mode.value = mode
        scope.launch {
            runCatching { context.searchModeStore.edit { it[key] = mode.name } }
        }
    }
}

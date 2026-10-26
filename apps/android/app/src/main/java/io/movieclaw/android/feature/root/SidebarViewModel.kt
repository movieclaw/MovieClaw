package io.movieclaw.android.feature.root

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.session.SessionPhase
import io.movieclaw.android.core.session.SessionRepository
import io.movieclaw.android.core.session.initials
import io.movieclaw.android.core.model.CollectionView
import io.movieclaw.android.core.model.LibraryView
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * 宽窗口侧边栏的数据：**逐个媒体库**与**首页合集**。
 *
 * 对应 iOS 的 `PadSidebarLibraryTabs`（`ipad.md` §3）：侧边栏不只有几个固定页签，
 * 还按「媒体库」「合集」两个分组把库与合集逐个列出来（口径同 Mac 版 `MacSidebar`）。
 *
 * 数据只拉一次（会话就绪时），之后随账号切换重拉——侧边栏是外壳，不需要跟着内容页刷新。
 * 注意：服务端 `LibraryView` 没有「部数」字段，所以这里列不出 iOS 那样的带部数文案。
 */
@HiltViewModel
class SidebarViewModel @Inject constructor(
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
) : ViewModel() {

    data class Data(
        val libraries: List<LibraryView> = emptyList(),
        val collections: List<CollectionView> = emptyList(),
        /** 侧栏底部账号行：之前没传，永远显示「未登录」 */
        val accountName: String? = null,
        val accountInitials: String? = null,
        val accountAvatarUrl: String? = null,
        val accountOrigin: String? = null,
    )

    private val _data = MutableStateFlow(Data())
    val data: StateFlow<Data> = _data.asStateFlow()

    init {
        viewModelScope.launch {
            repository.ui.collect { ui ->
                if (ui.phase != SessionPhase.READY) return@collect
                val origin = ui.origin ?: return@collect
                val api = apiFactory.forOrigin(origin)
                val libraries = runCatching { api.libraries().dataOrThrow() }.getOrDefault(emptyList())
                // 侧栏只要**用户合集**：全量列表会把内置/自动合集也带进来（「我的收藏」会重复一次）
        val collections = runCatching { api.collections().dataOrThrow().filter { it.kind == "user" }.distinctBy { it.id } }
                    .getOrDefault(emptyList())
                    // 只列「用户自建、可见」的合集：内置（我的收藏）与自动/系列合集在 iPad 侧栏里不出现，
                    // 同名的手动合集也只留一条（真机上「我的收藏」出现两次）
                    .filter { it.builtin == null && it.kind == "user" && !it.hidden }
                    .distinctBy { it.name }
                _data.value = Data(
                    libraries = libraries,
                    collections = collections,
                    // 侧栏底部账号行：之前这三项没传，永远显示「未登录」
                    accountName = ui.session?.nickname?.takeIf { it.isNotBlank() } ?: ui.session?.username,
                    accountInitials = ui.session.initials(),
                    accountAvatarUrl = ui.session?.avatarUrl,
                    accountOrigin = origin,
                )
            }
        }
    }
}

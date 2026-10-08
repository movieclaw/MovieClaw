package io.movieclaw.android.feature.library

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.ErrorPane
import io.movieclaw.android.core.designsystem.LibraryItemCard
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.McTopBar
import io.movieclaw.android.core.designsystem.McTopBarVariant
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.CollectionView
import io.movieclaw.android.core.model.LibraryItemView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * 合集详情（iOS `CollectionDetailView` / Web `library-collection-detail-view.tsx`）。
 *
 * 页头：封面叠放 + 名称 + 「N 部 · 来源」；右上排序菜单（默认档 = 合集自己的序，
 * 手动合集叫「自定顺序」，规则合集用它存的档）；之下是与单库海报墙同一套卡片的海报墙。
 *
 * 这一版**没有**搬的部分（iOS 有、这里按下不表）：自动收录的条件详情弹层与改条件、
 * 系列合集的「已有 N / 共 M」与缺片格、⋯ 菜单（改名 / 分享 / 整理顺序 / 显示在首页 / 隐藏 / 删除）、
 * 图床浏览模式。
 */
@HiltViewModel
class LibraryCollectionViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
) : ViewModel() {
    data class Ui(
        val loading: Boolean = true,
        val items: List<LibraryItemView> = emptyList(),
        val collection: CollectionView? = null,
        val loadingMore: Boolean = false,
        val hasMore: Boolean = false,
        val failed: String? = null,
        /** 当前排序档（"default" = 合集自己的序） */
        val sort: String = "default",
        val reversed: Boolean = false,
    )

    private val _ui = MutableStateFlow(Ui())
    val ui = _ui.asStateFlow()
    val origin: String? get() = repository.ui.value.origin

    private var collectionId: Long = 0
    private var offset = 0

    fun start(id: Long) {
        if (collectionId == id && _ui.value.items.isNotEmpty()) return
        collectionId = id
        reload()
    }

    fun reload() {
        viewModelScope.launch {
            _ui.value = _ui.value.copy(loading = true, failed = null, items = emptyList())
            offset = 0
            val origin = repository.ui.value.origin ?: return@launch
            try {
                val api = apiFactory.forOrigin(origin)
                // 合集的元信息（名称 / 来源 / 成员数）与第一页成员；合集不存在（已删）就报错
                val col = api.collection(collectionId).dataOrThrow()
                val page = api.collectionItems(
                    id = collectionId,
                    limit = PAGE_SIZE,
                    offset = 0,
                    sort = sortParam(),
                    order = orderParam(),
                ).dataOrThrow()
                offset = page.size
                _ui.value = _ui.value.copy(
                    loading = false,
                    collection = col,
                    items = page,
                    hasMore = page.size >= PAGE_SIZE,
                )
            } catch (e: Exception) {
                _ui.value = _ui.value.copy(loading = false, failed = friendlyMessage(e))
            }
        }
    }

    fun loadMore() {
        val s = _ui.value
        if (s.loadingMore || s.loading || !s.hasMore) return
        viewModelScope.launch {
            _ui.value = s.copy(loadingMore = true)
            val origin = repository.ui.value.origin ?: return@launch
            try {
                val page = apiFactory.forOrigin(origin).collectionItems(
                    id = collectionId,
                    limit = PAGE_SIZE,
                    offset = offset,
                    sort = sortParam(),
                    order = orderParam(),
                ).dataOrThrow()
                offset += page.size
                _ui.value = _ui.value.copy(
                    loadingMore = false,
                    items = _ui.value.items + page,
                    hasMore = page.size >= PAGE_SIZE,
                )
            } catch (_: Exception) {
                _ui.value = _ui.value.copy(loadingMore = false, hasMore = false)
            }
        }
    }

    /** 换排序档：回到第一页重拉 */
    fun setSort(sort: String, reversed: Boolean) {
        _ui.value = _ui.value.copy(sort = sort, reversed = reversed)
        reload()
    }

    /** 默认档把 sort 省掉，让服务端按合集自己的序（含方向）排 */
    private fun sortParam(): String? =
        if (_ui.value.sort == "default") null else _ui.value.sort

    private fun orderParam(): String? {
        val s = _ui.value
        if (!s.reversed) return null
        if (s.sort == "default") {
            // 默认档的方向由合集自己的序决定：集合自己的自然方向是升序的档（标题 / 自定顺序）反转成 desc
            return when (s.collection?.sort) {
                "title", "release_date_asc", null -> "desc"
                else -> "asc"
            }
        }
        val dir = io.movieclaw.android.core.model.HomeRows.preset(s.sort).direction ?: return null
        return if (dir.naturalAsc) "desc" else "asc"
    }

    private companion object {
        const val PAGE_SIZE = 60
    }
}

/** 合集详情可选的排序档（iOS CollectionDetailView.prefLabels） */
private val collectionSortOptions = listOf(
    "default" to "合集默认",
    "title" to "按标题",
    "added_at" to "最近添加",
    "release_date" to "按上映时间",
    "rating" to "按评分",
    "runtime" to "按片长",
    "last_played" to "最近观看",
)

@Composable
fun LibraryCollectionScreen(
    collectionId: Long,
    fallbackTitle: String,
    onBack: () -> Unit,
    onOpenItem: (Long, Long) -> Unit,
    vm: LibraryCollectionViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()
    val origin = vm.origin
    LaunchedEffect(collectionId) { vm.start(collectionId) }

    val col = state.collection
    val title = col?.name ?: fallbackTitle

    Column(Modifier.fillMaxSize().background(Bg)) {
        McTopBar(
            variant = McTopBarVariant.Sub,
            title = title,
            onBack = onBack,
        ) {
            var open by remember { mutableStateOf(false) }
            Box {
                TextButton(onClick = { open = true }) {
                    Text(
                        collectionSortOptions.firstOrNull { it.first == state.sort }?.second ?: "排序",
                        style = McType.subheadline,
                        color = Accent,
                    )
                    Spacer(Modifier.width(4.dp))
                    Icon(
                        Icons.Rounded.KeyboardArrowDown,
                        contentDescription = "排序",
                        tint = Accent,
                        modifier = Modifier.size(16.dp),
                    )
                }
                DropdownMenu(
                    expanded = open,
                    onDismissRequest = { open = false },
                    containerColor = Color(0xFF22252C),
                ) {
                    collectionSortOptions.forEach { (key, label) ->
                        DropdownMenuItem(
                            text = {
                                Text(
                                    label, fontSize = 14.sp,
                                    color = if (key == state.sort) Accent else TextPrimary,
                                )
                            },
                            onClick = {
                                open = false
                                vm.setSort(key, false)
                            },
                        )
                    }
                }
            }
        }

        when {
            state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            state.failed != null -> ErrorPane(message = state.failed!!, onRetry = vm::reload)
            else -> {
                val gridState = rememberLazyGridState()
                LaunchedEffect(gridState, state.items.size) {
                    androidx.compose.runtime.snapshotFlow { gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
                        .collect { last ->
                            val total = gridState.layoutInfo.totalItemsCount
                            if (total > 0 && last >= total - 6) vm.loadMore()
                        }
                }
                LazyVerticalGrid(
                    state = gridState,
                    columns = GridCells.Fixed(2),
                    contentPadding = PaddingValues(
                        start = McMetrics.pagePadding,
                        end = McMetrics.pagePadding,
                        top = 0.dp,
                        bottom = 24.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(18.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    item(span = { GridItemSpan(2) }) {
                        CollectionHeader(col, state.items.isEmpty(), origin)
                    }
                    if (state.items.isEmpty()) {
                        item(span = { GridItemSpan(2) }) {
                            Text(
                                "这个合集里还没有作品。",
                                fontSize = 15.sp, color = TextMuted,
                                modifier = Modifier.padding(vertical = 40.dp),
                            )
                        }
                    }
                    items(state.items, key = { it.mediaItemId }) { item ->
                        LibraryItemCard(
                            item = item,
                            origin = origin,
                            onClick = { onOpenItem(item.libraryId ?: col?.libraryId ?: -1L, item.mediaItemId) },
                        )
                    }
                    if (state.loadingMore) {
                        item(span = { GridItemSpan(2) }) {
                            Box(Modifier.fillMaxWidth().padding(14.dp), contentAlignment = Alignment.Center) {
                                CircularProgressIndicator(color = TextMuted, modifier = Modifier.size(20.dp))
                            }
                        }
                    }
                }
            }
        }
    }
}

/** 页头：封面叠放 + 名称 + 「N 部 · 来源」一行（照 iOS CollectionDetailView 的页头口径） */
@Composable
private fun CollectionHeader(col: CollectionView?, hasNoItems: Boolean, origin: String?) {
    Column(Modifier.padding(top = 4.dp, bottom = 14.dp)) {
        col?.let { c ->
            Box(Modifier.width(150.dp)) {
                CollectionCoverStack(c.covers, origin)
            }
            Spacer(Modifier.height(10.dp))
            Text(
                c.name,
                fontSize = 24.sp, fontWeight = FontWeight.Bold, color = TextPrimary,
                maxLines = 2, overflow = TextOverflow.Ellipsis,
            )
            Text(
                listOfNotNull(
                    "${c.itemCount} 部",
                    when {
                        c.kind == "series" -> "系列"
                        c.ruleDriven -> "自动收录"
                        else -> "固定名单"
                    },
                    if (c.libraryId == null) "跨库" else null,
                    if (c.visibility == "private") "只有我" else null,
                    if (c.hidden) "已隐藏" else null,
                ).joinToString(" · "),
                fontSize = 13.sp, color = TextFaint,
                modifier = Modifier.padding(top = 4.dp),
            )
        } ?: run {
            if (!hasNoItems) Text("正在读取合集…", fontSize = 13.sp, color = TextMuted)
        }
    }
}

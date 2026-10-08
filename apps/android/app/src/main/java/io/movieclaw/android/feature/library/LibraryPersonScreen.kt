package io.movieclaw.android.feature.library

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.pullToRefresh
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent2
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.PosterCard
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * 库内影人页（`GET /people/{tmdbPersonId}`；iOS `PersonDetailView`、网页 `person-detail-view.tsx`）：
 * 列出他在**我的库里**参演与执导的作品（参演在前、同档按主次与年份倒序，服务端排好），
 * 点作品进库内条目详情；404 = 库内没有这位影人的作品（给「刷新元数据」的解释与去媒体库入口）。
 *
 * 与发现页那个「TMDB 影人页」（`PersonScreen`，`discover/people/{id}`）是**两个独立页面**：
 * 一个只讲库里有什么（点了能直接看），一个讲完整履历（带「已入库 / 已订阅」斜标）。
 */
@HiltViewModel
class LibraryPersonViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val repository: SessionRepository,
    private val apiFactory: ApiFactory,
) : ViewModel() {

    private val personId: Int = savedStateHandle.get<String>("tmdbPersonId")?.toIntOrNull() ?: 0
    val origin: String? get() = repository.ui.value.origin

    data class Credit(
        val mediaItemId: Long,
        val libraryId: Long?,
        val title: String,
        val year: Int?,
        val posterUrl: String?,
        val department: String,
        val character: String?,
    )

    data class Ui(
        val loading: Boolean = true,
        /** 库内没有这位影人的作品（404） */
        val missing: Boolean = false,
        val error: String? = null,
        val refreshing: Boolean = false,
        val name: String = "",
        val originalName: String? = null,
        val avatarUrl: String? = null,
        val credits: List<Credit> = emptyList(),
    ) {
        val cast: List<Credit> get() = credits.filter { it.department == "cast" }
        val directed: List<Credit> get() = credits.filter { it.department == "director" }
    }

    private val _ui = MutableStateFlow(Ui())
    val ui = _ui.asStateFlow()

    init { load() }

    fun load(refresh: Boolean = false) = viewModelScope.launch {
        val origin = origin ?: run { _ui.update { it.copy(loading = false, error = "尚未连接服务器") }; return@launch }
        _ui.update { it.copy(loading = !refresh, refreshing = refresh, error = null, missing = false) }
        runCatching { apiFactory.forOrigin(origin).libraryPerson(personId).dataOrThrow().jsonObject }
            .onSuccess { raw ->
                val credits = (raw["credits"] as? JsonArray).orEmpty().mapNotNull { el ->
                    val o = el.jsonObject
                    val id = o["media_item_id"]?.jsonPrimitive?.intOrNull?.toLong() ?: return@mapNotNull null
                    Credit(
                        mediaItemId = id,
                        libraryId = o["library_id"]?.jsonPrimitive?.intOrNull?.toLong(),
                        title = o["title"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        year = o["year"]?.jsonPrimitive?.intOrNull,
                        posterUrl = o["poster_url"]?.jsonPrimitive?.contentOrNull,
                        department = o["department"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        character = o["character"]?.jsonPrimitive?.contentOrNull,
                    )
                }
                _ui.update {
                    it.copy(
                        loading = false, refreshing = false,
                        name = raw["name"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        originalName = raw["original_name"]?.jsonPrimitive?.contentOrNull,
                        avatarUrl = raw["avatar_url"]?.jsonPrimitive?.contentOrNull,
                        credits = credits,
                    )
                }
            }
            .onFailure { e ->
                // 404 = 库里没有这位影人的作品（iOS `Failure.missing`）
                val notFound = (e as? retrofit2.HttpException)?.code() == 404
                _ui.update { it.copy(loading = false, refreshing = false, missing = notFound, error = if (notFound) null else friendlyMessage(e)) }
            }
    }
}

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun LibraryPersonScreen(
    onBack: () -> Unit,
    onOpenItem: (Long, Long) -> Unit,
    onOpenLibrary: () -> Unit,
    vm: LibraryPersonViewModel = hiltViewModel(),
) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val origin = vm.origin

    Column(Modifier.fillMaxSize().background(Bg)) {
        SubTopBar(ui.name.ifBlank { "影人" }, onBack)
        when {
            ui.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            ui.missing -> CenterNote(
                title = "库内没有这位影人的作品",
                message = "可能是他参演的片都已从库里移除；也可能这个库是早前扫描的——影人档案随入库刮削一并建立，对它执行一次「刷新元数据」即可补齐，之后这里就会列出他在库内的全部作品。",
                actionText = "去媒体库",
                onAction = onOpenLibrary,
            )
            ui.error != null -> CenterNote(
                title = "未能加载影人档案",
                message = ui.error,
                actionText = "重试",
                onAction = { vm.load() },
            )
            else -> LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    horizontal = McMetrics.pagePadding, vertical = 12.dp,
                ),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier.fillMaxSize().pullToRefresh(
                    isRefreshing = ui.refreshing,
                    state = rememberPullToRefreshState(),
                    onRefresh = { vm.load(refresh = true) },
                ),
            ) {
                item(span = { GridItemSpan(3) }) {
                    PersonHeader(
                        name = ui.name,
                        avatarUrl = ui.avatarUrl,
                        origin = origin,
                        subtitle = ui.originalName?.takeIf { it != ui.name },
                        summary = "库内 ${ui.credits.size} 部" +
                            if (ui.cast.isNotEmpty() && ui.directed.isNotEmpty()) {
                                "（参演 ${ui.cast.size} · 执导 ${ui.directed.size}）"
                            } else {
                                ""
                            },
                    )
                }
                creditSection(ui.cast, "参演", showCharacter = true, onOpenItem = onOpenItem, origin = origin)
                creditSection(ui.directed, "执导", showCharacter = false, onOpenItem = onOpenItem, origin = origin)
            }
        }
    }
}

/** 一段作品格（「参演 N」/「执导 N」）：iOS `creditGrid` 同款；library_id 为空 = 只剩档案，不可点 */
private fun androidx.compose.foundation.lazy.grid.LazyGridScope.creditSection(
    credits: List<LibraryPersonViewModel.Credit>,
    title: String,
    showCharacter: Boolean,
    onOpenItem: (Long, Long) -> Unit,
    origin: String?,
) {
    if (credits.isEmpty()) return
    item(span = { GridItemSpan(3) }) {
        Row(
            Modifier.fillMaxWidth().padding(top = 6.dp),
            verticalAlignment = Alignment.Bottom,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(title, style = McType.title3, color = TextPrimary)
            Text("${credits.size}", style = McType.sub, color = TextFaint)
        }
    }
    items(credits, key = { "${it.mediaItemId}-${it.department}" }) { credit ->
        PosterCard(
            imageUrl = credit.posterUrl,
            origin = origin,
            title = credit.title,
            meta = if (showCharacter && credit.character != null) {
                "饰 ${credit.character}"
            } else {
                credit.year?.toString()
            },
            onClick = credit.libraryId?.let { lib -> { onOpenItem(lib, credit.mediaItemId) } },
        )
    }
}

/** 影人页头部（iOS `PersonHeader`）：92×138 头像 + 眉题「影人」+ 姓名 + 原名 + 作品统计 */
@Composable
private fun PersonHeader(
    name: String,
    avatarUrl: String?,
    origin: String?,
    subtitle: String?,
    summary: String,
) {
    Row(
        Modifier.fillMaxWidth().padding(top = 8.dp, bottom = 4.dp),
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Box(
            Modifier
                .width(92.dp)
                .height(138.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(androidx.compose.ui.graphics.Color.White.copy(alpha = 0.06f)),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                name.trim().take(1),
                fontSize = 34.sp, fontWeight = FontWeight.SemiBold,
                color = androidx.compose.ui.graphics.Color.White.copy(alpha = 0.3f),
            )
            if (!avatarUrl.isNullOrBlank()) {
                RemoteImage(avatarUrl, origin, contentDescription = name, modifier = Modifier.fillMaxSize())
            }
        }
        Column(Modifier.weight(1f).padding(bottom = 4.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                "影人",
                style = McType.caption.copy(fontWeight = FontWeight.SemiBold, letterSpacing = 2.5.sp),
                color = Accent2,
            )
            Text(name, style = McType.title2, color = TextPrimary, maxLines = 1)
            subtitle?.let { Text(it, style = McType.sub, color = TextPrimary.copy(alpha = 0.55f), maxLines = 1) }
            Text(
                summary,
                style = McType.sub.copy(fontFamily = FontFamily.Monospace),
                color = TextPrimary.copy(alpha = 0.7f),
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

/** 空态 / 错误态：主行 17、副行 14，可带一颗玻璃按钮（与「我的收藏」等页同一形态） */
@Composable
private fun CenterNote(title: String, message: String?, actionText: String?, onAction: () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(horizontal = 36.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(title, style = McType.headline, color = TextPrimary, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        message?.let {
            Spacer(Modifier.height(8.dp))
            Text(
                it, style = McType.sub, color = TextMuted,
                textAlign = androidx.compose.ui.text.style.TextAlign.Center, lineHeight = 21.sp,
            )
        }
        if (actionText != null) {
            Spacer(Modifier.height(16.dp))
            Box(
                Modifier
                    .clip(RoundedCornerShape(999.dp))
                    .border(1.dp, TextPrimary.copy(alpha = 0.28f), RoundedCornerShape(999.dp))
                    .clickable(onClick = onAction)
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            ) {
                Text(actionText, style = McType.sub, color = TextPrimary)
            }
        }
    }
}

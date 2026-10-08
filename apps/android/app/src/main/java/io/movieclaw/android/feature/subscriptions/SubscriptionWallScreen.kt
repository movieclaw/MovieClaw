package io.movieclaw.android.feature.subscriptions

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
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
import androidx.compose.foundation.lazy.grid.LazyGridScope
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.ErrorPane
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McTopBar
import io.movieclaw.android.core.designsystem.McTopBarVariant
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.SubscriptionView
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * 订阅海报墙（订阅首页「剧集订阅 ›」「电影订阅 ›」或一排末尾的「查看全部」压栈进来的二级页；
 * 网页 / iOS `SubscriptionWallView` 的对应物）。
 *
 * 与首页那一排是**同一份数据**（`GET /subscriptions`）与同一套状态签（[subChip] 与首页共用），
 * 顺序、计数口径两处一致。首页横滑只放前几排，这里放全部，按首页分隔线的两侧拆成三段：
 * 进行中（此刻最要紧的在前）/ 已暂停 / 已收齐（电影叫已入库）。
 */
@HiltViewModel
class SubscriptionWallViewModel @Inject constructor(
    savedStateHandle: androidx.lifecycle.SavedStateHandle,
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
) : ViewModel() {

    /** tv / movie */
    val kind: String = savedStateHandle.get<String>("kind").orEmpty().ifBlank { "movie" }

    data class UiState(
        val loading: Boolean = true,
        val error: String? = null,
        val items: List<SubscriptionView> = emptyList(),
        /** 海报是服务端相对路径，画图要拿它拼绝对地址（实机报「进入后没封面图」的根因） */
        val origin: String? = null,
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    init { load() }

    fun load() {
        viewModelScope.launch {
            val origin = repository.ui.value.origin
            if (origin == null) { _ui.update { it.copy(loading = false, error = "尚未连接服务器") }; return@launch }
            _ui.update { it.copy(loading = true, error = null, origin = origin) }
            try {
                val all = apiFactory.forOrigin(origin).subscriptions().dataOrThrow()
                _ui.update { it.copy(loading = false, items = all.filter { s -> s.media.kind == kind }) }
            } catch (e: Exception) {
                _ui.update { it.copy(loading = false, error = friendlyMessage(e)) }
            }
        }
    }
}

@Composable
fun SubscriptionWallScreen(
    onBack: () -> Unit,
    onOpenSubscription: (Long) -> Unit,
    vm: SubscriptionWallViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()
    val isMovie = vm.kind == "movie"
    val title = if (isMovie) "电影订阅" else "剧集订阅"
    val active = state.items.filter { it.status == "active" }
    val paused = state.items.filter { it.status == "paused" }
    val done = state.items.filterNot { it.status == "active" || it.status == "paused" }

    Box(Modifier.fillMaxSize().background(Bg)) {
        Column(Modifier.fillMaxSize().padding(top = McMetrics.topBarHeight)) {
            when {
                state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = TextMuted)
                }
                state.error != null -> ErrorPane(message = state.error!!, onRetry = vm::load)
                else -> LazyVerticalGrid(
                    columns = GridCells.Fixed(2),
                    contentPadding = PaddingValues(
                        start = McMetrics.pagePadding,
                        end = McMetrics.pagePadding,
                        bottom = 32.dp,
                    ),
                    verticalArrangement = Arrangement.spacedBy(18.dp),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    item(span = { GridItemSpan(2) }) {
                        Text(
                            "${state.items.size} 部" +
                                if (active.isNotEmpty()) " · ${active.size} 部进行中" else "",
                            style = McType.body,
                            color = TextMuted,
                            modifier = Modifier.padding(top = 6.dp, bottom = 2.dp),
                        )
                    }
                    section("进行中", active, state.origin, onOpenSubscription)
                    section("已暂停", paused, state.origin, onOpenSubscription)
                    section(if (isMovie) "已入库" else "已收齐", done, state.origin, onOpenSubscription)
                }
            }
        }

        McTopBar(
            variant = McTopBarVariant.Sub,
            title = title,
            onBack = onBack,
            modifier = Modifier.align(Alignment.TopCenter),
        )
    }
}

/** 一段（进行中 / 已暂停 / 已收齐）：段头「名字 + 计数」+ 两列海报 */
private fun LazyGridScope.section(
    name: String,
    items: List<SubscriptionView>,
    origin: String?,
    onOpenSubscription: (Long) -> Unit,
) {
    if (items.isEmpty()) return
    item(span = { GridItemSpan(2) }, key = "h-$name") {
        Row(Modifier.padding(top = 10.dp, bottom = 2.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(name, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = TextPrimary)
            Spacer(Modifier.width(6.dp))
            Text("${items.size}", fontSize = 14.sp, color = TextFaint)
        }
    }
    items(items, key = { it.id }) { sub ->
        WallSubCard(sub = sub, dim = name != "进行中", origin = origin) { onOpenSubscription(sub.id) }
    }
}

/** 墙上一格：海报（2:3）+ 状态签 + 片名 + 进度的同一套口径（与首页 SubCard 视觉同源） */
@Composable
private fun WallSubCard(sub: SubscriptionView, dim: Boolean, origin: String?, onClick: () -> Unit) {
    Column(Modifier.fillMaxWidth().clickable(onClick = onClick)) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(2f / 3f)
                .clip(RoundedCornerShape(12.dp))
                .background(Color(0xFF101219)),
        ) {
            RemoteImage(
                url = sub.media.posterUrl,
                origin = origin,
                contentDescription = sub.media.title,
                modifier = Modifier.fillMaxSize(),
                contentScale = ContentScale.Crop,
            )
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.6f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.6f))))
            val (chipText, chipColor) = subChip(sub)
            if (chipText.isNotEmpty()) {
                Row(
                    Modifier.align(Alignment.TopStart).padding(7.dp).clip(RoundedCornerShape(999.dp))
                        .background(Color.Black.copy(alpha = 0.38f)).padding(horizontal = 7.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.size(5.dp).clip(CircleShape).background(chipColor))
                    Spacer(Modifier.width(4.dp))
                    Text(chipText, fontSize = 10.5.sp, fontWeight = FontWeight.SemiBold, color = chipColor)
                }
            }
            val imported = sub.progress.imported
            val total = sub.progress.total
            if (imported in 1 until total) {
                Box(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(2.5.dp).background(Color.White.copy(alpha = 0.3f))) {
                    Box(Modifier.fillMaxWidth(imported.toFloat() / total.toFloat()).height(2.5.dp).background(Color.White.copy(alpha = 0.92f)))
                }
            }
        }
        Text(
            sub.media.title,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (dim) TextMuted else TextPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 6.dp),
        )
        val meta = if (sub.media.kind == "tv") {
            val season = sub.selectedSeasons.firstOrNull()
            "第 ${season ?: 1} 季 · ${sub.progress.imported} / ${sub.progress.total}"
        } else {
            listOfNotNull(sub.media.year?.toString(), if (sub.progress.imported > 0) "已入库" else "未入库").joinToString(" · ")
        }
        Text(meta, fontSize = 12.sp, color = TextFaint, modifier = Modifier.padding(top = 2.dp))
    }
}

package io.movieclaw.android.feature.share

import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.Danger
import io.movieclaw.android.core.designsystem.GlassCard
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McRow
import io.movieclaw.android.core.designsystem.McNavButton
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.PosterCard
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.Success
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.model.EpisodeView
import io.movieclaw.android.core.model.SharePublic
import io.movieclaw.android.core.model.SharedCollection
import io.movieclaw.android.core.model.SharedItem
import io.movieclaw.android.core.model.SharedCollectionItem
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.playback.PlayTarget
import io.movieclaw.android.core.playback.PlaybackSessionHolder
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * 访客分享(免登录):
 *   深链进入 → 探测 `/share/{slug}`(可能要密码)→ 条目/合集 →
 *   访客播放走公开播放通道(GuestPlaybackEndpoint),不读写任何成员态。
 * 图片路径由服务端按分享通道改写,需按 API 基址拼接。
 */
@HiltViewModel
class ShareViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val apiFactory: ApiFactory,
    private val holder: PlaybackSessionHolder,
) : ViewModel() {

    val origin: String = savedStateHandle.get<String>("origin").orEmpty()
    val slug: String = savedStateHandle.get<String>("slug").orEmpty()

    data class UiState(
        val loading: Boolean = true,
        val error: String? = null,
        val notice: String? = null,
        val probe: SharePublic? = null,
        val password: String = "",
        val item: SharedItem? = null,
        val collection: SharedCollection? = null,
        val selectedSeason: Int = 0,
        val episodes: List<EpisodeView> = emptyList(),
        val opening: Boolean = false,
    )

    private val _ui = MutableStateFlow(UiState())
    val ui = _ui.asStateFlow()

    /** 分享通道的图片要经 API 基址(/api/v1)访问 */
    private val apiBase: String get() = apiFactory.apiBaseOf(origin) ?: "$origin/api/v1"

    fun imageUrl(path: String?): String? =
        path?.takeIf { it.isNotEmpty() }?.let { if (it.startsWith("http")) it else apiBase + it }

    init {
        probe()
    }

    fun onPassword(value: String) = _ui.update { it.copy(password = value) }
    fun consumeNotice() = _ui.update { it.copy(notice = null) }

    fun probe() {
        viewModelScope.launch {
            _ui.update { it.copy(loading = true, error = null) }
            val api = apiFactory.guestForOrigin(origin)
            runCatching { api.sharePublic(slug).dataOrThrow() }
                .onSuccess { view ->
                    _ui.update { it.copy(loading = false, probe = view) }
                    if (!view.requiresPassword || view.unlocked) loadContent()
                }
                .onFailure { e -> _ui.update { it.copy(loading = false, error = friendlyMessage(e)) } }
        }
    }

    fun unlock() {
        val password = _ui.value.password
        if (password.isEmpty()) return
        viewModelScope.launch {
            _ui.update { it.copy(loading = true, error = null) }
            val api = apiFactory.guestForOrigin(origin)
            runCatching { api.shareUnlock(slug, io.movieclaw.android.core.model.ShareUnlockRequest(password)).dataOrThrow() }
                .onSuccess { view ->
                    _ui.update { it.copy(loading = false, probe = view, password = "") }
                    loadContent()
                }
                .onFailure { e ->
                    _ui.update { it.copy(loading = false, error = "密码不正确或分享已失效:${friendlyMessage(e)}") }
                }
        }
    }

    private fun loadContent() {
        viewModelScope.launch {
            val api = apiFactory.guestForOrigin(origin)
            val probe = _ui.value.probe
            if (probe?.collectionId != null) {
                runCatching { api.shareCollection(slug).dataOrThrow() }
                    .onSuccess { c -> _ui.update { it.copy(loading = false, collection = c) } }
                    .onFailure { e -> _ui.update { it.copy(loading = false, error = friendlyMessage(e)) } }
                return@launch
            }
            runCatching { api.shareItem(slug).dataOrThrow() }
                .onSuccess { item ->
                    val season = item.seasons.firstOrNull() ?: 0
                    _ui.update { it.copy(loading = false, item = item, selectedSeason = season) }
                    if (item.kind == "tv" && item.seasons.isNotEmpty()) loadEpisodes(season)
                }
                .onFailure { e -> _ui.update { it.copy(loading = false, error = friendlyMessage(e)) } }
        }
    }

    fun selectSeason(season: Int) {
        _ui.update { it.copy(selectedSeason = season) }
        loadEpisodes(season)
    }

    private fun loadEpisodes(season: Int) {
        viewModelScope.launch {
            val api = apiFactory.guestForOrigin(origin)
            runCatching { api.shareEpisodes(slug, season).dataOrThrow() }
                .onSuccess { view -> _ui.update { it.copy(episodes = view.episodes) } }
        }
    }

    /** 访客播放:movie 直接播;剧集取该集文件所在的播放单元 */
    fun play(episodeNumber: Int = 0) {
        val item = _ui.value.item ?: return
        val season = _ui.value.selectedSeason
        _ui.update { it.copy(opening = true) }
        holder.openGuest(
            origin = origin,
            slug = slug,
            target = PlayTarget(
                mediaItemId = item.mediaItemId,
                libraryId = 0,
                kind = item.kind,
                title = item.title,
                subtitle = if (item.kind == "tv") "第 $season 季 第 $episodeNumber 集" else null,
                seasonNumber = if (item.kind == "tv") season else 0,
                episodeNumber = if (item.kind == "tv") episodeNumber else 0,
            ),
        )
        _ui.update { it.copy(opening = false) }
    }
}

@Composable
fun ShareScreen(
    onBack: () -> Unit,
    vm: ShareViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()

    Column(Modifier.fillMaxSize()) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 4.dp, vertical = 4.dp),
        ) {
            McNavButton(
                icon = Icons.AutoMirrored.Rounded.ArrowBack,
                contentDescription = "返回",
                onClick = onBack,
            )
            Column(Modifier.weight(1f)) {
                Text("分享", style = McType.headline)
                Text(
                    vm.origin.removePrefix("https://").removePrefix("http://"),
                    style = McType.caption,
                    color = TextFaint,
                )
            }
            state.probe?.expiresAt?.let {
                Text("有效期至 ${McFormat.dateTime(it)}", style = McType.caption2, color = TextFaint)
            }
        }

        when {
            state.loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = TextMuted)
            }
            state.error != null -> Column(
                Modifier.fillMaxSize().padding(24.dp),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(state.error!!, style = McType.footnote, color = Danger, lineHeight = 20.sp)
                Spacer(Modifier.height(12.dp))
                TextButton(onClick = vm::probe) { Text("重试", color = Accent) }
            }
            state.probe?.requiresPassword == true && state.probe?.unlocked != true -> {
                Column(
                    Modifier.fillMaxSize().padding(24.dp),
                    verticalArrangement = Arrangement.Center,
                ) {
                    Icon(Icons.Rounded.Lock, contentDescription = null, tint = Accent, modifier = Modifier.size(30.dp))
                    Spacer(Modifier.height(10.dp))
                    Text("这是一个加密分享", style = McType.title3)
                    Spacer(Modifier.height(6.dp))
                    Text("请输入分享者提供的密码", style = McType.footnote, color = TextMuted)
                    Spacer(Modifier.height(14.dp))
                    OutlinedTextField(
                        value = state.password,
                        onValueChange = vm::onPassword,
                        singleLine = true,
                        placeholder = { Text("密码", style = McType.footnote, color = TextFaint) },
                        visualTransformation = PasswordVisualTransformation(),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedContainerColor = Color.White.copy(alpha = 0.055f),
                            unfocusedContainerColor = Color.White.copy(alpha = 0.055f),
                            focusedBorderColor = Accent.copy(alpha = 0.45f),
                            unfocusedBorderColor = Color.White.copy(alpha = 0.1f),
                            focusedTextColor = Color.White,
                            unfocusedTextColor = Color.White,
                            cursorColor = Accent,
                        ),
                        shape = RoundedCornerShape(12.dp),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Spacer(Modifier.height(12.dp))
                    Button(
                        onClick = vm::unlock,
                        enabled = state.password.isNotEmpty(),
                        shape = RoundedCornerShape(12.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = Accent, contentColor = Color(0xFF0A0E12)),
                        modifier = Modifier.fillMaxWidth().height(44.dp),
                    ) { Text("解锁", style = McType.subheadlineSemibold) }
                }
            }
            state.collection != null -> SharedCollectionList(
                collection = state.collection!!,
                imageUrl = vm::imageUrl,
            )
            state.item != null -> SharedItemDetail(
                item = state.item!!,
                episodes = state.episodes,
                selectedSeason = state.selectedSeason,
                opening = state.opening,
                imageUrl = vm::imageUrl,
                onSelectSeason = vm::selectSeason,
                onPlay = vm::play,
            )
        }
    }
}

@Composable
private fun SharedCollectionList(collection: SharedCollection, imageUrl: (String?) -> String?) {
    LazyColumn(
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier.fillMaxSize(),
    ) {
        item {
            Text(collection.name.ifEmpty { "分享合集" }, style = McType.title3)
            collection.description?.takeIf { it.isNotEmpty() }?.let {
                Spacer(Modifier.height(4.dp))
                Text(it, style = McType.caption, color = TextMuted)
            }
            Spacer(Modifier.height(10.dp))
        }
        items(collection.items, key = { it.mediaItemId }) { item ->
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(10.dp))
                    .padding(vertical = 6.dp),
            ) {
                Box(Modifier.width(44.dp).height(66.dp).clip(RoundedCornerShape(8.dp))) {
                    RemoteImage(
                        url = imageUrl(item.posterUrl),
                        origin = null,
                        guest = true,
                        contentDescription = item.title,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(item.title, style = McType.subheadlineSemibold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(
                        listOfNotNull(
                            item.year?.toString(),
                            if (item.kind == "tv") "剧集" else "电影",
                        ).joinToString(" · "),
                        style = McType.caption,
                        color = TextFaint,
                    )
                }
            }
        }
    }
}

@Composable
private fun SharedItemDetail(
    item: SharedItem,
    episodes: List<EpisodeView>,
    selectedSeason: Int,
    opening: Boolean,
    imageUrl: (String?) -> String?,
    onSelectSeason: (Int) -> Unit,
    onPlay: (Int) -> Unit,
) {
    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState()),
    ) {
        Box(Modifier.fillMaxWidth().height(220.dp)) {
            RemoteImage(
                url = imageUrl(item.backdropUrl ?: item.posterUrl),
                origin = null,
                        guest = true,
                contentDescription = item.title,
                modifier = Modifier.fillMaxSize(),
            )
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.3f), Color.Black))),
            )
            Row(Modifier.align(Alignment.BottomStart).padding(16.dp), verticalAlignment = Alignment.Bottom) {
                Box(Modifier.width(84.dp).height(126.dp).clip(RoundedCornerShape(10.dp))) {
                    RemoteImage(
                        url = imageUrl(item.posterUrl),
                        origin = null,
                        guest = true,
                        contentDescription = null,
                        modifier = Modifier.fillMaxSize(),
                    )
                }
                Spacer(Modifier.width(12.dp))
                Column {
                    Text(
                        item.title,
                        style = McType.title.copy(fontSize = 24.sp),
                        color = Color.White,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        listOfNotNull(
                            item.year?.toString(),
                            item.localMeta?.runtimeMinutes?.let { McFormat.durationMinutes(it) },
                            item.files.firstOrNull()?.resolution,
                            item.files.firstOrNull()?.videoCodec?.uppercase(),
                        ).filter { it.isNotEmpty() }.joinToString(" · "),
                        style = McType.caption,
                        color = TextMuted,
                    )
                }
            }
        }

        Row(Modifier.padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Button(
                onClick = {
                    onPlay(if (item.kind == "tv") episodes.firstOrNull { it.owned }?.episodeNumber ?: 0 else 0)
                },
                enabled = !opening,
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Accent, contentColor = Color(0xFF0A0E12)),
            ) {
                Icon(Icons.Rounded.PlayArrow, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(5.dp))
                Text(if (item.kind == "tv") "播放第一集" else "播放", style = McType.subheadlineSemibold)
            }
            Spacer(Modifier.width(12.dp))
            Text("访客播放 · 不记录到成员进度", style = McType.caption2, color = TextFaint)
        }

        item.localMeta?.plot?.takeIf { it.isNotEmpty() }?.let { plot ->
            Text(
                plot,
                style = McType.subheadline,
                color = TextMuted,
                lineHeight = 21.sp,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp),
            )
        }

        if (item.kind == "tv" && item.seasons.isNotEmpty()) {
            Spacer(Modifier.height(10.dp))
            LazyRow(
                contentPadding = PaddingValues(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(item.seasons) { season ->
                    Text(
                        "第 $season 季",
                        style = McType.footnote,
                        color = if (season == selectedSeason) Accent else TextMuted,
                        modifier = Modifier
                            .clip(RoundedCornerShape(999.dp))
                            .background(if (season == selectedSeason) Color.White.copy(alpha = 0.14f) else Color.White.copy(alpha = 0.05f))
                            .clickable { onSelectSeason(season) }
                            .padding(horizontal = 12.dp, vertical = 7.dp),
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            episodes.forEach { episode ->
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable(enabled = episode.owned) { onPlay(episode.episodeNumber) }
                        .padding(horizontal = 16.dp, vertical = 9.dp),
                ) {
                    Column(Modifier.weight(1f)) {
                        Text(
                            "第 ${episode.episodeNumber} 集" + (episode.name?.let { " · $it" } ?: ""),
                            style = McType.subheadlineSemibold,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        if (!episode.overview.isNullOrEmpty()) {
                            Text(
                                episode.overview,
                                style = McType.caption,
                                color = TextFaint,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                    if (episode.played) {
                        Icon(Icons.Rounded.CheckCircle, contentDescription = null, tint = Success, modifier = Modifier.size(18.dp))
                    } else if (!episode.owned) {
                        Text("缺集", style = McType.caption2, color = TextFaint)
                    }
                }
            }
        }

        Spacer(Modifier.height(24.dp))
        GlassCard(Modifier.padding(horizontal = 16.dp).fillMaxWidth()) {
            Text("分享说明", style = McType.subheadlineSemibold)
            Spacer(Modifier.height(5.dp))
            Text(
                "你正在以访客身份观看分享内容。播放记录不会写入任何成员的观看进度,退出即结束会话;" +
                    "分享链接有有效期,过期后需要分享者重新生成。",
                style = McType.caption,
                color = TextMuted,
                lineHeight = 18.sp,
            )
        }
        Spacer(Modifier.height(24.dp))
    }
}

/** 深链入口:把 origin/slug 交给 ShareViewModel(参数经 SavedStateHandle 传递) */
@Composable
fun ShareRoute(link: io.movieclaw.android.core.model.ShareLink, onExit: () -> Unit) {
    androidx.navigation.compose.NavHost(
        navController = androidx.navigation.compose.rememberNavController(),
        startDestination = "share/${Uri.encode(link.origin)}/${Uri.encode(link.slug)}",
        modifier = Modifier.fillMaxSize(),
    ) {
        composable("share/{origin}/{slug}") {
            ShareScreen(onBack = onExit)
        }
    }
}

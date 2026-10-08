package io.movieclaw.android.feature.discover

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.snapshotFlow
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
import io.movieclaw.android.core.designsystem.Bg
import io.movieclaw.android.core.designsystem.GlassCapsule
import io.movieclaw.android.core.designsystem.LineSoft
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.designsystem.Warn
import io.movieclaw.android.core.network.ApiFactory
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.network.friendlyMessage
import io.movieclaw.android.core.session.SessionRepository
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.floatOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import javax.inject.Inject

@Composable
internal fun TitleCell(t: DiscTitle, origin: String?, onClick: () -> Unit) {
    Column(Modifier.clickable(onClick = onClick)) {
        Box(
            Modifier.fillMaxWidth().aspectRatio(2f / 3f)
                .clip(RoundedCornerShape(McMetrics.posterRadius))
                .border(1.dp, LineSoft, RoundedCornerShape(McMetrics.posterRadius))
                .background(Color(0xFF101219)),
        ) {
            RemoteImage(t.posterUrl, origin, Modifier.fillMaxSize(), contentDescription = t.title)
            t.rating?.takeIf { it > 0f }?.let {
                Row(
                    Modifier.align(Alignment.TopEnd).padding(6.dp).clip(RoundedCornerShape(6.dp))
                        .background(Color.Black.copy(alpha = 0.7f)).padding(horizontal = 5.dp, vertical = 2.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Rounded.Star, contentDescription = null, tint = Warn, modifier = Modifier.size(9.dp))
                    Spacer(Modifier.width(3.dp))
                    Text("%.1f".format(it), fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                }
            }
        }
        Text(t.title, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 8.dp))
        val meta = listOfNotNull(t.year?.toString(), t.genres.take(2).joinToString(" / ").takeIf { it.isNotBlank() }).joinToString(" · ")
        if (meta.isNotBlank()) Text(meta, fontSize = 13.sp, color = TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 2.dp))
    }
}

/* ══════════ 影人页（iOS DiscoveredPersonView） ══════════ */

data class PersonState(
    val loading: Boolean = true,
    val error: String? = null,
    val name: String = "",
    val avatarUrl: String? = null,
    val titles: List<DiscTitle> = emptyList(),
)

@HiltViewModel
class PersonViewModel @Inject constructor(
    private val apiFactory: ApiFactory,
    private val repository: SessionRepository,
    savedStateHandle: androidx.lifecycle.SavedStateHandle,
) : ViewModel() {
    private val personId: Int = savedStateHandle.get<String>("tmdbPersonId")?.toIntOrNull() ?: 0
    private val _ui = MutableStateFlow(PersonState())
    val ui = _ui.asStateFlow()
    val origin: String? get() = repository.ui.value.origin

    init { load() }

    fun load() {
        viewModelScope.launch {
            val origin = origin ?: run { _ui.update { it.copy(loading = false, error = "尚未连接服务器") }; return@launch }
            try {
                val raw = apiFactory.forOrigin(origin).discoveredPerson(personId).dataOrThrow().jsonObject
                _ui.update {
                    it.copy(
                        loading = false,
                        name = raw["name"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                        avatarUrl = raw["avatar_url"]?.jsonPrimitive?.contentOrNull,
                        titles = parseTitles(raw),
                    )
                }
            } catch (e: Exception) {
                _ui.update { it.copy(loading = false, error = friendlyMessage(e)) }
            }
        }
    }
}

@Composable
fun PersonScreen(
    onBack: () -> Unit,
    onOpenTitle: (String) -> Unit,
    vm: PersonViewModel = hiltViewModel(),
) {
    val state by vm.ui.collectAsStateWithLifecycle()
    Column(Modifier.fillMaxSize().background(Bg)) {
        io.movieclaw.android.feature.library.SubTopBar(state.name.ifBlank { "影人" }, onBack)
        if (state.loading) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = TextMuted) }
        } else {
            Row(Modifier.padding(horizontal = McMetrics.pagePadding, vertical = 6.dp)) {
                Box(
                    Modifier.width(92.dp).height(138.dp)
                        .clip(RoundedCornerShape(12.dp)).background(Color(0xFF101219)),
                ) { RemoteImage(state.avatarUrl, vm.origin, Modifier.fillMaxSize(), contentDescription = state.name) }
                Spacer(Modifier.width(14.dp))
                Column {
                    Text("TMDB 影人", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 2.5.sp, color = Color(0xFF9FB0C9))
                    Text(state.name, fontSize = 22.sp, fontWeight = FontWeight.Bold, color = TextPrimary, modifier = Modifier.padding(top = 4.dp))
                    Text("共 ${state.titles.size} 部影视作品", fontSize = 13.sp, color = TextMuted, modifier = Modifier.padding(top = 6.dp))
                }
            }
            LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                contentPadding = PaddingValues(horizontal = McMetrics.pagePadding, vertical = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier.fillMaxSize(),
            ) {
                // distinctBy：网格按 ref 做 key，同页里重复一条（如同片挂多个身份）就会崩
                items(state.titles.distinctBy { it.ref }, key = { it.ref }) { t -> TitleCell(t, vm.origin) { onOpenTitle(t.ref) } }
            }
        }
    }
}

package io.movieclaw.android.feature.agent

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.movieclaw.android.core.api.McApi
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.LineColor
import io.movieclaw.android.core.designsystem.McFormat
import io.movieclaw.android.core.designsystem.McMetrics
import io.movieclaw.android.core.designsystem.Ok
import io.movieclaw.android.core.designsystem.PosterCard
import io.movieclaw.android.core.designsystem.PosterRibbon
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.TextFaint
import io.movieclaw.android.core.designsystem.TextMuted
import io.movieclaw.android.core.designsystem.TextPrimary
import io.movieclaw.android.core.model.LibraryFileView
import io.movieclaw.android.core.network.dataOrThrow
import io.movieclaw.android.core.playback.PlayTarget
import io.movieclaw.android.feature.subscriptions.subChip
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import io.movieclaw.android.core.designsystem.mcCards

/*
 * Agent 生成式 UI：行内媒体卡片（对应 iOS `AgentMediaCards.swift` + Web `agent-media-cards.tsx`）。
 *
 * 机制（docs/design/agent-generative-ui.md）：模型调用 show_media_cards_v1 时只给编号，
 * 客户端按编号调产品既有接口现取数据绘制卡片——卡片与发现页、媒体库页同款，
 * 订阅/入库/观看进度也永远是此刻的真实状态。实时事件与历史轨迹走同一条解析路径。
 *
 * 参数由模型生成，任何字段都可能缺失或错型：单项不合法跳过，整组一张都画不了返回 null。
 * 加载与失败占同样尺寸的盒子（卡片组在时间线中间，尺寸抖动会把正在读的正文推来推去）；
 * 编号查不到显示「未找到」而不是整组消失——用户要能看出模型引用了不存在的东西。
 */

private const val TOOL_MEDIA_CARDS_V1 = "show_media_cards_v1"
private val titleRefPattern = Regex("^(tmdb:(movie|tv):\\d+|douban:[^:/\\s]+)$")
private val mediaCardComponents = setOf("library", "title", "library_item", "subscription")

enum class AgentMediaCardKind { TITLE, LIBRARY, LIBRARY_ITEM, SUBSCRIPTION }

data class AgentMediaCardSpec(
    val kind: AgentMediaCardKind,
    /** 组内唯一（同一编号重复给出只画一次；库内条目带下标，与 iOS `AgentMediaCardSpec.id` 同口径） */
    val key: String,
    val titleRef: String? = null,
    val libraryId: Long? = null,
    val mediaItemId: Long? = null,
    val season: Int? = null,
    val episode: Int? = null,
    val subscriptionId: Long? = null,
)

/** 一张卡的主点击去哪（导航由屏幕回调决定；VM 只带目标） */
sealed interface AgentMediaCardOpen {
    data class Title(val titleRef: String) : AgentMediaCardOpen
    data class Library(val libraryId: Long) : AgentMediaCardOpen
    data class Item(val libraryId: Long, val mediaItemId: Long) : AgentMediaCardOpen
    data class Subscription(val subscriptionId: Long) : AgentMediaCardOpen
}

/** 一张卡此刻的展示态（loading / failed / ready 三态；失败不区分原因，画「未找到」） */
data class AgentMediaCardView(
    val spec: AgentMediaCardSpec,
    val loading: Boolean = true,
    val failed: Boolean = false,
    val title: String = "",
    val meta: String = "",
    /** 条目卡的片源规格一行（分辨率/HDR 标签 + 文件数与体积） */
    val specsLine: String = "",
    val imageUrl: String? = null,
    /** 宽卡（媒体库 21:10 / 库内条目 16:9）；false = 海报 2:3 */
    val wide: Boolean = false,
    val aspect: Float = McMetrics.posterAspect,
    val ribbon: PosterRibbon? = null,
    val progress: Float? = null,
    val played: Boolean = false,
    /** 条目卡中央播放键的目标；null = 这张卡不给播放键 */
    val play: PlayTarget? = null,
    /** 主点击去哪；占位卡（未解析出库归属等）为 null，不响应点击 */
    val open: AgentMediaCardOpen? = null,
)

data class AgentMediaCardGroup(
    val title: String?,
    val cards: List<AgentMediaCardView>,
)

internal object AgentMediaCards {

    fun isMediaCardsTool(name: String?): Boolean = name == TOOL_MEDIA_CARDS_V1

    /** 工具参数 → 卡片组（同 iOS `parse`：组件白名单、逐项校验、按编号去重、标题去空白） */
    fun parse(name: String?, arguments: JsonElement?): AgentMediaCardGroup? {
        if (name != TOOL_MEDIA_CARDS_V1) return null
        val args = arguments as? JsonObject ?: return null
        val component = (args["component"] as? JsonPrimitive)?.contentOrNull ?: return null
        if (component !in mediaCardComponents) return null
        val seen = mutableSetOf<String>()
        val cards = mutableListOf<AgentMediaCardView>()
        (args["items"] as? JsonArray)?.forEachIndexed { index, raw ->
            val item = raw as? JsonObject ?: return@forEachIndexed
            val spec = parseItem(component, item, index) ?: return@forEachIndexed
            if (seen.add(spec.key)) cards += AgentMediaCardView(spec = spec)
        }
        if (cards.isEmpty()) return null
        val title = (args["title"] as? JsonPrimitive)?.contentOrNull?.trim()?.takeIf { it.isNotEmpty() }
        return AgentMediaCardGroup(title = title, cards = cards)
    }

    fun failed(spec: AgentMediaCardSpec): AgentMediaCardView =
        AgentMediaCardView(spec = spec, loading = false, failed = true)

    private fun positiveLong(v: JsonElement?): Long? =
        (v as? JsonPrimitive)?.contentOrNull?.toLongOrNull()?.takeIf { it > 0 }

    private fun str(v: JsonElement?): String? = (v as? JsonPrimitive)?.contentOrNull

    private fun parseItem(component: String, item: JsonObject, index: Int): AgentMediaCardSpec? = when (component) {
        "library" -> positiveLong(item["library_id"])?.let {
            AgentMediaCardSpec(AgentMediaCardKind.LIBRARY, key = "library:$it", libraryId = it)
        }
        "subscription" -> positiveLong(item["subscription_id"])?.let {
            AgentMediaCardSpec(AgentMediaCardKind.SUBSCRIPTION, key = "subscription:$it", subscriptionId = it)
        }
        "title" -> {
            // 首选 title_ref；只有 TMDB 编号时按 tmdb_id + media_type 拼成同一形态（iOS 同口径）
            var ref = str(item["title_ref"])?.trim().orEmpty()
            if (ref.isEmpty()) {
                val tmdb = positiveLong(item["tmdb_id"])
                val type = str(item["media_type"])
                if (tmdb != null && (type == "movie" || type == "tv")) ref = "tmdb:$type:$tmdb"
            }
            if (titleRefPattern.matches(ref)) {
                AgentMediaCardSpec(AgentMediaCardKind.TITLE, key = ref, titleRef = ref)
            } else null
        }
        else -> {
            // 库内条目：季集必须成对；只给一半按整部处理（iOS 同口径）
            val id = positiveLong(item["media_item_id"]) ?: return null
            val season = str(item["season_number"])?.toIntOrNull()?.takeIf { it >= 0 }
            val episode = positiveLong(item["episode_number"])?.toInt()
            val pair = season != null && episode != null
            AgentMediaCardSpec(
                AgentMediaCardKind.LIBRARY_ITEM,
                key = "item:$id" + (if (pair) ":s${season}e$episode" else "") + ":$index",
                mediaItemId = id,
                season = if (pair) season else null,
                episode = if (pair) episode else null,
            )
        }
    }

    /** 按编号取数据（与 iOS 各卡 `.task` 同口径）：单项失败不拖垮整组，由调用方兜成 [failed] */
    suspend fun load(api: McApi, spec: AgentMediaCardSpec, subscribedRefs: Set<String>): AgentMediaCardView =
        when (spec.kind) {
            AgentMediaCardKind.TITLE -> loadTitle(api, spec, subscribedRefs)
            AgentMediaCardKind.LIBRARY -> loadLibrary(api, spec)
            AgentMediaCardKind.LIBRARY_ITEM -> loadLibraryItem(api, spec)
            AgentMediaCardKind.SUBSCRIPTION -> loadSubscription(api, spec)
        }

    private suspend fun loadTitle(
        api: McApi,
        spec: AgentMediaCardSpec,
        subscribedRefs: Set<String>,
    ): AgentMediaCardView {
        val ref = spec.titleRef ?: return failed(spec)
        val t = api.titleDetails(ref).dataOrThrow().title
        val ribbon = when {
            t.libraryStatus != null -> PosterRibbon.OWNED
            ref in subscribedRefs -> PosterRibbon.SUBSCRIBED
            else -> null
        }
        return AgentMediaCardView(
            spec = spec,
            loading = false,
            title = t.title,
            meta = listOfNotNull(t.releaseYear?.toString(), kindLabel(t.mediaType)).joinToString(" · "),
            imageUrl = t.posterUrl,
            ribbon = ribbon,
            open = AgentMediaCardOpen.Title(ref),
        )
    }

    private suspend fun loadLibrary(api: McApi, spec: AgentMediaCardSpec): AgentMediaCardView {
        val id = spec.libraryId ?: return failed(spec)
        val library = api.library(id).dataOrThrow()
        val meta = listOfNotNull(
            kindLabel(library.kind),
            if (library.stats.itemCount > 0) "${library.stats.itemCount} 部" else null,
            if (library.stats.totalSizeBytes > 0) McFormat.bytes(library.stats.totalSizeBytes) else null,
        ).joinToString(" · ")
        return AgentMediaCardView(
            spec = spec,
            loading = false,
            title = library.name,
            meta = meta,
            imageUrl = "/libraries/${library.id}/cover",
            wide = true,
            aspect = 21f / 10f,
            open = AgentMediaCardOpen.Library(library.id),
        )
    }

    private suspend fun loadLibraryItem(api: McApi, spec: AgentMediaCardSpec): AgentMediaCardView {
        val mediaItemId = spec.mediaItemId ?: return failed(spec)
        // 条目信息只认 media_item_id（库归属服务端按可见性解析）；详情与观看状态失败不拖垮卡片
        val info = api.playbackItem(mediaItemId).dataOrThrow()
        val detail = runCatching { api.libraryItemDetail(info.libraryId, mediaItemId).dataOrThrow() }.getOrNull()
        val watch = runCatching {
            api.resumeState(mediaItemId, spec.season ?: 0, spec.episode ?: 0).dataOrThrow()
        }.getOrNull()
        val unit = if (info.kind == "tv") {
            spec.season?.let { s -> spec.episode?.let { e -> s to e } }
        } else null
        val code = unit?.let { (s, e) -> "S%02dE%02d".format(s, e) }
        val progress = watch?.takeIf { it.positionMs > 0 && (it.durationMs ?: 0) > 0 }?.let {
            (it.positionMs.toFloat() / it.durationMs!!.toFloat()).coerceIn(0f, 1f)
        }
        return AgentMediaCardView(
            spec = spec,
            loading = false,
            title = info.title,
            meta = listOfNotNull(info.year?.toString(), kindLabel(info.kind), code).joinToString(" · "),
            specsLine = specLine(detail?.files, detail?.fileCount ?: 0, detail?.totalSizeBytes ?: 0),
            imageUrl = detail?.backdropUrl ?: detail?.posterUrl ?: info.posterUrl,
            wide = true,
            aspect = 16f / 9f,
            progress = progress,
            played = watch?.played == true,
            play = PlayTarget(
                mediaItemId = info.mediaItemId,
                libraryId = info.libraryId,
                kind = info.kind,
                title = info.title,
                seasonNumber = unit?.first ?: 0,
                episodeNumber = unit?.second ?: 0,
            ),
            open = AgentMediaCardOpen.Item(info.libraryId, info.mediaItemId),
        )
    }

    private suspend fun loadSubscription(api: McApi, spec: AgentMediaCardSpec): AgentMediaCardView {
        val id = spec.subscriptionId ?: return failed(spec)
        val sub = api.subscriptions().dataOrThrow().firstOrNull { it.id == id } ?: return failed(spec)
        val (chip, _) = subChip(sub)
        val p = sub.progress
        return AgentMediaCardView(
            spec = spec,
            loading = false,
            title = sub.media.title,
            meta = listOfNotNull(
                kindLabel(sub.media.kind),
                chip,
                if (p.total > 0) "${p.imported}/${p.total}" else null,
            ).joinToString(" · "),
            imageUrl = sub.media.posterUrl,
            progress = if (p.total > 0) (p.imported.toFloat() / p.total).coerceIn(0f, 1f) else null,
            open = AgentMediaCardOpen.Subscription(sub.id),
        )
    }

    /** 片源规格一行：去重的分辨率/HDR 标签 + 文件数与体积（iOS `specLine` 同口径） */
    private fun specLine(files: List<LibraryFileView>?, fileCount: Int, sizeBytes: Long): String {
        if (files == null) return ""
        val tags = mutableListOf<String>()
        files.forEach { file ->
            listOfNotNull(file.resolution, file.hdr).forEach { tag ->
                if (tag.isNotEmpty() && tag !in tags) tags += tag
            }
        }
        if (fileCount > 0) tags += "$fileCount 个文件"
        if (sizeBytes > 0) tags += McFormat.bytes(sizeBytes)
        return tags.joinToString(" · ")
    }
}

/** 类型文案（照媒体库页既有口径：movie/tv/video） */
internal fun kindLabel(kind: String?): String? = when (kind) {
    "movie" -> "电影"
    "tv" -> "剧集"
    "video" -> "其他视频"
    else -> null
}

/* ---------------- 渲染 ---------------- */

/** 一条气泡里的卡片组：可选小标题 + 横滚行 */
@Composable
internal fun AgentMediaCardsRow(
    group: AgentMediaCardGroup,
    origin: String?,
    onOpen: (AgentMediaCardOpen) -> Unit,
    onPlay: (PlayTarget) -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        group.title?.let {
            Text(it, fontSize = 13.5.sp, fontWeight = FontWeight.SemiBold, color = TextMuted)
            Spacer(Modifier.height(8.dp))
        }
        LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            items(group.cards, key = { it.spec.key }) { card ->
                AgentMediaCardItem(card, origin = origin, onOpen = onOpen, onPlay = onPlay)
            }
        }
    }
}

@Composable
private fun AgentMediaCardItem(
    card: AgentMediaCardView,
    origin: String?,
    onOpen: (AgentMediaCardOpen) -> Unit,
    onPlay: (PlayTarget) -> Unit,
) {
    when {
        card.loading || card.failed -> AgentCardPlaceholder(card)
        card.wide -> AgentWideCard(card, origin, onOpen, onPlay)
        else -> PosterCard(
            imageUrl = card.imageUrl,
            origin = origin,
            title = card.title,
            meta = card.meta.takeIf { it.isNotEmpty() },
            ribbon = card.ribbon,
            modifier = Modifier.width(mcCards.posterWidth),
            onClick = card.open?.let { target -> { onOpen(target) } },
        )
    }
}

/** 加载 / 失败占位：与真实卡片同尺寸，中央一行小字（iOS `AgentCardPlaceholder` 同款） */
@Composable
private fun AgentCardPlaceholder(card: AgentMediaCardView) {
    val width = if (card.wide) 212.dp else mcCards.posterWidth
    Box(
        Modifier
            .width(width)
            .aspectRatio(card.aspect)
            .clip(RoundedCornerShape(16.dp))
            .background(Color.White.copy(alpha = 0.04f))
            .border(1.dp, Color.White.copy(alpha = 0.06f), RoundedCornerShape(16.dp)),
        contentAlignment = Alignment.Center,
    ) {
        if (card.failed) {
            Text("未找到", fontSize = 13.sp, color = TextFaint)
        } else {
            CircularProgressIndicator(color = TextFaint, modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
        }
    }
}

/** 宽卡：媒体库（21:10 封面）与库内条目（16:9 剧照/背景 + 播放键） */
@Composable
private fun AgentWideCard(
    card: AgentMediaCardView,
    origin: String?,
    onOpen: (AgentMediaCardOpen) -> Unit,
    onPlay: (PlayTarget) -> Unit,
) {
    Column(Modifier.width(212.dp)) {
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(card.aspect)
                .clip(RoundedCornerShape(16.dp))
                .background(Color.White.copy(alpha = 0.05f))
                .clickable(enabled = card.open != null) { card.open?.let(onOpen) },
        ) {
            RemoteImage(card.imageUrl, origin, contentDescription = card.title, modifier = Modifier.fillMaxSize())
            // 底部渐隐 + 片名/库名（iOS 同款：图上压字保证任何封面上都可读）
            Box(
                Modifier
                    .fillMaxSize()
                    .background(
                        Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.75f))),
                    ),
            )
            Text(
                card.title,
                fontSize = 14.sp,
                fontWeight = FontWeight.SemiBold,
                color = Color.White,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.align(Alignment.BottomStart).padding(horizontal = 12.dp, vertical = 9.dp),
            )
            card.progress?.let { progress ->
                Box(
                    Modifier
                        .align(Alignment.BottomStart)
                        .fillMaxWidth()
                        .padding(horizontal = 8.dp, vertical = 8.dp)
                        .height(3.dp)
                        .clip(CircleShape)
                        .background(Color.White.copy(alpha = 0.25f)),
                ) {
                    Box(
                        Modifier
                            .fillMaxWidth(progress)
                            .height(3.dp)
                            .background(Accent),
                    )
                }
            }
            if (card.played) {
                Text(
                    "已看完",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = Color(0xFF0A1F14),
                    modifier = Modifier
                        .align(Alignment.TopEnd)
                        .padding(8.dp)
                        .clip(CircleShape)
                        .background(Ok)
                        .padding(horizontal = 8.dp, vertical = 3.dp),
                )
            }
            // 中央播放键：整卡进条目页，这个键直接起播（iOS 两个入口叠一起）
            card.play?.let { target ->
                Box(
                    Modifier.align(Alignment.Center).size(40.dp).clip(CircleShape)
                        .border(1.5.dp, Color.White.copy(alpha = 0.75f), CircleShape)
                        .clickable { onPlay(target) },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Rounded.PlayArrow,
                        contentDescription = "播放「${card.title}」",
                        tint = Color.White,
                        modifier = Modifier.size(22.dp),
                    )
                }
            }
            Box(Modifier.fillMaxSize().border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(16.dp)))
        }
        Spacer(Modifier.height(8.dp))
        Text(card.title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = TextPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        if (card.meta.isNotEmpty()) {
            Text(card.meta, fontSize = 13.sp, color = TextMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (card.specsLine.isNotEmpty()) {
            Text(card.specsLine, fontSize = 12.sp, color = TextFaint, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

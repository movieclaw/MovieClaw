package io.movieclaw.android.feature.library

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import io.movieclaw.android.core.designsystem.Accent
import io.movieclaw.android.core.designsystem.RemoteImage
import io.movieclaw.android.core.designsystem.TextMuted
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.roundToInt
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/**
 * 媒体库首页的「下拉二楼」：用力往下拉，松手进片段（与 iOS `ReelsFloor` 同一套交互，docs/design/reels.md §6）。
 *
 * - 照常下拉：内容跟着手指往下走（橡皮筋手感同 iOS），拉到 [REFRESH_AT] 触发刷新（转圈转起来）；
 * - 刷新触发后继续往下拉，内容上方从左侧送进一条 35mm 胶片（[ReelsFilmStrip]），跟着手指一格一格走；
 * - 再拉过 [ARM_BEYOND]：片门合拢、正中一格亮起并重震一下，这时松手就进片段；推回线内再松手只是刷新。
 *
 * iOS 的刷新是系统控件、触发距离随机型变，所以那边的线跟在「这次拖动里刷新实际触发的位置」后面；
 * 安卓不用 Material 下拉刷新（它只让转圈下滑、内容不动，露不出胶片的位置），刷新由这里自己触发，
 * 判定照搬同一套：只认手指拖着的越界（[NestedScrollSource.UserInput]），甩到顶的回弹不会误进。
 * 距离一律按 dp。
 */
@Stable
class ReelsFloorState {
    /** 手指拉过的原始距离（未经橡皮筋） */
    private var drag by mutableFloatStateOf(0f)
    /** 拉过线了，松手就进。只在拖动中更新：松手后回弹途中保持原样 */
    var armed by mutableStateOf(false)
        private set
    /** 这一次拖动里刷新在拉下多少时触发；还没触发为空，这时既不出胶片也不会过线 */
    var refreshedAt by mutableStateOf<Float?>(null)
        private set
    var dragging = false
        private set

    /** 顶端被拉下来多少 */
    val pull: Float get() = rubber(drag)
    val hasPull: Boolean get() = drag > 0f

    /** 刷新触发后再拉多少，胶片从无到完全入画（0～1） */
    val reveal: Float get() = refreshedAt?.let { ((pull - it) / REVEAL_SPAN).coerceIn(0f, 1f) } ?: 0f
    /** 从刷新触发到过线走了多少（0～1）：放映灯随它变亮、首页随它变暗 */
    val progress: Float get() = refreshedAt?.let { ((pull - it) / ARM_BEYOND).coerceIn(0f, 1f) } ?: 0f

    private val pastLine: Boolean get() = refreshedAt?.let { pull >= it + ARM_BEYOND } ?: false

    /**
     * 手指拖动（正 = 往下拉，负 = 往回推），返回用掉的量。第一下视为新一次拖动：
     * 从头判断，不然上次松手留下的「过线」会让下一次普通滑动松手也进二楼。
     * 返回后 [refreshedAt] 从空变成有值 = 这一下刚好触发刷新。
     */
    fun dragBy(delta: Float): Float {
        if (!dragging) {
            dragging = true
            refreshedAt = null
        }
        val next = (drag + delta).coerceAtLeast(0f)
        val used = next - drag
        drag = next
        // 记刷新点本身而不是这一帧拉到的位置：手指一帧走得远时线也不会被推远
        if (refreshedAt == null && pull >= REFRESH_AT) refreshedAt = REFRESH_AT
        armed = pastLine
        return used
    }

    /** 手指抬起；返回 true 表示这一下是拉过线后松手 */
    fun release(): Boolean {
        dragging = false
        return armed
    }

    /** 松手后回弹的动画帧（按原始距离） */
    fun settle(to: Float) {
        drag = to.coerceAtLeast(0f)
    }

    val rawDrag: Float get() = drag

    /** 进了片段：清掉这一次 */
    fun reset() {
        drag = 0f
        armed = false
        refreshedAt = null
        dragging = false
    }

    companion object {
        /** 刷新的触发点：与 iPhone 17 Pro 上系统刷新实测的位置一致，拉的手感两端一样 */
        const val REFRESH_AT = 183f
        const val REVEAL_SPAN = 20f
        const val ARM_BEYOND = 35f

        /** 橡皮筋：前 48 跟手，之后越拉越沉（按 iOS 实测曲线拟合） */
        fun rubber(drag: Float): Float {
            if (drag <= 48f) return drag
            val x = 0.6f * (drag - 48f)
            return 48f + x * 700f / (700f + x)
        }
    }
}

/**
 * 把首页的纵向滚动接过来：顶端越界时内容跟手下移，刷新、过线、松手都在这里判。
 * [onRefresh] 在拖动中拉到刷新点时调（已经在刷新就不再调），[onEnter] 在过线松手时调。
 */
@Composable
fun rememberReelsFloorConnection(
    state: ReelsFloorState,
    refreshing: Boolean,
    onRefresh: () -> Unit,
    onEnter: () -> Unit,
): NestedScrollConnection {
    val density = LocalDensity.current.density
    val scope = rememberCoroutineScope()
    val refreshingNow by rememberUpdatedState(refreshing)
    val refresh by rememberUpdatedState(onRefresh)
    val enter by rememberUpdatedState(onEnter)
    return remember(state, density) {
        object : NestedScrollConnection {
            var settling: Job? = null

            private fun pullBy(deltaPx: Float): Offset {
                settling?.cancel()
                val before = state.refreshedAt
                val used = state.dragBy(deltaPx / density)
                if (before == null && state.refreshedAt != null && !refreshingNow) refresh()
                return Offset(0f, used * density)
            }

            // 往回推：先把拉开的那截收回去，再轮到内容滚动
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (source != NestedScrollSource.UserInput || available.y >= 0f || !state.hasPull) return Offset.Zero
                return pullBy(available.y)
            }

            // 内容已经到顶还往下拉：剩下的都算越界
            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (source != NestedScrollSource.UserInput || available.y <= 0f) return Offset.Zero
                return pullBy(available.y)
            }

            override suspend fun onPreFling(available: Velocity): Velocity {
                val entered = state.release()
                if (!state.hasPull) return Velocity.Zero
                if (entered) {
                    enter()
                    state.reset()
                    return available
                }
                settling = scope.launch {
                    animate(state.rawDrag, 0f, animationSpec = spring(stiffness = 500f)) { value, _ -> state.settle(value) }
                }
                return available
            }
        }
    }
}

/** 下拉露出的那一截（插在首页内容最上面）：高度跟着下拉量，胶片挂在底边 */
@Composable
fun ReelsFloorGap(state: ReelsFloorState, stills: List<String>, origin: String?) {
    val pull = state.pull
    if (pull < 0.5f) return
    Box(
        Modifier.fillMaxWidth().height(pull.dp).clipToBounds(),
        contentAlignment = Alignment.BottomCenter,
    ) {
        if (state.reveal > 0f) ReelsFilmStrip(state, stills, origin)
    }
}

/** 首页随下拉暗下去，把注意力让给胶片（0～0.6） */
fun ReelsFloorState.dimAlpha(): Float = reveal * 0.3f + progress * 0.3f

private val FrameW = 112.dp
private val FrameH = 70.dp
/** 相邻两格的间距、整条胶片的宽（含上下齿孔带） */
private const val STEP = 124f
private val Band = 104.dp
/** 手指拉一点，胶片走几点 */
private const val TRAVEL = 2.6f
private const val SIDE = 3
private val Lamp = Color(0xFFCCDBFF)

/**
 * 二楼的「走片」（与 iOS `ReelsFilmStrip` 同一版）：一条 35mm 胶片随手指穿过片门。
 *
 * - 冷银配色：石墨片基、冷白放映灯，光透过齿孔；片门里那格全彩，两侧褪成黑白；
 * - 胶片绕着看不见的过片轮：中间拱起、两头沉下并略微转开，两头隐进黑里；
 * - 胶片位置只由下拉量决定（往回推就倒片），每过一格轻轻一下；
 * - 过线时两块拉丝钢压片板合拢、胶片对齐到最近一格，那一格闪一下白光，重震一下。
 * 画格是首页已经拿到的条目剧照，不另发请求。
 */
@Composable
private fun ReelsFilmStrip(state: ReelsFloorState, stills: List<String>, origin: String?) {
    val reveal = state.reveal
    val progress = state.progress
    val armed = state.armed
    val raw = state.pull * TRAVEL
    // 过线后对齐到最近一格，让它卡进片门
    val snap by animateFloatAsState(
        if (armed) (raw / STEP).roundToInt() * STEP - raw else 0f,
        spring(stiffness = 900f),
        label = "film-snap",
    )
    val position = raw + snap
    val index = (position / STEP).roundToInt()
    val haptic = LocalHapticFeedback.current
    val flash = remember { Animatable(0f) }
    var lastIndex by remember { mutableIntStateOf(index) }
    LaunchedEffect(index) {
        if (index != lastIndex && !armed) haptic.performHapticFeedback(HapticFeedbackType.SegmentFrequentTick)
        lastIndex = index
    }
    LaunchedEffect(armed) {
        if (!armed) return@LaunchedEffect
        haptic.performHapticFeedback(HapticFeedbackType.GestureThresholdActivate)
        flash.snapTo(1f)
        flash.animateTo(0f, tween(550))
    }
    Column(
        Modifier
            .fillMaxWidth()
            .padding(bottom = 16.dp)
            .graphicsLayer {
                alpha = reveal
                translationX = -(1f - reveal) * 120.dp.toPx()
            }
            .clearAndSetSemantics { },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            if (armed) "松手，开始欣赏" else "再拉一点，开始欣赏片段",
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.5.sp,
            color = if (armed) Accent else TextMuted,
        )
        Film(position, progress, armed, flash.value, stills, origin)
    }
}

@Composable
private fun Film(position: Float, progress: Float, armed: Boolean, flash: Float, stills: List<String>, origin: String?) {
    val base = floor(position / STEP).toInt()
    val frac = position - base * STEP
    BoxWithConstraints(
        Modifier
            .fillMaxWidth()
            .height(Band + 24.dp)
            // 两头隐进黑里
            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
            .drawWithContent {
                drawContent()
                drawRect(
                    Brush.horizontalGradient(0f to Color.Transparent, 0.2f to Color.Black, 0.8f to Color.Black, 1f to Color.Transparent),
                    blendMode = BlendMode.DstIn,
                )
            }
            // 放映灯
            .drawBehind {
                drawCircle(
                    Brush.radialGradient(
                        listOf(Lamp.copy(alpha = (0.16f + 0.3f * progress + 0.4f * flash).coerceAtMost(1f)), Color.Transparent),
                        center = center,
                        radius = (150 + 40 * progress).dp.toPx(),
                    ),
                    radius = (150 + 40 * progress).dp.toPx(),
                )
            },
        contentAlignment = Alignment.Center,
    ) {
        val half = maxWidth.value / 2f
        // 先画两侧、后画中间：中间那格压在最上面
        for (k in base - SIDE..base + SIDE) {
            key(k) {
                val x = (k - base) * STEP - frac
                val c = x / half
                val near = (1f - abs(c) * 1.35f).coerceAtLeast(0f)
                val url = if (stills.isEmpty()) null else stills[Math.floorMod(k, stills.size)]
                FilmCell(
                    url = url,
                    origin = origin,
                    light = (near * (0.35f + 0.65f * progress) + flash * near).coerceAtMost(1.2f),
                    color = near * (0.4f + 0.6f * progress),
                    modifier = Modifier
                        .zIndex(-abs(c))
                        .graphicsLayer {
                            translationX = x.dp.toPx()
                            translationY = (18f * c * c).dp.toPx()
                            rotationZ = Math.toDegrees(c * 0.11).toFloat()
                            val s = 1f - 0.16f * c * c
                            scaleX = s
                            scaleY = s
                        },
                )
            }
        }
        Gate(closed = armed, progress = progress, flash = flash)
    }
}

/** 片门：两块拉丝钢压片板，过线时合拢 */
@Composable
private fun Gate(closed: Boolean, progress: Float, flash: Float) {
    val gap by animateDpAsState(FrameW / 2 + 9.dp + if (closed) 0.dp else 14.dp, spring(stiffness = 700f), label = "gate")
    val outline by animateFloatAsState(if (closed) 0.85f else 0.25f, label = "gate-outline")
    val steel = Brush.verticalGradient(
        listOf(
            Color(0xFF30333B),
            Color(red = 0.8f + 0.07f * progress, green = 0.84f + 0.06f * progress, blue = 0.88f + 0.05f * progress),
            Color(0xFF262930),
        ),
    )
    Box(Modifier.size(FrameW + 6.dp, FrameH + 6.dp).border(1.dp, Accent.copy(alpha = outline), RoundedCornerShape(4.dp)))
    for (side in listOf(-1, 1)) {
        Box(
            Modifier
                .offset { androidx.compose.ui.unit.IntOffset((gap * side).roundToPx(), 0) }
                .size(6.dp, FrameH + 22.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(steel),
        )
    }
    if (flash > 0.01f) {
        Box(
            Modifier.size(180.dp).drawBehind {
                drawCircle(
                    Brush.radialGradient(listOf(Color.White.copy(alpha = 0.9f * flash), Color.Transparent)),
                    blendMode = BlendMode.Plus,
                )
            },
        )
    }
}

/** 一格胶片：片基、上下各一排透光的齿孔、中间的画格 */
@Composable
private fun FilmCell(url: String?, origin: String?, light: Float, color: Float, modifier: Modifier) {
    val lit = light.coerceAtMost(1f)
    val base = Color(red = 0.07f + 0.12f * light, green = 0.08f + 0.13f * light, blue = 0.09f + 0.14f * light).copy(alpha = 0.97f)
    val hole = Color(red = 0.89f, green = 0.92f, blue = 0.97f, alpha = 0.1f + 0.78f * lit)
    Box(
        modifier
            .width((STEP + 8).dp)
            .height(Band)
            .drawBehind {
                drawRect(base)
                val w = 11.dp.toPx()
                val h = 7.dp.toPx()
                val step = STEP.dp.toPx() / 4
                val left = (size.width - STEP.dp.toPx()) / 2 + 8.dp.toPx()
                for (y in listOf(4.dp.toPx(), size.height - 4.dp.toPx() - h)) {
                    for (j in 0 until 4) {
                        drawRoundRect(hole, Offset(left + j * step, y), Size(w, h), CornerRadius(2.dp.toPx()))
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        RemoteImage(
            url = url,
            origin = origin,
            modifier = Modifier.size(FrameW, FrameH).clip(RoundedCornerShape(3.dp)),
            colorFilter = filmFilter(color, -0.45f + 0.5f * lit),
        )
    }
}

/** 两侧褪成黑白、按背光调亮度（对应 iOS 的 saturation + contrast + brightness） */
private fun filmFilter(saturation: Float, brightness: Float): ColorFilter {
    val matrix = ColorMatrix().apply { setToSaturation(saturation.coerceIn(0f, 1f)) }
    val contrast = 1.08f
    val offset = (brightness + (1f - contrast) / 2f) * 255f
    matrix *= ColorMatrix(
        floatArrayOf(
            contrast, 0f, 0f, 0f, offset,
            0f, contrast, 0f, 0f, offset,
            0f, 0f, contrast, 0f, offset,
            0f, 0f, 0f, 1f, 0f,
        ),
    )
    return ColorFilter.colorMatrix(matrix)
}

/** 开着读屏（TalkBack）时做不了下拉手势：顶栏照旧给片段按钮 */
@Composable
fun rememberTouchExploration(): State<Boolean> {
    val context = androidx.compose.ui.platform.LocalContext.current
    val manager = remember(context) {
        context.getSystemService(android.content.Context.ACCESSIBILITY_SERVICE) as android.view.accessibility.AccessibilityManager
    }
    val enabled = remember { mutableStateOf(manager.isTouchExplorationEnabled) }
    androidx.compose.runtime.DisposableEffect(manager) {
        val listener = android.view.accessibility.AccessibilityManager.TouchExplorationStateChangeListener { enabled.value = it }
        manager.addTouchExplorationStateChangeListener(listener)
        onDispose { manager.removeTouchExplorationStateChangeListener(listener) }
    }
    return enabled
}

/** 每次启动换一次胶片画格的顺序（拖动、刷新时不变） */
private val floorSeed = kotlin.random.Random.nextInt()

/** 胶片画格：首页已经拿到的条目剧照，去重后随机取 8 张（不另发请求） */
fun floorStills(home: LibraryHome): List<String> =
    (home.upNext.mapNotNull { it.backdropUrl } +
        home.rows.flatMap { row -> row.items.mapNotNull { it.backdropUrl } } +
        home.kindRows.flatMap { row -> row.items.mapNotNull { it.backdropUrl } })
        .distinct()
        .shuffled(kotlin.random.Random(floorSeed))
        .take(8)

/** 刷新转圈：拉的时候按距离画满一圈，拉到刷新点（或正在刷新）转起来；胶片出来时淡掉 */
@Composable
fun FloorRefreshIndicator(floor: ReelsFloorState, refreshing: Boolean, modifier: Modifier = Modifier) {
    val pulling = floor.hasPull && floor.refreshedAt == null
    if (!refreshing && !floor.hasPull) return
    Box(
        modifier
            .size(36.dp)
            .graphicsLayer { alpha = 1f - floor.reveal * 0.8f }
            .clip(androidx.compose.foundation.shape.CircleShape)
            .background(io.movieclaw.android.core.designsystem.GlassRaised),
        contentAlignment = Alignment.Center,
    ) {
        if (pulling && !refreshing) {
            androidx.compose.material3.CircularProgressIndicator(
                progress = { (floor.pull / ReelsFloorState.REFRESH_AT).coerceIn(0f, 1f) },
                modifier = Modifier.size(20.dp),
                color = io.movieclaw.android.core.designsystem.TextPrimary,
                strokeWidth = 2.dp,
                trackColor = Color.Transparent,
            )
        } else {
            androidx.compose.material3.CircularProgressIndicator(
                modifier = Modifier.size(20.dp),
                color = io.movieclaw.android.core.designsystem.TextPrimary,
                strokeWidth = 2.dp,
            )
        }
    }
}

package io.movieclaw.android.core.designsystem

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.lerp
import dev.chrisbanes.haze.hazeEffect
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.min

/*
 * 新底栏（液态玻璃，preview-liquid-glass-tabbar.html 预览的上机版）。
 * 由「我的 → 底栏液态玻璃」开关切换，与 McCapsuleTabBar（当前形态）A/B 对比。
 *
 * 相对当前形态的差别（口径全部来自移动端网页 glass-tab-bar.tsx / globals.css）：
 *   · 选中胶囊走欠阻尼弹簧（刚度 650 / 阻尼 36）：速度越快横向拉得越长、行进中微微抬起，
 *     换目标时按当前速度接续（可打断）；
 *   · **点按即时反馈**：手指按下胶囊就先滑到手指所在格（iOS 液态底栏的按压预览），
 *     抬手才真正切页——药丸不等抬手才动，迟滞感从这里来（实机反馈）；
 *   · 按压辉光：触点处玻璃由内发亮（90ms 亮起 / 520ms 熄灭），整块玻璃鼓起 2%；
 *   · 边缘高光线：1px 环带亮度分布（左上主高光 / 右下回光 / 上沿偏亮）；
 *   · 图标带 1px 淡投影（压在亮海报上不糊）；
 *   · 角标 7dp + 2dp 深描边，「有人正在观看」绿点带呼吸扩散环；
 *   · 收缩形态：同一条胶囊缩到 44dp 钉在左端（页签向当前格收拢并糊掉，圆钮在胶囊内弹出）；
 *   · 按住底栏左右拖 = 拖动擦选（阈值 8dp），松手按惯性投射吸附最近页签。
 *
 * **手势必须读 rememberUpdatedState 的最新选中页**：pointerInput 不重启就不换闭包，
 * 直接捕获 selectedIndex 的话永远是底栏首次组装那一页——表现为「永远拖不回起始页」
 * （实机踩过：媒体库拖回首页被判成「没换页」而弹回）。
 *
 * Android 没有 backdrop-filter：玻璃底仍是「黑底等价」表达（见 Shell.kt 注释）。
 */

/** 弹簧参数（网页 lib/liquid-spring.ts 同一组：约 100ms 走完九成行程、轻微过冲） */
private const val SPRING_STIFFNESS = 650f
private const val SPRING_DAMPING = 36f

@Composable
fun McLiquidTabBar(
    icons: List<ImageVector>,
    labels: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    modifier: Modifier = Modifier,
    /** 最后一格是账号头像：有 `avatarUrl` 显示同步头像（iOS/网页同口径），否则首字徽标 */
    avatarInitials: String? = null,
    /** 当前账号的服务端头像（相对路径，走鉴权图片管线） */
    avatarUrl: String? = null,
    /** 头像地址解析用的服务器来源 */
    origin: String? = null,
    /** 要挂状态点的格下标 → 点（活动三色点 / 「我的」更新蓝点） */
    dots: Map<Int, TabDot> = emptyMap(),
    /** 背景模糊源（内容层已用 `tabGlassSource` 标记）；null = 退回黑底等价玻璃 */
    hazeState: dev.chrisbanes.haze.HazeState? = null,
) {
    val count = icons.size
    if (count == 0) return

    // 收缩过渡：底边不动、顶边下来（网页 --tabbar-h 54→44 的口径）。
    // 只在布局/图层阶段读它（传 lambda 下去）：560ms 过渡里每帧重组整条底栏 + 玻璃逐帧换尺寸，
    // 开液态玻璃后滚动一起步就掉帧（实机反馈）
    val miniState = animateFloatAsState(
        targetValue = if (TabBarMinimize.minimized) 1f else 0f,
        animationSpec = tween(560, easing = CubicBezierEasing(0.32f, 1.25f, 0.4f, 1f)),
        label = "liquid-minimize",
    )

    Box(modifier.fillMaxWidth().height(McMetrics.tabBarHeight + 8.dp)) {
        BoxWithConstraints(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = McMetrics.tabBarInset)
                .height(McMetrics.tabBarHeight + 8.dp)
                .align(Alignment.BottomCenter),
        ) {
            LiquidCapsule(
                fullW = maxWidth,
                mini = { miniState.value },
                count = count,
                icons = icons,
                labels = labels,
                selectedIndex = selectedIndex,
                onSelect = onSelect,
                avatarInitials = avatarInitials,
                avatarUrl = avatarUrl,
                origin = origin,
                dots = dots,
                hazeState = hazeState,
            )
        }
    }
}

@Composable
private fun androidx.compose.foundation.layout.BoxScope.LiquidCapsule(
    fullW: Dp,
    mini: () -> Float,
    count: Int,
    icons: List<ImageVector>,
    labels: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit,
    avatarInitials: String?,
    avatarUrl: String?,
    origin: String?,
    dots: Map<Int, TabDot>,
    hazeState: dev.chrisbanes.haze.HazeState?,
) {
    // 只在越过一半时变一次：收起/展开的切换点（页签浮现、指示器淡出跟它走）
    val collapsed by remember { derivedStateOf { mini() > 0.5f } }

    // 手势闭包里只能读这两个包装值：pointerInput 不重启就不换闭包，直接捕获参数会拿到
    // 底栏首次组装时的旧值（「拖不回起始页」的根因）
    val latestSelected by rememberUpdatedState(selectedIndex)
    val latestOnSelect by rememberUpdatedState(onSelect)

    // 按压预览：手指按在哪格，胶囊就先滑到那格（抬手才真正 onSelect 切页）
    var previewCell by remember { mutableStateOf<Int?>(null) }

    // 按压辉光
    var glowCenter by remember { mutableStateOf(Offset.Zero) }
    val glow = remember { Animatable(0f) }
    var pressed by remember { mutableStateOf(false) }
    /** 辉光的当前任务：按下（亮起）与抬手（熄灭）各一个；换新任务前显式取消旧的，
     *  避免两个协程抢同一个 Animatable（后启动的快照会把已在跑的熄灭动画顶掉 → 辉光卡住不灭） */
    var glowJob by remember { mutableStateOf<kotlinx.coroutines.Job?>(null) }

    // 弹簧胶囊 / 拖动擦选
    var pillX by remember { mutableFloatStateOf(0f) }   // px，相对页签层左缘
    var pillV by remember { mutableFloatStateOf(0f) }   // px/s
    var pillMoving by remember { mutableStateOf(false) }
    var dragActive by remember { mutableStateOf(false) }
    var springEpoch by remember { mutableIntStateOf(0) }
    // 首次落位（见下面的弹簧循环）：底栏被「移出合成再回来」（去设置页返回、跳别的路由再回来）
    // 时 remember 重建、pillX 回到初值 0，胶囊就会从最左格一路弹到当前页签——看着就是闪一下
    // （实机反馈：从服务器设置退出时）。第一次拿到有效几何且没有按压预览时直接落位，之后才走弹簧。
    var pillPlaced by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    // 换页兜底：无论手势收尾在哪条路径上漏掉（被取消/指针流中断），换页后都把辉光熄掉
    LaunchedEffect(selectedIndex) {
        glowJob?.cancel()
        glowJob = scope.launch { glow.animateTo(0f, tween(520, easing = LinearOutSlowInEasing)) }
    }

    Box(
        Modifier
            .align(Alignment.BottomStart)
            .layout { measurable, _ ->
                val m = mini()
                val w = lerp(fullW, 44.dp, m).roundToPx()
                val h = lerp(McMetrics.tabBarHeight, 44.dp, m).roundToPx()
                val placeable = measurable.measure(Constraints.fixed(w, h))
                layout(w, h) { placeable.place(0, 0) }
            }
            .graphicsLayer {
                // 按压鼓起 2%（网页 data-pressed）
                val s = if (pressed) 1.02f else 1f
                scaleX = s; scaleY = s
            }
            .pointerInput(count) {
                // 点按与拖动统一在这一处处理（此前点按靠子格 clickable、拖动靠父手势，
                // 两套机制抢事件：快甩时丢速度、点按偶发被吞——实机两项都踩了）。
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    pressed = true
                    dragActive = false
                    glowCenter = down.position
                    glowJob?.cancel()
                    glowJob = scope.launch { glow.snapTo(1f) }
                    val cell = (size.width - 6.dp.toPx()) / count
                    // 按下即时反馈：胶囊先滑到手指所在格（iOS 液态底栏的按压预览）
                    val downCell = ((down.position.x - 3.dp.toPx()).coerceIn(0f, size.width - 6.dp.toPx()) / cell)
                        .toInt().coerceIn(0, count - 1)
                    if (downCell != latestSelected) previewCell = downCell
                    val tracker = VelocityTracker()
                    tracker.addPosition(down.uptimeMillis, down.position)
                    var moved = false
                    try {
                        while (true) {
                        val change = awaitPointerEvent().changes.firstOrNull { it.id == down.id } ?: break
                        if (change.positionChange() != Offset.Zero || !change.pressed) {
                            runCatching { tracker.addPosition(change.uptimeMillis, change.position) }
                        }
                        if (moved || abs(change.position.x - down.position.x) > 8.dp.toPx()) {
                            moved = true
                            dragActive = true
                            pillX = (change.position.x - 3.dp.toPx() - cell / 2).coerceIn(0f, cell * (count - 1))
                            change.consume()
                        }
                        if (!change.pressed) break
                    }
                    } finally {
                        // 收尾一律走这里：手势被取消（换页 / 布局变化 / 指针流中断）也不能
                        // 把「按下态 + 辉光」留在屏幕上（实机反馈：点一下底栏后光斑不灭）
                        pressed = false
                        previewCell = null
                        dragActive = false
                        glowJob?.cancel()
                        glowJob = scope.launch { glow.animateTo(0f, tween(520, easing = LinearOutSlowInEasing)) }
                    }
                    if (!moved) {
                        // 点按：按下时预览的那格就是要去的那格
                        previewCell = null
                        latestOnSelect(downCell)
                    } else {
                        // 拖动松手：按速度做惯性投射（≈80ms 滑行，最多 1.5 格）再吸附最近页签；
                        // 只看手指最后位置的话，快丢手时手指还没过半格就会「甩过去又弹回来」
                        val velocity = runCatching { tracker.calculateVelocity().x }.getOrDefault(0f)
                        pillV = velocity
                        val carry = (velocity * 0.08f).coerceIn(-cell * 1.5f, cell * 1.5f)
                        val projected = (pillX + carry).coerceIn(0f, cell * (count - 1))
                        val nearest = ((projected + cell / 2) / cell).toInt().coerceIn(0, count - 1)
                        previewCell = null
                        dragActive = false
                        if (nearest == latestSelected) springEpoch++ else latestOnSelect(nearest)
                    }
                }
            },
    ) {
        /* ── 玻璃层：单独裁剪成胶囊形（模糊 + 遮罩 + 高光边都在这层）。
              裁剪只套玻璃自己，**不套页签层**——否则拖动时胶囊的抬起/拉伸会被上下裁平（实机反馈）；
              网页正是这样：.glass-capsule 不裁子元素，指示器能微微越出玻璃边 ── */
        Box(
            Modifier
                .matchParentSize()
                .clip(RoundedCornerShape(999.dp))
                // 真背景模糊（Haze 1.x）：必须排在遮罩色之前——
                // 越靠前的 Modifier 绘制越靠底层，模糊放 background 后面会被遮罩整个盖住
                .then(
                if (hazeState != null) {
                    Modifier.hazeEffect(
                        state = hazeState,
                        block = {
                            style = dev.chrisbanes.haze.HazeStyle(
                                backgroundColor = Color(0xFF0B0C10),
                                tints = listOf(dev.chrisbanes.haze.HazeTint(GlassCapsule)),
                                // 网页材质 backdrop-filter: blur(14px)
                                blurRadius = 14.dp,
                                noiseFactor = 0f,
                            )
                            // 降档抓取（默认 None=全分辨率，切页/滚动时每帧全尺寸抓+糊，
                            // 实机反馈「底栏卡卡的」）：Auto 按模糊半径自动降采样再模糊，
                            // 14dp 模糊下肉眼无差、开销大降
                            inputScale = dev.chrisbanes.haze.HazeInputScale.Auto
                        },
                    )
                } else {
                        Modifier
                    },
                )
                .background(GlassCapsule)
                // 边缘高光线：光从左上打来——左上主高光、右下回光、上沿偏亮的纵向渐变。
                // 渐变按尺寸缓存，只在尺寸变了才重建
                .drawWithCache {
                    val w = size.width
                    val h = size.height
                    val stroke = Stroke(width = 1.dp.toPx())
                    val corner = CornerRadius(h / 2f)
                    val topLeft = Brush.radialGradient(
                        colors = listOf(Color.White.copy(alpha = 0.62f), Color.Transparent),
                        center = Offset(w * 0.12f, 0f),
                        radius = 90.dp.toPx(),
                    )
                    val bottomRight = Brush.radialGradient(
                        colors = listOf(Color.White.copy(alpha = 0.34f), Color.Transparent),
                        center = Offset(w * 0.88f, h),
                        radius = 90.dp.toPx(),
                    )
                    val vertical = Brush.verticalGradient(
                        0f to Color.White.copy(alpha = 0.30f),
                        0.45f to Color.White.copy(alpha = 0.07f),
                        0.60f to Color.White.copy(alpha = 0.05f),
                        1f to Color.White.copy(alpha = 0.16f),
                    )
                    onDrawWithContent {
                        drawContent()
                        drawRoundRect(topLeft, size = size, style = stroke, cornerRadius = corner)
                        drawRoundRect(bottomRight, size = size, style = stroke, cornerRadius = corner)
                        drawRoundRect(vertical, size = size, style = stroke, cornerRadius = corner)
                    }
                },
        )
        // 按压辉光：触点处由内发亮。**单独一层**画在玻璃上面——画在玻璃层里的话，
        // 辉光 520ms 熄灭的每一帧都会让整块背景模糊重新渲染一遍
        Box(
            Modifier
                .matchParentSize()
                .clip(RoundedCornerShape(999.dp))
                .drawBehind {
                    val g = glow.value
                    if (g > 0.01f) {
                        drawRect(
                            Brush.radialGradient(
                                listOf(
                                    Color.White.copy(alpha = 0.24f),
                                    Color.White.copy(alpha = 0.07f),
                                    Color.Transparent,
                                ),
                                center = glowCenter,
                                radius = 72.dp.toPx(),
                            ),
                            alpha = g,
                        )
                    }
                },
        )
        /* ── 页签层：收起时向当前格收拢并糊掉（blur 是 API 31+ 的 RenderEffect，低版本只剩缩放淡出） ── */
        Box(
            Modifier
                .matchParentSize()
                .padding(3.dp)
                .graphicsLayer {
                    val m = mini()
                    alpha = 1f - m
                    scaleX = 1f - 0.18f * m
                    scaleY = 1f - 0.18f * m
                    transformOrigin = TransformOrigin((selectedIndex + 0.5f) / count, 0.5f)
                    // **只在收起时挂模糊**：RenderEffect 会把内容装进按节点尺寸定界的图层，
                    // 常态挂着它，拖动/抬起时探出页签层的部分会被图层边缘切平——
                    // 胶囊上下被「裁平」的根因（实机截图：右侧一条平直竖切边）。收起时胶囊已淡出，无碍。
                    // 在图层阶段设置而不是挂 Modifier.blur：后者半径每帧变就每帧重组
                    renderEffect = if (m > 0.01f && android.os.Build.VERSION.SDK_INT >= 31) {
                        val r = 6.dp.toPx() * m
                        BlurEffect(r, r, TileMode.Decal)
                    } else null
                },
        ) {
            // 页签层宽按**展开时**的宽算（胶囊宽 − 两侧 3dp）：按实时宽算的话，收起过渡里
            // 宽度每帧在变，整层页签跟着每帧重组、弹簧协程每帧重启
            val tabsW = fullW - 6.dp
            val cellWpx = with(LocalDensity.current) { (tabsW / count).toPx() }

            // 弹簧：欠阻尼 + 可打断。目标是「按压预览的那格；没有预览时是选中格」——
            // 按下即滑过去（即时反馈），抬手 onSelect 后 selectedIndex 变了、目标不变，无跳变
            LaunchedEffect(selectedIndex, previewCell, tabsW, springEpoch) {
                if (TabBarMinimize.minimized) return@LaunchedEffect
                val targetCell = previewCell ?: selectedIndex
                val target = cellWpx * targetCell
                // 首次落位：几何有效（tabsW > 0）且没有按压预览时，直接落到目标格、不做弹簧动画。
                // 不然重建后 pillX=0，会从最左格弹到当前页签（一闪）。按压预览一律走弹簧——
                // 那是用户手指下的即时反馈，瞬移反而会像「瞬移，没有滑动动画」。
                if (!pillPlaced) {
                    if (tabsW.value > 0f && previewCell == null) {
                        pillPlaced = true
                        pillX = target; pillV = 0f; pillMoving = false
                    }
                    return@LaunchedEffect
                }
                if (abs(pillX - target) < 0.5f && abs(pillV) < 1f) {
                    pillX = target; pillV = 0f; pillMoving = false
                    return@LaunchedEffect
                }
                pillMoving = true
                // 拖过头又往回拖松手的场景：剩余速度指向背离目标的方向时先衰减，
                // 不然弹簧会先朝速度方向冲一下再折返（看着像弹错格）
                if ((target - pillX) * pillV < 0f) pillV *= 0.3f
                // **真实时间步长**：帧率无关。固定 1/60 在 120Hz 屏上每帧走两步，
                // 弹簧双倍速播完——肉眼就是「瞬移，没有滑动动画」（实机反馈）
                var lastNanos = withFrameNanos { it }
                val dt = 1f / 60f
                var x = pillX
                var v = pillV
                while (isActive && !dragActive) {
                    val nanos = withFrameNanos { it }
                    val step = ((nanos - lastNanos) / 1_000_000_000f).coerceIn(1f / 240f, 1f / 30f)
                    lastNanos = nanos
                    val a = -SPRING_STIFFNESS * (x - target) - SPRING_DAMPING * v
                    v += a * step
                    x += v * step
                    pillX = x; pillV = v
                    if (abs(x - target) < 0.5f && abs(v) < 6f) break
                }
                if (!dragActive) {
                    pillX = target; pillV = 0f; pillMoving = false
                }
            }

            val indicatorAlpha by animateFloatAsState(if (collapsed) 0f else 1f, tween(160), label = "pill-alpha")
            // 选中胶囊：**一格宽**（网页 `width: calc(100% / var(--count))`）——
            // 这里必须显式给宽，不能 matchParentSize（那样是一条全宽亮条在平移，实机踩过）
            Box(
                Modifier
                    .fillMaxWidth(1f / count)
                    .fillMaxHeight()
                    .graphicsLayer {
                        translationX = pillX
                        val stretch = if (pillMoving || dragActive) {
                            min(abs(pillV) / density * 0.00035f, 0.32f)
                        } else 0f
                        // 拖动 = 「放大的气泡」：明显高出导航栏一截（iOS 液态底栏的手感；
                        // 之前只有 4.5% 的行进抬起，拖起来上下仍与栏齐平——实机反馈）。
                        // 页签层在玻璃裁剪之外，探出的部分不会被裁
                        val lift = if (dragActive) 1.22f else if (pillMoving) 1.045f else 1f
                        val widen = if (dragActive) 1.08f else 1f
                        scaleX = (1f + stretch) * widen
                        scaleY = lift
                        alpha = indicatorAlpha
                    }
                    .clip(RoundedCornerShape(999.dp))
                    .then(
                        if (dragActive) {
                            // 拖动中的「气泡」材质：更亮 + 内描边高光
                            Modifier
                                .background(Color.White.copy(alpha = 0.20f))
                                .border(1.dp, Color.White.copy(alpha = 0.16f), RoundedCornerShape(999.dp))
                        } else {
                            Modifier.background(Color.White.copy(alpha = 0.15f))
                        },
                    ),
            )

            // 页签格子（展开时自左向右依次浮现，每格延迟 22ms）
            Row(Modifier.matchParentSize()) {
                repeat(count) { i ->
                    val appear by animateFloatAsState(
                        targetValue = if (collapsed) 0f else 1f,
                        animationSpec = tween(300, delayMillis = if (collapsed) 0 else i * 22),
                        label = "tab-appear-$i",
                    )
                    Box(
                        Modifier
                            .weight(1f)
                            .fillMaxSize()
                            .graphicsLayer {
                                alpha = appear
                                scaleX = 0.7f + 0.3f * appear
                                scaleY = 0.7f + 0.3f * appear
                            }
                            // 点按/拖动都由胶囊层的统一手势处理（见上）：子格不再挂 clickable，
                            // 否则两套手势抢事件——快甩丢速度、点按偶发吞掉（实机两项都踩了）
                            .semantics {
                                contentDescription = labels.getOrNull(i) ?: ""
                                dots[i]?.let { dot -> stateDescription = dot.label }
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        if (i == count - 1 && (avatarUrl != null || avatarInitials != null)) {
                            // 「我的」格 = 当前账号头像：有同步头像显示头像（iOS/网页同口径），否则首字徽标
                            if (avatarUrl != null) {
                                RemoteImage(
                                    url = avatarUrl,
                                    origin = origin,
                                    widthHint = 96,
                                    contentDescription = labels.getOrNull(i),
                                    modifier = Modifier.size(25.dp).clip(CircleShape),
                                )
                            } else {
                                Box(
                                    Modifier.size(25.dp).clip(CircleShape).background(Color.White),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Text(avatarInitials ?: "", style = McType.microSemibold, color = Color(0xFF141821))
                                }
                            }
                        } else {
                            ShadowedIcon(icon = icons[i], description = labels.getOrNull(i))
                        }
                        dots[i]?.let { dot -> StatusDot(dot, livePulse = dot.color == Ok) }
                    }
                }
            }
        }

        // 收起态圆钮：胶囊内左端弹出（网页 .glass-tabbar__mini）
        Box(
            Modifier
                .align(Alignment.CenterStart)
                .size(40.dp)
                .graphicsLayer {
                    val m = mini()
                    alpha = m
                    val s = 0.6f + 0.4f * m
                    scaleX = s; scaleY = s
                }
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) { TabBarMinimize.restore() },
            contentAlignment = Alignment.Center,
        ) {
            ShadowedIcon(
                icon = icons.getOrNull(selectedIndex) ?: icons.first(),
                description = labels.getOrNull(selectedIndex),
                tint = Color(0xFF9DB8FF),
            )
        }
    }
}

/** 图标 + 1px 淡投影（网页 svg drop-shadow；安卓用「底下垫一层偏移黑影」表达） */
@Composable
private fun androidx.compose.foundation.layout.BoxScope.ShadowedIcon(
    icon: ImageVector,
    description: String?,
    tint: Color = Color.White,
) {
    Box {
        Icon(
            icon, contentDescription = null,
            tint = Color.Black.copy(alpha = 0.45f),
            modifier = Modifier.align(Alignment.Center).offset(y = 1.dp).size(23.dp),
        )
        Icon(
            icon, contentDescription = description,
            tint = tint,
            modifier = Modifier.align(Alignment.Center).size(23.dp),
        )
    }
}

/** 7dp 状态点 + 2dp 深描边；live 点带 1.6s 呼吸扩散环（网页 .glass-tabbar__badge） */
@Composable
private fun androidx.compose.foundation.layout.BoxScope.StatusDot(dot: TabDot, livePulse: Boolean) {
    Box(
        Modifier
            .align(Alignment.Center)
            .offset(x = 13.dp, y = -12.dp)
            .size(11.dp),
    ) {
        Box(Modifier.fillMaxSize().clip(CircleShape).background(Color(0xEA1C1E23)))
        if (livePulse) {
            // 无限动画只给 live 点开（以前任何状态点都在跑，且在组合里读值 = 永远每帧重组）
            val transition = rememberInfiniteTransition(label = "dot-ping")
            val ping = transition.animateFloat(
                initialValue = 0f,
                targetValue = 1f,
                animationSpec = infiniteRepeatable(tween(1600, easing = CubicBezierEasing(0f, 0f, 0.2f, 1f))),
                label = "dot-ping-value",
            )
            Box(
                Modifier
                    .align(Alignment.Center)
                    .size(7.dp)
                    .graphicsLayer {
                        val p = ping.value
                        scaleX = 1f + 1.2f * p
                        scaleY = 1f + 1.2f * p
                        alpha = (1f - p) * 0.6f
                    }
                    .clip(CircleShape)
                    .background(dot.color),
            )
        }
        Box(Modifier.align(Alignment.Center).size(7.dp).clip(CircleShape).background(dot.color))
    }
}

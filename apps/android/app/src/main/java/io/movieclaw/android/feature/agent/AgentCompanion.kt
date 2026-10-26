package io.movieclaw.android.feature.agent

import android.provider.Settings
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.foundation.layout.offset
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.currentStateAsState
import kotlin.random.Random
import kotlinx.coroutines.delay

/**
 * 小幕（iOS `AgentCompanion` 的对应物）：趴在输入框右上角的月夜小猫。
 *
 * 同一张 4 列 × 6 行的精灵图（`res/drawable-nodpi/agent_moon_companion.png`，1024×1536，每格 256）：
 * 第 0 行 idle、1 attentive、2 departing、3 working、4 complete、5 failed。
 * 任务状态驱动动作：在下 → 出发再工作；跑完 → 庆祝一下回待机；出错 → 停在 failed。
 * 轻点打招呼（播一遍 attentive）；系统「动画时长缩放 = 0」（减弱动效）或页面不在前台时保持静止。
 *
 * 素材是客户端内置的：服务端没有、也不下发这个形象（见 `docs/brand/companion/` 的图集说明），
 * 要换形象得重新出一张同网格的 4×6 图集并随 App 发版。
 */
enum class AgentCompanionState(
    val row: Int,
    /** 每帧时长；working 比其它动作慢一档（iOS 同款 300ms / 160ms） */
    val frameMs: Long,
    val label: String,
) {
    Idle(0, 160, "小幕，安静陪伴"),
    Attentive(1, 160, "小幕，正在听你说"),
    Departing(2, 160, "小幕，出发了"),
    Working(3, 300, "小幕，正在处理任务"),
    Complete(4, 160, "小幕，任务已完成"),
    Failed(5, 160, "小幕，任务遇到了问题"),
}

/** iOS `AgentCompanionState.resolve`：不可用→idle；在下→working；出错→failed；跑完→complete */
fun resolveCompanion(
    busy: Boolean,
    unavailable: Boolean,
    failed: Boolean,
    completed: Boolean,
): AgentCompanionState = when {
    unavailable -> AgentCompanionState.Idle
    busy -> AgentCompanionState.Working
    failed -> AgentCompanionState.Failed
    completed -> AgentCompanionState.Complete
    else -> AgentCompanionState.Idle
}

/** 减弱动效：系统里把「动画时长缩放」关掉（开发者选项/无障碍里都可能为 0） */
private fun reduceMotion(context: android.content.Context): Boolean = runCatching {
    Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE) == 0f
}.getOrDefault(false)

@Composable
fun AgentCompanion(
    /** 这一轮的状态（由会话页/新会话页算） */
    activity: AgentCompanionState,
    /** 输入框聚焦且有内容：待机时换成「正在听你说」 */
    attentive: Boolean,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val lifecycleState by lifecycle.currentStateAsState()
    val animated = lifecycleState == Lifecycle.State.RESUMED && !reduceMotion(context)

    val image = remember { loadCompanionBitmap(context) }
    var pose by remember { mutableStateOf(AgentCompanionState.Idle) }
    var frame by remember { mutableIntStateOf(0) }
    var moving by remember { mutableStateOf(false) }
    var greeting by remember { mutableIntStateOf(0) }
    var observedGreeting by remember { mutableIntStateOf(0) }

    LaunchedEffect(activity, attentive, greeting, animated) {
        // 只有真的点了才播「打招呼」：状态变化触发的重启不算
        val tappedNow = greeting != observedGreeting
        observedGreeting = greeting
        var next = activity
        // 重进已结束的历史会话不重复庆祝（iOS：上一状态不是 working 时的 complete 视为 idle）
        if (next == AgentCompanionState.Complete && pose != AgentCompanionState.Working) next = AgentCompanionState.Idle
        if ((next == AgentCompanionState.Idle || next == AgentCompanionState.Failed) && attentive) {
            next = AgentCompanionState.Attentive
        }
        pose = next
        frame = 0
        moving = false
        if (!animated) return@LaunchedEffect

        suspend fun playOnce(state: AgentCompanionState) {
            pose = state
            moving = true
            for (i in 0 until 4) {
                frame = i
                delay(state.frameMs)
            }
            moving = false
        }

        when {
            next == AgentCompanionState.Working -> {
                playOnce(AgentCompanionState.Departing)
                playOnce(AgentCompanionState.Working)
            }
            next == AgentCompanionState.Complete -> {
                playOnce(AgentCompanionState.Complete)
                delay(1_200)
                pose = if (attentive) AgentCompanionState.Attentive else AgentCompanionState.Idle
            }
            next == AgentCompanionState.Failed -> playOnce(AgentCompanionState.Failed)
            next == AgentCompanionState.Attentive && tappedNow ->
                playOnce(AgentCompanionState.Attentive)
            tappedNow && next == AgentCompanionState.Idle -> {
                playOnce(AgentCompanionState.Attentive)
                pose = AgentCompanionState.Idle
            }
        }
        frame = 0

        // 待机/工作时偶尔眨眼：working 15～25 秒、idle 8～14 秒（iOS 同款节奏）
        while (pose == AgentCompanionState.Working || pose == AgentCompanionState.Idle) {
            val seconds = if (pose == AgentCompanionState.Working) Random.nextInt(15, 26) else Random.nextInt(8, 15)
            delay(seconds * 1_000L)
            moving = true
            frame = if (pose == AgentCompanionState.Working) 2 else 1
            delay(250)
            frame = 0
            moving = false
        }
    }

    val departing = pose == AgentCompanionState.Departing
    Canvas(
        modifier
            .size(72.dp)
            .offset(
                x = if (departing) (frame * 5).dp else 0.dp,
                y = if (departing) (-(frame % 3) * 4).dp else 0.dp,
            )
            .clickable { greeting += 1 }
            .semantics { contentDescription = pose.label },
    ) {
        drawCompanionFrame(image, pose, frame)
    }
}

/** 从图集裁一格画到画布；图暂缺时什么都不画（不阻塞会话页） */
private fun DrawScope.drawCompanionFrame(image: ImageBitmap?, state: AgentCompanionState, frame: Int) {
    if (image == null) return
    val cellW = image.width / 4
    val cellH = image.height / 6
    drawImage(
        image = image,
        srcOffset = IntOffset(
            x = (frame.coerceIn(0, 3)) * cellW,
            y = state.row.coerceIn(0, 5) * cellH,
        ),
        srcSize = IntSize(cellW, cellH),
        dstSize = IntSize(size.width.toInt(), size.height.toInt()),
        filterQuality = FilterQuality.Low,
    )
}

private fun loadCompanionBitmap(context: android.content.Context): ImageBitmap? = runCatching {
    android.graphics.BitmapFactory.decodeResource(context.resources, io.movieclaw.android.R.drawable.agent_moon_companion)
        ?.asImageBitmap()
}.getOrNull()

/**
 * 会话状态 → 小幕的状态（iOS `.resolve(turn:busy:unavailable:)` 的安卓版）：
 * 没接入模型（models 为空）说明 AI 不可用 → 待机；在下 → working；上一轮失败 → failed；
 * 刚跑完的这一轮 → complete（2 秒后回到待机，庆祝只播一次）。
 */
@Composable
fun rememberCompanionActivity(
    running: Boolean,
    lastRunFailed: Boolean,
    unavailable: Boolean,
): AgentCompanionState {
    var completed by remember { mutableStateOf(false) }
    var wasRunning by remember { mutableStateOf(running) }
    LaunchedEffect(running, lastRunFailed) {
        if (wasRunning && !running && !lastRunFailed) {
            completed = true
            delay(2_000)
            completed = false
        }
        wasRunning = running
    }
    return when {
        unavailable -> AgentCompanionState.Idle
        running -> AgentCompanionState.Working
        lastRunFailed -> AgentCompanionState.Failed
        completed -> AgentCompanionState.Complete
        else -> AgentCompanionState.Idle
    }
}

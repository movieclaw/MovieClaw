package io.movieclaw.android.core.designsystem

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import dev.chrisbanes.haze.HazeState
import dev.chrisbanes.haze.hazeSource
import kotlin.math.roundToInt

/**
 * 液态底栏的模糊源（glass-kit 同款结构）：MainTabScreen 在**开关打开时**提供，
 * 各页签根页的内容层用 [tabGlassSource] 标记。开关关闭时 Local 为 null，标记原样返回，
 * 不付任何图层捕获的代价。
 */
val LocalTabHazeState = staticCompositionLocalOf<HazeState?> { null }

/**
 * 本页签此刻是否在前台。主页签切换时**不再拆掉重建**页面（每次切都从头组装列表、图片、轮播，
 * 那一帧很重，底栏胶囊会顿一下——实机反馈「切 tab 不跟手」），而是把去过的页签留在组合里、
 * 只是不摆放；后台页签据此停掉轮播计时、滚动收起追踪这类只该在前台跑的东西。
 * 不在主页签里的页面（二级页）恒为 true。
 */
val LocalTabActive = androidx.compose.runtime.compositionLocalOf { true }

/**
 * 液态玻璃气泡的取样源：前台页签的内容被**同时**记录进一个锚点层，底栏气泡用 AGSL
 * 折射这一层里「气泡底下那块画面」——iOS 26 选中胶囊的材质。
 *
 * Haze 的模糊与这里的折射取样是同一份内容的两种用法，但 Haze 自己保存它的源层、读不到，
 * 所以另记一层（一次记录、零拷贝，成本与 `hazeSource` 同量级）；切页签时由源节点换层。
 */
private class FrontSlot {
    var value: GraphicsLayer? = null
}

class TabGlassLayerHolder {
    /**
     * 消费者读的那张层。**双缓冲**：内容每帧录到「另一张」上，这里始终指向上一次录完的那张——
     * 否则画在内容层**内部**的玻璃件（筛选胶囊、任务卡上的键）会在录制进行中去读同一张纹理，
     * 实机读到的是空内容（整块发黑）。代价只有一帧滞后（16ms），滚动时肉眼不可见。
     */
    var layer by mutableStateOf<GraphicsLayer?>(null)

    /** 源内容节点在根坐标里的位置：气泡据此把源画面摆正到自己正下方 */
    var origin by mutableStateOf(Offset.Zero)
}

/** 气泡取样源的 Local；null = 开关关闭或非前台页签 */
val LocalTabGlassLayer = staticCompositionLocalOf<TabGlassLayerHolder?> { null }

/** 内容层标记：把本节点的绘制喂给玻璃件的背景模糊（`hazeSource`），并录一份给气泡折射采样 */
@Composable
fun Modifier.tabGlassSource(): Modifier {
    val state = LocalTabHazeState.current
    val holder = LocalTabGlassLayer.current
    // 双缓冲的两张层 + 当前「已录完」的那张（消费者读它）
    val layerA = if (holder != null) rememberGraphicsLayer() else null
    val layerB = if (holder != null) rememberGraphicsLayer() else null
    // front 用普通字段（非 Compose state）：绘制期写 state 会让本节点每帧自我失效
    val slot = remember(holder) { FrontSlot() }

    if (holder != null && layerA != null && layerB != null) {
        SideEffect { holder.layer = layerA }
        SideEffect { slot.value = layerA }
        DisposableEffect(holder, layerA, layerB) {
            onDispose { if (holder.layer === layerA || holder.layer === layerB) holder.layer = null }
        }
    }

    return this
        .then(if (state != null) Modifier.hazeSource(state) else Modifier)
        .then(
            if (holder != null && layerA != null && layerB != null) {
                Modifier
                    // 源节点位置（气泡把源画面摆正要用）：布局变了才回调
                    .onGloballyPositioned { holder.origin = it.positionInRoot() }
                    // 记录 + 原样画回：内容照常显示，同时留下一份可被气泡/顶栏玻璃件采样的层。
                    // 必须显式给 density 和**像素**尺寸：单参数重载按 1:1 密度记，
                    // 在 450dpi 这类高密度屏上记出来的是内容的左上角放大 2.8 倍的一块
                    // （气泡里看着「字大了一倍多」的根因）
                    //
                    // 这里**不按「底栏收起」停录**：顶栏的玻璃件（搜索圆钮、筛选胶囊）也要采这一层，
                    // 它们滚动时一直可见，停录会让取样冻住。代价是一次整屏离屏写，实测量到
                    // 滚动 0% 现代口径卡顿、p50 7–8ms（`dumpsys gfxinfo`，见 4358b032 的同类口径）。
                    // 低端机若真卡，下一档是降采样录制（约省 3/4 填充），代价是画面略软。
                    .drawWithContent {
                        // 录到「背面」那张，消费者读「正面」那张（上一帧的完整内容）→ 无同纹理读写冲突
                        val front = slot.value
                        val back = if (front === layerA) layerB else layerA
                        back.record(
                            density = this,
                            layoutDirection = layoutDirection,
                            size = androidx.compose.ui.unit.IntSize(
                                size.width.roundToInt(),
                                size.height.roundToInt(),
                            ),
                        ) {
                            this@drawWithContent.drawContent()
                        }
                        // 本帧稍后绘制的玻璃件（气泡、顶栏、内容层里的胶囊）读这张
                        holder.layer = front
                        drawLayer(back)
                        slot.value = back
                    }
            } else {
                Modifier
            },
        )
}

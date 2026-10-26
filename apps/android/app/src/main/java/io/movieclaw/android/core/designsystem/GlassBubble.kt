package io.movieclaw.android.core.designsystem

import android.graphics.RenderEffect
import android.graphics.RuntimeShader
import android.os.Build
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asComposeRenderEffect
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.layer.GraphicsLayer
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.unit.IntSize
import kotlin.math.roundToInt

/*
 * 液态玻璃气泡（AGSL / API 33+）：把气泡下面那块**真实画面**按「透镜折射 + 边缘色散 +
 * 菲涅尔边缘光 + 定向高光」画出来 —— iOS 26 选中胶囊的材质。
 *
 * 为什么安卓能做得比网页"真"：网页的 WebGL 读不到 DOM 内容，只能「清透 CSS + WebGL 厚边」
 * （见 docs/design/web-themes-mobile/04）；安卓的 AGSL（RuntimeShader）能把实时内容当
 * shader 输入直接采样，而气泡只有一格宽 —— 每帧只算这一小块，成本 ≈ 一次小尺寸离屏绘制。
 *
 * 取数全在**绘制阶段**（lambda 现读）：气泡弹簧/拖动每帧都在动，走组合参数会让整条底栏逐帧重组。
 * `source()` 为空（开关关闭、离开前台页签、低版本）时不画任何东西，气泡维持调用方原来的填充材质。
 */

/** 气泡底下的取样源与几何（全部现读，见文件头注释） */
class GlassBubbleSource(
    /** 前台页签内容被记录进的那一层 */
    val layer: () -> GraphicsLayer?,
    /** 源内容节点在根坐标里的位置 */
    val sourceOrigin: () -> Offset,
    /** 气泡本体在根坐标里的位置 */
    val bubbleOrigin: () -> Offset,
    /** 按压辉光强度 0..1 */
    val glow: () -> Float,
    /** 触点在气泡内（气泡局部坐标）的位置 */
    val glowInBubble: () -> Offset,
    /** 气泡当前被图层缩放的比例（拖动抬起 1.22、行进 1.045、拉伸…） */
    val scale: () -> Offset = { Offset(1f, 1f) },
    /** 高光方向：默认光从左上打来，与底栏 1px 高光环同一套 */
    val lightDir: Offset = Offset(-0.6f, -1f),
)

/**
 * 液态玻璃气泡本体（AGSL）。**只给「有独立取样层、且画在内容之后」的件用**——
 * 目前是底栏选中气泡（`McLiquidTabBar`）。顶栏那些画在页面里的胶囊/圆钮走
 * [glassSurface]（Haze 真背景模糊）：它们在内容层内部绘制，采同一张正在录制的纹理
 * 会读到空内容（试过：整块发黑）。
 */
/**
 * 画在**页面内容层内部**的玻璃件（筛选胶囊、任务卡上的操作键、hero 上的动作胶囊）：
 * 走与底栏气泡同一套 AGSL 折射材质。
 *
 * 依赖 [TabGlassLayerHolder] 的**双缓冲**：内容每帧录到「背面」那张，这里读「正面」那张
 * （上一帧的完整内容），所以不会在录制进行中去读同一张纹理——那正是这套材质
 * 一开始在顶栏胶囊上「整块发黑」的原因。
 */
@Composable
fun Modifier.glassSurfaceLens(): Modifier {
    val holder = LocalTabGlassLayer.current ?: return this
    if (Build.VERSION.SDK_INT < 33) return this
    val origin = remember { mutableStateOf(Offset.Zero) }
    val source = remember(holder) {
        GlassBubbleSource(
            layer = { holder.layer },
            sourceOrigin = { holder.origin },
            bubbleOrigin = { origin.value },
            glow = { 0f },
            glowInBubble = { Offset.Zero },
        )
    }
    return this
        .onGloballyPositioned { origin.value = it.positionInRoot() }
        .glassBubble(source, contentOnTop = true)
}

@Composable
fun Modifier.glassBubble(
    source: GlassBubbleSource,
    /**
     * 玻璃画完后是否继续画节点自身内容。
     * 顶栏胶囊/圆钮的图标是**子节点**，必须画在玻璃上（true）；
     * 底栏选中气泡没有子节点、只有一层回退填充（false，避免那层淡白盖在玻璃上）。
     */
    contentOnTop: Boolean = true,
): Modifier {
    if (Build.VERSION.SDK_INT < 33) return this
    val scratch = rememberGraphicsLayer()
    val shader = remember(source.lightDir) {
        RuntimeShader(AGSL_BUBBLE).apply {
            setFloatUniform("light", source.lightDir.x, source.lightDir.y)
        }
    }
    return this.drawWithContent {
        val layer = source.layer()
        if (layer == null) {
            drawContent()
            return@drawWithContent
        }
        val w = size.width
        val h = size.height
        // ① AGSL：位移折射 + 色散 + 菲涅尔 + 高光 + 按压辉光（uniform 与 effect 先就位）
        shader.setFloatUniform("size", w, h)
        val s = source.scale()
        shader.setFloatUniform("bscale", s.x, s.y)
        shader.setFloatUniform("glow", source.glow())
        val g = source.glowInBubble()
        shader.setFloatUniform("glowCenter", g.x, g.y)
        // **effect 必须在 record 之前设**：设在 record 之后会把刚录好的内容清掉，
        // shader 的 content 就成了空纹理——气泡只剩下「膜 + 边光」，看着像一块灰玻璃，
        // 顶栏胶囊更是整块发黑（2026-10-13 定位到，诊断构建不挂 effect 时内容与对齐都正常）。
        // 另外每帧现建 effect：record() 会清图层的 renderEffect，缓存复用会被 Compose 的
        // 值 diff 跳过（同一个实例再设一次不作数）。
        scratch.renderEffect = RenderEffect.createRuntimeShaderEffect(shader, "content").asComposeRenderEffect()
        // ② 只把「气泡底下那块画面」录进一个气泡大小的小层（源画面摆正：源根坐标 − 气泡根坐标）
        val delta = source.sourceOrigin() - source.bubbleOrigin()
        scratch.record(this, layoutDirection, IntSize(w.roundToInt(), h.roundToInt())) {
            clipRect(0f, 0f, w, h) {
                translate(delta.x, delta.y) { drawLayer(layer) }
            }
        }
        drawLayer(scratch)
        if (contentOnTop) drawContent()
    }
}

/**
 * AGSL：凸透镜折射 + 边缘色散 + 菲涅尔边缘光 + 定向高光。
 *
 * 几何：胶囊 SDF（内部为负），`edge` = 只在边界向内 `RIM` 一圈里非零的权重。
 * 折射：**只有这一圈**把取样点朝中心收（边缘强弯），内部原样不位移——苹果说的 lensing
 * 就是「边上一圈被玻璃压弯」；整块都位移的话画面会整体偏移而不是放大（踩过）。
 * 色散：R/B 通道沿法线错开 `DISP*edge²`，比折射带更贴在边上；
 * 高光：菲涅尔边光 + 与 light 点积的镜面项（两项都乘 edge，否则中心会糊一层白）；
 * 按压辉光按到触点的距离高斯衰减。
 * 输出前先按 s.a 去预乘（内容层通常不透明，去预乘对结果是恒等，防的是半透明内容）。
 */
private const val AGSL_BUBBLE = """
uniform shader content;
uniform float2 size;
uniform float2 bscale;
uniform float2 light;
uniform float glow;
uniform float2 glowCenter;

const float RIM = 10.0;   // 边缘折射带宽度（px）
const float BEND = 7.0;   // 边缘最大内收量（px）＝透镜弯曲强度
const float DISP = 1.0;   // 色散错位（px，只在最外圈）

half4 main(float2 p) {
    float2 c = size * 0.5;
    // 气泡被图层缩放时（拖动抬起），层里的像素 p 最终落在屏上 u；几何与取样都按屏上算，
    // 而**形状中心始终是 c**——图层自己就是绕中心缩放的，形状再按 sz/2 取中心会二次偏移
    // （上一版把中心写成 sz*0.5：气泡被推到栏身下方约 20px，上半截压回栏里，看着又小又扁）
    float2 u = c + (p - c) * bscale;
    float2 sz = size * bscale;
    float2 hf = sz * 0.5;
    float r = min(hf.x, hf.y);
    float2 q = abs(u - c) - (hf - float2(r, r));
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    float inside = clamp(0.5 - d, 0.0, 1.0);

    // 边缘权重：边界处 1、向内 RIM 衰减到 0（smoothstep 手写，避免反向 edge 的移植差异）
    float e = 1.0 - clamp(max(-d, 0.0) / RIM, 0.0, 1.0);
    float edge = e * e * (3.0 - 2.0 * e);

    float2 n = normalize(u - c + float2(0.0001, 0.0));

    // 折射：边缘圈内收取样（局部放大）；色散 R/B 沿法线错开，只出现在最外圈
    float2 uv = u - n * (edge * BEND);
    float2 dd = n * (DISP * edge * edge);
    // 4 点平均 = 一层假模糊：栏身是 14dp 模糊，气泡若拿全清晰画面会比栏身「更锐」而露馅
    half4 s0 = content.eval(uv + float2(1.3, 1.3) + dd);
    half4 s1 = content.eval(uv + float2(-1.3, 1.3));
    half4 s2 = content.eval(uv + float2(1.3, -1.3));
    half4 s3 = content.eval(uv + float2(-1.3, -1.3) - dd);
    half4 sm = (s0 + s1 + s2 + s3) * 0.25;
    float3 col = float3(sm.r, sm.g, sm.b) / max(sm.a, 0.001);

    // 与栏身同一层玻璃（GlassCapsule = 0x663E3E42，40% 灰膜）+ 选中提亮一档。
    // 提亮口径照网页/相册的选中药丸：比栏身**略亮**（浅色页上约 +16 灰阶），
    // 不是磨砂白——亮度仍由底下画面主导
    col = mix(col, float3(0.243, 0.243, 0.259), 0.40);
    col = col * 1.06 + float3(0.075);
    col += float3(pow(edge, 2.2) * 0.18);                                       // 菲涅尔边光
    col += float3(1.0) * (pow(max(dot(n, normalize(light)), 0.0), 10.0) * 0.25 * edge);  // 定向高光

    float2 gc = c + (glowCenter - c) * bscale;
    float gd = distance(u, gc) / 46.0;
    col += float3(1.0) * (glow * exp(-gd * gd) * 0.22);

    half a = half(inside);
    return half4(half3(min(col, 1.6)) * a, a);
}
"""

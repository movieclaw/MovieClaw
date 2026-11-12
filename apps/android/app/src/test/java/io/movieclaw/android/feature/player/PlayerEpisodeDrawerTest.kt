package io.movieclaw.android.feature.player

import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import androidx.compose.animation.core.FloatSpringSpec
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.compose.ui.util.lerp
import io.movieclaw.android.core.designsystem.McType
import io.movieclaw.android.core.designsystem.MovieClawTheme
import io.movieclaw.core.model.generated.EpisodeView
import io.movieclaw.core.playback.EpisodePickerText
import kotlinx.coroutines.awaitCancellation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import kotlin.math.abs

/**
 * 播放器选集（同 iPhone 横屏的选集抽屉）：画面让位的布局、正在放的那一集单独成卡、点一集就换、换季、缺集、失败重试。
 * 截图存到 app/build/ui-previews（真实 Compose 绘制），逐项对照 iPhone 的效果。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = "w891dp-h411dp-land-xxhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class PlayerEpisodeDrawerTest {
    @get:Rule val compose = createComposeRule()

    private val names = listOf("有关地狱的好消息", "半环", "永恒", "你的身份", "残暴不仁的光学与设计部", "捉迷藏", "叛逆的爵士乐", "晚饭吃什么？", "我们的身份")

    private fun season1() = names.mapIndexed { index, name ->
        val number = index + 1L
        EpisodeView(
            episodeNumber = number,
            name = name,
            overview = if (number == 3L) "马克带领团队去实地考察，这期间赫莉仍继续反抗。" else "简介 $number",
            owned = number <= 6,
            played = number == 1L,
            positionMs = if (number == 2L) 41_000 else 0,
            progressPercent = if (number == 2L) 12 else null,
        )
    }

    // ── 让位布局（同 iPhone EpisodeStageLayout 横屏）──

    @Test fun `stage puts the drawer on the right and keeps the video aspect on the left`() {
        val stage = EpisodeStageLayout.resolve(891f, 411f, 0f, 0f, 16f / 9f)
        assertEquals(325f, stage.drawer.width)
        assertEquals(891f - 8f, stage.drawer.right)
        assertEquals(8f, stage.drawer.y)
        assertEquals(411f - 16f, stage.drawer.height)
        // 画面从左缘 + 16 起，右边离面板 16，保持 16:9，不压面板
        assertEquals(16f, stage.video.x, 0.01f)
        assertTrue(abs(stage.video.right - (stage.drawer.x - 16f)) < 0.01f)
        assertEquals(16f / 9f, stage.video.width / stage.video.height, 0.001f)
        // 集名简介在画面正下方、同宽、不出屏幕
        val caption = assertNotNullAndGet(stage.caption)
        assertEquals(stage.video.x, caption.x)
        assertEquals(stage.video.width, caption.width)
        assertEquals(stage.video.bottom + 12f, caption.y, 0.01f)
        assertTrue(caption.bottom <= 411f)
    }

    @Test fun `stage clears a cutout on either side and drops the caption on a short window`() {
        val stage = EpisodeStageLayout.resolve(891f, 411f, 32f, 32f, 2.39f)
        assertEquals(891f - 32f, stage.drawer.right)
        assertEquals(48f, stage.video.x, 0.01f)
        assertEquals(2.39f, stage.video.width / stage.video.height, 0.001f)
        // 分屏小窗：放不下集名简介就全给画面
        val short = EpisodeStageLayout.resolve(700f, 220f, 0f, 0f, 16f / 9f)
        assertNull(short.caption)
        assertTrue(short.video.bottom <= 220f)
        assertTrue(short.video.right <= short.drawer.x)
    }

    @Test fun `stage spring overshoot is clamped to legal visual progress`() {
        val spec = FloatSpringSpec(dampingRatio = 0.86f, stiffness = Spring.StiffnessMediumLow)
        val opening = (0L..1_500L).map { millis ->
            spec.getValueFromNanos(millis * 1_000_000L, initialValue = 0f, targetValue = 1f, initialVelocity = 0f)
        }
        val closing = (0L..1_500L).map { millis ->
            spec.getValueFromNanos(millis * 1_000_000L, initialValue = 1f, targetValue = 0f, initialVelocity = 0f)
        }

        assertTrue(opening.any { it > 1f })
        assertTrue(closing.any { it < 0f })
        assertTrue((opening + closing).all { EpisodeStageLayout.visualProgress(it) in 0f..1f })
        assertEquals(0f, EpisodeStageLayout.visualProgress(-0.031728577f))
        assertEquals(1f, EpisodeStageLayout.visualProgress(1.0317286f))
    }

    @Test fun `stage exit animation renders safely through spring overshoot`() {
        compose.mainClock.autoAdvance = false
        var open by mutableStateOf(true)
        compose.setContent {
            val animatedProgress by animateFloatAsState(
                if (open) 1f else 0f,
                spring(dampingRatio = 0.86f, stiffness = Spring.StiffnessMediumLow),
                label = "test-episodes-stage",
            )
            val progress = EpisodeStageLayout.visualProgress(animatedProgress)
            Box(
                Modifier
                    .offset(lerp(0f, 16f, progress).dp, lerp(0f, 20f, progress).dp)
                    .size(lerp(891f, 534f, progress).dp, lerp(411f, 300f, progress).dp)
                    .alpha(progress)
                    .clip(RoundedCornerShape((EpisodeStageLayout.VIDEO_CORNER * progress).dp))
                    .background(Color.Black)
                    .testTag("animated-stage-video"),
            )
        }

        compose.runOnIdle { open = false }
        repeat(100) { compose.mainClock.advanceTimeByFrame() }
        compose.onNodeWithTag("animated-stage-video").assertExists()
    }

    @Test fun `episode wording matches the other clients`() {
        assertEquals("已看完" to true, EpisodePickerText.meta(EpisodeView(1, owned = true, played = true)))
        assertEquals("缺集" to false, EpisodePickerText.meta(EpisodeView(1, owned = false, played = true)))
        assertEquals("看到 12:30" to false, EpisodePickerText.meta(EpisodeView(1, owned = true, positionMs = 750_000, progressPercent = 40)))
        assertNull(EpisodePickerText.meta(EpisodeView(1, owned = true)))
        assertEquals(0.4f, EpisodePickerText.partial(EpisodeView(1, owned = true, progressPercent = 40))!!, 0.001f)
        assertNull(EpisodePickerText.partial(EpisodeView(1, owned = true, played = true, progressPercent = 40)))
        assertEquals(35, EpisodePickerText.minutesLeft(18 * 60_000 + 42_000, 53 * 60_000))
        assertEquals(1, EpisodePickerText.minutesLeft(53 * 60_000, 53 * 60_000))
        assertEquals("第 3 集", EpisodePickerText.caption(3, ""))
        assertEquals("第 3 集 · 永恒", EpisodePickerText.caption(3, "永恒"))
    }

    // ── 面板 ──

    @Test fun `opens on the playing episode and a tap switches to another one`() {
        val picked = mutableListOf<Triple<Long, Long, List<EpisodeView>?>>()
        var closed = 0
        var refreshed = 0
        showStage(onPick = { s, e, l -> picked += Triple(s, e, l) }, onClose = { closed++ }, onRefresh = { refreshed++ })
        // 正在放的那一集单独成卡：「正在播放」、实时进度、还剩几分钟
        compose.onNodeWithTag("episode-current").assertExists()
        compose.onNodeWithText("正在播放").assertExists()
        compose.onNodeWithText("剩 34 分钟").assertExists()
        // 状态：看完的写「已看完」、看了一半的写看到哪、缺集置灰点不动
        compose.onNodeWithText("已看完").assertExists()
        compose.onNodeWithText("看到 0:41").assertExists()
        assertEquals(1, refreshed)
        savePreview("player-episodes-stage")
        // 点正在放的那一集只是收起
        compose.onNodeWithTag("episode-current").performClick()
        assertEquals(1, closed)
        compose.onNodeWithTag("episode-4").performClick()
        assertEquals(listOf(Triple(1L, 4L, null)), picked)
    }

    @Test fun `missing episodes cannot be picked`() {
        val picked = mutableListOf<Long>()
        showStage(onPick = { _, e, _ -> picked += e })
        compose.onNode(hasScrollAction()).performScrollToNode(hasTestTag("episode-7"))
        compose.onNodeWithTag("episode-7").assertIsNotEnabled()
        compose.onNodeWithTag("episode-7").performClick()
        assertTrue(picked.isEmpty())
    }

    @Test fun `season menu switches the list and a pick carries that season`() {
        val picked = mutableListOf<Triple<Long, Long, List<EpisodeView>?>>()
        val second = (1L..10L).map { EpisodeView(episodeNumber = it, name = "第二季 $it", owned = it <= 3) }
        showStage(seasons = listOf(1L, 2L), loadSeason = { second }, onPick = { s, e, l -> picked += Triple(s, e, l) })
        compose.onNodeWithTag("episodes-season").performClick()
        savePreview("player-episodes-season-menu")
        compose.onNodeWithText("第 2 季").performClick()
        compose.onNodeWithText("第二季 1").assertExists()
        // 看别的季时没有「正在播放」那一张
        compose.onNodeWithText("正在播放").assertDoesNotExist()
        savePreview("player-episodes-season2")
        compose.onNodeWithTag("episode-2").performClick()
        assertEquals(listOf(Triple(2L, 2L, second)), picked)
    }

    @Test fun `switching seasons cancels an unfinished load`() {
        val picked = mutableListOf<Pair<Long, Long>>()
        showStage(
            seasons = listOf(1L, 2L, 3L),
            loadSeason = { season -> if (season == 2L) awaitCancellation(); listOf(EpisodeView(1, name = "第三季开篇", owned = true)) },
            onPick = { s, e, _ -> picked += s to e },
        )
        compose.onNodeWithTag("episodes-season").performClick()
        compose.onNodeWithText("第 2 季").performClick()
        compose.onNodeWithTag("episodes-season").performClick()
        compose.onNodeWithText("第 3 季").performClick()
        compose.onNodeWithText("第三季开篇").performClick()
        assertEquals(listOf(3L to 1L), picked)
    }

    @Test fun `a failed season load can be retried without closing`() {
        var attempts = 0
        showStage(seasons = listOf(1L, 2L), loadSeason = { if (++attempts == 1) null else listOf(EpisodeView(1, name = "重试后", owned = true)) })
        compose.onNodeWithTag("episodes-season").performClick()
        compose.onNodeWithText("第 2 季").performClick()
        compose.onNodeWithText("重试").performClick()
        compose.onNodeWithText("重试后").assertExists()
        assertEquals(2, attempts)
    }

    @Test fun `bottom bar shows an episodes capsule with a next button that greys out without a next episode`() {
        var opened = 0
        var next = 0
        compose.setContent {
            MovieClawTheme {
                Box(Modifier.fillMaxSize().background(Color(0xFF2B3A4A))) {
                    Column(Modifier.align(Alignment.BottomCenter)) {
                        PlayerBottomControls(series = true, hasNext = false, onNext = { next++ }, onEpisodes = { opened++ }, tracks = {})
                    }
                }
            }
        }
        compose.onNodeWithText("选集").assertExists()
        compose.onNodeWithTag("player-episodes-button").performClick()
        assertEquals(1, opened)
        compose.onNodeWithTag("player-next-episode").assertIsNotEnabled()
        assertEquals(0, next)
        savePreview("player-episodes-button")
    }

    /**
     * 摆出播放页打开选集时的样子：画面（一块示意色，引擎画面在测试里画不出来）按让位布局缩到左边、下面写集名简介，
     * 右边是真实的选集面板；四周的氛围色用渐变代替剧照
     */
    private fun showStage(
        seasons: List<Long> = listOf(1L),
        loadSeason: suspend (Long) -> List<EpisodeView>? = { null },
        onPick: (Long, Long, List<EpisodeView>?) -> Unit = { _, _, _ -> },
        onClose: () -> Unit = {},
        onRefresh: () -> Unit = {},
    ) {
        val episodes = season1()
        compose.setContent {
            MovieClawTheme {
                BoxWithConstraints(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF3A4651), Color(0xFF14181D))))) {
                    val stage = EpisodeStageLayout.resolve(maxWidth.value, maxHeight.value, 0f, 0f, 16f / 9f)
                    Box(
                        Modifier.offset(stage.video.x.dp, stage.video.y.dp).size(stage.video.width.dp, stage.video.height.dp)
                            .background(Brush.linearGradient(listOf(Color(0xFF5B7A99), Color(0xFF243447)))),
                        contentAlignment = Alignment.Center,
                    ) { Text("画面", color = Color.White.copy(alpha = 0.5f)) }
                    stage.caption?.let { caption ->
                        Column(Modifier.offset(caption.x.dp, caption.y.dp).width(caption.width.dp)) {
                            Text(EpisodePickerText.caption(3, "永恒"), style = McType.headline, color = Color.White)
                            Text(episodes[2].overview.orEmpty(), style = McType.caption, color = Color.White.copy(alpha = 0.66f), maxLines = 2)
                        }
                    }
                    PlayerEpisodeDrawer(
                        title = "人生切割术",
                        currentSeason = 1,
                        currentEpisode = 3,
                        playingEpisodes = episodes,
                        seasons = seasons,
                        loadSeason = loadSeason,
                        onRefresh = onRefresh,
                        positionMs = 18 * 60_000L + 42_000,
                        durationMs = 52 * 60_000L,
                        paused = true,
                        imageOrigin = null,
                        guest = false,
                        onPick = onPick,
                        onClose = onClose,
                        modifier = Modifier.offset(stage.drawer.x.dp, stage.drawer.y.dp).size(stage.drawer.width.dp, stage.drawer.height.dp),
                    )
                }
            }
        }
        compose.mainClock.advanceTimeBy(1_500)
        compose.waitForIdle()
    }

    private fun <T : Any> assertNotNullAndGet(value: T?): T {
        assertNotNull(value)
        return value!!
    }

    /** 整个窗口（含下拉菜单这类弹出窗）画成 PNG，存到 app/build/ui-previews/<name>.png */
    private fun savePreview(name: String) {
        compose.waitForIdle()
        val globalClass = Class.forName("android.view.WindowManagerGlobal")
        val global = globalClass.getMethod("getInstance").invoke(null)
        @Suppress("UNCHECKED_CAST")
        val views = globalClass.getDeclaredField("mViews").apply { isAccessible = true }.get(global) as List<View>
        val root = views.first()
        val bitmap = Bitmap.createBitmap(root.width, root.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        views.forEach { view ->
            val location = IntArray(2).also(view::getLocationOnScreen)
            canvas.save()
            canvas.translate(location[0].toFloat(), location[1].toFloat())
            view.draw(canvas)
            canvas.restore()
        }
        File("build/ui-previews").mkdirs()
        File("build/ui-previews/$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        assertFalse(bitmap.isRecycled)
    }
}

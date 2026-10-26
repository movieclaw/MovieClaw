package io.movieclaw.androidtv.ui.player

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import io.movieclaw.androidtv.ui.TV_QUALIFIERS
import io.movieclaw.androidtv.ui.savePreview
import io.movieclaw.androidtv.ui.setTvContent
import io.movieclaw.androidtv.ui.theme.pt
import io.movieclaw.core.playback.DiagLine
import io.movieclaw.core.playback.DiagSection
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** 电视的播放诊断卡片：内容来自引擎的 DiagnosticsReport，这里看排版（电视上字要比手机大一号） */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [34], qualifiers = TV_QUALIFIERS)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class DiagnosticsPanelTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun rendersSectionsLikeTheiPhonePanel() {
        val sections = listOf(
            DiagSection("引擎", listOf(DiagLine("ExoPlayer（Media3）", DiagLine.Kind.Source), DiagLine("通路 服务端 HLS 流", DiagLine.Kind.Action), DiagLine("视频 c2.mtk.avc.decoder（硬解）", DiagLine.Kind.Action))),
            DiagSection("流媒体", listOf(DiagLine("MKV · 15 Mbps", DiagLine.Kind.Source), DiagLine("HLS · fMP4（硬件转码）", DiagLine.Kind.Action))),
            DiagSection("执行", listOf(DiagLine("本地硬件转码", DiagLine.Kind.Source), DiagLine("位置：NAS", DiagLine.Kind.Action), DiagLine("后端：vaapi · h264_vaapi", DiagLine.Kind.Action))),
            DiagSection("视频", listOf(DiagLine("2160p · HEVC · 30 fps", DiagLine.Kind.Source), DiagLine("转码（H264 1080p · vaapi）", DiagLine.Kind.Action), DiagLine("掉帧 0 / 2052"))),
            DiagSection("传输", listOf(DiagLine("实时 8.0 Mbps · 带宽 42 Mbps · 缓冲 12.3 秒 · 播放头 228.0 秒"), DiagLine("会话 01M51YDNBBZ4KVD9RG7HK1PHCE", DiagLine.Kind.Muted))),
            DiagSection(null, listOf(DiagLine("2160p 超出设备可解码的分辨率，已降分辨率；音轨 AAC 可直通", DiagLine.Kind.Muted))),
        )
        rule.setTvContent(emptyMap()) {
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF34506B), Color(0xFF1B2230))))) {
                TvDiagnosticsPanel(sections, Modifier.align(Alignment.TopStart).padding(start = 80.pt, top = 60.pt))
            }
        }
        rule.waitForIdle()
        rule.onNodeWithText("播放诊断").assertIsDisplayed()
        rule.onNodeWithText("本地硬件转码").assertIsDisplayed()
        rule.savePreview("player-diagnostics")
    }
}

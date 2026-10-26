package io.movieclaw.androidtv.ui.theme

import android.app.Application
import androidx.activity.ComponentActivity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.text.font.FontWeight
import io.movieclaw.core.model.generated.EpisodeView
import io.movieclaw.androidtv.ui.components.Text
import io.movieclaw.androidtv.ui.components.tvWeight
import io.movieclaw.androidtv.ui.detail.EpisodeCard
import io.movieclaw.androidtv.ui.home.GenreCard
import io.movieclaw.androidtv.ui.savePreview
import io.movieclaw.androidtv.ui.setTvContent
import io.movieclaw.androidtv.ui.stage.StageInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * 字体样张：大图区片名 / 信息、字号阶梯、分集卡、类型卡。用 Android 9（电视盒子最常见的系统，系统中文字体只有常规一个字重）、
 * 系统语言繁体中文（不少盒子出厂如此）渲染，存 build/ui-previews/font-specimen.png 对比字形与字重。
 */
@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class, sdk = [28], qualifiers = "zh-rTW-w960dp-h540dp-land-television-xhdpi")
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class FontSpecimenTest {
    @get:Rule val rule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun weightsCollapseToRegularAndBold() {
        assertEquals(FontWeight.Normal, tvWeight(FontWeight.Medium))
        assertEquals(FontWeight.Normal, tvWeight(FontWeight.Normal))
        assertEquals(FontWeight.Bold, tvWeight(FontWeight.SemiBold))
        assertEquals(FontWeight.Bold, tvWeight(FontWeight.Bold))
        assertNull(tvWeight(null))
    }

    @Test
    fun specimen() {
        rule.setTvContent(emptyMap()) {
            Column(Modifier.fillMaxSize().background(McColors.Page).padding(80.pt), verticalArrangement = Arrangement.spacedBy(28.pt)) {
                StageInfo(
                    title = "吞噬星空",
                    logo = null,
                    headline = "第 1 季 第 60 集 · 骨角之战",
                    meta = "2020 · 动画 · 科幻",
                    overview = "罗峰在直播中迎战强敌，决定写下新的篇章，遍寻宇宙中的真相。",
                )
                Row(horizontalArrangement = Arrangement.spacedBy(40.pt)) {
                    Column(Modifier.width(820.pt), verticalArrangement = Arrangement.spacedBy(10.pt)) {
                        Text("继续观看 Up Next 2024", style = McType.Headline)
                        Text("我的媒体库 · 收藏 12 部", style = McType.size(32, FontWeight.SemiBold))
                        Text("全部分集 1–50 · 51–100", style = McType.size(28, FontWeight.SemiBold))
                        Text("播放 第 1 季第 60 集", style = McType.Body.copy(fontWeight = FontWeight.Medium))
                        Text("剩 18 分钟 · 已看完", style = McType.Caption)
                    }
                    EpisodeCard(EpisodeView(episodeNumber = 60, name = "骨角之战", overview = "直播迎战，遍寻真相。", owned = true), 24, {}, {})
                    GenreCard("科幻", 12, "tv", null, {})
                }
            }
        }
        rule.waitForIdle()
        rule.savePreview("font-specimen")
    }
}

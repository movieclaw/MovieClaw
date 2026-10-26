package io.movieclaw.android.core.designsystem

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [CardMetrics] 的取值全部来自 `docs/design/ipad.md` §4.1 那张表。
 *
 * 这些断言的用处：**手机版式零变化**完全靠「Phone 的每个值都等于改动前的 `McMetrics`」
 * 这一条，所以把它钉死；宽窗口那套钉死表格里的数字，免得又出现「自己算出来 177、
 * 表格写 168」这种对不上的情况。
 */
class CardMetricsTest {

    @Test
    fun `phone 每个值都与改动前的 McMetrics 一致`() {
        val phone = CardMetrics.Phone
        // 改动前 Theme.kt：pagePadding / rowSpacing / rowCardWidth
        assertEquals(16.dp, phone.pagePadding)
        assertEquals(12.dp, phone.rowSpacing)
        assertEquals(126.dp, phone.posterWidth)
        // 改动前各处写死的网格最小列宽与若干卡宽
        assertEquals(140.dp, phone.wallMinColumn)
        assertEquals(200.dp, phone.wideThumbWidth)
        assertEquals(230.dp, phone.libraryCardWidth)
        assertEquals(264.dp, phone.newInWidth)
        assertEquals(104.dp, phone.castWidth)
        assertNull(phone.readableWidth)
        assertTrue(!phone.isWide)
    }

    @Test
    fun `wide 每个值都等于 ipad md 的表`() {
        val wide = CardMetrics.Wide
        assertEquals(32.dp, wide.pagePadding)          // edge 32（同 Mac）
        assertEquals(18.dp, wide.rowSpacing)           // 横滑行间距 18
        assertEquals(168.dp, wide.posterWidth)         // 首页/相似/系列/发现/订阅 168
        assertEquals(296.dp, wide.wideThumbWidth)      // 接下来继续、分集 296
        assertEquals(296.dp, wide.libraryCardWidth)    // 我的媒体库库卡 296
        assertEquals(296.dp, wide.newInWidth)          // 订阅「刚刚入库」296
        assertEquals(128.dp, wide.castWidth)           // 演职员 128
        assertEquals(150.dp, wide.wallMinColumn)       // 海报墙最小列宽 150
        assertEquals(720.dp, wide.readableWidth)       // 长文本限宽 720
        assertTrue(wide.isWide)
    }

    @Test
    fun `断点两侧各取一套`() {
        assertEquals(CardMetrics.Phone, CardMetrics.forWindow(839.dp))
        assertEquals(CardMetrics.Wide, CardMetrics.forWindow(840.dp))
        // 本平板实测：竖屏 640dp、横屏 1024dp
        assertEquals(CardMetrics.Phone, CardMetrics.forWindow(640.dp))
        assertEquals(CardMetrics.Wide, CardMetrics.forWindow(1024.dp))
    }

    @Test
    fun `宽窗口的每种卡都比手机宽`() {
        val phone = CardMetrics.Phone
        val wide = CardMetrics.Wide
        assertTrue(wide.posterWidth > phone.posterWidth)
        assertTrue(wide.wideThumbWidth > phone.wideThumbWidth)
        assertTrue(wide.libraryCardWidth > phone.libraryCardWidth)
        assertTrue(wide.newInWidth > phone.newInWidth)
        assertTrue(wide.castWidth > phone.castWidth)
    }

    @Test
    fun `手机不会有阅读宽上限`() {
        // 手机若也限宽，列表页会被缩到 720 里——这正是「手机版式不变」最容易被破坏的地方
        assertNull(CardMetrics.Phone.readableWidth)
        assertEquals(720.dp, CardMetrics.Wide.readableWidth)
    }

    @Test
    fun `骨架屏张数`() {
        assertEquals(4, CardMetrics.Phone.skeletonCount)
        assertEquals(6, CardMetrics.Wide.skeletonCount)
    }

    // ── fitted(contentWidth:)：照 iOS `CardMetrics.fitted` ──
    // 宽窗口的海报宽是**按内容区算出来的**，不是固定 168；
    // 手机、以及「还没量到宽」时原样返回。

    @Test
    fun `宽窗口按内容区把海报排成整列`() {
        // 本平板横屏：窗口 1024dp、侧边栏 248dp → 内容区 776dp
        // rowWidth = 776 - 32*2 = 712；列数 = round((712+18)/(168+18)) = 4；
        // 列宽 = floor((712 - 3*18)/4) = floor(164.5) = 164
        val fitted = CardMetrics.Wide.fitted(776.dp)
        assertEquals(164.dp, fitted.posterWidth)
        assertEquals(776.dp, fitted.contentWidth)
    }

    @Test
    fun `没量到内容区时不改海报宽`() {
        assertEquals(168.dp, CardMetrics.Wide.fitted(0.dp).posterWidth)
    }

    @Test
    fun `手机不做整列重排`() {
        assertEquals(126.dp, CardMetrics.Phone.fitted(776.dp).posterWidth)
    }

    @Test
    fun `补的三个字段照 iOS 取值`() {
        assertEquals(200.dp, CardMetrics.Phone.episodeWidth)
        assertEquals(296.dp, CardMetrics.Wide.episodeWidth)
        assertEquals(118.dp, CardMetrics.Phone.recentLogoWidth)
        assertEquals(140.dp, CardMetrics.Wide.recentLogoWidth)
        // 类型剧照卡两套都是 196（不随窗口放大）
        assertEquals(196.dp, CardMetrics.Phone.genreTileWidth)
        assertEquals(196.dp, CardMetrics.Wide.genreTileWidth)
    }
}

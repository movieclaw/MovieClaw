package io.movieclaw.androidtv.ui.stage

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * 大图区滑走时的整层透明度：详情页滑到下半截正好淡完（不留一点看不见的透明度让这层大图每帧重画），
 * 不足 2% 按 0（整层不画、慢推停）
 */
class StageFadeTest {
    @Test
    fun pinnedThenFadesOut() {
        assertEquals(1f, stageLayerAlpha(scrollPx = 300f, pinnedPx = 460f, fadePx = 700f), 0f)
        assertEquals(0.5f, stageLayerAlpha(scrollPx = 810f, pinnedPx = 460f, fadePx = 700f), 1e-4f)
        assertEquals(0f, stageLayerAlpha(scrollPx = 2000f, pinnedPx = 460f, fadePx = 700f), 0f)
    }

    @Test
    fun detailLowerHalfIsFullyFaded() {
        // 剧集详情：滑到下半截滚了 750 点（918 + 82 − 250），淡完的距离就是它
        assertEquals(0f, stageLayerAlpha(scrollPx = 750f, pinnedPx = 0f, fadePx = 750f), 0f)
        // 吸附动画停在差一两个像素的地方也算淡完
        assertEquals(0f, stageLayerAlpha(scrollPx = 738f, pinnedPx = 0f, fadePx = 750f), 0f)
        assertEquals(0.2f, stageLayerAlpha(scrollPx = 600f, pinnedPx = 0f, fadePx = 750f), 1e-4f)
    }
}

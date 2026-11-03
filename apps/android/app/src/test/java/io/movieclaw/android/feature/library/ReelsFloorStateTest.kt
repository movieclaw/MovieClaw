package io.movieclaw.android.feature.library

import io.movieclaw.android.feature.library.ReelsFloorState.Companion.ARM_BEYOND
import io.movieclaw.android.feature.library.ReelsFloorState.Companion.REFRESH_AT
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 首页「下拉二楼」的判定（同 iOS `ReelsFloorTests`）：刷新先触发、线在刷新之后；只认拖着拉过线后松手；
 * 推回线内松手只刷新；上次进二楼留下的过线不带到下一次。距离按 dp。
 */
class ReelsFloorStateTest {
    /** 把下拉量拉到 [pull]（反解橡皮筋，按手指距离拖） */
    private fun ReelsFloorState.pullTo(pull: Float) {
        var lo = 0f
        var hi = 5000f
        repeat(60) {
            val mid = (lo + hi) / 2
            if (ReelsFloorState.rubber(mid) < pull) lo = mid else hi = mid
        }
        dragBy(hi - rawDrag)
    }

    @Test fun refreshFiresBeforeLine() {
        val floor = ReelsFloorState()
        floor.pullTo(REFRESH_AT - 1)
        assertNull("刷新点之前不触发", floor.refreshedAt)
        floor.pullTo(REFRESH_AT + 1)
        assertNotNull("拉到刷新点触发刷新", floor.refreshedAt)
        assertFalse("刚刷新还没过线", floor.armed)
        assertEquals(0f, floor.progress, 0.05f)
    }

    @Test fun releasePastLineEnters() {
        val floor = ReelsFloorState()
        floor.pullTo(REFRESH_AT + ARM_BEYOND + 10)
        assertTrue(floor.armed)
        assertEquals(1f, floor.reveal, 0.001f)
        assertTrue(floor.release())
    }

    @Test fun refreshDistanceOnlyRefreshes() {
        val floor = ReelsFloorState()
        floor.pullTo(REFRESH_AT + 15)
        assertTrue("胶片开始出来", floor.reveal > 0f)
        assertFalse(floor.release())
    }

    @Test fun pushingBackBelowLineCancels() {
        val floor = ReelsFloorState()
        floor.pullTo(REFRESH_AT + ARM_BEYOND + 20)
        floor.pullTo(REFRESH_AT + ARM_BEYOND - 20)
        assertFalse(floor.armed)
        assertFalse(floor.release())
    }

    @Test fun nextDragStartsDisarmed() {
        val floor = ReelsFloorState()
        floor.pullTo(REFRESH_AT + ARM_BEYOND + 10)
        assertTrue(floor.release())
        floor.settle(0f)
        // 下一次拖动：往上滑列表时一点越界都没有，第一下就要清掉上次的过线和刷新点
        floor.dragBy(0f)
        assertFalse(floor.armed)
        assertNull(floor.refreshedAt)
        assertFalse(floor.release())
    }

    @Test fun resetClearsEverything() {
        val floor = ReelsFloorState()
        floor.pullTo(REFRESH_AT + ARM_BEYOND + 10)
        floor.release()
        floor.reset()
        assertEquals(0f, floor.pull, 0f)
        assertFalse(floor.armed)
        assertEquals(0f, floor.reveal, 0f)
    }

    @Test fun rubberBandFollowsFingerThenStiffens() {
        assertEquals(30f, ReelsFloorState.rubber(30f), 0f)
        val near = ReelsFloorState.rubber(200f) - ReelsFloorState.rubber(150f)
        val far = ReelsFloorState.rubber(450f) - ReelsFloorState.rubber(400f)
        assertTrue("越拉越沉", far < near)
    }
}

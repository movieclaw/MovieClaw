package io.movieclaw.androidtv.ui.stage

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 首页托字黑的画法：Android 9 的真机（极米 H3S）上合成着色器画成一片白，Android 9 及以下离屏 + DstIn，Android 10 起一遍画完 */
class StageScrimTest {
    @Test
    fun onePassFromAndroid10() {
        assertFalse(scrimInOnePass(23))
        assertFalse(scrimInOnePass(28))
        assertTrue(scrimInOnePass(29))
        assertTrue(scrimInOnePass(34))
    }
}

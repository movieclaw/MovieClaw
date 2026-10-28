package io.movieclaw.android.core.network

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 内外网切换后选路收尾（实机反馈：内外网自动切换后偶发卡在旧入口——媒体卡片没封面、
 * 实时通知一直未连接，冷启动才恢复）。
 */
class RouteSettleTest {
    private val home = "wifi|192.168.1.0/24"
    private val cell = "cell|10.20.30.0/24"
    private val lan = "http://192.168.1.10:3010"
    private val wan = "http://nas.example.com:3010"

    private fun sel(url: String, kind: String, fp: String, verified: Boolean = true) =
        ServerAddressBook.Selection(origin = lan, url = url, kind = kind, fingerprint = fp, verified = verified)

    @Test fun `出门后外网验过就切走，不再守着家里验过的内网`() {
        assertTrue(shouldSwitchTo(sel(lan, "lan", home), cell, wan, isLan = false))
    }

    @Test fun `同一个网络上已在内网，外网后到不降级`() {
        assertFalse(shouldSwitchTo(sel(lan, "lan", home), home, wan, isLan = false))
    }

    @Test fun `已在外网，内网后到就升级`() {
        assertTrue(shouldSwitchTo(sel(wan, "wan", home), home, lan, isLan = true))
    }

    @Test fun `一个都没验过时，别的网络上的内网入口不能留用，回登录地址且不记忆`() {
        val settle = settleRound(sel(lan, "lan", home), cell, prePicked = false, verified = emptyList())
        assertTrue(settle.fallbackToLogin)
        assertFalse(settle.remember)
    }

    @Test fun `外网回内网只探内网失败时，外网入口照旧保留，但不记到新网络名下`() {
        val settle = settleRound(sel(wan, "wan", cell), home, prePicked = false, verified = emptyList())
        assertFalse(settle.fallbackToLogin)
        assertFalse(settle.remember)
    }

    @Test fun `本轮在这个网络上验过的入口才记忆`() {
        val settle = settleRound(sel(wan, "wan", cell), cell, prePicked = false, verified = listOf(wan))
        assertFalse(settle.fallbackToLogin)
        assertTrue(settle.remember)
    }

    @Test fun `有预选但没验过：不回登录地址，也不记忆`() {
        val settle = settleRound(sel(wan, "wan", cell, verified = false), cell, prePicked = true, verified = emptyList())
        assertFalse(settle.fallbackToLogin)
        assertFalse(settle.remember)
    }
}

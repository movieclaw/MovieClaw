package io.movieclaw.android.core.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1089：开着系统 VPN（Shadowrocket 一类出国代理）被当成「经 VPN 回家」，先用连不上的内网地址；
 * 开关 VPN 也不算换网络、不重新选。
 */
class VpnRouteTest {
    private val lan = "http://192.168.1.10:3010"
    private val wanHttps = "https://nas.example.com"
    private val book = listOf(
        ServerAddressBook.Entry(lan, "lan", "auto"),
        ServerAddressBook.Entry(wanHttps, "wan", "manual"),
    )
    private val notInSubnet: (String) -> Boolean = { false }

    private fun plan(remembered: String? = null, cellular: Boolean, vpn: Boolean, inSubnet: (String) -> Boolean = notInSubnet) =
        planRoutes(book, loginUrl = lan, remembered = remembered, cellular = cellular, vpn = vpn, inSameSubnet = inSubnet)

    @Test fun `开着 VPN、登录地址是内网且不在网段：先用 https 外网，不先用内网`() {
        assertEquals(wanHttps, plan(cellular = true, vpn = true).prePick)
        assertEquals(wanHttps, plan(cellular = false, vpn = true).prePick)
    }

    @Test fun `开着 VPN 时地址簿里的内网候选照样参加竞速（探测通了才算经 VPN 回家）`() {
        // 登录地址是外网域名：内网候选只能来自地址簿
        val p = planRoutes(book, loginUrl = wanHttps, remembered = null, cellular = true, vpn = true, inSameSubnet = notInSubnet)
        assertEquals(listOf(lan), p.lan)
        assertEquals(wanHttps, p.prePick)
        val noVpn = planRoutes(book, loginUrl = wanHttps, remembered = null, cellular = true, vpn = false, inSameSubnet = notInSubnet)
        assertEquals(emptyList<String>(), noVpn.lan)
    }

    @Test fun `只剩蜂窝、没开 VPN：先用 https 外网`() {
        assertEquals(wanHttps, plan(cellular = true, vpn = false).prePick)
    }

    @Test fun `这个网络（含这条隧道）记过登录地址：VPN 回家照旧直接用`() {
        assertEquals(lan, plan(remembered = lan, cellular = true, vpn = true).prePick)
    }

    @Test fun `在家同网段：直接用内网登录地址`() {
        assertEquals(lan, plan(cellular = false, vpn = false, inSubnet = { it == lan }).prePick)
    }

    @Test fun `没开 VPN 时指纹与旧格式相同`() {
        assertEquals("wifi|192.168.1.0/24", NetSnapshot("wifi", "192.168.1.0/24", vpn = null, cellularOnly = false).fingerprint)
    }

    @Test fun `开关 VPN、换隧道都算换了网络`() {
        val off = NetSnapshot("cell", "10.20.30.0/24", vpn = null, cellularOnly = true)
        val proxy = off.copy(vpn = "172.19.0.0/24")
        val wireguard = off.copy(vpn = "10.8.0.0/24")
        val noIpv4Tunnel = off.copy(vpn = "nosubnet")
        assertNotEquals(off.fingerprint, proxy.fingerprint)
        assertNotEquals(proxy.fingerprint, wireguard.fingerprint)
        assertNotEquals(off.fingerprint, noIpv4Tunnel.fingerprint)
    }

    @Test fun `网络变了，手里是上个网络的内网入口：算过期`() {
        val sel = ServerAddressBook.Selection(lan, lan, "lan", fingerprint = "cell|10.20.30.0/24|vpn:10.8.0.0/24", verified = true)
        assertTrue(isStaleLan(sel, "cell|10.20.30.0/24"))
        assertFalse(isStaleLan(sel, sel.fingerprint))
        assertFalse(isStaleLan(sel.copy(url = wanHttps, kind = "wan"), "cell|10.20.30.0/24"))
    }
}

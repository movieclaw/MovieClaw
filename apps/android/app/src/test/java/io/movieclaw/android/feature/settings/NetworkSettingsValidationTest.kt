package io.movieclaw.android.feature.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 网络页的对齐口径（iOS `NetworkSettingsValidation` / `proxyTitle`）：文案与地址校验 */
class NetworkSettingsValidationTest {
    @Test fun proxyTitlesMatchIos() {
        assertEquals("不使用", proxyTitle("off"))
        assertEquals("环境变量", proxyTitle("env"))
        assertEquals("手动", proxyTitle("manual"))
        assertEquals("不使用", proxyTitle(null))
    }

    @Test fun proxyUrlAllowsSocksAndRejectsJunk() {
        assertTrue(validNetworkUrl("socks5://192.168.1.2:7891", proxy = true))
        assertTrue(validNetworkUrl("socks5h://host:1080", proxy = true))
        assertTrue(validNetworkUrl("http://127.0.0.1:7890", proxy = true))
        assertTrue(validNetworkUrl("", proxy = true)) // 手填留空由保存按钮的「有改动」把守
        assertFalse(validNetworkUrl("socks5://", proxy = true))
        assertFalse(validNetworkUrl("ftp://host", proxy = true))
        assertFalse(validNetworkUrl("http://ho st:1", proxy = true))
    }

    @Test fun mirrorUrlOnlyHttp() {
        assertTrue(validNetworkUrl("https://tmdb.example.com"))
        assertFalse(validNetworkUrl("socks5://tmdb.example.com"))
        assertFalse(validNetworkUrl("tmdb.example.com"))
    }

    @Test fun externalUrlAllowsEmptyAndOnlyHttp() {
        assertTrue(validExternalUrl(""))
        assertTrue(validExternalUrl("http://gaojianyu.fun:3010"))
        assertTrue(validExternalUrl("https://movie.example.com"))
        assertFalse(validExternalUrl("ftp://movie.example.com"))
        assertFalse(validExternalUrl("example.com:3000"))
        assertFalse(validExternalUrl("http://a b"))
    }
}

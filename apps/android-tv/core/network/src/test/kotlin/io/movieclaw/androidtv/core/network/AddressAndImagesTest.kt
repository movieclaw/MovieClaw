package io.movieclaw.androidtv.core.network

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AddressAndImagesTest {
    @Test
    fun parsesHandTypedAddresses() {
        assertEquals("http://192.168.1.10:3000", ServerAddress.parse("192.168.1.10:3000").toString())
        assertEquals("https://mc.example.com", ServerAddress.parse(" https://mc.example.com/api/v1/ ").toString())
        assertEquals("http://nas:3000/api/v1", ServerAddress.parse("http://nas:3000")!!.apiBase.toString())
        assertNull(ServerAddress.parse("   "))
    }

    @Test
    fun buildsImageUrlsOnTheWidthLadder() {
        val server = ServerAddress.parse("http://nas:3000")!!
        assertEquals(
            "http://nas:3000/api/v1/libraries/3/cover?w=480",
            ImageUrls.build(server, "/libraries/3/cover", 400).toString(),
        )
        assertEquals(
            "http://nas:3000/api/v1/images/assets/a.jpg",
            ImageUrls.build(server, "/api/v1/images/assets/a.jpg").toString(),
        )
        assertEquals(
            "http://nas:3000/api/v1/images/proxy?url=https%3A%2F%2Fimage.tmdb.org%2Ft%2Fp%2Fw500%2Fx.jpg&w=3840",
            ImageUrls.build(server, "https://image.tmdb.org/t/p/w500/x.jpg", 5000).toString(),
        )
        assertNull(ImageUrls.build(server, " "))
    }

    @Test
    fun userAgentMatchesServerPattern() {
        val ua = ClientIdentity("0.1.0", 1, "BRAVIA 4K VH2", "12").userAgent
        assertEquals("MovieClaw-AndroidTV/0.1.0 (BRAVIA 4K VH2; Android 12; build 1)", ua)
    }
}

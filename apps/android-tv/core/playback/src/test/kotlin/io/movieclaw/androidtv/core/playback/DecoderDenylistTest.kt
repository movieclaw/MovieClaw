package io.movieclaw.androidtv.core.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DecoderDenylistTest {
    private val prefs = object : PrefsStore {
        val map = mutableMapOf<String, String>()
        override fun string(key: String) = map[key]
        override fun putString(key: String, value: String?) {
            if (value == null) map.remove(key) else map[key] = value
        }
    }
    private var now = 1_000_000L

    @Test
    fun aDecoderThatGaveUpIsAvoidedUntilItExpires() {
        val list = DecoderDenylist(prefs, "0.4.0") { now }
        assertFalse(list.isDenied("OMX.vendor.hevc.decoder"))
        list.deny("OMX.vendor.hevc.decoder", "video/hevc", "本机没有能解这路视频的解码器")
        assertTrue(list.isDenied("OMX.vendor.hevc.decoder"))
        assertFalse(list.isDenied("c2.android.hevc.decoder"))
        assertEquals("video/hevc", list.entries().getValue("OMX.vendor.hevc.decoder").mime)
        // 30 天后再给它一次机会（厂商可能推了固件）
        now += DecoderDenylist.TTL_MS
        assertFalse(list.isDenied("OMX.vendor.hevc.decoder"))
    }

    @Test
    fun anAppUpgradeClearsTheList() {
        DecoderDenylist(prefs, "0.4.0") { now }.deny("OMX.vendor.hevc.decoder", "video/hevc", "x")
        assertFalse(DecoderDenylist(prefs, "0.5.0") { now }.isDenied("OMX.vendor.hevc.decoder"))
    }

    @Test
    fun corruptStorageIsIgnored() {
        prefs.putString("pref.playback.decoder-denylist", "{")
        prefs.map["playback.decoder-denylist"] = "not json"
        assertFalse(DecoderDenylist(prefs, "0.4.0") { now }.isDenied("x"))
    }
}

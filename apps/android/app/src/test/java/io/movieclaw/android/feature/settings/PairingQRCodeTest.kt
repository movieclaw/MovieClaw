package io.movieclaw.android.feature.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** 设备登录二维码解析（iOS `PairingQRCode` 同规格）：URL 与纯码都认，别的二维码不认 */
class PairingQRCodeTest {
    @Test fun parsesVerificationUriComplete() {
        val s = PairingQRCode.parse("http://192.168.1.10:3300/activate?code=MCLW-7F3K")!!
        assertEquals("MCLW-7F3K", s.code)
        assertEquals("192.168.1.10:3300", s.host)
    }

    @Test fun parsesLegacyDevicesPathAndBareCode() {
        assertEquals("MCLW-AB2C", PairingQRCode.parse("https://movie.example.com/settings/devices?code=ab2c")!!.code)
        val bare = PairingQRCode.parse("MCLW-AB2C")!!
        assertEquals("MCLW-AB2C", bare.code)
        assertNull(bare.host)
    }

    @Test fun normalizesSeparatorsAndPartialCodes() {
        assertEquals("MCLW-7F3K", PairingQRCode.normalize("mclw_7f-3k"))
        assertEquals("MCLW-7F3K", PairingQRCode.normalize("7f3k"))
        assertEquals("MCLW-7F3K", PairingQRCode.normalize("MCLW7F3K"))
    }

    @Test fun rejectsForeignCodes() {
        assertNull(PairingQRCode.parse("https://example.com/wifi?ssid=home"))
        assertNull(PairingQRCode.parse("HELLO"))
        assertNull(PairingQRCode.normalize("7F3"))
        assertNull(PairingQRCode.normalize("7F3KX"))
        assertNull(PairingQRCode.normalize("7F3!"))
    }
}

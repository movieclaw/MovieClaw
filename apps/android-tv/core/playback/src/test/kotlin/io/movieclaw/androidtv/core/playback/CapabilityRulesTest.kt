package io.movieclaw.androidtv.core.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CapabilityRulesTest {
    @Test
    fun softwareDecodersAreDeclaredOnlyUpTo1080p() {
        // 模拟器（及弱盒子）：HEVC 只有软解码器，自报 4096p。软解 4K 必卡，不能让服务端直接给原文件
        assertEquals(1080, CapabilityRules.maxHeight(listOf(4096 to false)))
        assertEquals(2160, CapabilityRules.maxHeight(listOf(2160 to true, 4096 to false)))
        assertEquals(720, CapabilityRules.maxHeight(listOf(720 to false)))
        assertNull(CapabilityRules.maxHeight(emptyList()))
    }

    @Test
    fun dolbyVisionProfilesComeFromTheDecoderAndNeedADolbyVisionDisplay() {
        // CodecProfileLevel：DvheStn (P5) = 0x20、DvheSt (P8) = 0x100
        assertEquals(setOf(5, 8), CapabilityRules.dolbyVisionProfiles(listOf(0x20, 0x100, 0x100), displaySupportsDolbyVision = true))
        assertEquals(emptySet<Int>(), CapabilityRules.dolbyVisionProfiles(listOf(0x20, 0x100), displaySupportsDolbyVision = false))
    }

    @Test
    fun baseLayerFallbackFollowsExoAlternativeDecoders() {
        assertEquals(setOf(4, 8), CapabilityRules.baseLayerProfiles(hevc = true, avc = false, av1 = false))
        assertEquals(setOf(4, 8, 9, 10), CapabilityRules.baseLayerProfiles(hevc = true, avc = true, av1 = true))
        assertEquals(emptySet<Int>(), CapabilityRules.baseLayerProfiles(hevc = false, avc = false, av1 = false))
    }
}

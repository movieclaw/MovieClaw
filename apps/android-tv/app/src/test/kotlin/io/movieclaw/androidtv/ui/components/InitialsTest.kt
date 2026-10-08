package io.movieclaw.androidtv.ui.components

import org.junit.Assert.assertEquals
import org.junit.Test

class InitialsTest {
    @Test
    fun matchesAppleRules() {
        assertEquals("小", initials(" 小雨 "))
        assertEquals("AD", initials("admin"))
        assertEquals("?", initials("   "))
        assertEquals("さく", initials("さくら"))
    }
}

package io.movieclaw.androidtv.core.session

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VersionsTest {
    @Test
    fun comparesNumericParts() {
        assertTrue(Versions.atLeast("0.33.0", "0.33.0"))
        assertTrue(Versions.atLeast("0.34.0", "0.33.0"))
        assertTrue(Versions.atLeast("1.0", "0.33.0"))
        assertTrue(Versions.atLeast("0.33.1-dev.20261008", "0.33.0"))
        assertFalse(Versions.atLeast("0.32.9", "0.33.0"))
        assertFalse(Versions.atLeast("0.4.0", "0.33.0"))
    }
}

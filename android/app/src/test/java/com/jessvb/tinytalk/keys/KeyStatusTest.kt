package com.jessvb.tinytalk.keys

import org.junit.Assert.assertEquals
import org.junit.Test

class KeyStatusTest {
    @Test fun overrideWins() = assertEquals(KeyStatus.YOURS, KeyStatus.of(override = "fake-own", baked = "fake-baked"))
    @Test fun blankOverrideFallsBackToBuiltIn() = assertEquals(KeyStatus.BUILT_IN, KeyStatus.of(override = "  ", baked = "fake-baked"))
    @Test fun nullOverrideFallsBackToBuiltIn() = assertEquals(KeyStatus.BUILT_IN, KeyStatus.of(override = null, baked = "fake-baked"))
    @Test fun neither() = assertEquals(KeyStatus.NONE, KeyStatus.of(override = null, baked = " "))

    @Test fun labels() {
        assertEquals("Using your key", KeyStatus.YOURS.label)
        assertEquals("Using the built-in key", KeyStatus.BUILT_IN.label)
        assertEquals("No key set", KeyStatus.NONE.label)
    }
}

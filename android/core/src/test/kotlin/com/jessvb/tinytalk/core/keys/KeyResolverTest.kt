package com.jessvb.tinytalk.core.keys

import com.jessvb.tinytalk.core.settings.InMemorySttModeStore
import com.jessvb.tinytalk.core.settings.SttMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class KeyResolverTest {
    @Test fun overrideBeatsBaked() {
        assertEquals("ov", KeyResolver("baked") { "ov" }.current())
    }

    @Test fun whitespaceOverrideFallsThroughToBaked() {
        assertEquals("baked", KeyResolver("baked") { "   " }.current())
        assertEquals("baked", KeyResolver("baked") { null }.current())
    }

    @Test fun bothBlankIsNull() {
        assertNull(KeyResolver("") { null }.current())
        assertNull(KeyResolver("  ") { " " }.current())
    }

    @Test fun overrideChangeVisibleWithoutRecreating() {
        var ov: String? = null
        val r = KeyResolver("baked") { ov }
        assertEquals("baked", r.current())
        ov = "new"
        assertEquals("new", r.current())
        ov = null
        assertEquals("baked", r.current())
    }

    @Test fun overrideIsTrimmed() {
        assertEquals("ov", KeyResolver("baked") { "  ov \n" }.current())
    }

    @Test fun bakedIsTrimmed() {
        assertEquals("b", KeyResolver(" b ") { null }.current())
    }

    @Test fun sttModeDefaultsToOnDevice() {
        val s = InMemorySttModeStore()
        assertEquals(SttMode.ON_DEVICE, s.mode)
        s.mode = SttMode.CLOUD
        assertEquals(SttMode.CLOUD, s.mode)
    }
}

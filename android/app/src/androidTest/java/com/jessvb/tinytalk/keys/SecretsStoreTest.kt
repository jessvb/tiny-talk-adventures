package com.jessvb.tinytalk.keys

import androidx.test.platform.app.InstrumentationRegistry
import com.jessvb.tinytalk.core.keys.KeyName
import com.jessvb.tinytalk.core.settings.SttMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Silent: no audio. Uses obviously fake values only. */
class SecretsStoreTest {
    private val ctx = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun roundTripAndClear() {
        val s = SecretsStore(ctx)
        s.set(KeyName.API_NINJAS, null)
        assertNull(s.get(KeyName.API_NINJAS))
        s.set(KeyName.API_NINJAS, "  fake-test-value ")
        assertEquals("fake-test-value", s.get(KeyName.API_NINJAS))
        assertEquals("fake-test-value", SecretsStore(ctx).get(KeyName.API_NINJAS))
        s.set(KeyName.API_NINJAS, "   ")
        assertNull(s.get(KeyName.API_NINJAS))
        s.set(KeyName.API_NINJAS, "fake-test-value")
        s.set(KeyName.API_NINJAS, null)
        assertNull(s.get(KeyName.API_NINJAS))
    }

    @Test fun corruptBlobIsAbsent() {
        ctx.getSharedPreferences("tinytalk_secrets", 0).edit()
            .putString(KeyName.GROQ.name, "not-base64-or-valid!!").commit()
        assertNull(SecretsStore(ctx).get(KeyName.GROQ))
    }

    @Test fun sttModeDefaultsAndFallsBack() {
        val prefs = ctx.getSharedPreferences("tinytalk_settings", 0)
        prefs.edit().clear().commit()
        val s = SettingsStores(ctx)
        assertEquals(SttMode.ON_DEVICE, s.mode)
        s.mode = SttMode.CLOUD
        assertEquals(SttMode.CLOUD, SettingsStores(ctx).mode)
        prefs.edit().putString("stt_mode", "bogus").commit()
        assertEquals(SttMode.ON_DEVICE, s.mode)
        prefs.edit().clear().commit()
    }
}

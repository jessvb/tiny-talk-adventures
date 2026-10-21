package com.jessvb.tinytalk.keys

import android.util.Base64
import androidx.test.platform.app.InstrumentationRegistry
import com.jessvb.tinytalk.core.keys.KeyName
import com.jessvb.tinytalk.core.settings.SttMode
import java.security.KeyStore
import java.security.ProviderException
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * Silent: no audio. Fake values only. Uses TEST-ONLY pref files and a TEST-ONLY Keystore
 * alias; this class must never reference the production names (tinytalk_secrets,
 * tinytalk_settings, tinytalk_secrets_v1) so running it cannot touch real data.
 */
class SecretsStoreTest {
    private val ctx = InstrumentationRegistry.getInstrumentation().targetContext
    private fun secrets() = SecretsStore(ctx, SECRETS_PREFS, ALIAS)
    private fun settings() = SettingsStores(ctx, SETTINGS_PREFS)
    private fun prefs(n: String) = ctx.getSharedPreferences(n, 0)

    @Before fun setUp() = cleanUp()
    @After fun tearDown() = cleanUp()

    private fun cleanUp() {
        prefs(SECRETS_PREFS).edit().clear().commit()
        prefs(SETTINGS_PREFS).edit().clear().commit()
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (ks.containsAlias(ALIAS)) ks.deleteEntry(ALIAS)
    }

    @Test fun roundTripAndClear() {
        val s = secrets()
        assertNull(s.get(KeyName.API_NINJAS))
        s.set(KeyName.API_NINJAS, "  fake-test-value ")
        assertEquals("fake-test-value", s.get(KeyName.API_NINJAS))
        assertEquals("fake-test-value", secrets().get(KeyName.API_NINJAS))
        s.set(KeyName.API_NINJAS, "   ")
        assertNull(s.get(KeyName.API_NINJAS))
        s.set(KeyName.API_NINJAS, "fake-test-value")
        s.set(KeyName.API_NINJAS, null)
        assertNull(s.get(KeyName.API_NINJAS))
    }

    @Test fun corruptBase64IsAbsentAndRemoved() {
        prefs(SECRETS_PREFS).edit().putString(KeyName.GROQ.name, "not-base64-or-valid!!").commit()
        assertNull(secrets().get(KeyName.GROQ))
        assertNull(prefs(SECRETS_PREFS).getString(KeyName.GROQ.name, null))
    }

    @Test fun tamperedCiphertextIsAbsentAndRemoved() {
        val s = secrets()
        s.set(KeyName.GROQ, "fake-test-value")
        val raw = Base64.decode(prefs(SECRETS_PREFS).getString(KeyName.GROQ.name, null), Base64.NO_WRAP)
        raw[raw.size - 1] = (raw[raw.size - 1].toInt() xor 1).toByte()
        prefs(SECRETS_PREFS).edit()
            .putString(KeyName.GROQ.name, Base64.encodeToString(raw, Base64.NO_WRAP)).commit()
        assertNull(secrets().get(KeyName.GROQ))
        assertNull(prefs(SECRETS_PREFS).getString(KeyName.GROQ.name, null))
    }

    @Test fun transientKeystoreErrorKeepsBlob() {
        secrets().set(KeyName.GROQ, "fake-test-value")
        val before = prefs(SECRETS_PREFS).getString(KeyName.GROQ.name, null)
        assertNotNull(before)
        val flaky = SecretsStore(ctx, SECRETS_PREFS, ALIAS, keyProvider = { throw ProviderException("busy") })
        assertNull(flaky.get(KeyName.GROQ))
        assertEquals(before, prefs(SECRETS_PREFS).getString(KeyName.GROQ.name, null))
        assertEquals("fake-test-value", secrets().get(KeyName.GROQ))
    }

    @Test fun sttModeDefaultsAndFallsBack() {
        val s = settings()
        assertEquals(SttMode.ON_DEVICE, s.mode)
        s.mode = SttMode.CLOUD
        assertEquals(SttMode.CLOUD, settings().mode)
        prefs(SETTINGS_PREFS).edit().putString("stt_mode", "bogus").commit()
        assertEquals(SttMode.ON_DEVICE, s.mode)
    }

    private companion object {
        const val SECRETS_PREFS = "tinytalk_secrets_test"
        const val SETTINGS_PREFS = "tinytalk_settings_test"
        const val ALIAS = "tinytalk_secrets_key_test"
    }
}

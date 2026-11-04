package com.jessvb.tinytalk.keys

import androidx.test.platform.app.InstrumentationRegistry
import com.jessvb.tinytalk.core.storybook.StorySettingsStore
import com.jessvb.tinytalk.core.storybook.current
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/** Silent: no audio. A TEST-ONLY prefs file; never touches the production `tinytalk_settings`. */
class StorySettingsStoreTest {
    private val ctx = InstrumentationRegistry.getInstrumentation().targetContext
    private fun store(): StorySettingsStore = SettingsStores(ctx, PREFS)

    @Before fun setUp() { ctx.getSharedPreferences(PREFS, 0).edit().clear().commit() }
    @After fun tearDown() { ctx.getSharedPreferences(PREFS, 0).edit().clear().commit() }

    @Test fun defaultsAreSevenTurnsAndFivePages() {
        assertEquals(7, store().turnCount)
        assertEquals(5, store().pageCount)
    }

    @Test fun valuesPersistAcrossInstances() {
        store().turnCount = 9
        store().pageCount = 6
        assertEquals(9, store().turnCount)
        assertEquals(6, store().pageCount)
        assertEquals(9, store().current().turnCount)
    }

    @Test fun valuesAreClampedOnWriteAndRead() {
        store().turnCount = 99
        store().pageCount = 0
        assertEquals(12, store().turnCount)
        assertEquals(3, store().pageCount)
        ctx.getSharedPreferences(PREFS, 0).edit().putInt("story_turn_count", -5).commit()
        assertEquals(4, store().turnCount)
    }

    private companion object { const val PREFS = "tinytalk_settings_storysettings_test" }
}

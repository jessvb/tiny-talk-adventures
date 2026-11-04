package com.jessvb.tinytalk.core.storybook

import org.junit.Assert.assertEquals
import org.junit.Test

class StorySettingsTest {
    @Test fun `defaults are 7 turns and 5 pages`() {
        val s = StorySettings()
        assertEquals(7, s.turnCount)
        assertEquals(5, s.pageCount)
    }

    @Test fun `turn count clamps to 4 through 12`() {
        assertEquals(4, StorySettings(turnCount = 1).turnCount)
        assertEquals(12, StorySettings(turnCount = 99).turnCount)
        assertEquals(9, StorySettings(turnCount = 9).turnCount)
    }

    @Test fun `page count clamps to 3 through 10`() {
        assertEquals(3, StorySettings(pageCount = 0).pageCount)
        assertEquals(10, StorySettings(pageCount = 50).pageCount)
        assertEquals(6, StorySettings(pageCount = 6).pageCount)
    }
}

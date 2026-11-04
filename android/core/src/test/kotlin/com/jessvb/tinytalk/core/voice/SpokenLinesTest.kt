package com.jessvb.tinytalk.core.voice

import com.jessvb.tinytalk.core.Safety
import org.junit.Assert.assertTrue
import org.junit.Test

class SpokenLinesTest {
    @Test
    fun `spoken lines are kid-safe, short and non-empty`() {
        for (line in listOf(SpokenLines.KEY_PROBLEM, SpokenLines.TRY_AGAIN)) {
            assertTrue(line, Safety.isSafe(line))
            assertTrue(line, line.isNotBlank() && line.length < 120)
        }
    }

    @Test
    fun `key problem line asks for a grown-up`() {
        assertTrue(SpokenLines.KEY_PROBLEM.contains("grown-up"))
    }
}

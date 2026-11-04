package com.jessvb.tinytalk.keys

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyCopyTest {
    @Test fun clearActionNamesTheBuiltInKeyOnlyWhenThereIsOne() {
        assertEquals("Use built-in key", KeyCopy.clearAction(bakedPresent = true))
        assertEquals("Remove my key", KeyCopy.clearAction(bakedPresent = false))
    }

    @Test fun groqIntroNeverClaimsABuiltInKeyThatIsNotThere() {
        assertTrue(KeyCopy.groqIntro(bakedPresent = true).contains("built-in key"))
        val none = KeyCopy.groqIntro(bakedPresent = false)
        assertFalse(none.contains("built-in"))
        assertTrue(none.contains("needs a key"))
    }

    @Test fun statusLinesAreTrueForEachCase() {
        assertEquals("Using your key", KeyCopy.status(KeyStatus.YOURS))
        assertEquals("Using the built-in key", KeyCopy.status(KeyStatus.BUILT_IN))
        assertEquals("No key set", KeyCopy.status(KeyStatus.NONE))
    }
}

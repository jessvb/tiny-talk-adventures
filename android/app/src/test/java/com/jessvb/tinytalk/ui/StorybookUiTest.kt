package com.jessvb.tinytalk.ui

import com.jessvb.tinytalk.core.storybook.RewriteStatus
import com.jessvb.tinytalk.core.storybook.StorySummary
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant
import java.time.ZoneOffset

class StorybookUiTest {
    private val now = Instant.parse("2026-11-04T15:00:00Z")
    private fun label(iso: String) = relativeDateLabel(iso, now, ZoneOffset.UTC)

    // ---- relativeDateLabel (port of iOS SavedStory.swift)

    @Test fun `same calendar day is today`() = assertEquals("today", label("2026-11-04T00:00:01Z"))
    @Test fun `the previous calendar day is yesterday`() = assertEquals("yesterday", label("2026-11-03T23:59:59Z"))
    @Test fun `two to six days is N days ago`() {
        assertEquals("2 days ago", label("2026-11-02T10:00:00Z"))
        assertEquals("6 days ago", label("2026-10-29T10:00:00Z"))
    }
    @Test fun `a week or more is N weeks ago`() {
        assertEquals("1 week ago", label("2026-10-28T10:00:00Z")) // 7 days
        assertEquals("1 week ago", label("2026-10-22T10:00:00Z")) // 13 days
        assertEquals("2 weeks ago", label("2026-10-21T10:00:00Z")) // 14 days
    }
    @Test fun `a date in the future reads as today`() = assertEquals("today", label("2026-11-06T10:00:00Z"))
    @Test fun `an unreadable date gives an empty label instead of crashing`() = assertEquals("", label("not a date"))

    // ---- card state and caption

    private fun summary(status: RewriteStatus, pages: Int = 3, title: String? = "The Fox") =
        StorySummary("a", "2026-11-04T10:00:00Z", title, pages, status)

    @Test fun `only a written story can be opened`() {
        assertEquals(CardState.READY, cardState(summary(RewriteStatus.DONE)))
        assertEquals(CardState.WRITING, cardState(summary(RewriteStatus.PENDING)))
        assertEquals(CardState.FAILED, cardState(summary(RewriteStatus.FAILED)))
    }

    @Test fun `captions use the iOS wording`() {
        assertEquals("today · 3 pages", cardCaption(summary(RewriteStatus.DONE), now, ZoneOffset.UTC))
        assertEquals("Elsie is still writing this one…", cardCaption(summary(RewriteStatus.PENDING), now, ZoneOffset.UTC))
        assertEquals("Couldn't finish this storybook", cardCaption(summary(RewriteStatus.FAILED), now, ZoneOffset.UTC))
    }

    @Test fun `one page is singular`() {
        assertEquals("today · 1 page", cardCaption(summary(RewriteStatus.DONE, pages = 1), now, ZoneOffset.UTC))
    }

    @Test fun `the card title falls back to Untitled`() {
        assertEquals("Untitled", cardTitle(summary(RewriteStatus.DONE, title = null)))
        assertEquals("Untitled", cardTitle(summary(RewriteStatus.DONE, title = "   ")))
    }
}

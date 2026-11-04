package com.jessvb.tinytalk.ui

import com.jessvb.tinytalk.core.storybook.RewriteStatus
import com.jessvb.tinytalk.core.storybook.StorySummary
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.ChronoUnit

/** Pure helpers for the Library / Reading / The End screens, so the wording is JVM-tested. */

/** Port of iOS `relativeDateLabel`: calendar-day based; a bad date gives "" rather than a crash. */
fun relativeDateLabel(createdAtIso: String, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): String {
    val created = try { Instant.parse(createdAtIso) } catch (e: Exception) { return "" }
    val days = ChronoUnit.DAYS.between(created.atZone(zone).toLocalDate(), now.atZone(zone).toLocalDate())
    return when {
        days < 1 -> "today"
        days == 1L -> "yesterday"
        days in 2..6 -> "$days days ago"
        else -> {
            val weeks = maxOf(1L, days / 7)
            if (weeks == 1L) "1 week ago" else "$weeks weeks ago"
        }
    }
}

enum class CardState { READY, WRITING, FAILED }

/** Only a written story can be opened. */
fun cardState(summary: StorySummary): CardState = when (summary.status) {
    RewriteStatus.DONE -> CardState.READY
    RewriteStatus.PENDING -> CardState.WRITING
    RewriteStatus.FAILED -> CardState.FAILED
}

fun cardTitle(summary: StorySummary): String = summary.title?.takeIf { it.isNotBlank() } ?: "Untitled"

fun cardCaption(summary: StorySummary, now: Instant = Instant.now(), zone: ZoneId = ZoneId.systemDefault()): String =
    when (cardState(summary)) {
        CardState.READY -> {
            val pages = if (summary.pageCount == 1) "1 page" else "${summary.pageCount} pages"
            "${relativeDateLabel(summary.createdAtIso, now, zone)} · $pages"
        }
        CardState.WRITING -> "Elsie is still writing this one…"
        CardState.FAILED -> "Couldn't finish this storybook"
    }

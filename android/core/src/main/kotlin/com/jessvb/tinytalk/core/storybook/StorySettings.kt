package com.jessvb.tinytalk.core.storybook

/** Parent-adjustable story length, clamped to the iOS/server ranges. */
class StorySettings(turnCount: Int = DEFAULT_TURNS, pageCount: Int = DEFAULT_PAGES) {
    val turnCount: Int = turnCount.coerceIn(MIN_TURNS, MAX_TURNS)
    val pageCount: Int = pageCount.coerceIn(MIN_PAGES, MAX_PAGES)

    companion object {
        const val DEFAULT_TURNS = 7
        const val MIN_TURNS = 4
        const val MAX_TURNS = 12
        const val DEFAULT_PAGES = 5
        const val MIN_PAGES = 3
        const val MAX_PAGES = 10
    }
}

/** Persistence seam for [StorySettings]; the app implements it on SharedPreferences. */
interface StorySettingsStore {
    var turnCount: Int
    var pageCount: Int
}

fun StorySettingsStore.current(): StorySettings = StorySettings(turnCount, pageCount)

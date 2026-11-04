package com.jessvb.tinytalk.keys

import android.content.Context
import com.jessvb.tinytalk.core.settings.SttMode
import com.jessvb.tinytalk.core.settings.SttModeStore
import com.jessvb.tinytalk.core.storybook.StorySettings
import com.jessvb.tinytalk.core.storybook.StorySettingsStore

class SettingsStores internal constructor(context: Context, prefsName: String) : SttModeStore, StorySettingsStore {
    constructor(context: Context) : this(context, "tinytalk_settings")

    private val prefs = context.applicationContext
        .getSharedPreferences(prefsName, Context.MODE_PRIVATE)

    override var mode: SttMode
        get() = prefs.getString(KEY_STT_MODE, null)
            ?.let { s -> SttMode.entries.firstOrNull { it.name == s } }
            ?: SttMode.ON_DEVICE
        set(value) {
            // commit(): the listening mode decides where audio goes; it must be on disk at once.
            prefs.edit().putString(KEY_STT_MODE, value.name).commit()
        }

    /** Elsie's TextToSpeech voice name; null = the engine's default. */
    var voiceName: String?
        get() = prefs.getString(KEY_VOICE, null)
        set(value) {
            val e = prefs.edit()
            if (value == null) e.remove(KEY_VOICE) else e.putString(KEY_VOICE, value)
            e.apply()
        }

    /** Parent-set story length (turns) for the NEXT story; clamped to 4-12 on write and read. */
    override var turnCount: Int
        get() = StorySettings(turnCount = prefs.getInt(KEY_TURNS, StorySettings.DEFAULT_TURNS)).turnCount
        set(value) {
            prefs.edit().putInt(KEY_TURNS, StorySettings(turnCount = value).turnCount).apply()
        }

    /** Parent-set storybook page count for the NEXT story; clamped to 3-10 on write and read. */
    override var pageCount: Int
        get() = StorySettings(pageCount = prefs.getInt(KEY_PAGES, StorySettings.DEFAULT_PAGES)).pageCount
        set(value) {
            prefs.edit().putInt(KEY_PAGES, StorySettings(pageCount = value).pageCount).apply()
        }

    private companion object {
        const val KEY_TURNS = "story_turn_count"
        const val KEY_PAGES = "storybook_page_count"
        const val KEY_VOICE = "tts_voice_name"
        const val KEY_STT_MODE = "stt_mode"
    }
}

package com.jessvb.tinytalk.keys

import android.content.Context
import com.jessvb.tinytalk.core.settings.SttMode
import com.jessvb.tinytalk.core.settings.SttModeStore

class SettingsStores internal constructor(context: Context, prefsName: String) : SttModeStore {
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

    private companion object {
        const val KEY_VOICE = "tts_voice_name"
        const val KEY_STT_MODE = "stt_mode"
    }
}

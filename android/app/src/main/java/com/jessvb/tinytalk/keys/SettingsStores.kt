package com.jessvb.tinytalk.keys

import android.content.Context
import com.jessvb.tinytalk.core.settings.SttMode
import com.jessvb.tinytalk.core.settings.SttModeStore

class SettingsStores(context: Context) : SttModeStore {
    private val prefs = context.applicationContext
        .getSharedPreferences("tinytalk_settings", Context.MODE_PRIVATE)

    override var mode: SttMode
        get() = prefs.getString(KEY_STT_MODE, null)
            ?.let { s -> SttMode.entries.firstOrNull { it.name == s } }
            ?: SttMode.ON_DEVICE
        set(value) {
            prefs.edit().putString(KEY_STT_MODE, value.name).apply()
        }

    private companion object {
        const val KEY_STT_MODE = "stt_mode"
    }
}

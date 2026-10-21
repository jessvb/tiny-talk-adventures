package com.jessvb.tinytalk.ui

import android.content.Context

enum class Screen { ONBOARDING, LANDING, STORY, SETTINGS }

/** Persisted parent consent. Nothing (mic, network) may start until [accepted] is true. */
interface ConsentStore {
    var accepted: Boolean
}

class SharedPrefsConsentStore(context: Context) : ConsentStore {
    private val prefs = context.applicationContext.getSharedPreferences("tinytalk_consent", Context.MODE_PRIVATE)

    override var accepted: Boolean
        get() = prefs.getBoolean(KEY, false)
        set(value) {
            prefs.edit().putBoolean(KEY, value).apply()
        }

    private companion object {
        const val KEY = "consent_accepted_v1"
    }
}

/** Plain-Kotlin navigation state (no Android imports in the logic). No route past ONBOARDING without consent. */
class Navigator(private val consent: ConsentStore) {
    private val stack = ArrayDeque<Screen>()

    var declinedNotice: Boolean = false
        private set

    /** Called after every change; the Compose root uses it to re-read [current]. */
    var onChange: (() -> Unit)? = null

    init {
        stack.addLast(if (consent.accepted) Screen.LANDING else Screen.ONBOARDING)
    }

    val current: Screen get() = stack.last()

    fun acceptConsent() {
        consent.accepted = true
        declinedNotice = false
        stack.clear()
        stack.addLast(Screen.LANDING)
        onChange?.invoke()
    }

    fun declineConsent() {
        declinedNotice = true
        onChange?.invoke()
    }

    fun goTo(screen: Screen) {
        if (!consent.accepted) return
        if (screen == Screen.ONBOARDING || screen == Screen.LANDING && current == Screen.LANDING) return
        if (screen == Screen.LANDING) {
            stack.clear()
        }
        stack.addLast(screen)
        onChange?.invoke()
    }

    /** Returns true if consumed; false means the system should handle back (leave the app). */
    fun back(): Boolean {
        if (stack.size <= 1) return false
        stack.removeLast()
        onChange?.invoke()
        return true
    }

    companion object {
        const val DECLINED_MESSAGE = "Nothing is sent until you agree."
    }
}

package com.jessvb.tinytalk.ui

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

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
            // commit(): consent must be on disk before anything acts on it.
            prefs.edit().putBoolean(KEY, value).commit()
        }

    private companion object {
        const val KEY = "consent_accepted_v1"
    }
}

/** What the UI renders: the current screen and whether the "not now" notice shows. */
data class NavState(val screen: Screen, val declinedNotice: Boolean = false)

/**
 * Plain-Kotlin navigation state (no Android imports in the logic). No route past ONBOARDING
 * without consent. Call from the main thread only. [state] is a StateFlow the Compose root
 * collects, so every change recomposes without a callback.
 *
 * Stack rules: goTo(current) is a no-op; going to a screen already in the stack pops back to it
 * (screens never nest, so SETTINGS opened from STORY returns to STORY on back); LANDING clears
 * the stack; ONBOARDING is reachable only through [revokeConsent].
 */
class Navigator(private val consent: ConsentStore) {
    private val stack = ArrayDeque<Screen>()
    private val _state: MutableStateFlow<NavState>

    init {
        stack.addLast(if (consent.accepted) Screen.LANDING else Screen.ONBOARDING)
        _state = MutableStateFlow(NavState(stack.last()))
    }

    val state: StateFlow<NavState> = _state.asStateFlow()

    val current: Screen get() = stack.last()
    val declinedNotice: Boolean get() = _state.value.declinedNotice

    private fun publish(declined: Boolean = false) {
        _state.value = NavState(stack.last(), declined)
    }

    fun acceptConsent() {
        consent.accepted = true
        stack.clear()
        stack.addLast(Screen.LANDING)
        publish()
    }

    fun declineConsent() {
        publish(declined = true)
    }

    /** Parent withdrew consent in Settings: forget it and go back to ONBOARDING (the caller stops the loop). */
    fun revokeConsent() {
        consent.accepted = false
        stack.clear()
        stack.addLast(Screen.ONBOARDING)
        publish()
    }

    fun goTo(screen: Screen) {
        if (!consent.accepted) return
        if (screen == Screen.ONBOARDING || screen == current) return
        when {
            screen == Screen.LANDING -> stack.clear()
            screen in stack -> while (stack.last() != screen) stack.removeLast()
        }
        if (stack.lastOrNull() != screen) stack.addLast(screen)
        publish()
    }

    /** Returns true if consumed; false means the system should handle back (leave the app). */
    fun back(): Boolean {
        if (stack.size <= 1) return false
        stack.removeLast()
        publish()
        return true
    }

    companion object {
        const val DECLINED_MESSAGE = "Nothing is sent until you agree."
    }
}

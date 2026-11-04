package com.jessvb.tinytalk

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import com.jessvb.tinytalk.ui.LandingScreen
import com.jessvb.tinytalk.ui.LibraryScreen
import com.jessvb.tinytalk.ui.ReadingScreen
import com.jessvb.tinytalk.ui.TheEndScreen
import com.jessvb.tinytalk.ui.OnboardingScreen
import com.jessvb.tinytalk.ui.Screen
import com.jessvb.tinytalk.ui.SettingsScreen
import com.jessvb.tinytalk.ui.StoryScreen
import com.jessvb.tinytalk.ui.TTA

@Composable
fun TinyTalkApp(vm: TinyTalkViewModel) {
    val navigator = vm.navigator
    val nav by navigator.state.collectAsState()

    // Consumed only when there is somewhere to go back to; otherwise the system leaves the app.
    BackHandler(enabled = nav.screen != Screen.LANDING && nav.screen != Screen.ONBOARDING) { navigator.back() }

    Box(Modifier.fillMaxSize().background(TTA.Palette.OuterPaper)) {
        when (nav.screen) {
            Screen.ONBOARDING -> OnboardingScreen(navigator, nav.declinedNotice)
            Screen.LANDING -> LandingScreen(
                onCreateStory = { navigator.goTo(Screen.STORY) },
                onReadStories = vm::openLibrary,
                onSettings = { navigator.goTo(Screen.SETTINGS) },
            )
            Screen.STORY -> StoryScreen(
                vm,
                onBack = { navigator.back() },
                onSettings = { navigator.goTo(Screen.SETTINGS) },
            )
            Screen.SETTINGS -> SettingsScreen(vm, onBack = { navigator.back() })
            Screen.LIBRARY -> LibraryScreen(vm, onBack = { navigator.back() }, onNewStory = { navigator.goTo(Screen.STORY) })
            Screen.READING -> {
                val id by vm.readingStoryId.collectAsState()
                id?.let { ReadingScreen(vm, it, onBack = { navigator.back() }) }
            }
            Screen.THE_END -> TheEndScreen(vm)
        }
    }
}

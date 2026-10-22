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
import com.jessvb.tinytalk.ui.OnboardingScreen
import com.jessvb.tinytalk.ui.Screen
import com.jessvb.tinytalk.ui.StoryScreen
import com.jessvb.tinytalk.ui.TTA

@Composable
fun TinyTalkApp(vm: TinyTalkViewModel) {
    val navigator = vm.navigator
    val nav by navigator.state.collectAsState()

    // Consumed only when there is somewhere to go back to; otherwise the system leaves the app.
    BackHandler(enabled = nav.screen == Screen.STORY || nav.screen == Screen.SETTINGS) { navigator.back() }

    Box(Modifier.fillMaxSize().background(TTA.Palette.OuterPaper)) {
        when (nav.screen) {
            Screen.ONBOARDING -> OnboardingScreen(navigator, nav.declinedNotice)
            Screen.LANDING -> LandingScreen(
                onCreateStory = { navigator.goTo(Screen.STORY) },
                onSettings = { navigator.goTo(Screen.SETTINGS) },
            )
            Screen.STORY -> StoryScreen(
                vm,
                onBack = { navigator.back() },
                onSettings = { navigator.goTo(Screen.SETTINGS) },
            )
            Screen.SETTINGS -> androidx.compose.material3.Text("Settings: next commit")
        }
    }
}

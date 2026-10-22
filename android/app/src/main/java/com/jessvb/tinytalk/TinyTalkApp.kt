package com.jessvb.tinytalk

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.jessvb.tinytalk.ui.LandingScreen
import com.jessvb.tinytalk.ui.Navigator
import com.jessvb.tinytalk.ui.OnboardingScreen
import com.jessvb.tinytalk.ui.Screen
import com.jessvb.tinytalk.ui.TTA

@Composable
fun TinyTalkApp(navigator: Navigator) {
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
            // Task 10 replaces these placeholders.
            Screen.STORY -> Placeholder("Story screen coming in the next task")
            Screen.SETTINGS -> Placeholder("Settings screen coming in the next task")
        }
    }
}

@Composable
private fun Placeholder(text: String) {
    Box(Modifier.fillMaxSize().statusBarsPadding().padding(24.dp), contentAlignment = Alignment.Center) {
        Text(text, style = TTA.Typography.body(18f), color = TTA.Palette.Ink)
    }
}

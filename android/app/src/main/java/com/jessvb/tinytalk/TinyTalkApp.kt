package com.jessvb.tinytalk

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
    var version by remember { mutableIntStateOf(0) }
    DisposableEffect(navigator) {
        navigator.onChange = { version++ }
        onDispose { navigator.onChange = null }
    }
    @Suppress("UNUSED_EXPRESSION") version // re-read navigator state whenever it changes

    // Consumed only when there is somewhere to go back to; otherwise the system leaves the app.
    BackHandler(enabled = navigator.current == Screen.STORY || navigator.current == Screen.SETTINGS) { navigator.back() }

    Box(Modifier.fillMaxSize().background(TTA.Palette.OuterPaper)) {
        when (navigator.current) {
            Screen.ONBOARDING -> OnboardingScreen(navigator, navigator.declinedNotice)
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

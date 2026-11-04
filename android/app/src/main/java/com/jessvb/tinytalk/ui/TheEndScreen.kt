package com.jessvb.tinytalk.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.jessvb.tinytalk.TinyTalkViewModel

/**
 * Shown automatically once a story is over and Elsie has finished speaking. "Read it now" opens the
 * storybook as soon as it is written; until then it waits (greyed), and says so if it could not be
 * written (port of iOS TheEndView, without the page art).
 */
@Composable
fun TheEndScreen(vm: TinyTalkViewModel) {
    val end by vm.theEnd.collectAsState()
    val state = end
    Column(
        Modifier.fillMaxSize().background(TTA.Palette.Paper).statusBarsPadding().navigationBarsPadding()
            .padding(horizontal = TTA.Spacing.ScreenH),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("You wrote a whole story!", style = TTA.Typography.display(26f), color = TTA.Palette.Ink, textAlign = TextAlign.Center)
        Text("The End.", style = TTA.Typography.display(48f), color = TTA.Palette.Scarf, modifier = Modifier.padding(vertical = 12.dp))
        val ready = state?.ready == true
        PrimaryButton(
            "Read it now",
            onClick = { state?.let { vm.openStory(it.storyId) } },
            modifier = Modifier.padding(top = 20.dp),
            enabled = ready,
        )
        when {
            state?.failed == true ->
                Text("Couldn't finish this storybook", style = TTA.Typography.story(14f, italic = true), color = TTA.Palette.Alert)
            !ready ->
                Text("Elsie is still writing this one…", style = TTA.Typography.story(14f, italic = true), color = TTA.Palette.InkSoft)
        }
        SecondaryButton("Back home", onClick = vm::backHome, modifier = Modifier.padding(top = 14.dp))
    }
}

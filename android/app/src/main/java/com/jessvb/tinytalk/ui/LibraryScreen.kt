package com.jessvb.tinytalk.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.jessvb.tinytalk.TinyTalkViewModel
import com.jessvb.tinytalk.core.storybook.StorySummary

private val CardGradients = listOf(
    listOf(TTA.Palette.Scarf, TTA.Palette.ScarfShadow),
    listOf(TTA.Palette.Teal, TTA.Palette.TealShadow),
    listOf(Color(0xFF8A7BB8), Color(0xFF4A3F75)),
)

/** "Your Stories": the phone's saved storybooks, newest first (port of iOS LibraryView). */
@Composable
fun LibraryScreen(vm: TinyTalkViewModel, onBack: () -> Unit, onNewStory: () -> Unit) {
    val stories by vm.libraryStories.collectAsState()
    Column(
        Modifier.fillMaxSize().background(TTA.Palette.Paper).statusBarsPadding().navigationBarsPadding(),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            IconTile(onBack) {
                Text("‹", style = TTA.Typography.display(26f), color = TTA.Palette.Wood,
                    modifier = Modifier.semantics { contentDescription = "Back" })
            }
            Text("Your Stories", style = TTA.Typography.display(28f), color = TTA.Palette.Ink)
        }
        if (stories.isEmpty()) {
            Column(
                Modifier.weight(1f).fillMaxWidth().padding(horizontal = TTA.Spacing.ScreenH),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Text(
                    "No stories yet — make one with me first!",
                    style = TTA.Typography.story(15f, italic = true),
                    color = TTA.Palette.InkSoft,
                    textAlign = TextAlign.Center,
                )
                Box(Modifier.padding(top = 12.dp).fillMaxWidth(0.6f)) { NewStoryTile(onNewStory) }
            }
        } else {
            LazyVerticalGrid(
                columns = GridCells.Fixed(2),
                modifier = Modifier.weight(1f).fillMaxWidth(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(20.dp),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                verticalArrangement = Arrangement.spacedBy(22.dp),
            ) {
                itemsIndexed(stories, key = { _, s -> s.id }) { index, summary ->
                    StoryCard(summary, CardGradients[index % CardGradients.size]) { vm.openStory(summary.id) }
                }
                item(key = "new") { NewStoryTile(onNewStory) }
            }
        }
    }
}

@Composable
private fun StoryCard(summary: StorySummary, colors: List<Color>, onOpen: () -> Unit) {
    val state = cardState(summary)
    val shape = RoundedCornerShape(topStart = 5.dp, bottomStart = 5.dp, topEnd = 13.dp, bottomEnd = 13.dp)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(
            Modifier.fillMaxWidth().height(190.dp).clip(shape)
                .background(Brush.linearGradient(colors))
                .then(if (state == CardState.READY) Modifier.clickable(onClickLabel = "Open story", onClick = onOpen) else Modifier),
            contentAlignment = Alignment.BottomStart,
        ) {
            if (state == CardState.READY) {
                Text(cardTitle(summary), style = TTA.Typography.display(19f), color = TTA.Palette.Cream,
                    modifier = Modifier.padding(14.dp))
            }
        }
        Text(
            cardCaption(summary),
            style = if (state == CardState.READY) TTA.Typography.story(13f) else TTA.Typography.story(13f, italic = true),
            color = if (state == CardState.FAILED) TTA.Palette.Alert else TTA.Palette.InkSoft,
        )
    }
}

@Composable
private fun NewStoryTile(onClick: () -> Unit) {
    val shape = RoundedCornerShape(13.dp)
    Column(
        Modifier.fillMaxWidth().height(190.dp).clip(shape)
            .background(TTA.Palette.Cream)
            .clickable(role = androidx.compose.ui.semantics.Role.Button, onClick = onClick),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text("+", style = TTA.Typography.display(44f), color = TTA.Palette.Scarf)
        Text("New story", style = TTA.Typography.display(18f), color = TTA.Palette.Ink)
    }
}

package com.jessvb.tinytalk.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.jessvb.tinytalk.TinyTalkViewModel
import com.jessvb.tinytalk.core.storybook.LocalStory

/**
 * Reads a saved storybook: swipe between pages, 🔊 reads the current page aloud (port of iOS
 * ReadingView, text only until the illustrations spec). The one-true-thing epilogue sits under the
 * last page. Leaving the screen, or turning a page, stops any narration.
 */
@Composable
fun ReadingScreen(vm: TinyTalkViewModel, storyId: String, onBack: () -> Unit) {
    val loaded by produceState<LocalStory?>(initialValue = null, storyId) { value = vm.loadStory(storyId) }
    DisposableEffect(Unit) { onDispose { vm.stopSpeakingPage() } }

    val story = loaded
    Column(Modifier.fillMaxSize().background(TTA.Palette.Paper).statusBarsPadding().navigationBarsPadding()) {
        if (story == null || story.pages.isEmpty()) {
            TopBar(title = "", onBack = onBack, onReplay = null)
            return@Column
        }
        val pagerState = rememberPagerState(pageCount = { story.pages.size })
        LaunchedEffect(pagerState.currentPage) { vm.stopSpeakingPage() } // a turned page is silent
        TopBar(
            title = story.title.orEmpty(),
            onBack = onBack,
            onReplay = { vm.speakPage(story.pages[pagerState.currentPage].text) },
        )
        HorizontalPager(state = pagerState, modifier = Modifier.weight(1f).fillMaxWidth()) { index ->
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 28.dp, vertical = 20.dp)) {
                Text("PAGE ${index + 1}", style = TTA.Typography.display(14f), color = TTA.Palette.Scarf)
                Spacer(Modifier.size(10.dp))
                Text(story.pages[index].text, style = TTA.Typography.story(22f), color = TTA.Palette.Ink)
                if (index == story.pages.lastIndex && story.epilogue != null) {
                    Spacer(Modifier.size(18.dp))
                    FactLine(story.epilogue!!)
                }
            }
        }
        BottomBar(count = story.pages.size, current = pagerState.currentPage)
    }
}

@Composable
private fun TopBar(title: String, onBack: () -> Unit, onReplay: (() -> Unit)?) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 18.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        IconTile(onBack) {
            Text("‹", style = TTA.Typography.display(26f), color = TTA.Palette.Wood,
                modifier = Modifier.semantics { contentDescription = "Back" })
        }
        Text(title, style = TTA.Typography.display(14f), color = TTA.Palette.Ink, modifier = Modifier.weight(1f).padding(horizontal = 12.dp))
        if (onReplay != null) {
            IconTile(onReplay) {
                Text("🔊", style = TTA.Typography.body(20f), modifier = Modifier.semantics { contentDescription = "Read this page aloud" })
            }
        } else {
            Spacer(Modifier.size(48.dp))
        }
    }
}

@Composable
private fun FactLine(text: String) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(TTA.Palette.Gold.copy(alpha = 0.12f))
            .padding(horizontal = 14.dp, vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text("✨", style = TTA.Typography.body(16f))
        Text(text, style = TTA.Typography.story(18f, italic = true), color = TTA.Palette.InkSoft, modifier = Modifier.weight(1f))
        Text("✨", style = TTA.Typography.body(16f))
    }
}

@Composable
private fun BottomBar(count: Int, current: Int) {
    Column(Modifier.fillMaxWidth().padding(bottom = 20.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            Modifier.clip(RoundedCornerShape(14.dp)).background(TTA.Palette.Ink.copy(alpha = 0.45f)).padding(horizontal = 14.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            repeat(count) { i ->
                Box(Modifier.size(9.dp).clip(CircleShape).background(if (i == current) TTA.Palette.Gold else TTA.Palette.Paper.copy(alpha = 0.4f)))
            }
        }
        Text("swipe to turn the page", style = TTA.Typography.story(12.5f, italic = true), color = TTA.Palette.InkSoft)
    }
}

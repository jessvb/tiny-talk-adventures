package com.jessvb.tinytalk.ui

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.jessvb.tinytalk.TinyTalkViewModel
import com.jessvb.tinytalk.core.voice.LoopState

/**
 * The live conversation screen, after iOS StoryView: header with the state label, a
 * parent-facing banner, the transcript (auto-scrolls to the newest line), and a bottom bar
 * with New Story, Elsie's avatar and a pause/listen button. Mic problems are shown, never silent.
 */
@Composable
fun StoryScreen(vm: TinyTalkViewModel, onBack: () -> Unit, onSettings: () -> Unit) {
    val state by vm.story.collectAsState()
    val paused by vm.listeningPaused.collectAsState()
    val context = LocalContext.current
    var askedOnce by rememberSaveable { mutableStateOf(false) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        askedOnce = true
        vm.onPermissionResult(granted)
    }
    val label = if (paused && !state.micPermissionMissing && state.micUnavailable == null && !state.listeningNotInstalled) "Listening is paused"
        else StoryReducer.stateLabel(state)

    BoxWithConstraints(Modifier.fillMaxSize().background(TTA.Palette.OuterPaper)) {
        // At large font scales the notices scroll inside at most ~40% of the screen, so the
        // transcript keeps room and the bottom bar is never pushed off-screen.
        val noticeMax = maxHeight * 0.4f
        Column(Modifier.fillMaxSize()) {
            Header(label, onBack, onSettings)
            Column(Modifier.heightIn(max = noticeMax).verticalScroll(rememberScrollState())) {
                state.banner?.let { BannerView(it, onSettings) }
                if (state.listeningNotInstalled) {
                    InfoNotice(StoryReducer.LISTENING_NOT_INSTALLED_MESSAGE, onSettings)
                }
                when {
                    state.micPermissionMissing -> MicNotice(
                        title = "Allow microphone",
                        message = "Elsie needs the microphone to hear your story. A grown-up can allow it.",
                        button = "Allow microphone",
                        onClick = { permission.launch(Manifest.permission.RECORD_AUDIO) },
                        secondary = if (askedOnce) "Open phone settings" to {
                            context.startActivity(
                                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null))
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                            )
                        } else null,
                    )
                    state.micUnavailable != null -> MicNotice(
                        title = "Microphone unavailable",
                        message = state.micUnavailable!!,
                        // Retrying cannot fix audio parts that never built: no button then.
                        button = if (state.micUnavailableRetryable) "Try again" else null,
                        onClick = vm::retryMic,
                    )
                }
            }
            Transcript(state, Modifier.weight(1f).heightIn(min = 72.dp))
            BottomBar(
                state = state,
                label = label,
                paused = paused,
                onNewStory = vm::newStory,
                onTogglePause = { vm.setListeningPaused(!paused) },
            )
        }
    }
}

@Composable
private fun Header(label: String, onBack: () -> Unit, onSettings: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().background(TTA.Palette.Paper).statusBarsPadding()
            .padding(horizontal = 18.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        IconTile(onBack, size = 48.dp) {
            Text("‹", style = TTA.Typography.display(26f), color = TTA.Palette.Wood,
                modifier = Modifier.semantics { contentDescription = "Back" })
        }
        Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
            Text("Tiny Talk Adventures", style = TTA.Typography.display(15f), color = TTA.Palette.Ink)
            Text(label, style = TTA.Typography.body(11.5f, FontWeight.SemiBold), color = TTA.Palette.InkSoft,
                modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        }
        IconTile(onSettings, size = 48.dp) {
            Text("⚙", style = TTA.Typography.body(22f), color = TTA.Palette.Wood,
                modifier = Modifier.semantics { contentDescription = "Settings" })
        }
    }
}

@Composable
private fun BannerView(banner: Banner, onSettings: () -> Unit) {
    Column(
        Modifier.padding(horizontal = 16.dp).padding(top = 14.dp).fillMaxWidth()
            .clip(RoundedCornerShape(14.dp)).background(TTA.Palette.Alert).padding(12.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(banner.message, style = TTA.Typography.body(13f, FontWeight.SemiBold), color = TTA.Palette.Cream)
        if (banner.showSettings) {
            ChunkyButton(
                "Open Settings", onSettings,
                fill = TTA.Palette.Cream, edge = TTA.Palette.Wood.copy(alpha = 0.35f),
                foreground = TTA.Palette.Ink, fontSize = 15f,
            )
        }
    }
}

/** Friendly (teal) notice: Elsie can't listen in this build until a grown-up changes Settings. */
@Composable
private fun InfoNotice(message: String, onSettings: () -> Unit) {
    Column(
        Modifier.padding(horizontal = 16.dp).padding(top = 14.dp).fillMaxWidth()
            .clip(RoundedCornerShape(14.dp)).background(TTA.Palette.TealSurface).padding(12.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(message, style = TTA.Typography.body(13f, FontWeight.SemiBold), color = TTA.Palette.Teal)
        ChunkyButton(
            "Open Settings", onSettings,
            fill = TTA.Palette.Cream, edge = TTA.Palette.Wood.copy(alpha = 0.35f),
            foreground = TTA.Palette.Ink, fontSize = 15f,
        )
    }
}

@Composable
private fun MicNotice(
    title: String,
    message: String,
    button: String?,
    onClick: () -> Unit,
    secondary: Pair<String, () -> Unit>? = null,
) {
    TTACard(Modifier.padding(horizontal = 16.dp).padding(top = 14.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = TTA.Typography.display(17f), color = TTA.Palette.Alert)
            Text(message, style = TTA.Typography.body(14f), color = TTA.Palette.Ink)
            button?.let { PrimaryButton(it, onClick) }
            secondary?.let { (text, action) -> SecondaryButton(text, action) }
        }
    }
}

@Composable
private fun Transcript(state: StoryUiState, modifier: Modifier) {
    val list = rememberLazyListState()
    val thinking = state.loopState == LoopState.THINKING
    val count = state.lines.size + (if (thinking) 1 else 0) + (if (state.storyFinished) 1 else 0)
    LaunchedEffect(count) {
        if (count > 0) list.animateScrollToItem(count - 1)
    }
    LazyColumn(
        modifier.fillMaxWidth(),
        state = list,
        contentPadding = PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        if (state.lines.isEmpty() && !thinking && !state.storyFinished) {
            item(key = "hint") {
                Text(
                    "Say hello to Elsie and tell her what your story should be about!",
                    style = TTA.Typography.story(16f, italic = true),
                    color = TTA.Palette.InkSoft,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(top = 24.dp),
                )
            }
        }
        items(state.lines, key = { it.id }) { Bubble(it) }
        if (thinking) item(key = "thinking") { ThinkingRow() }
        if (state.storyFinished) item(key = "end") {
            Text(
                "The end! Say something to start a new story.",
                style = TTA.Typography.display(18f),
                color = TTA.Palette.Scarf,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
            )
        }
    }
}

@Composable
private fun Bubble(line: TranscriptLine) {
    val elsie = line.speaker == LineSpeaker.ELSIE
    val shape = if (elsie) RoundedCornerShape(20.dp, 20.dp, 20.dp, 6.dp) else RoundedCornerShape(20.dp, 20.dp, 6.dp, 20.dp)
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = if (elsie) Arrangement.Start else Arrangement.End,
        verticalAlignment = Alignment.Bottom,
    ) {
        if (elsie) {
            ElsieAvatar(ElsieMood.IDLE, diameter = 38.dp)
            Spacer(Modifier.size(9.dp))
        } else {
            Spacer(Modifier.size(38.dp))
        }
        Text(
            line.text,
            style = TTA.Typography.story(16.5f),
            color = if (elsie) TTA.Palette.Ink else TTA.Palette.Cream,
            modifier = Modifier.weight(1f, fill = false).clip(shape)
                .background(if (elsie) TTA.Palette.Cream else TTA.Palette.Teal).padding(12.dp)
                .semantics { contentDescription = (if (elsie) "Elsie: " else "You: ") + line.text },
        )
        if (elsie) Spacer(Modifier.size(38.dp))
    }
}

@Composable
private fun ThinkingRow() {
    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
        ElsieAvatar(ElsieMood.WAITING_FOR_REPLY, diameter = 38.dp)
        Text(
            "Elsie is thinking…",
            style = TTA.Typography.story(13.5f, italic = true),
            color = TTA.Palette.InkSoft,
            modifier = Modifier.clip(RoundedCornerShape(20.dp, 20.dp, 20.dp, 6.dp))
                .background(TTA.Palette.Cream).padding(horizontal = 16.dp, vertical = 13.dp),
        )
    }
}

@Composable
private fun BottomBar(
    state: StoryUiState,
    label: String,
    paused: Boolean,
    onNewStory: () -> Unit,
    onTogglePause: () -> Unit,
) {
    val micOff = paused || state.micPermissionMissing || state.micUnavailable != null || state.listeningNotInstalled
    val mood = when (state.loopState) {
        LoopState.IDLE -> ElsieMood.IDLE
        LoopState.LISTENING -> ElsieMood.LISTENING
        LoopState.THINKING -> ElsieMood.WAITING_FOR_REPLY
        LoopState.SPEAKING -> ElsieMood.SPEAKING
    }
    Row(
        Modifier.fillMaxWidth().background(TTA.Palette.Paper).navigationBarsPadding()
            .padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(Modifier.weight(1f)) {
            ChunkyButton("New Story", onNewStory, fill = TTA.Palette.Teal, edge = TTA.Palette.TealShadow, fontSize = 15f)
        }
        Column(
            Modifier.widthIn(min = 96.dp).semantics(mergeDescendants = true) {
                contentDescription = "Elsie. $label"
            },
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            ElsieAvatar(mood, isMuted = micOff, diameter = 68.dp)
            Text(
                label,
                style = TTA.Typography.display(12f),
                color = if (micOff) TTA.Palette.Alert else TTA.Palette.Teal,
                textAlign = TextAlign.Center,
            )
        }
        Box(Modifier.weight(1f)) {
            val canToggle = !state.micPermissionMissing && state.micUnavailable == null && !state.listeningNotInstalled
            ChunkyButton(
                if (paused) "Listen" else "Pause",
                onTogglePause,
                fill = if (paused) TTA.Palette.Scarf else TTA.Palette.Cream,
                edge = if (paused) TTA.Palette.ScarfShadow else TTA.Palette.Wood.copy(alpha = 0.35f),
                foreground = if (paused) TTA.Palette.Cream else TTA.Palette.Wood,
                fontSize = 15f,
                enabled = canToggle,
            )
        }
    }
}

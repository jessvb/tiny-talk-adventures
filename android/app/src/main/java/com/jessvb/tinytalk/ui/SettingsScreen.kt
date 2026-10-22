package com.jessvb.tinytalk.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jessvb.tinytalk.TinyTalkViewModel
import com.jessvb.tinytalk.core.keys.KeyName
import com.jessvb.tinytalk.core.settings.SttMode
import com.jessvb.tinytalk.keys.KeyStatus

/** Exact helper text for the "better listening" switch (plan Task 10). */
const val BETTER_LISTENING_HELP = "Sends your child's voice to the cloud for more accurate listening"

private const val BETTER_LISTENING_DISCLOSURE =
    "With Better listening on, your child's voice is sent to the cloud to be turned into words, " +
        "instead of that happening on this phone. This app doesn't save recordings. " +
        "You can turn it off here at any time."

/**
 * Grown-up settings (iOS SettingsView, away-from-home parts): keys with built-in/own status,
 * the "better listening" switch with an in-context disclosure, Elsie's voice, the privacy
 * note, and resetting consent.
 */
@Composable
fun SettingsScreen(vm: TinyTalkViewModel, onBack: () -> Unit) {
    val s by vm.settings.collectAsState()
    LaunchedEffect(Unit) { vm.refreshSettings() }
    var confirmCloud by rememberSaveable { mutableStateOf(false) }
    var confirmReset by rememberSaveable { mutableStateOf(false) }
    var pickVoice by rememberSaveable { mutableStateOf(false) }

    Column(Modifier.fillMaxSize().background(TTA.Palette.OuterPaper)) {
        Row(
            Modifier.fillMaxWidth().background(TTA.Palette.Paper).statusBarsPadding()
                .padding(horizontal = 20.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            IconTile(onBack, size = 44.dp) {
                Text("‹", style = TTA.Typography.display(26f), color = TTA.Palette.Wood,
                    modifier = Modifier.semantics { contentDescription = "Back" })
            }
            Text("Grown-up settings", style = TTA.Typography.display(22f), color = TTA.Palette.Ink)
        }
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            Card("ELSIE'S THINKING") {
                Help("Elsie thinks up the story in the cloud. The app comes with a built-in key; you can use your own instead.")
                KeyField("GROQ API KEY", KeyName.GROQ, s.keyStatus[KeyName.GROQ], vm)
                KeyField("API NINJAS KEY (ANIMAL FACTS)", KeyName.API_NINJAS, s.keyStatus[KeyName.API_NINJAS], vm)
                Help("Optional, for storybook pictures in a later version of the app (stored now, not used yet).")
                KeyField("CLOUDFLARE ACCOUNT ID", KeyName.CLOUDFLARE_ACCOUNT_ID, s.keyStatus[KeyName.CLOUDFLARE_ACCOUNT_ID], vm)
                KeyField("CLOUDFLARE API TOKEN", KeyName.CLOUDFLARE_TOKEN, s.keyStatus[KeyName.CLOUDFLARE_TOKEN], vm)
            }

            Card("LISTENING") {
                val on = s.sttMode == SttMode.CLOUD
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Better listening", style = TTA.Typography.body(16f, FontWeight.SemiBold), color = TTA.Palette.Ink)
                        Help(BETTER_LISTENING_HELP)
                    }
                    Switch(
                        checked = on,
                        onCheckedChange = { want -> if (want) confirmCloud = true else vm.useOnDeviceListening() },
                        colors = SwitchDefaults.colors(checkedTrackColor = TTA.Palette.Wood),
                    )
                }
                Text(
                    if (on) "On: your child's voice is sent to the cloud to be turned into words."
                    else "Off: your child's voice is turned into words on this phone.",
                    style = TTA.Typography.body(12.5f),
                    color = if (on) TTA.Palette.Alert else TTA.Palette.InkSoft,
                )
            }

            Card("ELSIE'S VOICE") {
                val current = s.voices.firstOrNull { it.name == s.voiceName }
                val label = when {
                    s.voiceName == null -> "Default voice"
                    current != null -> voiceLabel(current.localeName, current.name)
                    s.voicesLoading -> "Loading voices…"
                    else -> "Default voice (chosen voice not installed)"
                }
                Row(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(11.dp)).background(TTA.Palette.Paper)
                        .clickable(role = Role.Button) { pickVoice = true }.padding(11.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(label, style = TTA.Typography.body(15f), color = TTA.Palette.Ink, modifier = Modifier.weight(1f))
                    Text("›", style = TTA.Typography.display(20f), color = TTA.Palette.InkSoft)
                }
                Help("Voices installed on this phone. Changes from Elsie's next sentence.")
            }

            Card("PRIVACY") {
                Text(consentBody(), style = TTA.Typography.body(14f), color = TTA.Palette.Ink)
                Help(
                    if (s.sttMode == SttMode.CLOUD) "Better listening is on, so your child's voice is also sent to the cloud (see Listening above)."
                    else "Better listening is off.",
                )
                ChunkyButton(
                    "Reset consent", { confirmReset = true },
                    fill = TTA.Palette.Cream, edge = TTA.Palette.Wood.copy(alpha = 0.35f),
                    foreground = TTA.Palette.Alert, fontSize = 15f,
                )
                Help("Stops Elsie listening and shows the \"Before we start\" note again.")
            }
        }
    }

    if (confirmCloud) {
        AlertDialog(
            onDismissRequest = { confirmCloud = false },
            title = { Text("Send your child's voice to the cloud?") },
            text = { Text(BETTER_LISTENING_DISCLOSURE) },
            confirmButton = {
                TextButton(onClick = { confirmCloud = false; vm.enableCloudListening() }) { Text("Turn on") }
            },
            dismissButton = { TextButton(onClick = { confirmCloud = false }) { Text("Keep it off") } },
        )
    }
    if (confirmReset) {
        AlertDialog(
            onDismissRequest = { confirmReset = false },
            title = { Text("Reset consent?") },
            text = { Text("Elsie stops listening and nothing more is sent until a grown-up agrees again.") },
            confirmButton = {
                TextButton(onClick = { confirmReset = false; vm.revokeConsent() }) { Text("Reset") }
            },
            dismissButton = { TextButton(onClick = { confirmReset = false }) { Text("Cancel") } },
        )
    }
    if (pickVoice) {
        AlertDialog(
            onDismissRequest = { pickVoice = false },
            title = { Text("Elsie's voice") },
            text = {
                LazyColumn(Modifier.heightIn(max = 380.dp)) {
                    item { VoiceRow("Default voice", s.voiceName == null) { vm.setVoice(null); pickVoice = false } }
                    items(s.voices, key = { it.name }) { v ->
                        VoiceRow(voiceLabel(v.localeName, v.name), s.voiceName == v.name) { vm.setVoice(v.name); pickVoice = false }
                    }
                    if (s.voicesLoading) item { Help("Loading voices…") }
                    else if (s.voices.isEmpty()) item { Help("No offline English voices found; Elsie uses the default voice.") }
                }
            },
            confirmButton = { TextButton(onClick = { pickVoice = false }) { Text("Done") } },
        )
    }
}

private fun voiceLabel(localeName: String, name: String) = "$localeName · $name"

@Composable
private fun VoiceRow(label: String, selected: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().selectable(selected = selected, role = Role.RadioButton, onClick = onClick)
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        RadioButton(selected = selected, onClick = null)
        Text(label, style = TTA.Typography.body(14f), color = TTA.Palette.Ink, modifier = Modifier.padding(start = 8.dp))
    }
}

@Composable
private fun Card(title: String, content: @Composable () -> Unit) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(TTA.Palette.Cream).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(title, style = TTA.Typography.display(12f).copy(letterSpacing = 1.5.sp), color = TTA.Palette.InkSoft)
        content()
    }
}

@Composable
private fun Help(text: String) {
    Text(text, style = TTA.Typography.body(12.5f), color = TTA.Palette.InkSoft)
}

/**
 * One key: status ("Using the built-in key" / "Using your key"), an empty masked field (the
 * stored or baked value is never shown), Save, and "Use built-in key" to clear the override.
 */
@Composable
private fun KeyField(label: String, name: KeyName, status: KeyStatus?, vm: TinyTalkViewModel) {
    var text by remember(name) { mutableStateOf("") }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(label, style = TTA.Typography.display(12f).copy(letterSpacing = 1.5.sp), color = TTA.Palette.InkSoft)
        Text(
            status?.label ?: "Checking…",
            style = TTA.Typography.body(13f, FontWeight.SemiBold),
            color = if (status == KeyStatus.NONE) TTA.Palette.Alert else TTA.Palette.Teal,
            modifier = Modifier.semantics { stateDescription = status?.label ?: "" },
        )
        OutlinedTextField(
            value = text,
            onValueChange = { text = it },
            placeholder = { Text("Paste a new key") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
            modifier = Modifier.fillMaxWidth(),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextButton(
                onClick = { vm.saveKey(name, text.trim()); text = "" },
                enabled = text.isNotBlank(),
            ) { Text("Save") }
            TextButton(
                onClick = { vm.saveKey(name, null); text = "" },
                enabled = status == KeyStatus.YOURS,
            ) { Text("Use built-in key") }
        }
    }
}

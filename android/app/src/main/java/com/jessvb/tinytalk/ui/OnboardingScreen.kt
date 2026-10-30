package com.jessvb.tinytalk.ui

import android.Manifest
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.blur
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp

private const val CONSENT_TITLE = "Before we start"

/** Author-approved wording (plan Task 9), verbatim; bold marks the key facts. */
internal fun consentBody(): AnnotatedString = buildAnnotatedString {
    val bold = SpanStyle(fontWeight = FontWeight.Bold)
    append("Tiny Talk Adventures lets your child make up stories out loud with Elsie. To do that, your child's voice is turned into words ")
    withStyle(bold) { append("on this phone") }
    append(", and ")
    withStyle(bold) { append("this app doesn't save recordings") }
    append(". The words of the story conversation are sent to ")
    withStyle(bold) { append("the cloud") }
    append(" so Elsie can think of what to say next. Stories stay on this phone. The app creator's account pays for the cloud service for now; you can enter your own key in Settings. By tapping \"I agree\" you're saying you're a parent or guardian and you're happy with this.")
}

/**
 * iOS-style welcome page, then the parent consent page. Granting consent stores it first;
 * the microphone permission is requested afterwards, only as a permission prompt (no audio starts).
 * Denial is not an error: the app proceeds to Landing either way.
 */
@Composable
fun OnboardingScreen(navigator: Navigator, declinedNotice: Boolean) {
    var step by rememberSaveable { mutableStateOf(0) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { /* granted or denied: both fine */ }

    BackHandler(enabled = step == 1) { step = 0 }

    Box(Modifier.fillMaxSize()) {
        ElsieImage(zoom = 1.3f, anchorX = 0.5f, anchorY = 0.32f, modifier = Modifier.fillMaxSize().blur(3.dp))
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    listOf(
                        TTA.Palette.Paper.copy(alpha = 0.82f),
                        TTA.Palette.Paper.copy(alpha = 0.4f),
                        TTA.Palette.WoodDark.copy(alpha = 0.78f),
                    ),
                ),
            ),
        )
        Column(
            Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = TTA.Spacing.ScreenH),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Spacer(Modifier.height(24.dp))
            ElsieAvatar(ElsieMood.IDLE, diameter = 132.dp)
            if (step == 0) {
                WelcomePage(onNext = { step = 1 })
            } else {
                ConsentPage(
                    declinedNotice = declinedNotice,
                    onAgree = {
                        navigator.acceptConsent()
                        permission.launch(Manifest.permission.RECORD_AUDIO)
                    },
                    onDecline = { navigator.declineConsent() },
                )
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun WelcomePage(onNext: () -> Unit) {
    Text(
        "Hello, I'm Elsie!",
        style = TTA.Typography.display(34f),
        color = TTA.Palette.Cream,
        textAlign = TextAlign.Center,
        modifier = Modifier.padding(top = 20.dp),
    )
    Text(
        "I love facts and I love stories. If you talk, I'll listen — and we'll write a story together, out loud.",
        style = TTA.Typography.body(17f),
        color = TTA.Palette.Paper,
        textAlign = TextAlign.Center,
        modifier = Modifier.padding(top = 12.dp),
    )
    TTACard(Modifier.padding(top = 22.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            Box(
                Modifier.size(44.dp).clip(RoundedCornerShape(14.dp)).background(TTA.Palette.Teal),
                contentAlignment = Alignment.Center,
            ) { Text("♪", style = TTA.Typography.display(20f), color = TTA.Palette.Cream) }
            Column {
                Text("Can I hear you?", style = TTA.Typography.display(16f), color = TTA.Palette.Ink)
                // Diverges from iOS ("Nothing ever leaves your house"): not true on Android, see consent page.
                Text(
                    "Tiny Talk needs the microphone so Elsie can hear your story.",
                    style = TTA.Typography.body(13.5f),
                    color = TTA.Palette.InkSoft,
                )
            }
        }
    }
    PrimaryButton("Yes, let's talk!", onNext, Modifier.padding(top = 16.dp))
}

@Composable
private fun ConsentPage(declinedNotice: Boolean, onAgree: () -> Unit, onDecline: () -> Unit) {
    Text(
        CONSENT_TITLE,
        style = TTA.Typography.display(30f),
        color = TTA.Palette.Cream,
        textAlign = TextAlign.Center,
        modifier = Modifier.padding(top = 20.dp),
    )
    TTACard(Modifier.padding(top = 16.dp)) {
        Text(consentBody(), style = TTA.Typography.body(15f), color = TTA.Palette.Ink)
    }
    if (declinedNotice) {
        Text(
            Navigator.DECLINED_MESSAGE,
            style = TTA.Typography.display(15f, FontWeight.SemiBold),
            color = TTA.Palette.Cream,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
        )
    }
    PrimaryButton("I agree", onAgree, Modifier.padding(top = 16.dp))
    SecondaryButton("Not now", onDecline, Modifier.padding(top = 4.dp))
}

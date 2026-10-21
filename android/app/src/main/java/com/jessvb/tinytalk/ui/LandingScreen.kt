package com.jessvb.tinytalk.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun LandingScreen(onCreateStory: () -> Unit, onSettings: () -> Unit) {
    Box(Modifier.fillMaxSize()) {
        ElsieImage(zoom = 1.1f, anchorX = 0.46f, anchorY = 0.4f, modifier = Modifier.fillMaxSize())
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    listOf(
                        TTA.Palette.WoodDark.copy(alpha = 0.1f),
                        TTA.Palette.WoodDark.copy(alpha = 0.32f),
                        TTA.Palette.WoodDark.copy(alpha = 0.88f),
                    ),
                ),
            ),
        )
        Column(
            Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Row(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 8.dp), horizontalArrangement = Arrangement.End) {
                IconTile(onSettings) {
                    // No icons dependency: a text glyph stands in for the iOS gearshape.
                    Text("⚙", style = TTA.Typography.body(24f), color = TTA.Palette.Wood,
                        modifier = Modifier.semantics { contentDescription = "Settings" })
                }
            }
            SignPlaque(Modifier.padding(top = 24.dp))
            Spacer(Modifier.weight(1f))
            Column(Modifier.padding(horizontal = 26.dp).padding(bottom = 30.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                PrimaryButton("Create a Story", onCreateStory)
                // Phase 2: shown but disabled, clearly labelled.
                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                    Box(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(TTA.Radius.Wide))
                            .background(TTA.Palette.Cream.copy(alpha = 0.14f)).padding(vertical = 18.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text("Read Stories", style = TTA.Typography.display(22f), color = TTA.Palette.Cream.copy(alpha = 0.55f))
                    }
                    Text(
                        "Coming later — you'll be able to read your stories here!",
                        style = TTA.Typography.story(13.5f, italic = true),
                        color = TTA.Palette.Paper,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(top = 9.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun SignPlaque(modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(TTA.Radius.Plaque)
    Column(
        modifier
            .rotate(-1.4f)
            .shadow(14.dp, shape, ambientColor = Color.Black.copy(alpha = 0.3f), spotColor = Color.Black.copy(alpha = 0.3f))
            .clip(shape)
            .background(Brush.verticalGradient(listOf(TTA.Palette.Wood, TTA.Palette.WoodDark)))
            .border(1.dp, TTA.Palette.WoodDark, shape)
            .padding(horizontal = 26.dp, vertical = 14.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text("TINY TALK", style = TTA.Typography.display(14f).copy(letterSpacing = 3.sp), color = TTA.Palette.Gold)
        Text("Adventures", style = TTA.Typography.display(32f), color = TTA.Palette.Cream)
        Text("stories you say out loud", style = TTA.Typography.story(12f, italic = true), color = TTA.Palette.Gold)
    }
}

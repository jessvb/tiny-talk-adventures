package com.jessvb.tinytalk.ui

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.jessvb.tinytalk.R
import androidx.compose.foundation.Image as ComposeImage

/**
 * Visual language ported from ios/TinyTalkApp/TinyTalkApp/DesignSystem.swift ("Storybook-literal").
 * iOS uses system rounded/serif/default designs (Baloo 2 / Lora are not bundled there either).
 * Compose has no "rounded" system design, so display text uses the default sans at ExtraBold
 * (closest free equivalent, no font files bundled); story text uses FontFamily.Serif.
 */
object TTA {
    object Palette {
        val OuterPaper = Color(0xFFEFE7DC)
        val Paper = Color(0xFFF6ECD8)
        val Cream = Color(0xFFFFF8EC)
        val Ink = Color(0xFF3A2A1C)
        val InkSoft = Color(0xFF6B5442)
        val Wood = Color(0xFF8B5E34)
        val WoodDark = Color(0xFF6B4526)
        val Scarf = Color(0xFFC9612E)
        val ScarfShadow = Color(0xFF8F3F18)
        val Teal = Color(0xFF2F7F78)
        val TealShadow = Color(0xFF1D5F59)
        val TealSurface = Color(0xFFE7F2F0)
        val Gold = Color(0xFFD9A327)
        val Alert = Color(0xFF96382C)
        val AlertShadow = Color(0xFF7D2C22)
    }

    object Typography {
        /** Anything a child taps: chunky, heavy. */
        fun display(size: Float, weight: FontWeight = FontWeight.ExtraBold) =
            TextStyle(fontFamily = FontFamily.SansSerif, fontWeight = weight, fontSize = size.sp)

        /** Anything a child reads. */
        fun story(size: Float, italic: Boolean = false) = TextStyle(
            fontFamily = FontFamily.Serif,
            fontWeight = FontWeight.Normal,
            fontSize = size.sp,
            fontStyle = if (italic) FontStyle.Italic else FontStyle.Normal,
        )

        /** Captions, settings rows. */
        fun body(size: Float, weight: FontWeight = FontWeight.Normal) =
            TextStyle(fontFamily = FontFamily.Default, fontWeight = weight, fontSize = size.sp)
    }

    object Radius {
        val Button = 22.dp
        val Card = 22.dp
        val Plaque = 18.dp
        val Wide = 24.dp
    }

    object Spacing {
        val ScreenH = 34.dp
        val ButtonEdge = 5.dp
        val MinTap = 56.dp
    }
}

/** Chunky physical-feeling button: solid fill with a 5dp bottom edge; presses down onto the edge. */
@Composable
fun ChunkyButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    fill: Color = TTA.Palette.Scarf,
    edge: Color = TTA.Palette.ScarfShadow,
    foreground: Color = TTA.Palette.Cream,
    fontSize: Float = 20f,
    enabled: Boolean = true,
) {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val shape = RoundedCornerShape(TTA.Radius.Button)
    Box(
        modifier
            .fillMaxWidth()
            .padding(bottom = TTA.Spacing.ButtonEdge)
            .offset(y = if (pressed && enabled) TTA.Spacing.ButtonEdge else 0.dp)
            .alpha(if (enabled) 1f else 0.5f),
    ) {
        Box(Modifier.matchParentSize().offset(y = TTA.Spacing.ButtonEdge).clip(shape).background(edge))
        Box(
            Modifier
                .fillMaxWidth()
                .heightIn(min = TTA.Spacing.MinTap)
                .clip(shape)
                .background(fill)
                .clickable(interactionSource = source, indication = null, enabled = enabled, onClick = onClick)
                .padding(vertical = 16.dp, horizontal = 16.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(text, style = TTA.Typography.display(fontSize), color = foreground)
        }
    }
}

@Composable
fun PrimaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) =
    ChunkyButton(text, onClick, modifier, enabled = enabled)

@Composable
fun SecondaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) =
    ChunkyButton(text, onClick, modifier, TTA.Palette.Teal, TTA.Palette.TealShadow, enabled = enabled)

/** Small square icon button (gear etc.): cream on paper with a soft wood border. */
@Composable
fun IconTile(onClick: () -> Unit, modifier: Modifier = Modifier, size: Dp = 48.dp, content: @Composable () -> Unit) {
    val shape = RoundedCornerShape(size * 0.34f)
    Box(
        modifier
            .size(size)
            .clip(shape)
            .background(TTA.Palette.Cream)
            .border(BorderStroke(1.5.dp, TTA.Palette.Wood.copy(alpha = 0.32f)), shape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { content() }
}

/** Paper-coloured rounded card. */
@Composable
fun TTACard(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Box(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(TTA.Radius.Card))
            .background(TTA.Palette.Paper.copy(alpha = 0.94f))
            .padding(PaddingValues(16.dp)),
    ) { content() }
}

/**
 * Cropped/zoomed view into the Elsie photo, mirroring ElsieImage.swift: the source (1408x768) is
 * scaled to cover the container at [zoom]x and panned so (anchorX, anchorY) of the source sits at the centre.
 */
@Composable
fun ElsieImage(
    zoom: Float,
    modifier: Modifier = Modifier,
    anchorX: Float = 0.5f,
    anchorY: Float = 0.5f,
    colorFilter: ColorFilter? = null,
) {
    val sourceAspect = 1408f / 768f
    BoxWithConstraints(modifier.clipToBounds()) {
        val cw = maxWidth
        val ch = maxHeight
        val w: Dp
        val h: Dp
        if (cw / ch > sourceAspect) {
            w = cw * zoom; h = w / sourceAspect
        } else {
            h = ch * zoom; w = h * sourceAspect
        }
        ComposeImage(
            painter = painterResource(R.drawable.elsie),
            contentDescription = null,
            contentScale = ContentScale.FillBounds,
            colorFilter = colorFilter,
            modifier = Modifier
                .requiredSize(w, h)
                .align(Alignment.Center)
                .offset(x = -w * (anchorX - 0.5f), y = -h * (anchorY - 0.5f)),
        )
    }
}

/** What Elsie is doing; the Story screen drives this later (mirrors iOS SessionState). */
enum class ElsieMood { IDLE, LISTENING, WAITING_FOR_REPLY, SPEAKING }

@Composable
fun ElsieAvatar(
    mood: ElsieMood,
    modifier: Modifier = Modifier,
    isMuted: Boolean = false,
    diameter: Dp = 74.dp,
) {
    val ringColor = when {
        isMuted -> TTA.Palette.Alert.copy(alpha = 0.35f)
        mood == ElsieMood.LISTENING -> TTA.Palette.Teal.copy(alpha = 0.55f)
        mood == ElsieMood.SPEAKING -> TTA.Palette.Scarf.copy(alpha = 0.5f)
        mood == ElsieMood.WAITING_FOR_REPLY -> TTA.Palette.Gold.copy(alpha = 0.4f)
        else -> TTA.Palette.Wood.copy(alpha = 0.18f)
    }
    val animating = !isMuted && mood != ElsieMood.IDLE
    val t = rememberInfiniteTransition(label = "elsie-ring")
    val phase by t.animateFloat(
        0f, 1f,
        infiniteRepeatable(tween(2100, easing = LinearEasing), RepeatMode.Restart),
        label = "phase",
    )
    val p = if (animating) phase else 0f
    Box(modifier.size(diameter), contentAlignment = Alignment.Center) {
        Box(
            Modifier
                .size(diameter)
                .scale(1f + 0.16f * p)
                .alpha(if (animating) 0.55f * (1f - p) else 0.55f)
                .background(ringColor, CircleShape),
        )
        ElsieImage(
            zoom = 2.1f,
            anchorY = 0.44f,
            colorFilter = if (isMuted) ColorFilter.colorMatrix(ColorMatrix().apply { setToSaturation(0f) }) else null,
            modifier = Modifier
                .size(diameter - 12.dp)
                .shadow(6.dp, CircleShape)
                .clip(CircleShape)
                .border(3.dp, TTA.Palette.Cream, CircleShape),
        )
    }
}

package com.jessvb.tinytalk.spike

import android.Manifest
import android.content.pm.PackageManager
import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.Button
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.foundation.layout.Row
import androidx.compose.ui.Alignment
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.sqrt

private const val TAG = "TinyTalkSpike"

const val TEST_PARAGRAPH =
    "Once upon a time, a little fox found a shiny red key in the garden. " +
        "She wondered what it could possibly open. " +
        "Behind the old oak tree, she spotted a tiny wooden door! " +
        "Did anyone know that doors could hide whole worlds? " +
        "The fox smiled, turned the key, and stepped inside."

@Composable
fun SpikeScreen() {
    val context = LocalContext.current
    val main = remember { Handler(Looper.getMainLooper()) }
    var logLines by remember { mutableStateOf(listOf<String>()) }
    var level by remember { mutableStateOf(0f) }
    var running by remember { mutableStateOf(false) }
    var denied by remember { mutableStateOf(false) }
    var unavailable by remember { mutableStateOf(false) }
    var commMode by remember { mutableStateOf(SentenceTts.DEFAULT_COMMUNICATION_MODE) }
    var bargeRunning by remember { mutableStateOf(false) }
    var bargeSummary by remember { mutableStateOf("") }
    val bargeRef = remember { AtomicReference<BargeInSpike?>(null) }

    val log: (String) -> Unit = remember {
        { msg ->
            Log.i(TAG, msg)
            main.post { logLines = logLines + msg }
        }
    }
    var probability by remember { mutableStateOf(0f) }
    val vad = remember { SileroVad(context) }
    val detector = remember { SpeechDetector() }
    val mic = remember {
        // onFrame runs on the capture thread only; vad/detector are touched nowhere else while running.
        var inferenceFailures = 0
        var frameCount = 0
        var totalMs = 0.0
        MicCapture(
            onFrame = { frame ->
                var sum = 0.0
                for (s in frame) sum += s.toDouble() * s
                val rms = sqrt(sum / frame.size).toFloat() / Short.MAX_VALUE
                main.post { level = rms }
                try {
                    val t0 = System.nanoTime()
                    val p = vad.probability(frame)
                    totalMs += (System.nanoTime() - t0) / 1e6
                    frameCount++
                    if (frameCount % 100 == 0) log("VAD mean inference %.2f ms".format(totalMs / frameCount))
                    main.post { probability = p }
                    when (detector.onProbability(p)) {
                        SpeechEvent.SpeechStart -> {
                            log("SpeechStart @ ${System.currentTimeMillis()}")
                            bargeRef.get()?.onSpeechStart()
                        }
                        SpeechEvent.SpeechEnd -> log("SpeechEnd @ ${System.currentTimeMillis()}")
                        SpeechEvent.None -> {}
                    }
                } catch (e: Exception) {
                    if (inferenceFailures++ < 5) log("VAD inference failed: $e")
                }
            },
            onLog = log,
        )
    }
    // Rebuilt when the communication-mode toggle flips (it is fixed at SentenceTts construction).
    // No AudioTrack/AudioRecord session sharing: audioSessionIdProvider keeps its default (0).
    val tts = remember(commMode) { SentenceTts(context, log, communicationMode = commMode) }
    val barge = remember(tts) {
        BargeInSpike(
            tts = tts,
            startMic = { vad.reset(); detector.reset(); mic.start() },
            micRunning = { mic.isRunning },
            stopMic = { mic.stop() },
            onLog = log,
            onSummary = { s -> main.post { bargeSummary = s } },
        )
    }
    LaunchedEffect(bargeRunning, barge) {
        while (bargeRunning) {
            barge.checkMic()
            kotlinx.coroutines.delay(250)
        }
    }
    DisposableEffect(tts) {
        onDispose {
            bargeRef.compareAndSet(barge, null)
            barge.stop()
            tts.close()
        }
    }
    DisposableEffect(Unit) {
        onDispose {
            mic.stop()
            vad.close()
        }
    }

    fun startMic() {
        vad.reset()
        detector.reset()
        running = mic.start()
        unavailable = !running
        if (unavailable) log("Microphone unavailable")
    }

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) {
            denied = false
            startMic()
        } else {
            denied = true
            log("Microphone permission denied")
        }
    }

    val listState = rememberLazyListState()
    LaunchedEffect(logLines.size) {
        if (logLines.isNotEmpty()) listState.animateScrollToItem(logLines.size - 1)
    }

    Column(
        Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("Tiny Talk spike")
        Button(onClick = {
            if (running) {
                mic.stop()
                running = false
            } else if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
            ) {
                denied = false
                startMic()
            } else {
                launcher.launch(Manifest.permission.RECORD_AUDIO)
            }
        }) { Text(if (running) "Stop mic" else "Start mic") }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Switch(checked = commMode, enabled = !bargeRunning, onCheckedChange = { commMode = it })
            Text("communicationMode ${if (commMode) "ON" else "OFF"}")
        }
        Button(onClick = {
            if (bargeRunning) {
                bargeRef.set(null)
                barge.stop()
                bargeRunning = false
                running = mic.isRunning
            } else if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
            ) {
                val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                log("--- barge-in test: model=${Build.MODEL} SDK=${Build.VERSION.SDK_INT} communicationMode=${if (commMode) "ON" else "OFF"} ---")
                bargeRef.set(barge)
                bargeRunning = true
                barge.start(TEST_PARAGRAPH)
                running = mic.isRunning
                log("AEC available=${mic.aecAvailable} enabled=${mic.aecEnabled}; media volume ${am.getStreamVolume(AudioManager.STREAM_MUSIC)}/${am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)}; call-stream volume ${am.getStreamVolume(AudioManager.STREAM_VOICE_CALL)}/${am.getStreamMaxVolume(AudioManager.STREAM_VOICE_CALL)}")
            } else {
                log("Grant mic permission first (tap Start mic), then run the barge-in test")
            }
        }) { Text(if (bargeRunning) "Stop barge-in test" else "Barge-in test") }
        if (bargeSummary.isNotEmpty()) {
            Text("Barge-in: $bargeSummary")
            Text("(software stop only; excludes ~100 ms VAD attack and output-buffer latency)")
        }
        Text(
            "Test script (phone speaker, no headphones, quiet room, ~40 cm): " +
                "1) stay SILENT through the whole paragraph, x3 -> false triggers must be 0. " +
                "2) say \"stop, wait!\" ~2 sentences in, x5 -> stops about 1 s or less. " +
                "3) repeat 1 at medium and max media volume. Tap Stop between runs.",
        )
        Button(onClick = { tts.speak(TEST_PARAGRAPH) }) { Text("Speak test paragraph") }
        Button(onClick = { tts.stop() }) { Text("Stop speaking") }
        if (denied) Text("Microphone permission denied")
        if (unavailable) Text("Microphone unavailable")
        Text("Level: ${"%.3f".format(level)}  Speech prob: ${"%.2f".format(probability)}")
        LazyColumn(state = listState, modifier = Modifier.weight(1f)) {
            items(logLines) { Text(it) }
        }
    }
}

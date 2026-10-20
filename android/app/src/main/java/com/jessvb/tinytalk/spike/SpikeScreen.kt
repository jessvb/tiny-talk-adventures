package com.jessvb.tinytalk.spike

import android.Manifest
import android.content.pm.PackageManager
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
import androidx.compose.material3.Text
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
                        SpeechEvent.SpeechStart -> log("SpeechStart @ ${System.currentTimeMillis()}")
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
    val tts = remember { SentenceTts(context, log) }
    DisposableEffect(Unit) {
        onDispose {
            tts.close()
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

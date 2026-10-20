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

@Composable
fun SpikeScreen() {
    val context = LocalContext.current
    val main = remember { Handler(Looper.getMainLooper()) }
    var logLines by remember { mutableStateOf(listOf<String>()) }
    var level by remember { mutableStateOf(0f) }
    var running by remember { mutableStateOf(false) }
    var denied by remember { mutableStateOf(false) }

    val log: (String) -> Unit = remember {
        { msg ->
            Log.i(TAG, msg)
            main.post { logLines = logLines + msg }
        }
    }
    val mic = remember {
        MicCapture(
            onFrame = { frame ->
                var sum = 0.0
                for (s in frame) sum += s.toDouble() * s
                val rms = sqrt(sum / frame.size).toFloat() / Short.MAX_VALUE
                main.post { level = rms }
            },
            onLog = log,
        )
    }
    DisposableEffect(Unit) { onDispose { mic.stop() } }

    fun startMic() {
        mic.start()
        running = true
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
        if (denied) Text("Microphone permission denied")
        Text("Level: ${"%.3f".format(level)}")
        LazyColumn(state = listState, modifier = Modifier.weight(1f)) {
            items(logLines) { Text(it) }
        }
    }
}

package com.jessvb.tinytalk.stt

import android.content.Context
import android.os.SystemClock
import android.util.Log
import com.jessvb.tinytalk.core.stt.OnDeviceTranscriptionException
import com.jessvb.tinytalk.core.stt.TranscriptCleaner
import com.jessvb.tinytalk.voice.ListeningAvailability
import com.jessvb.tinytalk.voice.WarmTranscriber
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineWhisperModelConfig
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Whisper tiny.en (int8) through sherpa-onnx, entirely on the phone: the child's audio never
 * leaves the device and is never written to disk (in memory only). Same config as the Phase B
 * spike harness (android/stt-spike-app), which measured a warm median of 0.70 s on the Pixel 3.
 *
 * Lifecycle: construct cheaply, call [load] once on a background thread at app start (it blocks
 * for ~1-2 s, longer on the first launch after an install while the model is unpacked), then
 * [transcribe] as often as needed; [close] when the app container goes away.
 *
 * Threading: ALL native work (load, every decode, release) runs on ONE dedicated thread
 * ([native]), so decodes are serialized and release can never free the recognizer under a
 * running decode. [transcribe] awaits its decode with [suspendCancellableCoroutine]: when the
 * caller is cancelled (barge-in, a newer utterance, DemoSession's 60 s withTimeout) the awaiting
 * coroutine ends at once; the native decode, which cannot be interrupted, finishes in the
 * background and its result is dropped. A decode whose caller was cancelled before its turn on
 * the thread is skipped entirely. The next decode always waits for the previous one.
 *
 * Privacy: logs only lengths and timings, never transcript text or audio.
 */
class OnDeviceTranscriber(
    context: Context,
    private val threads: Int = 2,
    private val log: (String) -> Unit = { Log.i(TAG, it) },
) : WarmTranscriber, AutoCloseable {
    private val appContext = context.applicationContext

    private val native: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "on-device-stt").apply { isDaemon = true }
    }

    /** Touched only on the [native] thread. */
    private var recognizer: OfflineRecognizer? = null

    private val _availability = MutableStateFlow(ListeningAvailability.LOADING)
    override val availability: StateFlow<ListeningAvailability> = _availability.asStateFlow()

    val isLoaded: Boolean get() = _availability.value == ListeningAvailability.READY

    @Volatile private var closed = false

    /**
     * Loads the model (blocking; call off the main thread). Idempotent. Throws
     * [OnDeviceTranscriptionException] with a clear message if the model is missing or cannot
     * load; [availability] then stays FAILED (no retry loop: restarting the app retries).
     * Returns the load time in ms (0 if it was already loaded).
     */
    fun load(): Long {
        val future = try {
            native.submit<Long> { loadOnNativeThread() }
        } catch (e: RejectedExecutionException) {
            throw OnDeviceTranscriptionException("on-device listening was already closed", e)
        }
        return try {
            future.get()
        } catch (e: ExecutionException) {
            throw e.cause as? OnDeviceTranscriptionException
                ?: OnDeviceTranscriptionException("on-device listening could not load", e.cause)
        }
    }

    private fun loadOnNativeThread(): Long {
        if (recognizer != null) return 0
        if (closed) throw OnDeviceTranscriptionException("on-device listening was already closed")
        val t0 = SystemClock.elapsedRealtime()
        try {
            val dir = ModelInstaller.install(appContext, log)
            val config = OfflineRecognizerConfig(
                modelConfig = OfflineModelConfig(
                    whisper = OfflineWhisperModelConfig(
                        encoder = File(dir, ENCODER).path,
                        decoder = File(dir, DECODER).path,
                        language = "en",
                        task = "transcribe",
                    ),
                    tokens = File(dir, TOKENS).path,
                    numThreads = threads,
                    modelType = "whisper",
                ),
            )
            // File paths with a null AssetManager, exactly as the spike harness loads it.
            recognizer = OfflineRecognizer(null, config)
        } catch (t: Throwable) { // includes UnsatisfiedLinkError from the native library
            _availability.value = ListeningAvailability.FAILED
            log("on-device listening failed to load: ${t.javaClass.simpleName}")
            throw t as? OnDeviceTranscriptionException
                ?: OnDeviceTranscriptionException("on-device listening could not load the speech model", t)
        }
        val ms = SystemClock.elapsedRealtime() - t0
        log("on-device listening loaded in $ms ms (threads=$threads)")
        _availability.value = ListeningAvailability.READY
        return ms
    }

    override suspend fun transcribe(pcm16: ShortArray, sampleRate: Int): String {
        if (sampleRate != SAMPLE_RATE) {
            // The app always records 16 kHz mono (MicCapture); anything else is a wiring bug.
            throw OnDeviceTranscriptionException("expected $SAMPLE_RATE Hz audio, got $sampleRate Hz")
        }
        if (closed) throw OnDeviceTranscriptionException("on-device listening was already closed")
        if (!isLoaded) throw OnDeviceTranscriptionException("on-device listening is not loaded")
        val samples = pcm16ToFloat(pcm16)
        val raw = suspendCancellableCoroutine { cont ->
            val task = Runnable {
                if (!cont.isActive) return@Runnable // superseded before its turn: skip the decode
                // A resume after cancellation is ignored, so a late result is simply dropped.
                cont.resumeWith(runCatching { decodeOnNativeThread(samples) })
            }
            try {
                native.execute(task)
            } catch (e: RejectedExecutionException) {
                cont.resumeWith(Result.failure(OnDeviceTranscriptionException("on-device listening was already closed", e)))
            }
        }
        return TranscriptCleaner.clean(raw)
    }

    private fun decodeOnNativeThread(samples: FloatArray): String {
        val rec = recognizer ?: throw OnDeviceTranscriptionException("on-device listening is not loaded")
        val t0 = SystemClock.elapsedRealtime()
        try {
            val stream = rec.createStream()
            try {
                stream.acceptWaveform(samples, SAMPLE_RATE)
                rec.decode(stream)
                val text = rec.getResult(stream).text
                log("on-device decode: ${samples.size * 1000L / SAMPLE_RATE} ms audio in ${SystemClock.elapsedRealtime() - t0} ms, ${text.length} chars")
                return text
            } finally {
                stream.release()
            }
        } catch (t: Throwable) {
            log("on-device decode failed: ${t.javaClass.simpleName}")
            throw t as? OnDeviceTranscriptionException
                ?: OnDeviceTranscriptionException("on-device listening failed to decode", t)
        }
    }

    /** Releases the recognizer AFTER any decode already running, then stops the thread. */
    override fun close() {
        synchronized(this) {
            if (closed) return
            closed = true
        }
        _availability.value = ListeningAvailability.FAILED
        try {
            native.execute {
                recognizer?.release()
                recognizer = null
            }
        } catch (_: RejectedExecutionException) {
        }
        native.shutdown()
    }

    /**
     * Unpacks the model from the APK's assets (assets/stt/whisper-tiny.en/, put there by the
     * sttModelAssets Gradle task) into no-backup app storage, once per installed APK version:
     * sherpa-onnx loads from file paths, as in the spike harness. Each file is written to a
     * temporary name and renamed, and a marker records which APK it came from, so an
     * interrupted unpack is redone rather than loaded half-written.
     */
    internal object ModelInstaller {
        fun install(context: Context, log: (String) -> Unit): File {
            val dir = File(context.noBackupFilesDir, "stt/whisper-tiny.en")
            val marker = File(dir, ".installed")
            val stamp = apkStamp(context)
            val present = FILES.all { File(dir, it).length() > 0 }
            if (present && marker.isFile && marker.readText() == stamp) return dir

            val t0 = SystemClock.elapsedRealtime()
            dir.mkdirs()
            marker.delete()
            for (name in FILES) {
                val tmp = File(dir, "$name.tmp")
                try {
                    context.assets.open("$ASSET_DIR/$name").use { input ->
                        tmp.outputStream().use { input.copyTo(it, 1 shl 16) }
                    }
                } catch (e: FileNotFoundException) {
                    tmp.delete()
                    throw OnDeviceTranscriptionException(
                        "the speech model file $name is missing from this build of the app " +
                            "(build it after running android/stt-spike/fetch-models.sh)",
                        e,
                    )
                }
                val dest = File(dir, name)
                if (!tmp.renameTo(dest)) {
                    tmp.delete()
                    throw OnDeviceTranscriptionException("could not unpack the speech model file $name")
                }
            }
            marker.writeText(stamp)
            log("on-device listening model unpacked in ${SystemClock.elapsedRealtime() - t0} ms")
            return dir
        }

        private fun apkStamp(context: Context): String {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            return "${info.lastUpdateTime}"
        }
    }

    companion object {
        private const val TAG = "TinyTalk"
        const val SAMPLE_RATE = 16_000
        private const val ASSET_DIR = "stt/whisper-tiny.en"
        private const val ENCODER = "tiny.en-encoder.int8.onnx"
        private const val DECODER = "tiny.en-decoder.int8.onnx"
        private const val TOKENS = "tiny.en-tokens.txt"
        private val FILES = listOf(ENCODER, DECODER, TOKENS)
    }
}

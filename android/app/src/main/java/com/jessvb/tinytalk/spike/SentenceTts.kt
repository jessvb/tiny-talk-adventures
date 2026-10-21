package com.jessvb.tinytalk.spike

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import com.jessvb.tinytalk.voice.Speaker
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit

/**
 * Speaks text one sentence at a time: each sentence is synthesized to a WAV in the cache dir, decoded
 * to PCM, and written to a single streaming AudioTrack. The engine synthesizes sentence N+1 while
 * sentence N plays. stop() drops everything (pending synthesis, queue, buffered audio).
 *
 * [communicationMode]: while speaking, set AudioManager.MODE_IN_COMMUNICATION and force the
 * loudspeaker, with USAGE_VOICE_COMMUNICATION on the track, so the AEC on the mic has a render
 * reference. Pass false (or flip [DEFAULT_COMMUNICATION_MODE]) to A/B against plain media output.
 * [audioSessionIdProvider]: read each time the AudioTrack is created (so a mic session id that only exists
 * after start() can be passed lazily); 0 = let the system allocate a new session (the default; no sharing).
 *
 * Threads and the cheap stop (barge-in from the mic's capture thread):
 * - [lock] guards only in-memory state and is never held across a binder, audio-mode or disk
 *   call. [stop] under the lock: bumps the generation, clears pending text/queue/tracker, detaches
 *   the AudioTrack and mutes it with setVolume(0) (client-side shared-memory gain, no binder), and
 *   posts the expensive cleanup. It returns in microseconds and nothing of the stopped generation
 *   is audible afterwards: the playback thread re-checks the generation under the lock before
 *   every write, and the detached track is muted.
 * - [audioExec] (one thread, FIFO) runs everything slow, in the order it was posted under the
 *   lock (= generation order): stop cleanup (TextToSpeech.stop, track pause/flush/release, audio
 *   mode restore, stale temp-file deletion), audio routing, and the synthesizeToFile calls of a
 *   run. So a stop's late TextToSpeech.stop or audio-mode restore always runs BEFORE the next
 *   run's routing and synthesis and can never cancel or un-route it. A speak() skips the restore
 *   in its own cleanup (it is about to route again), so stop-then-speak costs no extra mode flip.
 *   Routing state lives in [route] ([AudioRouteState]), confined to that thread.
 * - Playback thread: decodes and writes PCM; it creates and starts a track outside the lock and
 *   installs it under the lock only if its generation is still current.
 */
class SentenceTts(
    context: Context,
    private val onLog: (String) -> Unit,
    private val communicationMode: Boolean = DEFAULT_COMMUNICATION_MODE,
    private val audioSessionIdProvider: () -> Int = { 0 },
) : Speaker {
    private class Item(val gen: Int, val idx: Int, val file: File?)

    private val appContext = context.applicationContext
    private val audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val lock = Any()
    private val queue = LinkedBlockingQueue<Item>()
    private val tracker = RunTracker(SYNTH_TIMEOUT_MS)
    private val main = Handler(Looper.getMainLooper())
    private val audioExec: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "SentenceTts-audio").apply { isDaemon = true }
    }

    // audioExec-confined.
    private val route = AudioRouteState()
    private var savedMode = AudioManager.MODE_NORMAL
    private var savedSpeakerphone = false

    // All guarded by lock unless @Volatile.
    private var generation = 0
    @Volatile private var tts: TextToSpeech? = null
    private var ready = false
    private var unavailable = false
    private var pendingText: String? = null
    private var track: AudioTrack? = null
    private var trackRate = 0
    private var framesInTrack = 0L
    private var speakStartNs = 0L
    private var firstAudioLogged = false
    @Volatile private var closed = false
    @Volatile private var speaking = false

    /** Total frames ever written to any AudioTrack by this instance (for tests). */
    @Volatile var framesWritten = 0L
        private set

    /** Audio config actually used, set once the engine is ready / first track exists. */
    @Volatile var engineInfo: String = ""
        private set
    @Volatile var lastFirstAudioLatencyMs: Long = -1
        private set

    override val isSpeaking: Boolean get() = speaking

    private val playbackThread = Thread({ playbackLoop() }, "SentenceTts-playback").also {
        it.isDaemon = true
        it.start()
    }

    init {
        tts = TextToSpeech(appContext) { status -> onInit(status) }
        // Never hang if the engine binding never answers.
        main.postDelayed({
            val shouldFail = synchronized(lock) { !ready && !unavailable }
            if (shouldFail) markUnavailable("init timed out after ${INIT_TIMEOUT_MS} ms")
        }, INIT_TIMEOUT_MS)
    }

    /** Posts [task] to [audioExec]; call under [lock] so posting order = generation order. */
    private fun postLocked(task: () -> Unit) {
        try {
            audioExec.execute(task)
        } catch (_: RejectedExecutionException) {
            // closed: nothing more to do
        }
    }

    private fun onInit(status: Int) {
        val engine = tts
        if (status != TextToSpeech.SUCCESS || engine == null) {
            markUnavailable("init status=$status")
            return
        }
        val rc = engine.setLanguage(Locale.US)
        if (rc == TextToSpeech.LANG_MISSING_DATA || rc == TextToSpeech.LANG_NOT_SUPPORTED) {
            markUnavailable("no English voice (setLanguage rc=$rc)")
            return
        }
        engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {}
            override fun onDone(utteranceId: String?) = finished(utteranceId, ok = true)
            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) = finished(utteranceId, ok = false)
            override fun onError(utteranceId: String?, errorCode: Int) {
                onLog("TTS synth error code=$errorCode id=$utteranceId")
                finished(utteranceId, ok = false)
            }
        })
        engineInfo = "engine=${engine.defaultEngine}, voice=${engine.voice?.name}, locale=${engine.voice?.locale}"
        onLog("TTS ready: $engineInfo")
        synchronized(lock) {
            if (closed) return
            ready = true
            val text = pendingText ?: return
            pendingText = null
            val gen = generation
            postLocked { startSynthesis(text, gen) }
        }
    }

    private fun markUnavailable(reason: String) {
        synchronized(lock) {
            unavailable = true
            pendingText = null
            speaking = false
        }
        onLog("TTS UNAVAILABLE: $reason")
    }

    override fun speak(text: String) {
        if (splitSentences(text).isEmpty()) return
        synchronized(lock) {
            if (closed) return
            if (!unavailable) {
                cancelLocked(restoreRouting = false) // about to route again: skip the mode flip
                speaking = true
                speakStartNs = System.nanoTime()
                firstAudioLogged = false
                if (!ready) {
                    pendingText = text
                } else {
                    val gen = generation
                    postLocked { startSynthesis(text, gen) }
                }
                return
            }
        }
        onLog("TTS UNAVAILABLE: speak ignored")
    }

    /** audioExec: routes audio (if needed) then hands the run's sentences to the engine. */
    private fun startSynthesis(text: String, gen: Int) {
        val sentences = splitSentences(text)
        synchronized(lock) {
            if (closed || !speaking || gen != generation) return // stopped or superseded meanwhile
            tracker.begin(gen, sentences.size, nowMs())
        }
        routeAudio()
        val engine = tts ?: return
        sentences.forEachIndexed { i, s ->
            if (!isCurrent(gen)) return // a stop's cleanup is queued behind us; feed no more
            val file = File(appContext.cacheDir, "$FILE_PREFIX${gen}_$i.wav")
            val id = "$gen:$i:${sentences.size}"
            val rc = engine.synthesizeToFile(s, Bundle(), file, id)
            if (rc != TextToSpeech.SUCCESS) {
                onLog("synthesizeToFile rc=$rc for sentence $i")
                finished(id, ok = false)
            }
        }
    }

    private fun nowMs() = System.nanoTime() / 1_000_000

    private fun finished(utteranceId: String?, ok: Boolean) {
        val parts = utteranceId?.split(":") ?: return
        if (parts.size != 3) return
        val gen = parts[0].toIntOrNull() ?: return
        val idx = parts[1].toIntOrNull() ?: return
        val file = File(appContext.cacheDir, "$FILE_PREFIX${gen}_$idx.wav")
        val current = synchronized(lock) { gen == generation && !closed }
        // Stale generation, duplicate, or already timed out: drop it.
        if (!current || !tracker.arrived(gen, idx, nowMs())) {
            file.delete()
            return
        }
        if (!ok) file.delete()
        queue.put(Item(gen, idx, if (ok) file else null))
    }

    private fun playbackLoop() {
        while (!closed) {
            val item = try { queue.poll(200, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) { return }
            if (item == null) {
                tracker.expire(nowMs())?.let { e ->
                    onLog("TTS synthesis timed out for sentence ${e.idx}; skipping")
                    if (e.runFinished && isCurrent(e.gen)) {
                        drain(e.gen)
                        finishRun(e.gen)
                    }
                }
                continue
            }
            try {
                play(item)
            } catch (e: Exception) {
                onLog("TTS playback error: $e")
                item.file?.delete()
                completeSentence(item)
            }
        }
    }

    private fun isCurrent(gen: Int) = synchronized(lock) { gen == generation && !closed }

    private fun play(item: Item) {
        val file = item.file
        if (file != null) {
            if (!isCurrent(item.gen) || tracker.isDone(item.gen, item.idx)) {
                file.delete()
                return
            }
            val wav = try { decodeWav(file) } finally { file.delete() }
            if (wav == null) {
                onLog("could not decode WAV for sentence; skipping")
            } else {
                writePcm(item.gen, wav)
            }
        }
        completeSentence(item)
    }

    /** Marks the sentence accounted for; finishes the run only once all sentences are. */
    private fun completeSentence(item: Item) {
        if (tracker.done(item.gen, item.idx) && isCurrent(item.gen)) {
            drain(item.gen)
            finishRun(item.gen)
        }
    }

    private fun writePcm(gen: Int, wav: Wav) {
        var offset = 0
        val pcm = wav.pcm
        while (offset < pcm.size) {
            var written = 0
            var needTrack = false
            synchronized(lock) {
                if (gen != generation || closed) return
                val t = track
                if (t == null) {
                    needTrack = true
                } else {
                    if (trackRate != wav.sampleRate) {
                        onLog("sample rate changed $trackRate -> ${wav.sampleRate}; skipping sentence")
                        return
                    }
                    // WRITE_NON_BLOCKING copies into the shared buffer: no binder under the lock.
                    written = t.write(pcm, offset, minOf(pcm.size - offset, CHUNK_SHORTS), AudioTrack.WRITE_NON_BLOCKING)
                    if (written < 0) {
                        onLog("AudioTrack.write error $written")
                        return
                    }
                    if (written > 0) {
                        framesInTrack += written
                        framesWritten += written
                        if (!firstAudioLogged) {
                            firstAudioLogged = true
                            lastFirstAudioLatencyMs = (System.nanoTime() - speakStartNs) / 1_000_000
                            onLog("first audio latency ms: $lastFirstAudioLatencyMs")
                        }
                    }
                }
            }
            if (needTrack) {
                if (!installTrack(gen, wav.sampleRate)) return
                continue
            }
            if (written == 0) Thread.sleep(5) else offset += written
        }
    }

    /**
     * Playback thread: builds and starts a track OUTSIDE the lock (binder calls), then installs it
     * only if [gen] is still current. Returns false if the run was stopped meanwhile.
     */
    private fun installTrack(gen: Int, rate: Int): Boolean {
        val t = createTrack(rate) ?: return false
        try {
            t.play() // an empty track just underruns until the first write
        } catch (e: IllegalStateException) {
            onLog("AudioTrack.play failed: $e")
            t.release()
            return false
        }
        val installed = synchronized(lock) {
            if (gen != generation || closed || track != null) {
                false
            } else {
                track = t
                trackRate = rate
                framesInTrack = 0
                true
            }
        }
        if (!installed) t.release()
        return installed
    }

    private fun createTrack(rate: Int): AudioTrack? {
        val minBuf = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minBuf <= 0) {
            onLog("AudioTrack.getMinBufferSize failed: $minBuf")
            return null
        }
        var audioSessionId = 0
        val usage = if (communicationMode) AudioAttributes.USAGE_VOICE_COMMUNICATION else AudioAttributes.USAGE_MEDIA
        val t = try {
            audioSessionId = audioSessionIdProvider()
            AudioTrack(
                AudioAttributes.Builder()
                    .setUsage(usage)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
                AudioFormat.Builder()
                    .setSampleRate(rate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
                maxOf(minBuf, rate * 2), // ~1 s of 16-bit mono
                AudioTrack.MODE_STREAM,
                audioSessionId,
            )
        } catch (e: Exception) {
            onLog("AudioTrack construction failed: $e")
            return null
        }
        if (t.state != AudioTrack.STATE_INITIALIZED) {
            onLog("AudioTrack failed to initialize")
            t.release()
            return null
        }
        onLog("AudioTrack created: rate=$rate usage=$usage sessionId=${t.audioSessionId} (requested $audioSessionId)")
        return t
    }

    /** Wait until the last written sample has actually been played (or the run was cancelled). */
    private fun drain(gen: Int) {
        val deadline = System.nanoTime() + 5_000_000_000L // safety net, not an expected path
        while (System.nanoTime() < deadline) {
            val done = synchronized(lock) {
                if (gen != generation || closed) return
                val t = track ?: return
                t.playbackHeadPosition.toLong() >= framesInTrack
            }
            if (done) return
            try {
                Thread.sleep(20)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt() // close() interrupts the playback thread
                return
            }
        }
        onLog("drain timed out")
    }

    /** Natural end of run [gen]: release the track and restore audio on audioExec, unless superseded. */
    private fun finishRun(gen: Int) {
        synchronized(lock) {
            if (gen != generation) return
            speaking = false
            val t = detachTrackLocked()
            postLocked {
                releaseTrack(t)
                val (cur, spk) = synchronized(lock) { generation to speaking }
                if (route.shouldRestoreAfterRun(gen, cur, spk)) restoreAudio()
            }
        }
    }

    /**
     * Stops speech immediately and drops everything queued. Safe when idle and when repeated.
     * O(microseconds): no binder, audio-mode or disk work on the caller's thread (see class doc).
     */
    override fun stop() {
        synchronized(lock) { cancelLocked(restoreRouting = true) }
    }

    private fun cancelLocked(restoreRouting: Boolean) {
        generation++
        val newGen = generation
        pendingText = null
        speaking = false
        queue.clear()
        tracker.cancel()
        val t = detachTrackLocked()
        try {
            t?.setVolume(0f) // client-side gain: silent at once, no binder
        } catch (_: IllegalStateException) {}
        postLocked { cleanup(t, newGen, restoreRouting) }
    }

    private fun detachTrackLocked(): AudioTrack? {
        val t = track
        track = null
        trackRate = 0
        framesInTrack = 0
        return t
    }

    /** audioExec: the slow half of a stop, ordered before any later run's routing/synthesis. */
    private fun cleanup(t: AudioTrack?, newGen: Int, restoreRouting: Boolean) {
        try { tts?.stop() } catch (e: Exception) { onLog("tts.stop failed: $e") }
        releaseTrack(t)
        if (restoreRouting && route.shouldRestoreAfterStop()) restoreAudio()
        appContext.cacheDir.listFiles { f -> AudioRouteState.isStaleTempFile(f.name, FILE_PREFIX, newGen) }
            ?.forEach { it.delete() }
    }

    private fun releaseTrack(t: AudioTrack?) {
        t ?: return
        try { t.pause(); t.flush() } catch (_: IllegalStateException) {}
        t.release()
    }

    /** audioExec only. */
    private fun routeAudio() {
        if (!communicationMode || !route.shouldRoute()) return
        savedMode = audioManager.mode
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val speaker = audioManager.availableCommunicationDevices
                .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            val ok = speaker != null && audioManager.setCommunicationDevice(speaker)
            onLog("setCommunicationDevice(speaker) ok=$ok, active=${audioManager.communicationDevice?.type} (speaker=${AudioDeviceInfo.TYPE_BUILTIN_SPEAKER})")
        } else {
            @Suppress("DEPRECATION")
            run {
                savedSpeakerphone = audioManager.isSpeakerphoneOn
                audioManager.isSpeakerphoneOn = true
            }
            @Suppress("DEPRECATION")
            onLog("isSpeakerphoneOn set true, now=${audioManager.isSpeakerphoneOn}")
        }
        val effective = audioManager.mode
        onLog("audio mode requested=${AudioManager.MODE_IN_COMMUNICATION}, effective=$effective" +
            if (effective != AudioManager.MODE_IN_COMMUNICATION) " -- NOT APPLIED (permission/denied?)" else "")
    }

    /** audioExec only; the caller has checked [route]. */
    private fun restoreAudio() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audioManager.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            run { audioManager.isSpeakerphoneOn = savedSpeakerphone }
        }
        audioManager.mode = savedMode
    }

    fun close() {
        synchronized(lock) {
            if (closed) return
            cancelLocked(restoreRouting = true)
            closed = true
            postLocked {
                tts?.shutdown()
                tts = null
            }
        }
        audioExec.shutdown() // runs the queued cleanup and shutdown, then the thread exits
        main.removeCallbacksAndMessages(null)
        playbackThread.interrupt()
    }

    class Wav(val sampleRate: Int, val pcm: ShortArray)

    companion object {
        /** Flip to false to A/B plain media output against the voice-communication path. */
        const val DEFAULT_COMMUNICATION_MODE = true
        private const val FILE_PREFIX = "sentence_tts_"
        private const val INIT_TIMEOUT_MS = 10_000L
        private const val SYNTH_TIMEOUT_MS = 20_000L // no synthesis progress for this long fails a sentence
        private const val CHUNK_SHORTS = 2048

        fun splitSentences(text: String): List<String> =
            text.trim().split(Regex("(?<=[.!?])\\s+")).map { it.trim() }.filter { it.isNotEmpty() }

        /** Parses a RIFF/WAVE file (mono 16-bit PCM); returns null if unsupported or malformed. */
        fun decodeWav(file: File): Wav? {
            val bytes = file.readBytes()
            if (bytes.size < 12 || String(bytes, 0, 4) != "RIFF" || String(bytes, 8, 4) != "WAVE") return null
            val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            var pos = 12
            var rate = 0
            var channels = 0
            var bits = 0
            var format = 0
            while (pos + 8 <= bytes.size) {
                val id = String(bytes, pos, 4)
                var size = bb.getInt(pos + 4)
                val body = pos + 8
                if (id == "fmt " && body + 16 <= bytes.size) {
                    format = bb.getShort(body).toInt() and 0xFFFF
                    channels = bb.getShort(body + 2).toInt()
                    rate = bb.getInt(body + 4)
                    bits = bb.getShort(body + 14).toInt()
                } else if (id == "data") {
                    // Streaming writers may leave the size 0/0xFFFFFFFF; clamp to what is there.
                    if (size <= 0 || body + size > bytes.size) size = bytes.size - body
                    // format 1 = PCM, 0xFFFE = extensible
                    if ((format != 1 && format != 0xFFFE) || channels != 1 || bits != 16 || rate <= 0) return null
                    val n = size / 2
                    val pcm = ShortArray(n)
                    bb.position(body)
                    bb.asShortBuffer().get(pcm)
                    return Wav(rate, pcm)
                }
                pos = body + size + (size and 1)
                if (size < 0) return null
            }
            return null
        }
    }
}

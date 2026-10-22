package com.jessvb.tinytalk.spike

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import com.jessvb.tinytalk.core.audio.FrameChunker
import com.jessvb.tinytalk.voice.MicSource

/**
 * 16 kHz mono 16-bit mic capture via VOICE_COMMUNICATION with AEC/NS attached when available.
 * Delivers exact 512-sample frames on a background thread. Caller must hold RECORD_AUDIO.
 *
 * [onStopped] fires once, on the capture thread as it exits, when capture ended for any reason
 * other than [stop] (AudioRecord.read error such as ERROR_DEAD_OBJECT, or [onFrame] throwing).
 * It must not block or join the capture thread; post the reaction elsewhere.
 */
class MicCapture(
    private val onFrame: (ShortArray) -> Unit,
    private val onLog: (String) -> Unit,
    private val onStopped: (reason: String) -> Unit = {},
) : MicSource {
    var aecAvailable: Boolean = false
        private set
    var aecEnabled: Boolean = false
        private set
    var audioSessionId: Int = 0
        private set

    val isRunning: Boolean get() = running

    private var record: AudioRecord? = null
    private var aec: AcousticEchoCanceler? = null
    private var ns: NoiseSuppressor? = null
    private var thread: Thread? = null
    @Volatile private var running = false

    /** Returns true only if capture is actually recording. */
    @SuppressLint("MissingPermission")
    @Synchronized
    override fun start(): Boolean {
        if (running) return true
        teardown() // release anything left by a previous read-error stop
        onLog("device: ${Build.MODEL}, SDK_INT=${Build.VERSION.SDK_INT}")
        val minBuf = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minBuf <= 0) {
            onLog("getMinBufferSize failed: $minBuf")
            return false
        }
        val rec = try {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuf, FRAME_SIZE * 2 * 4),
            )
        } catch (e: SecurityException) {
            onLog("AudioRecord construction denied: $e")
            return false
        } catch (e: IllegalArgumentException) {
            onLog("AudioRecord construction failed: $e")
            return false
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            onLog("AudioRecord failed to initialize")
            rec.release()
            return false
        }
        record = rec
        audioSessionId = rec.audioSessionId

        // Audio effects are best-effort: a throw here (setEnabled can throw IllegalStateException)
        // must not abort capture or escape to the caller; teardown() releases whatever was made.
        try {
            aecAvailable = AcousticEchoCanceler.isAvailable()
            if (aecAvailable) {
                aec = AcousticEchoCanceler.create(audioSessionId)
                val rc = aec?.setEnabled(true)
                aecEnabled = aec?.enabled == true
                onLog("AEC available=true, setEnabled(true) rc=$rc, enabled=$aecEnabled")
                if (aec == null || !aecEnabled) onLog("AEC UNAVAILABLE (create/enable failed)")
            } else {
                onLog("AEC UNAVAILABLE")
            }
            val nsAvailable = NoiseSuppressor.isAvailable()
            if (nsAvailable) {
                ns = NoiseSuppressor.create(audioSessionId)
                ns?.setEnabled(true)
            }
            onLog("NoiseSuppressor available=$nsAvailable, enabled=${ns?.enabled == true}")
        } catch (e: RuntimeException) {
            aecEnabled = false
            onLog("audio effects failed: ${e.javaClass.name}; continuing without them")
        }
        onLog("audioSessionId=$audioSessionId")

        try {
            rec.startRecording()
        } catch (e: IllegalStateException) {
            onLog("startRecording threw: $e")
            teardown()
            return false
        }
        if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            onLog("startRecording did not start (recordingState=${rec.recordingState}); mic busy?")
            teardown()
            return false
        }
        running = true
        thread = Thread({ readLoop(rec) }, "MicCapture").also { it.start() }
        onLog("mic started")
        return true
    }

    private fun readLoop(rec: AudioRecord) {
        val chunker = FrameChunker(FRAME_SIZE)
        val buf = ShortArray(FRAME_SIZE)
        var lost: String? = null
        try {
            while (running) {
                val n = rec.read(buf, 0, buf.size)
                if (n < 0) {
                    // ERROR_INVALID_OPERATION / ERROR_DEAD_OBJECT etc: never pass as a length.
                    // After a deliberate stop() (running already false) an error is expected.
                    if (running) lost = "AudioRecord.read error $n"
                    break
                }
                if (n == 0) continue
                for (frame in chunker.push(buf, n)) onFrame(frame)
            }
        } catch (t: Throwable) {
            if (running) lost = "capture thread failed: ${t.javaClass.name}"
        }
        if (lost != null) {
            running = false
            onLog("$lost; capture stopped")
            onStopped(lost)
        }
    }

    @Synchronized
    override fun stop() {
        teardown()
        onLog("mic stopped")
    }

    /**
     * Stops the read loop and releases native resources. The capture thread must have
     * exited before release(): releasing an AudioRecord while read() runs on it crashes in
     * native code. stop() makes a blocked read() return promptly, so the join normally takes
     * at most one frame (32 ms); the [JOIN_SAFETY_CAP_MS] cap only stops a wedged driver
     * from hanging the caller forever, and in that case the AudioRecord is deliberately
     * leaked rather than released under a live read.
     */
    private fun teardown() {
        running = false
        val rec = record
        if (rec != null) {
            try { rec.stop() } catch (_: IllegalStateException) {}
        }
        val t = thread
        thread = null
        // From the capture thread itself (an onFrame callback calling stop()) there is no
        // read in progress, and the loop exits as soon as the callback returns.
        val exited = t == null || t === Thread.currentThread() || joinCapped(t)
        if (rec != null) {
            if (exited) {
                rec.release()
            } else {
                onLog("mic thread did not exit within $JOIN_SAFETY_CAP_MS ms; NOT releasing AudioRecord (would crash under a live read)")
            }
        }
        record = null
        aec?.release(); aec = null
        ns?.release(); ns = null
        aecEnabled = false
    }

    private fun joinCapped(t: Thread): Boolean {
        val deadline = System.nanoTime() + JOIN_SAFETY_CAP_MS * 1_000_000
        var interrupted = false
        while (t.isAlive) {
            val left = (deadline - System.nanoTime()) / 1_000_000
            if (left <= 0) break
            try {
                t.join(left)
            } catch (_: InterruptedException) {
                interrupted = true // keep waiting: releasing early is the crash we are avoiding
            }
        }
        if (interrupted) Thread.currentThread().interrupt()
        return !t.isAlive
    }

    companion object {
        const val SAMPLE_RATE = 16000
        const val FRAME_SIZE = 512
        private const val JOIN_SAFETY_CAP_MS = 3_000L
    }
}

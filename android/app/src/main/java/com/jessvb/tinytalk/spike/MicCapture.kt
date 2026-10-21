package com.jessvb.tinytalk.spike

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import com.jessvb.tinytalk.core.audio.FrameChunker

/**
 * 16 kHz mono 16-bit mic capture via VOICE_COMMUNICATION with AEC/NS attached when available.
 * Delivers exact 512-sample frames on a background thread. Caller must hold RECORD_AUDIO.
 */
class MicCapture(
    private val onFrame: (ShortArray) -> Unit,
    private val onLog: (String) -> Unit,
) {
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
    fun start(): Boolean {
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
        while (running) {
            val n = rec.read(buf, 0, buf.size)
            if (n < 0) {
                // ERROR_INVALID_OPERATION / ERROR_DEAD_OBJECT etc: never pass as a length.
                onLog("AudioRecord.read error $n; stopping capture")
                running = false
                break
            }
            if (n == 0) continue
            for (frame in chunker.push(buf, n)) onFrame(frame)
        }
    }

    @Synchronized
    fun stop() {
        teardown()
        onLog("mic stopped")
    }

    private fun teardown() {
        running = false
        thread?.join(500)
        thread = null
        record?.let {
            try { it.stop() } catch (_: IllegalStateException) {}
            it.release()
        }
        record = null
        aec?.release(); aec = null
        ns?.release(); ns = null
        aecEnabled = false
    }

    companion object {
        const val SAMPLE_RATE = 16000
        const val FRAME_SIZE = 512
    }
}

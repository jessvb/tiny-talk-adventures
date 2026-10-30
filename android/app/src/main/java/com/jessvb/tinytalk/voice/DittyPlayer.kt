package com.jessvb.tinytalk.voice

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import com.jessvb.tinytalk.core.rethrowIfFatal
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit

/**
 * Loops [WaitingDitty] on the MEDIA stream (so the parent's media volume governs it, like
 * Elsie's voice) while the child waits for a reply.
 *
 * [start] and [stop] only flip a flag and post to one FIFO thread, so they are safe from the
 * mic's capture thread (barge-in) and return at once; the AudioTrack work happens on that
 * thread. A `stop()` that arrives before a queued start runs wins (the start re-checks the
 * flag). Like iOS, the chime gives up after [MAX_SECONDS] so it can never drone on forever
 * (here it only goes quiet; the turn's own timeouts decide whether it failed).
 */
class DittyPlayer(private val onLog: (String) -> Unit) : WaitingSound {
    private val exec = ScheduledThreadPoolExecutor(1) { r -> Thread(r, "DittyPlayer").apply { isDaemon = true } }

    @Volatile private var wanted = false
    @Volatile private var generation = 0
    private var track: AudioTrack? = null // exec thread only

    override fun start() {
        wanted = true
        val gen = ++generation
        post {
            if (!wanted || gen != generation) return@post
            halt() // never two tracks
            play()
            exec.schedule({ if (gen == generation) { wanted = false; halt() } }, MAX_SECONDS, TimeUnit.SECONDS)
        }
    }

    override fun stop() {
        if (!wanted && track == null) return
        wanted = false
        generation++
        post { halt() }
    }

    /** Releases the thread; the player is unusable afterwards. */
    fun close() {
        wanted = false
        generation++
        post { halt() }
        exec.shutdown()
    }

    private fun post(block: () -> Unit) {
        try {
            exec.execute {
                try { block() } catch (t: Throwable) {
                    t.rethrowIfFatal()
                    onLog("waiting chime failed: ${t.javaClass.name}")
                }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            // closed
        }
    }

    private fun play() {
        val samples = WaitingDitty.samples
        val bytes = samples.size * 2
        val t = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(WaitingDitty.SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setBufferSizeInBytes(bytes)
            .build()
        if (t.state != AudioTrack.STATE_INITIALIZED) {
            onLog("waiting chime track failed to initialize")
            t.release()
            return
        }
        t.write(samples, 0, samples.size)
        t.setLoopPoints(0, samples.size, -1) // forever; the silent tail paces it
        t.play()
        track = t
        onLog("waiting chime started")
    }

    private fun halt() {
        val t = track ?: return
        track = null
        try { t.stop() } catch (_: IllegalStateException) {}
        t.release()
        onLog("waiting chime stopped")
    }

    companion object {
        /** iOS: 45 s. */
        const val MAX_SECONDS = 45L
    }
}

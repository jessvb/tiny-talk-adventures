package com.jessvb.tinytalk.sttspike

import android.os.Build
import android.os.Debug
import androidx.test.platform.app.InstrumentationRegistry
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineWhisperModelConfig
import com.k2fsa.sherpa.onnx.OnlineModelConfig
import com.k2fsa.sherpa.onnx.OnlineRecognizer
import com.k2fsa.sherpa.onnx.OnlineRecognizerConfig
import com.k2fsa.sherpa.onnx.OnlineTransducerModelConfig
import org.json.JSONObject
import org.junit.Test
import org.vosk.Model
import org.vosk.Recognizer
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Headless: reads WAV files, runs recognizers. Never touches AudioTrack/AudioRecord/TTS. */
class SttSpikeTest {
    private class Wav(val name: String, val shorts: ShortArray) {
        val floats = FloatArray(shorts.size) { shorts[it] / 32768f }
        val ms get() = shorts.size * 1000.0 / 16000.0
    }

    private interface Engine {
        fun transcribe(w: Wav): String
        fun release()
    }

    private fun readWav(f: File): Wav {
        val b = ByteBuffer.wrap(f.readBytes()).order(ByteOrder.LITTLE_ENDIAN)
        var pos = 12
        while (pos + 8 <= b.limit()) {
            val id = String(ByteArray(4) { b.get(pos + it) })
            val size = b.getInt(pos + 4)
            if (id == "data") {
                val n = minOf(size, b.limit() - pos - 8) / 2
                val s = ShortArray(n) { b.getShort(pos + 8 + it * 2) }
                return Wav(f.nameWithoutExtension, s)
            }
            pos += 8 + size + (size and 1)
        }
        error("no data chunk in $f")
    }

    // Native-heap PSS (KB -> MB) from Debug.MemoryInfo.nativePss.
    private fun pssMb(): Double {
        val mi = Debug.MemoryInfo()
        Debug.getMemoryInfo(mi)
        return mi.nativePss / 1024.0
    }

    @Test
    fun run() {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val dir = ctx.getExternalFilesDir(null)!!
        val models = File(dir, "models")
        val wavs = File(dir, "wav").listFiles { f -> f.name.endsWith(".wav") }!!
            .sortedBy { it.name }.map { readWav(it) }
        val csv = StringBuilder("id,voice,candidate,audio_ms,latency_ms,rtf,cold,hyp\n")
        val meta = StringBuilder()
        meta.append("device=${Build.MANUFACTURER} ${Build.MODEL}\nsdk=${Build.VERSION.SDK_INT}\n")
        meta.append("cores=${Runtime.getRuntime().availableProcessors()}\nwav_count=${wavs.size}\n")
        val lastChunkMs = StringBuilder("candidate,id,voice,after_last_chunk_ms\n")

        // Optional instrumentation args: only=<substring of candidate name>, leadMs=<zipformer
        // leading silence>, out=<output file prefix>.
        val args = InstrumentationRegistry.getArguments()
        val filter = args.getString("only") ?: ""
        val leadMs = args.getString("leadMs")?.toInt() ?: 0
        val out = args.getString("out") ?: ""
        val chunkMs = args.getString("chunkMs")?.toInt() ?: 100
        val zs = (if (leadMs > 0) "-lead$leadMs" else "") + (if (chunkMs != 100) "-chunk$chunkMs" else "")
        val all = listOf(
            Triple("whisper-tiny.en-t2", 2) { whisper(File(models, "whisper-tiny.en"), 2) },
            Triple("whisper-tiny.en-t4", 4) { whisper(File(models, "whisper-tiny.en"), 4) },
            Triple("zipformer-20M-t2$zs", 2) { zipformer(File(models, "zipformer-en-20M"), 2, lastChunkMs, "zipformer-20M-t2$zs", leadMs, chunkMs) },
            Triple("zipformer-20M-t4$zs", 4) { zipformer(File(models, "zipformer-en-20M"), 4, lastChunkMs, "zipformer-20M-t4$zs", leadMs, chunkMs) },
            Triple("vosk-small-en-us-0.15", 1) { vosk(File(models, "vosk-model-small-en-us-0.15")) },
        )
        val candidates = all.filter { it.first.contains(filter) }

        for ((name, threads, make) in candidates) {
            System.gc()
            val pssBefore = pssMb()
            val t0 = System.nanoTime()
            val eng = make()
            val loadMs = (System.nanoTime() - t0) / 1e6
            val pssAfter = pssMb()
            meta.append("$name: threads=$threads load_ms=%.0f pss_before_mb=%.1f pss_after_load_mb=%.1f\n".format(loadMs, pssBefore, pssAfter))

            // Cold = first call after load (recorded as cold=1). Then one untimed warm-up, then all wavs warm.
            val first = wavs[0]
            val c0 = System.nanoTime()
            val hypCold = eng.transcribe(first)
            val coldMs = (System.nanoTime() - c0) / 1e6
            row(csv, first, name, coldMs, 1, hypCold)
            eng.transcribe(first) // untimed warm-up
            // Note: zipformer_last_chunk.csv also holds the cold + warm-up rows (first 2 per candidate).
            for (w in wavs) {
                val s = System.nanoTime()
                val hyp = eng.transcribe(w)
                val ms = (System.nanoTime() - s) / 1e6
                row(csv, w, name, ms, 0, hyp)
            }
            meta.append("$name: pss_after_run_mb=%.1f\n".format(pssMb()))
            eng.release()
        }
        File(dir, "${out}results.csv").writeText(csv.toString())
        File(dir, "${out}zipformer_last_chunk.csv").writeText(lastChunkMs.toString())
        File(dir, "${out}meta.txt").writeText(meta.toString())
    }

    private fun row(sb: StringBuilder, w: Wav, cand: String, ms: Double, cold: Int, hyp: String) {
        val (id, voice) = w.name.split("_", limit = 2)
        val clean = hyp.replace("\"", "'").replace("\n", " ")
        sb.append("%s,%s,%s,%.0f,%.1f,%.4f,%d,\"%s\"\n".format(id, voice, cand, w.ms, ms, ms / w.ms, cold, clean))
    }

    private fun whisper(d: File, threads: Int): Engine {
        val cfg = OfflineRecognizerConfig(
            modelConfig = OfflineModelConfig(
                whisper = OfflineWhisperModelConfig(
                    encoder = File(d, "tiny.en-encoder.int8.onnx").path,
                    decoder = File(d, "tiny.en-decoder.int8.onnx").path,
                    language = "en", task = "transcribe",
                ),
                tokens = File(d, "tiny.en-tokens.txt").path,
                numThreads = threads, modelType = "whisper",
            ),
        )
        val rec = OfflineRecognizer(null, cfg)
        return object : Engine {
            override fun transcribe(w: Wav): String {
                val s = rec.createStream()
                s.acceptWaveform(w.floats, 16000)
                rec.decode(s)
                val t = rec.getResult(s).text
                s.release()
                return t.trim()
            }
            override fun release() = rec.release()
        }
    }

    private fun zipformer(d: File, threads: Int, lastChunk: StringBuilder, cand: String, leadMs: Int, chunkMs: Int): Engine {
        val cfg = OnlineRecognizerConfig(
            modelConfig = OnlineModelConfig(
                transducer = OnlineTransducerModelConfig(
                    encoder = File(d, "encoder-epoch-99-avg-1.int8.onnx").path,
                    decoder = File(d, "decoder-epoch-99-avg-1.int8.onnx").path,
                    joiner = File(d, "joiner-epoch-99-avg-1.int8.onnx").path,
                ),
                tokens = File(d, "tokens.txt").path,
                numThreads = threads,
            ),
            enableEndpoint = false,
        )
        val rec = OnlineRecognizer(null, cfg)
        return object : Engine {
            override fun transcribe(w: Wav): String {
                val s = rec.createStream("")
                // Optional leading silence (a live mic has some before the child speaks).
                val x = FloatArray(leadMs * 16) + w.floats
                // 100 ms chunks by default; chunkMs=0 feeds the whole utterance in one call.
                val chunk = if (chunkMs > 0) chunkMs * 16 else x.size
                val total = x.size
                val lastStart = ((total - 1) / chunk) * chunk
                var i = 0
                // Feed all but the final chunk (decoding as it goes, like live streaming), then
                // time from the last chunk + 0.5 s trailing silence until the final text is ready.
                while (i < lastStart) {
                    s.acceptWaveform(x.copyOfRange(i, i + chunk), 16000)
                    while (rec.isReady(s)) rec.decode(s)
                    i += chunk
                }
                val t0 = System.nanoTime()
                s.acceptWaveform(x.copyOfRange(lastStart, total), 16000)
                s.acceptWaveform(FloatArray(8000), 16000)
                s.inputFinished()
                while (rec.isReady(s)) rec.decode(s)
                val after = (System.nanoTime() - t0) / 1e6
                val t = rec.getResult(s).text
                s.release()
                val (id, voice) = w.name.split("_", limit = 2)
                lastChunk.append("$cand,$id,$voice,%.1f\n".format(after))
                return t.trim()
            }
            override fun release() = rec.release()
        }
    }

    private fun vosk(d: File): Engine {
        val model = Model(d.path)
        return object : Engine {
            override fun transcribe(w: Wav): String {
                Recognizer(model, 16000f).use { r ->
                    r.acceptWaveForm(w.shorts, w.shorts.size)
                    return JSONObject(r.finalResult).optString("text").trim()
                }
            }
            override fun release() = model.close()
        }
    }
}

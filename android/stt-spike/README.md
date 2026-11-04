# On-device STT spike (issue #88, Phase 0b)

Compares three on-device speech-to-text candidates on the Pixel 3 (Android 12, SD845) for speed
and accuracy, with **no audio playback**. Findings from Phase A research: `PHASE-A-REPORT.md`.

Candidates: (a) sherpa-onnx Whisper tiny.en int8 (offline), (b) sherpa-onnx streaming zipformer
en-20M int8, (c) Vosk `vosk-model-small-en-us-0.15`.

## Author steps

Download libs + models (network; ~250 MB; idempotent, safe to re-run):

```
! bash /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/android-demo-mode/android/stt-spike/fetch-models.sh
```

Test audio is already generated (silent, files only) by `make-test-audio.sh` into `testdata/wav/`
(144 files = 24 utterances in `utterances.tsv` x 6 adult macOS voices).

## Phase B design (measurement without sound)

- A throwaway Gradle module/test (e.g. `android/stt-spike-app`) depending on
  `downloads/libs/sherpa-onnx-1.13.8.aar` (`implementation(files(...))`) and
  `com.alphacephei:vosk-android:0.3.75`. Do not wire it into the real app.
- Push inputs with adb (no playback anywhere), to the app's external files dir:
  `adb -s 8BDX18J4R push testdata/wav /sdcard/Android/data/<appId>/files/wav`, and the three model
  dirs from `downloads/models/` to `.../files/models/`.
- An instrumented test (`androidTest`, headless; it never touches AudioTrack/AudioRecord) loads
  each WAV, converts 16-bit PCM to `FloatArray` (/32768f) for sherpa, or passes `ShortArray`/bytes
  to Vosk, and runs each candidate on every utterance.
- Per utterance record: audio duration, wall-clock latency (ms, via `System.nanoTime`), and RTF =
  processing time / audio duration. Report cold (first call after model load; also model load
  time) separately from warm (median and p95 of subsequent calls, after 1 untimed warm-up).
  Streaming zipformer: feed the whole utterance in ~100 ms chunks plus ~0.5 s of trailing zeros,
  and also report latency after the last chunk (the time the child waits). Peak memory:
  `Debug.getNativePss()` / `Runtime` sampled after load and after the run (best effort).
- Output one CSV (`id,voice,candidate,audio_ms,latency_ms,rtf,cold,hyp`) to the files dir, pulled
  back with `adb pull`. WER computed on the Mac (small script): normalize reference and hypothesis
  by lowercasing and stripping punctuation, word-level edit distance / reference words, summed
  over all utterances and per voice.
- Caveat: TTS voices are adult and clean; use them for speed and a rough sanity check only. Child
  accuracy needs the author's own later testing.

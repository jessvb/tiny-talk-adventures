# Android on-device STT spike: results (issue #88, Phase B)

Date 2026-10-21. Silent run: WAV files read from disk and fed to three recognizers by a headless instrumented test (`android/stt-spike-app`, throwaway module). No audio was played or recorded. Raw data: `android/stt-spike/results/` (CSV, meta, summaries). Reproduce the numbers with `python3 -I android/stt-spike/wer.py [results.csv]`.

## Device

Google Pixel 3 (Snapdragon 845, 8 cores reported), Android 12 (SDK 31), arm64-v8a, debug-build APK (native inference code is unaffected by that), no other app deliberately running. Test set: 24 short kid-style utterances x 6 macOS TTS voices = 144 WAVs (16 kHz mono), 924 reference words. Each candidate: model load (timed), first call on the first WAV (cold), one untimed warm-up, then all 144 WAVs (warm). Latency is wall clock for the whole recognize call; RTF = latency / audio duration.

## Results

| Candidate | Model on disk | Load ms | Native PSS after load (MB) | Cold first call ms | Warm median / p95 latency ms | Warm median / p95 RTF | WER overall |
|---|---|---|---|---|---|---|---|
| Whisper tiny.en int8, 2 threads | 110 MB (112,424 KB) | 1103 | 132 | 849 | 702 / 864 | 0.363 / 0.715 | 14.6% |
| Whisper tiny.en int8, 4 threads | same | 1004 | 134 | 908 | 711 / 906 | 0.386 / 0.800 | 14.5% |
| Zipformer en-20M int8, 2 threads | 42 MB (43,056 KB) | 1714 | 77 | 462 | 316 / 510 | 0.166 / 0.254 | 75.5% |
| Zipformer en-20M int8, 4 threads | same | 2002 | 77 | 797 | 548 / 800 | 0.285 / 0.405 | 75.9% |
| Vosk small en-us 0.15, 1 thread | 68 MB (69,276 KB) | 1925 | 144 | 1851 | 1399 / 2310 | 0.780 / 1.116 | 24.7% |

Peak native PSS after the full 144-utterance run (best effort, one sample): Whisper 236 MB, zipformer 78 to 79 MB, Vosk 163 MB. "PSS after load" includes the shared native libraries and leftover heap from the previous candidate (the "before" figures vary 5 to 37 MB), so treat the figures as approximate, roughly +-30 MB.

WER per voice (percent), warm, same normalization (lowercase, punctuation stripped):

| Candidate | Daniel | Junior | Karen | Kathy | Samantha | Tessa |
|---|---|---|---|---|---|---|
| Whisper t2 | 5.8 | 24.0 | 11.7 | 29.9 | 8.4 | 7.8 |
| Whisper t4 | 6.5 | 24.0 | 11.0 | 29.9 | 7.8 | 7.8 |
| Zipformer t2 | 74.0 | 87.0 | 65.6 | 85.7 | 73.4 | 67.5 |
| Vosk | 13.6 | 42.9 | 13.0 | 56.5 | 10.4 | 11.7 |

Junior (a high-pitched novelty voice) and Kathy (a low-quality legacy voice) are the hardest for every engine; they are the closest thing here to "atypical" speech but are not child speech.

### Zipformer latency after the last chunk

Streaming mode: audio fed in 100 ms chunks, then 0.5 s of trailing silence; time measured from the last chunk until the final text is ready: **median 74 ms, p95 138 ms, max 169 ms** (2 threads); 144 / 221 / 268 ms (4 threads). That is the wait the child would see, and it is by far the best of the three, but see the accuracy problem below.

### Zipformer accuracy problem (unresolved)

With this model and config the transcripts consistently lose the start of the utterance (for example "The little fox wants to find a red balloon" came out as "'S WANTS TO FIND A RED BALLOON"; several 6 to 9 word utterances came out empty). Two follow-up runs on the same 144 WAVs, 2 threads: 500 ms of leading silence prepended (WER 67.7%, latency after last chunk median 60 ms), and the whole utterance fed in one call plus the 500 ms lead (WER 67.7%, same text). So chunking and missing leading silence are not the cause. Not diagnosed further: it may be the int8 20M model itself on TTS audio, a feature or config detail in the harness, or the audio level. Treat the 67 to 76% figure as "not usable as configured", not as a verdict on the model family. The summaries are in `results/wer-summary*.txt`.

### Worst Whisper utterances (for context)

Whisper failures are mostly the nonsense-word and very short items: "The ducks said quack quack quack" (heard as "the dark sand black black black"), single words ("Yes" came back empty or "Yes, yes", "Okay" came back "Okay. Okay"), and the Kathy voice on longer sentences. Short single-word replies are a Whisper weak spot (repetition and empty output) that matters for a kid saying "yes".

## ORT collision assessment

Both candidate libraries bundle a native `libonnxruntime.so` for arm64-v8a: sherpa-onnx-1.13.8.aar ships its own 22.2 MB `libonnxruntime.so` (the build embeds ORT version string 1.28.2, found by `strings`; best-effort), and the real app already depends on `onnxruntime-android:1.31.0`, which ships a same-named file. Vosk does not bring ORT (its natives are `libvosk.so` and JNA's `libjnidispatch.so`).

Verified empirically: adding `onnxruntime-android:1.31.0` to the spike module together with the sherpa AAR fails the build with `mergeDebugNativeLibs: 2 files found with path 'lib/arm64-v8a/libonnxruntime.so'`. So it collides in the real app. A `pickFirsts` workaround is risky because the Java ORT 1.31.0 binding would load a 1.28.2 native library (or the reverse); not tested.

Recommendation: do not use both. Either (1) switch to the `sherpa-onnx-static-link-onnxruntime-1.13.8.aar` variant (38.7 MB, links ORT statically, so no second `libonnxruntime.so`; not tested here), or (2) drop the app's direct `onnxruntime-android` dependency if nothing else needs it and let sherpa's AAR provide ORT. Option 1 is the cleaner fix; verify with a build that includes both before committing to it.

The AAR does contain the Kotlin API classes (`com.k2fsa.sherpa.onnx.OfflineRecognizer`, `OnlineRecognizer`, and friends, in `classes.jar`) and the JNI libs, so no source copying was needed. Vosk 0.3.75 resolved from Maven Central.

## Licenses

Unverified here (no offline source read): sherpa-onnx code Apache-2.0 per Phase A (not re-checked); Whisper weights MIT (widely documented, not read from the model files here); zipformer model license not verified; Vosk library and `vosk-model-small-en-us-0.15` Apache 2.0 per the vendor model page and Phase A (the model's README, read offline, states only copyright Alpha Cephei Inc 2020 and the accuracy figures).

## What this does and does not tell us

- The voices are adult synthetic TTS, clean and noiseless. Nothing here is reliable about child speech (higher pitch, unclear articulation, made-up words) or real rooms (TV, siblings, distance from the phone). Child accuracy is likely worse than these figures and needs the author's own later testing with real recordings.
- Speed numbers are real and device-specific, and transfer reasonably well: they depend on audio length and the chip, not on who is speaking. One device, one idle thermal state, one run; no thermal throttling over longer use was assessed.
- WER is over 24 short sentences, 924 words, so small differences (Whisper t2 vs t4) are noise. Words like "quack" show the vocabulary issue: made-up or animal words are hard for all engines.
- The zipformer result is inconclusive for the reason above. Its speed and streaming latency are attractive, so it might merit one diagnostic pass (different model, or the non-quantized one) before being ruled out.
- Thread count: 4 threads gave no speedup over 2 for Whisper and was slower for zipformer, so use 2.

## Recommendation (labeled as such; the author decides)

- On-device default: **Whisper tiny.en int8 with 2 threads**. It is the only candidate with usable accuracy on this set (14.6% overall, 6 to 8% on the clean voices), at about 0.7 s per 2 to 3 second utterance warm (median RTF 0.36, p95 0.72), 1.1 s to load, about 130 to 235 MB of native memory. That is a tolerable wait for a turn-based story app.
- Vosk is worse on both axes here (24.7% WER, slower than real time at p95) and not recommended.
- Zipformer: do not pick as it stands.
- Cloud "better listening" fallback: this data does not show it is necessary for clean adult speech, and it cannot say anything about children. Keep it designed-in as an optional fallback (off by default, since the decision is that the child's voice stays on the phone) and decide after the author tests real child speech with Whisper tiny.en. If kid accuracy turns out poor, trying whisper base.en on-device is the next step before any cloud path.
- APK-size impact of the winner: model 103.6 MB pushed (int8 encoder 12.9 MB + decoder 89.9 MB + tokens; about 110 MB on disk) plus the library: the arm64 native libs in the spike APK are `libonnxruntime.so` 22.2 MB, `libsherpa-onnx-jni.so` 4.8 MB, `libsherpa-onnx-c-api.so` 4.5 MB, `libsherpa-onnx-cxx-api.so` 0.4 MB (about 32 MB uncompressed; the whole spike APK with sherpa and Vosk, no models, arm64 only, was 17.7 MB compressed). Expect roughly +130 MB uncompressed if shipping model and library together; consider downloading the model on first run instead of bundling (Play bundle limits apply to a Play release, not to this sideloaded household app).

# Phase B report: on-device STT spike (#88)

Full results and recommendation: `docs/superpowers/specs/2026-10-21-android-stt-spike-results.md`. Raw data and summaries: `android/stt-spike/results/`.

## What was built
- Throwaway module `android/stt-spike-app` (applicationId `com.jessvb.tinytalk.sttspike`, arm64 only, no activities, no audio permissions), registered in `android/settings.gradle.kts`. Headless instrumented test `SttSpikeTest` reads WAVs from the app's external files dir and runs Whisper tiny.en (2 and 4 threads), zipformer en-20M (2 and 4 threads), Vosk small. Optional instrumentation args: `only`, `leadMs`, `chunkMs`, `out`.
- `android/stt-spike/wer.py` (stdlib only) prints cold/warm latency, RTF, WER overall and per voice, 8 worst utterances, and zipformer latency after the last chunk.
- Run on the Pixel 3 (8BDX18J4R, Android 12) via `adb install`, `adb push` and `am instrument -w`; nothing was played.

## Answers to the Phase A open questions
- The AAR contains the Kotlin API (`com.k2fsa.sherpa.onnx.*` in classes.jar) and its own `libonnxruntime.so` (22.2 MB arm64, string "1.28.2" inside). No source copy needed.
- ORT collision with `onnxruntime-android:1.31.0` is real: `mergeDebugNativeLibs` fails with "2 files found with path lib/arm64-v8a/libonnxruntime.so". Recommended fix: the `sherpa-onnx-static-link-onnxruntime-1.13.8.aar` variant (untested) or drop the app's separate ORT dependency.
- Vosk 0.3.75 resolved from Maven Central. Whisper `modelType = "whisper"` works.

## Headline numbers (warm, 144 WAVs, 924 ref words)
- Whisper tiny.en int8, 2 threads: median RTF 0.363, median latency 702 ms, WER 14.6%. 4 threads: no gain.
- Zipformer en-20M int8: median RTF 0.166, latency after last chunk median 74 ms, but WER 75.5% (drops utterance starts; not resolved, leading silence and whole-utterance feeding did not help).
- Vosk small: median RTF 0.780 (p95 1.116), WER 24.7%.

## Concerns
- Adult synthetic voices only; nothing reliable about children or noise.
- Zipformer's accuracy failure is undiagnosed; may be harness, config or model.
- PSS figures are approximate (the "before" baseline drifts between candidates).
- Licenses for Whisper/zipformer unverified offline.
- Harness bug found and fixed on the way: `Debug.getNativePss()` does not exist; `Debug.MemoryInfo.nativePss` is used.
- Note: the first full run (`results/results.csv`) has zipformer without leading silence; the extra runs are `results/lead500_*` and `results/whole_*`.

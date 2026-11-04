# Phase A report: on-device STT spike (#88)

Date 2026-10-21. Research via WebFetch of official pages; nothing downloaded, nothing played.

## Sources checked
- sherpa-onnx latest release v1.13.8 (Sep 10): https://github.com/k2-fsa/sherpa-onnx/releases/latest and asset list via https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/latest
- asr-models release asset list: https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/tags/asr-models
- Android docs index (no dependency info; only prebuilt APKs / build from source): https://k2-fsa.github.io/sherpa/onnx/android/index.html
- AAR build recipe: https://github.com/k2-fsa/sherpa-onnx/tree/master/android/SherpaOnnxAar
- Kotlin API sources (tag v1.13.8): https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.8/sherpa-onnx/kotlin-api/OfflineRecognizer.kt, OfflineStream.kt, OnlineRecognizer.kt, OnlineStream.kt
- Whisper export doc: https://k2-fsa.github.io/sherpa/onnx/pretrained_models/whisper/export-onnx.html
- HF model repos: https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny.en/tree/main , https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17/tree/main
- Vosk: https://alphacephei.com/vosk/install , https://alphacephei.com/vosk/models , https://repo1.maven.org/maven2/com/alphacephei/vosk-android/maven-metadata.xml , https://github.com/alphacep/vosk-api (Recognizer.java, SpeechService.java, android/lib/build.gradle)

## Integration facts per candidate

### Common: sherpa-onnx (a and b)
- NOT on Maven Central as far as found (no coordinates in any official doc). Route: prebuilt AAR from the GitHub release: asset `sherpa-onnx-1.13.8.aar` (50,129,134 bytes). Variant `sherpa-onnx-static-link-onnxruntime-1.13.8.aar` (38,691,998 bytes) statically links ORT; relevant because the app already depends on ONNX Runtime Android 1.31.0 and the plain AAR presumably ships its own libonnxruntime.so (possible duplicate-.so clash; unverified, try the static variant if packaging fails). Also exists: `sherpa-onnx-v1.13.8-android.tar.bz2` (46 MB, raw jniLibs bundle).
- AAR is built as a Gradle library module with jniLibs for arm64-v8a, armeabi-v7a, x86, x86_64 (SherpaOnnxAar README). Package `com.k2fsa.sherpa.onnx`; native lib `sherpa-onnx-jni`. That the AAR contains the Kotlin API classes is inferred, not verified (fetch script prints `unzip -l`). Fallback: copy `sherpa-onnx/kotlin-api/*.kt` from the repo at tag v1.13.8.
- Native build default min API android-21 (build-android-arm64-v8a.sh); fine for minSdk 26.
- License: repo Apache-2.0. Pass `assetManager = null` to load from file paths (models pushed via adb).

### (a) Whisper tiny.en int8, offline
- Files (HF `csukuangfj/sherpa-onnx-whisper-tiny.en`): `tiny.en-encoder.int8.onnx` 12.9 MB, `tiny.en-decoder.int8.onnx` 89.9 MB, `tiny.en-tokens.txt` 836 kB. Also a 118,071,777-byte `sherpa-onnx-whisper-tiny.en.tar.bz2` in asr-models.
- API:
  ```kotlin
  val cfg = OfflineRecognizerConfig(modelConfig = OfflineModelConfig(
      whisper = OfflineWhisperModelConfig(encoder = ".../tiny.en-encoder.int8.onnx",
          decoder = ".../tiny.en-decoder.int8.onnx", language = "en", task = "transcribe"),
      tokens = ".../tiny.en-tokens.txt", numThreads = 2, modelType = "whisper"))
  val rec = OfflineRecognizer(null, cfg)
  val s = rec.createStream(); s.acceptWaveform(floatSamples /*[-1,1]*/, 16000)
  rec.decode(s); val text = rec.getResult(s).text; s.release()
  ```
  (`modelType="whisper"` and the exact example layout are from my reading of the config classes; field names verified, usage sequence assembled from signatures.)
- Whisper license MIT (not fetched; widely known, mark unverified). Caveat: Whisper pads to a 30 s window so latency is roughly constant per utterance; short utterances may hallucinate; this is the expected slow one on SD845.

### (b) Streaming zipformer en-20M int8
- Files (HF `csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17`): `encoder-epoch-99-avg-1.int8.onnx` 42.8 MB, `decoder-epoch-99-avg-1.int8.onnx` 539 kB, `joiner-epoch-99-avg-1.int8.onnx` 260 kB, `tokens.txt` 5 kB (~44 MB). GitHub `asr-models` tarball `sherpa-onnx-streaming-zipformer-en-20M-2023-02-17.tar.bz2` = 127,887,156 bytes.
- API: `OnlineRecognizerConfig(modelConfig = OnlineModelConfig(transducer = OnlineTransducerModelConfig(encoder, decoder, joiner), tokens, numThreads))`; `OnlineRecognizer(null, cfg)`; `createStream()`; `stream.acceptWaveform(FloatArray, 16000)`; `while (rec.isReady(s)) rec.decode(s)`; `rec.getResult(s).text`; `isEndpoint(s)`; `reset(s)`; `inputFinished()`; append some trailing zeros to flush.
- Optional offline alternative: `sherpa-onnx-zipformer-small-en-2023-06-26.tar.bz2` (112,232,184 bytes), opt-in with `INCLUDE_OPTIONAL=1`; its internal file names unverified. Parakeet 0.6B (1.1 GB) is too big; no parakeet-110m asset seen (list partially read). Moonshine tiny int8 (107.6 MB) exists but was not asked for.
- License of the model: not verified (repo code is Apache-2.0).

### (c) Vosk small en-us 0.15
- Dependency: Maven Central `com.alphacephei:vosk-android`, latest 0.3.75 (metadata.xml); docs show `implementation group: 'com.alphacephei', name: 'vosk-android', version: '0.3.32+'`. minSdk 21; pulls `net.java.dev.jna:jna:5.18.1@aar` (from vosk-api android/lib/build.gradle; the repo build file may differ slightly from the published 0.3.75 POM).
- Model: https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip, 40M, Apache 2.0, WER 9.85 LibriSpeech test-clean / 10.38 TED-LIUM (vendor numbers). Unzips to a directory; loaded by path.
- API: `val model = Model(dirPath)`; `val rec = Recognizer(model, 16000f)`; `rec.acceptWaveForm(shorts /*or bytes/floats*/, n)` returns true at utterance end; `JSONObject(rec.finalResult).getString("text")`; Recognizer is `AutoCloseable`. `SpeechService` (mic) exists but we feed our own PCM, so skip it.
- License: library Apache 2.0 (per SpeechService header), model Apache 2.0.
- Android 12 / old-SoC caveats: none found documented for any candidate; unverified, to be measured.

## Unverified
- Exact download URLs for the AAR and asr-models assets (built from verified asset names plus GitHub's standard pattern).
- AAR internal contents (Kotlin classes included? bundled libonnxruntime.so?).
- Whisper MIT license, zipformer model licenses.
- Any Android 12 / SD845 performance caveats (to be measured in Phase B).
- Exact `modelType` string for Whisper; whether the Vosk published 0.3.75 matches the repo build.gradle.
- Whether sherpa-onnx has a Maven Central artifact (none found in docs).

## Files created (android/stt-spike/)
`.gitignore`, `fetch-models.sh` (not run; network), `make-test-audio.sh`, `utterances.tsv` (24 lines), `README.md` (Phase B design), this report.

## Test audio
Generated silently by `make-test-audio.sh` (say -o + afconvert): 144 WAVs (24 utterances x 6 voices), 8.8 MB, 16 kHz mono Int16 (checked with afinfo), in gitignored `testdata/wav/`. Voices: Junior (most child-like macOS voice), Kathy, Samantha, Daniel (en_GB), Karen (en_AU), Tessa (en_ZA). No process played audio. These are ADULT synthetic voices (Junior is only a higher-pitched novelty voice); they say nothing about real child-speech accuracy.

## Author action
`! bash /Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/android-demo-mode/android/stt-spike/fetch-models.sh`
(optionally prefix `INCLUDE_OPTIONAL=1`). Total ~250 MB.

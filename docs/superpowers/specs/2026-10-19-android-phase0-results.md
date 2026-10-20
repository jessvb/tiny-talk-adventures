# Android demo mode: Phase 0 audio spike results

Status: **MEASURED 2026-10-20 on the author's Pixel 3; verdict recommended by Claude, awaiting the author's confirmation.** Pass criteria (from the design spec): on the phone speaker, no headphones, quiet room, Elsie's own voice must not trigger the VAD, and a child's interruption stops her within about 1 s.

Runs were driven by hand by the author (tapping the spike screen's buttons) and read back from `adb logcat -s TinyTalkSpike`. Run types below are classified from the log (a run with no `SpeechStart` is a silent run; a `SpeechStart during playback` is an interruption), not from the author's notes.

## Device facts

| Item | Value | Source |
| --- | --- | --- |
| Device | Pixel 3 | barge-in log |
| Android | 12 (SDK 31) | barge-in log |
| TTS engine / voice | com.google.android.tts, en-US, 24 kHz | Task 5 / barge-in log |
| AEC available / enabled | available=true, enabled=true (every run) | barge-in log |
| NoiseSuppressor | not captured (log cleared before the audible runs) | n/a |
| Audio mode / routing (communicationMode ON) | requested=3, effective=3 (MODE_IN_COMMUNICATION applied); `setCommunicationDevice(speaker) ok=true, active=2 (speaker=2)` | barge-in log |
| Media volume levels used | 14/25 ("medium") and 25/25 (max) | barge-in log |

## First-audio latency (speak() to first sample written)

- Warm, communicationMode ON, barge-in runs: 383-650 ms (560, 383, 633, 644, 613, 614, 650, 631 ms).
- communicationMode OFF, max volume: 293 ms.
- Cold engine (after the toggle rebuilt `SentenceTts`): 4789 ms. Earlier cold start from Task 5: 5861 ms.
- Task 5 instrumented run: warm 0.85-1.6 s; the 16.7 s paragraph played in 18.4 s wall time with no measurable gaps.

## VAD inference time (Silero via ONNX Runtime)

- Task 4 instrumented run: mean 1.22 ms per 512-sample frame (a frame is 32 ms of audio), max 12.6 ms on the first call. Silence max probability 0.009; synthetic noise max 0.025.
- Live app, barge-in runs: running mean 2.3-2.9 ms per frame. Well inside the 32 ms budget.

## False triggers (silent runs: author stays quiet while the paragraph plays; target 0)

Count of `SpeechStart` during playback ("false triggers=N" summary).

| communicationMode | Volume | Result |
| --- | --- | --- |
| ON | medium (14/25) | 0, 0, 0 (three runs; durations about 16 s, 4 s, 24 s, so the 4 s run is weak evidence) |
| OFF (A/B) | max (25/25) | 0 (one run, about 20 s) |
| ON | max (25/25) | 0 (one run, about 55 s, including a speech-engine stall, see below) |

## Stop latencies (interruption runs: author says "stop, wait!" mid-paragraph; target about 1 s or less)

SpeechStart to `SentenceTts.stop()` returned with `isSpeaking` false, from the `stopped after N ms` log line.

| communicationMode | Volume | Stops (ms) |
| --- | --- | --- |
| ON | medium (14/25) | 7, 11, 10, 11, 7 (five runs) |

Note: this measures software stop only. The time from the child's first syllable to SpeechStart (3 voiced 32 ms frames, about 100 ms plus VAD) is on top of it, and any audio already queued in the device output buffer after stop is not measured (the track is paused and flushed). The author heard Elsie stop each time; the end-to-end figure is therefore well under 1 s but was not measured with a stopwatch.

## AEC status

Available and enabled on this Pixel 3 in every run. The communicationMode A/B was **inconclusive**: both OFF and ON gave 0 false triggers at max volume, so these runs cannot show that communication mode is what prevents echo triggers (the phone's AEC is attached to the mic either way). Keep it ON as the default; it is not proven necessary. The test distance (phone on a table about 40 cm away) was the favorable case; a phone held closer to the mouth/speaker was not tested.

AudioTrack/AudioRecord session sharing was deliberately not used; the AEC render reference appears to come from the system output path.

## Other findings

- **Audible cut-offs without barging in (author-reported, "once or twice").** None of them were detector triggers: there is no `SpeechStart during playback` line in the silent runs. The log shows a speech-engine stall that is a likely cause: after the toggle rebuilt `SentenceTts`, first audio took 4.8 s and `TTS synthesis timed out for sentence 4; skipping` fired (the 20 s no-progress watchdog). The exact cause of the other cut-off is unconfirmed. Implication for Phase 1: keep one warm `TextToSpeech` instance for the app's lifetime, and expect to handle occasional per-sentence synthesis stalls.
- **Spike UI bug (throwaway code):** the button label and the toggle follow a "run active" flag that only resets when the author taps the button, so a run that ends by interruption or by reaching the end leaves the label at "Stop barge-in test" and the toggle disabled. Not fixed, since the spike is throwaway.

## Verdict

**GO (recommended).** Against the pass criteria: Elsie's own voice did not trigger the VAD in any silent run (0 false triggers across 5 runs, medium and max volume, communication mode ON and OFF), and every interruption stopped her in 7-11 ms of software time plus about 100 ms of detection.

Caveats the author should weigh before confirming: one device, one quiet room, one distance and one (computer) voice; small samples (the shortest silent run was 4 s; one run per condition at max volume); the by-ear cut-offs are explained only in part; the communicationMode A/B did not separate the two settings.

## Options if the author disagrees (from the spec)

- Push-to-talk
- Headphones-recommended mode
- Drop the Pixel 3 as a target

# Android demo mode: Phase 0 audio spike results

Status: **TEMPLATE.** Everything marked `TBD (author run)` needs a live audible run on the Pixel 3 and has not been measured. No verdict has been written. Pass criteria (from the design spec): on the phone speaker, no headphones, quiet room, Elsie's own voice must not trigger the VAD, and a child's interruption stops her within about 1 s.

## Device facts

| Item | Value | Source |
| --- | --- | --- |
| Device | Pixel 3 | Task 5 run |
| Android | 12 (SDK 31) | Task 5 run |
| TTS engine / voice | com.google.android.tts, en-US, 24 kHz | Task 5 run |
| AEC available / enabled | TBD (author run) | barge-in log: `AEC available=... enabled=...` |
| NoiseSuppressor | TBD (author run) | MicCapture log |
| Audio mode / routing (communicationMode ON) | TBD (author run) | log: `audio mode requested=..., effective=...`, `setCommunicationDevice` |
| Media volume levels used | TBD (author run) | log: `media volume N/MAX` |

## First-audio latency (speak() to first sample written)

Source: Task 5 on-device run (SentenceTtsTest).

- Warm: 0.85-1.6 s (1604, 1558, 1126, 865, 852, 887 ms)
- Cold first run: 5861 ms
- The 16.7 s paragraph played in 18.4 s wall time with no measurable gaps.
- stop() about 0.5 s in: `isSpeaking` false immediately, no frames written afterwards.

## VAD inference time (Silero via ONNX Runtime)

Source: Task 4 on-device run.

- Mean 1.22 ms per 512-sample frame (a frame is 32 ms of audio), max 12.6 ms on the first call.
- Silence max probability 0.009; synthetic noise max 0.025.

## False triggers (silent run: author stays quiet for the whole paragraph; target 0)

Count of `SpeechStart` during playback ("false triggers=N" summary).

| communicationMode | Volume | Run 1 | Run 2 | Run 3 |
| --- | --- | --- | --- | --- |
| ON | default | TBD (author run) | TBD (author run) | TBD (author run) |
| ON | medium | TBD (author run) | TBD (author run) | TBD (author run) |
| ON | max | TBD (author run) | TBD (author run) | TBD (author run) |
| OFF (A/B) | default | TBD (author run) | TBD (author run) | TBD (author run) |

## Stop latencies (interruption run: say "stop, wait!" about two sentences in; target about 1 s or less)

SpeechStart to `SentenceTts.stop()` returned with `isSpeaking` false, from the `stopped after N ms` log line.

| communicationMode | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 |
| --- | --- | --- | --- | --- | --- |
| ON | TBD (author run) | TBD (author run) | TBD (author run) | TBD (author run) | TBD (author run) |

Note: this measures software stop only. The time from the child's first syllable to SpeechStart (3 voiced 32 ms frames, so about 100 ms plus VAD) is on top of it; any audio already queued in the device output buffer after stop is not measured (the track is paused and flushed).

## AEC status

TBD (author run): available / enabled (from the log), and whether it made a measurable difference (compare communicationMode ON vs OFF false-trigger counts).

AudioTrack/AudioRecord session sharing was deliberately not used (see the Task 6 report); the AEC render reference is expected to come from the system output path in MODE_IN_COMMUNICATION.

## Verdict

TBD (author run): GO or NO-GO against the pass criteria above.

## Options if NO-GO (from the spec)

- Push-to-talk
- Headphones-recommended mode
- Drop the Pixel 3 as a target

What the numbers suggest: TBD (author run).

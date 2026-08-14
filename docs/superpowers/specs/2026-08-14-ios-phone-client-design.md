# iOS Phone Client — Design Spec

Status: Approved (architecture confirmed by user 2026-08-14)

## Context

This is the second sub-project of Tiny Talk Adventures. The first —
the voice/dialog pipeline's Mac server — is built and merged to `main`
(`server/`), verified end to end against real models including a real
barge-in test, with a CLI tool (`server/tools/test_client.py`) standing in
for the phone client until now.

This spec covers the real phone client: the piece that actually captures a
child's voice, detects when they're speaking (including mid-barge-in),
streams audio to the server, and plays back replies. See
`docs/superpowers/specs/2026-08-12-voice-dialog-pipeline-design.md` for the
full original design and the wire protocol this client must speak
(`server/tinytalk/protocol.py` is the authoritative reference).

Personal pet project, single household, not shipped or scaled. Runs on the
author's own iPhone 13 Pro over home WiFi, connecting to the Mac server.
Android (Pixel 3) is an explicit non-goal for this sub-project, per the
original design's own deferral.

## Goals

- Get the interruptible voice loop working end to end on real hardware:
  connect, talk, hear replies, barge in mid-reply — proving out the parts
  the Mac-only CLI test client structurally cannot (real mic, real VAD,
  real acoustic echo, real barge-in latency).
- Measure the metric the original design spec called out as the one that
  matters most: VAD-fire → playback-stopped latency, end to end, on-device.
  The server side already logs its own interrupt-handling time, but that
  number alone doesn't answer whether barge-in actually feels instant to a
  child — only this client can measure that.

## Non-goals

- Any real UI polish, kid-facing design, or app "look" — this is a bare-bones
  test harness, the phone-side equivalent of the server's CLI test client,
  not a demo for the child yet.
- Animal facts, story visuals, illustrated storybook — all deferred to
  later sub-projects per the original design's own roadmap.
- Background audio mode. Foreground-only operation.
- Auto-reconnect logic. Mirrors the server's own philosophy: surface a
  failure clearly, require a manual restart, rather than building retry
  logic this single-user pet project doesn't need.
- Android/Pixel 3. Deferred, per the original spec's own non-goals.

## Architecture

- **SwiftUI** app, a single screen: a server-address field (persisted via
  `UserDefaults`, since the Mac's WiFi IP can change between sessions), a
  connect/disconnect button, a status line showing current state plus the
  last transcript/reply text for debugging, and on-screen latency numbers.
- **`URLSessionWebSocketTask`** for the WebSocket connection to the server —
  built into iOS, no third-party networking dependency needed for what this
  protocol requires.
- **Silero VAD via ONNX Runtime's iOS package**, running continuously on the
  mic stream for as long as the app is connected. Exact integration
  specifics (the model's expected input sample rate/chunk size, the exact
  inference call shape) are confirmed during implementation rather than
  assumed here — the same discipline applied to `moshi_mlx` on the server
  side, where assumptions from the original design turned out to not match
  the real installed package.
- **`AVAudioEngine`** for mic capture and playback, with `AVAudioSession` set
  to a voice-processing-enabled category. This is what provides hardware
  acoustic echo cancellation (AEC) — without it, the phone would hear its
  own TTS output through the mic and falsely trigger the VAD mid-reply,
  making barge-in unusable. This exact requirement was called out in the
  original design spec's error-handling section.

## Components

- **`AudioEngine`** — wraps `AVAudioEngine`. Taps the mic input continuously
  from connect to disconnect (never paused, including while the agent is
  speaking — this is what makes barge-in possible at all), converts the
  hardware's native capture format to the wire format (24kHz mono PCM16 LE,
  matching `server/tinytalk/audio.py`'s `MIC_SAMPLE_RATE`/`TTS_SAMPLE_RATE`,
  both 24kHz), and does the reverse conversion to play incoming TTS audio
  chunks. Owns `AVAudioSession`'s voice-processing category for AEC.
  Exposes a synchronous stop-playback-immediately method with no async
  dependencies — this is on the critical path for barge-in latency.
- **`VoiceActivityDetector`** — wraps Silero VAD via ONNX Runtime. Feeds it
  audio chunks, applies a probability threshold plus a short "hangover"
  window (a handful of consecutive quiet chunks required before declaring
  speech actually ended, to avoid flickering on brief mid-sentence pauses),
  and exposes clean speech-start/speech-end events to `SessionCoordinator`.
  Silero's model may expect a different native sample rate than the wire's
  24kHz (commonly 16kHz for Silero) — if so, this component owns whatever
  resampling that requires internally; confirmed during implementation.
- **`ServerConnection`** — wraps `URLSessionWebSocketTask`. Sends control
  JSON frames (`speech_start`/`speech_end`/`interrupt`, matching
  `server/tinytalk/protocol.py` exactly) and binary audio frames, decodes
  incoming JSON control messages (`transcript_partial`, `transcript_final`,
  `response_text`, `turn_end`, `error`) and binary TTS audio frames, and
  exposes them as an async event stream to `SessionCoordinator`.
- **`SessionCoordinator`** — the client-side counterpart to the server's
  `SessionRunner`. Owns a small state machine:
  `idle → listening → waitingForReply → speaking → idle`. This is where the
  interrupt logic lives: the moment `VoiceActivityDetector` fires while the
  state is `speaking` *or* `waitingForReply` (a barge-in can happen before
  any reply audio has even started arriving), it calls `AudioEngine`'s
  stop-playback method synchronously, in-process, with no network
  round-trip on the critical path, and sends `interrupt` over the
  `ServerConnection` in parallel — matching the design spec's core
  principle that the phone stops locally and doesn't wait for the server to
  confirm.
- **`LatencyLogger`** — records timestamps at VAD-fire, interrupt-sent, and
  playback-stopped for each barge-in event, and surfaces the deltas on
  screen. This is the acceptance test for the whole client, not an
  afterthought — see Goals above.
- **`ContentView`** (SwiftUI) — binds to `SessionCoordinator`'s published
  state: server address field, connect button, current state, last
  transcript/reply, latency numbers.

## Data flow

**Happy path:**
1. App launches idle; user enters/confirms the Mac's address and taps
   Connect.
2. On a successful WebSocket handshake, `AudioEngine` starts mic capture
   and `VoiceActivityDetector` starts evaluating it, continuously, for the
   life of the connection.
3. VAD detects speech onset while idle → `SessionCoordinator` sends
   `speech_start`, transitions to `listening`, and streams mic audio
   frames as they're captured.
4. VAD detects speech offset → sends `speech_end`, transitions to
   `waitingForReply`. VAD keeps running in the background (see interrupt
   path below).
5. Server sends `transcript_final` and `response_text` (shown on screen
   for debugging) and streams TTS audio chunks.
6. On the first audio chunk, `SessionCoordinator` transitions to
   `speaking` and `AudioEngine` begins playback while VAD keeps
   monitoring the mic throughout — AEC prevents the phone's own speaker
   output from re-triggering it.
7. Server sends `turn_end` → transition back to `idle`.

**Interrupt path:**
1. While `speaking` (or `waitingForReply`), VAD detects genuine speech.
2. `SessionCoordinator` immediately (a) tells `AudioEngine` to stop
   playback right now, locally, with no network dependency, and (b) sends
   `interrupt` over the `ServerConnection`, in parallel.
3. `LatencyLogger` records the VAD-fire and playback-stopped timestamps
   for this event.
4. State transitions to `listening`; the newly-detected speech becomes the
   start of a new utterance, continuing from happy-path step 3.

## Error handling

- **WebSocket disconnects or fails to connect:** clear disconnected/error
  state on screen, mic capture stops, user must manually reconnect — no
  auto-reconnect, per the non-goals above.
- **Server sends an `error` message:** treat it as ending the current turn
  immediately (return to `idle`) rather than waiting for a `turn_end` that
  may never arrive. This is a lesson carried forward directly from a real
  bug found and fixed in the server's own CLI test client, where the tool
  hung forever on an `error` frame before that fix.
- **Mic/audio permission denied:** clear on-screen message, no crash.
- **VAD model fails to load:** clear one-time error state; the app cannot
  meaningfully function without VAD, so this blocks starting a
  conversation but does not crash.

## Testing approach

Same philosophy as the server sub-project: automated tests for logic that
can be isolated from hardware, manual on-device verification for
everything that can't (none of the audio/VAD/AEC/playback behavior is
meaningfully testable in the iOS Simulator).

- **Unit tests (XCTest):** `SessionCoordinator`'s state machine and event
  handling, driven with a fake `ServerConnection` and fake VAD events — no
  real audio, no real network. Mirrors how the server's `SessionRunner`
  was tested with fakes standing in for the real STT/LLM/TTS engines.
- **Manual on-device testing:** mic capture, VAD accuracy, AEC
  effectiveness, and playback must be verified on a real iPhone 13 Pro.
- **Latency measurement is the acceptance test for this whole client:**
  confirm via `LatencyLogger`'s on-screen numbers that VAD-fire →
  playback-stopped is genuinely near-instant, closing the loop the
  original design spec asked for but that the server alone couldn't
  measure.

## Open questions / risks

- Silero VAD's exact ONNX Runtime iOS integration (package name, model
  input format/sample rate, exact inference call shape) is unconfirmed —
  to be resolved during implementation via direct exploration, the same
  verification-first approach used for `moshi_mlx` on the server side. Do
  not assume a specific API surface before checking what the installed
  package actually provides.
- No confirmed measurement yet of real barge-in latency on an iPhone 13
  Pro. This is precisely what this sub-project exists to produce — not
  known in advance, the whole reason `LatencyLogger` is a first-class
  component rather than a nice-to-have.
- AEC effectiveness in practice (does `AVAudioSession`'s voice-processing
  mode fully prevent the phone hearing its own speaker output at
  real-world volumes in a real room) is unverified until manual on-device
  testing happens.

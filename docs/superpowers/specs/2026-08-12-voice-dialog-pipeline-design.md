# Voice/Dialog Pipeline — Design Spec

Status: Approved (architecture confirmed by user 2026-08-12)

## Context

This is the first sub-project of a larger pet project: a voice-based, collaborative
story-writing app for kids, where a child and an LLM co-write a story aloud, with
facts about a chosen animal, inspiration from the child's real environment (via
on-device object recognition), and an eventual illustrated storybook.

That full app is too large for one spec. It decomposes into: (1) this voice/dialog
pipeline, (2) the story generation engine (narrative arc + safety scaffolding),
(3) animal facts retrieval, (4) on-device object recognition, (5) illustration
sourcing with attribution, (6) storybook persistence.

This spec covers **only the voice/dialog pipeline** — the interruptible speech
I/O layer. It is being built first, ahead of the story engine, because
implementing low-latency interrupt handling is an explicit personal learning
goal for this project, alongside building something the author's child can use.

Personal pet project. Single user/household. Not scaled, not shipped, no
external users, no auth/TLS requirements. Runs entirely on the author's own
hardware over their home WiFi.

## Goals

- Build a working interruptible voice dialog loop: child talks, agent replies
  by voice, child can barge in at any point and have the agent respond to the
  interruption, not just finish its line.
- All models free to use, running locally (phone + home Mac server) — no
  cloud AI APIs, for cost and child-privacy reasons.
- Learn how real interrupt-latency engineering works in practice.

## Non-goals (deferred to later specs)

- Narrative structure (exposition/rising action/climax/falling action/resolution)
- Animal facts integration
- Environment-based inspiration (on-device object recognition)
- Illustration sourcing/attribution
- Storybook persistence and flip-through UI
- Production-grade content safety scaffolding — this spec includes only a
  placeholder keyword/topic filter on LLM output, not the real thing
- Android/Pixel 3 polish — built for iPhone 13 Pro first; Pixel 3 is a known
  secondary target likely needing separate VAD/audio-pipeline tuning later

## Hardware target

- Phone: iPhone 13 Pro (primary), Google Pixel 3 (secondary, unpolished)
- Server: M1 MacBook Pro, 16GB unified memory, same home WiFi network

## Model choices (verified 2026-08-12)

| Role | Model | Why | Fallback |
|---|---|---|---|
| STT | Kyutai STT (MLX build) | Standalone streaming STT model from the Moshi team — not the full-duplex Moshi model, just its STT capability. MLX build targets Apple Silicon. Includes a built-in semantic voice-activity signal (currently only exposed in Kyutai's Rust server, not the Python/MLX path — see Open Questions). | whisper.cpp streaming (higher latency, ~1-2s vs Kyutai's ~200ms, but far more prior art if Kyutai's MLX path proves difficult) |
| LLM | Qwen 3.5 9B, Q4_K_M, via Ollama (Metal backend) | Fits ~6.6GB, strong reasoning for its size, confirmed to fit 16GB Macs cleanly. Note: Ollama's new MLX backend (added March 2026) needs 32GB unified memory, so this 16GB Mac will use Ollama's default Metal backend, not MLX — still a solid, well-tested path, just not the newest one | Llama 3.3 8B via Ollama — more widely documented if Qwen tooling has rough edges |
| TTS | Kokoro-82M | 82M params, ~327MB, Apache 2.0, CPU-friendly, notably more natural-sounding than Piper — voice warmth matters for a kids' app | Piper (much faster ~40ms first-audio, but flatter/more synthetic voice) |
| VAD (on phone) | Silero VAD | Small enough to run continuously on-device (including the Pixel 3), fast enough for near-instant barge-in detection | — |

All four are free/open-weight and runnable fully offline.

## Architecture

```
┌─────────────────────────┐         WebSocket (LAN)          ┌──────────────────────────┐
│   Phone (iOS client)     │ ───────────────────────────────► │   Mac server (Python)    │
│                          │   binary: mic audio chunks       │                          │
│  - AVAudioEngine mic     │   JSON:   speech_start/end,      │  - Kyutai STT (MLX)      │
│    capture + AEC         │           interrupt              │  - Ollama (Qwen 3.5 9B)  │
│  - Silero VAD (on-device)│                                   │    kid-safe system prompt│
│  - WebSocket client      │ ◄─────────────────────────────── │  - stub safety filter    │
│  - Audio playback,       │   binary: TTS audio chunks        │  - Kokoro TTS            │
│    stops locally on      │   JSON:   transcript_final,       │  - WebSocket server      │
│    local VAD interrupt   │           response_text           │                          │
└─────────────────────────┘                                   └──────────────────────────┘
```

**Phone responsibilities:**
- Capture mic audio continuously
- Run Silero VAD locally on the mic stream at all times, including while the
  agent's own TTS is playing (this is what makes barge-in near-instant — no
  network round-trip is on the critical path for stopping playback)
- Enable iOS voice-processing AEC (`AVAudioSession` voice-chat mode) so the
  phone doesn't hear its own speaker output and false-trigger the VAD
- Stream mic audio to the Mac while VAD indicates speech
- Play back TTS audio chunks as they arrive; on local VAD interrupt, stop
  playback immediately and send an `interrupt` message to the server in
  parallel (not as a prerequisite to stopping)

**Mac server responsibilities:**
- One WebSocket session per phone connection
- Feed incoming audio to Kyutai STT, emit partial/final transcripts
- On `speech_end` (from phone's VAD) or STT's own end-of-turn signal, send
  the finalized transcript + running conversation context to the LLM
- LLM (Qwen 3.5 9B via Ollama) generates a short story-continuation reply
  under a kid-safe system prompt
- Stub safety filter checks the reply (keyword/topic denylist placeholder)
- Kokoro synthesizes the reply to audio, streamed back to the phone in chunks
  as it's generated (don't wait for full synthesis before sending first chunk)
- On receiving `interrupt` mid-turn, abort in-flight LLM generation and/or
  TTS synthesis for that turn and discard partial output

## Data flow

**Happy path:**
1. Phone samples mic audio continuously; local VAD watches it
2. VAD detects speech onset → phone streams audio to Mac, UI shows "listening"
3. Mac's Kyutai STT transcribes incrementally as audio arrives
4. VAD detects speech offset (silence) → phone sends `speech_end`
5. Mac finalizes the transcript, sends it + story-so-far context to the LLM
6. LLM generates a reply; stub safety filter checks it
7. Kokoro synthesizes audio, streamed to the phone in chunks
8. Phone plays chunks as they arrive; VAD continues monitoring the mic in
   the background throughout playback

**Interrupt path:**
1. While TTS is playing, phone's local VAD (with AEC active) is still
   watching the mic
2. VAD fires on genuine child speech → phone stops local playback
   immediately (no network dependency) and sends `interrupt` to the server
   in parallel
3. Server aborts any in-flight LLM generation / TTS synthesis for that turn
4. Server begins accepting the new audio stream as a normal speech-onset flow
5. The new transcript is appended to conversation context with a marker that
   the previous turn was interrupted, so the LLM's next reply can naturally
   react to the interruption (e.g. "wait, make it a dragon!")

## Error handling

- **Echo/feedback false-triggering VAD:** primary mitigation is enabling
  iOS's built-in AEC. This is a required integration step, not optional —
  flagged explicitly because it's easy to skip and will otherwise make the
  whole interrupt system unusable (agent will constantly "interrupt itself").
- **WiFi drop / Mac unreachable:** phone shows a clear connection-error state.
  No auto-reconnect logic needed for v1 given single-user/manual-restart
  pet-project scope — surfacing the failure clearly is enough.
- **Server-side model failure** (Ollama/Kyutai STT/Kokoro not running or
  crashed): server returns an explicit error message over the WebSocket;
  phone displays it. No auto-restart/supervisor needed for v1.
- **Rapid repeated interruptions:** not explicitly debounced in v1; if this
  proves annoying in practice, VAD sensitivity/minimum-speech-duration
  tuning is the fix, not new architecture.

## Testing approach

Given this is a personal project with a hardware-in-the-loop interaction
(real mic, real speaker, a real child's voice), automated end-to-end audio
testing isn't a good investment. The plan:

- Unit tests for the turn-taking state machine (idle → listening → agent
  speaking → interrupted → listening) — pure logic, no real audio needed
- Manual end-to-end testing on the actual phone + Mac over home WiFi,
  tuning VAD sensitivity by ear
- Latency instrumentation: log timestamps at VAD-fire, interrupt-message-sent,
  and playback-stopped, to confirm the local-stop design actually delivers
  near-instant interrupt response (this is the metric that matters most,
  given the project's learning goal)

## Open questions / risks

- Kyutai's built-in semantic VAD ("is the user done talking") is documented
  as available in their Rust server but not confirmed for the Python/MLX
  path this design relies on. If it's unavailable there, `speech_end` will
  rely solely on the phone-side Silero VAD's silence detection instead —
  acceptable fallback, but worth confirming early during implementation.
- No confirmed benchmark of Kyutai STT/Kokoro/Qwen 3.5 9B running
  concurrently on an M1 (vs. the newer chips most current benchmarks target).
  Should validate real-world latency/memory headroom early, since running
  three models on one 16GB Mac at once is the main hardware risk.

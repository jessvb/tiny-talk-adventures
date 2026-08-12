# Tiny Talk Adventures

A voice-based, collaborative story-writing app for kids. A child and an LLM
write a story together, out loud: the child picks an animal, real facts about
it get woven into the story, the story pulls inspiration from the child's own
environment (recognized on-device via camera), and the child can jump in and
change the story at any point. All AI runs locally — nothing leaves the
household.

Personal pet project, built for one family, not intended to scale or ship.

## Why

Three reasons this exists:
- Learning to build with Claude Code
- Learning how to build an interruptible, low-latency voice dialog system
- Building something real for the author's kid to play and learn with

## Status

The full app is being built as a sequence of independent sub-projects; each
gets its own design spec before implementation. See `docs/superpowers/specs/`
for specs in progress.

The **voice/dialog pipeline** — the interruptible speech I/O layer (phone
client + local Mac server), built first because low-latency barge-in
handling is the core technical learning goal — has its server implemented on
the `voice-dialog-server` branch, pending merge. One piece is still
pending: `tinytalk/stt_kyutai.py`'s recognizer is a deliberate stub
while the real `moshi_mlx` API is explored separately (see "Running the
server" below).

Next up: the iOS phone client.

Planned after that, in rough order: story generation engine (narrative arc +
safety scaffolding), animal facts retrieval, on-device object recognition for
environment-based inspiration, illustration sourcing with attribution,
storybook persistence.

## Architecture (current sub-project)

- **Phone** (iPhone 13 Pro primary target, Android/Pixel 3 secondary):
  captures mic audio, runs on-device voice-activity detection for
  near-instant interrupt handling, streams audio to the server, plays back
  spoken responses.
- **Server** (M1 MacBook Pro, 16GB, on the same home WiFi): runs local
  speech-to-text, a local LLM for story dialogue, and local text-to-speech.
  No cloud AI APIs — everything free and offline.

See `docs/superpowers/specs/2026-08-12-voice-dialog-pipeline-design.md` for
the full design. Note on the wire protocol: a client must send its
`speech_start`/`interrupt` control frame *before* the audio frames for that
utterance — audio arriving outside a listening state is silently dropped
(see `server/tinytalk/protocol.py`'s module docstring for details).

## Setup

The voice/dialog pipeline server (see Status above) is implemented under
`server/`. This section covers how to set up the environment to run it.
Commands verified 2026-08-12; re-check versions if it's been a while.

### Mac server prerequisites

1. **Homebrew** (if not already installed): https://brew.sh
2. **Python 3.12** — required by `moshi_mlx` (Kyutai STT):
   ```
   brew install python@3.12
   ```
3. **espeak-ng** — required by Kokoro TTS:
   ```
   brew install espeak-ng
   ```
4. **Ollama** — local LLM runtime:
   ```
   brew install ollama
   ollama pull qwen3.5:9b
   ```
   Note: Ollama's newer MLX backend (added March 2026) needs 32GB unified
   memory. On this 16GB M1, Ollama will use its default Metal backend
   instead — that's expected, not a misconfiguration.
5. **Kyutai STT** (MLX build), in a Python 3.12 virtualenv:
   ```
   pip install moshi_mlx
   ```
   Quick test once installed:
   ```
   python -m moshi_mlx.run_inference --hf-repo kyutai/stt-2.6b-en-mlx <audio-file> --temp 0
   ```
6. **Kokoro TTS**, in the same virtualenv:
   ```
   pip install kokoro soundfile
   ```

### Phone (iOS) prerequisites

- Xcode (latest stable) — for building/running the iPhone 13 Pro client
- An Apple ID added to Xcode for on-device deployment (required to run a
  dev build on a physical iPhone rather than the simulator — needed here
  since mic/speaker/camera hardware testing requires a real device)
- iPhone and Mac on the same home WiFi network; the phone app will connect
  to the Mac's local IP address (`ifconfig | grep inet` on the Mac to find it)

### Android (Pixel 3) — secondary target

Not yet scoped in detail; deferred until the iOS path is working. Will need
Android Studio and likely separate VAD/audio tuning given the older hardware
(see the design spec's non-goals).

### Running the server

**Known limitation:** `tinytalk/stt_kyutai.py`'s recognizer is
currently a deliberate stub (`NotImplementedError`) pending exploration of
the real `moshi_mlx` API — a human partner is filling it in separately. If
you follow the steps below today, expect
`error: Kyutai STT failed to transcribe: ...` on the first real utterance.
That's expected, not a bug.

First, create the virtualenv and install the package (one-time setup):

```bash
cd server
python3.12 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
```

Then, three terminals:

```bash
# 1. Ollama
ollama serve

# 2. The voice/dialog server
cd server && source .venv/bin/activate && python -m tinytalk.app

# 3. The CLI test client (stands in for the phone)
cd server && source .venv/bin/activate
say "tell me a story about a brave little fox" -o /tmp/utterance.wav --data-format=LEI16@16000
python tools/test_client.py /tmp/utterance.wav          # full turn
python tools/test_client.py /tmp/utterance.wav --interrupt-after 0.8   # barge-in
afplay /tmp/reply.wav
```

Run the tests with `cd server && source .venv/bin/activate && pytest`.

## Repo layout

- `docs/superpowers/specs/` — design specs, one per sub-project, dated
- `server/` — the voice/dialog pipeline server: Python, pytest, see
  "Running the server" below
- (further implementation directories to follow as sub-projects are built)

## Development

See `CLAUDE.md` for project conventions and context for AI-assisted
development in this repo.

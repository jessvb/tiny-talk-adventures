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
- Learning how to build an interruptible, low-latency voice dialog system
- Learning to build with Claude Code
- Building something real for my kiddo to play and learn with

## Status

The full app is being built as a sequence of independent sub-projects; each
gets its own design spec before implementation. See `docs/superpowers/specs/`
for specs in progress.

The **voice/dialog pipeline** — the interruptible speech I/O layer (phone
client + local Mac server), built first because low-latency barge-in
handling is the core technical learning goal — has its server implemented
and merged to `main`, verified end to end against real models (Kyutai STT,
Qwen 3.5 9B via Ollama, Kokoro TTS) including a real barge-in test.

**Known constraint, confirmed real (not just a risk on paper):** running all
three models concurrently is tight on an M1/16GB — see the design spec's
"Open questions / risks" for what was actually measured. In short: expect
slow or occasionally failed replies on a loaded machine, and close other
memory-hungry apps for a fair test.

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
Commands verified 2026-08-13; re-check versions if it's been a while.

**Isolation policy:** nothing for this project is ever installed into
system Python or a global environment. Python version selection is pinned
per-directory via [pyenv](https://github.com/pyenv/pyenv) (`server/.python-version`),
and every Python package — including `tinytalk` itself — lives in
`server/.venv`, created fresh by the steps below. The one exception is
system-level tooling that isn't a Python package and has no meaningful
"environment" of its own: Ollama and espeak-ng are installed via Homebrew,
same as any other CLI tool on the machine. (Docker was considered and
rejected for this project: Kyutai STT's MLX backend needs direct access to
Apple's Metal/Neural Engine hardware, which Docker Desktop on macOS cannot
provide — containers there run inside a Linux VM with no Metal passthrough.)

### Mac server prerequisites

1. **Homebrew** (if not already installed): https://brew.sh
2. **pyenv** — manages the pinned Python version without ever touching
   system Python:
   ```
   brew install pyenv
   pyenv install 3.12.12   # matches server/.python-version
   ```
   `cd server` will then auto-select 3.12.12 via `.python-version` — no
   `brew install python@3.12`, and no relying on whatever `python3` already
   resolves to on your machine.
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
5. **Kyutai STT** (MLX build) — already declared in `server/pyproject.toml`;
   no manual installation needed. It will be installed automatically in step 3
   of "Running the server" below when you run `pip install -e ".[dev]"` inside
   the venv. Once the venv is active, you can test it standalone:
   ```
   python -m moshi_mlx.run_inference --hf-repo kyutai/stt-2.6b-en-mlx <audio-file> --temp 0
   ```
6. **Kokoro TTS** — also already declared in `server/pyproject.toml`; no manual
   installation needed. Like Kyutai STT, it installs automatically with
   `pip install -e ".[dev]"` in step 3 of "Running the server" below.

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

**Known constraint:** all three models (Kyutai STT, Ollama/Qwen, Kokoro TTS)
together need close to the full 16GB on an M1. Close other memory-heavy
apps (browsers, IDEs, VMs) before testing — with them running, expect slow
replies or an occasional failed turn from Ollama specifically, not from
this server's own code. See the design spec's "Open questions / risks" for
what was actually measured.

**First setup (one-time only):** Create the virtualenv and install all
dependencies (`tinytalk` itself, Kyutai STT, Kokoro TTS, and test tools) —
this is the only place anything gets installed:

```bash
cd server
python3.12 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
```

> **Copy-pasting commands from this README:** paste each code block as a
> whole, not line-by-line with extra text appended. If your shell is zsh
> (the macOS default — check with `echo $SHELL`), it does **not** treat a
> trailing `# comment` as a comment inside an interactive command the way
> bash does; anything after `#` gets passed as a literal extra argument
> instead. That's why these commands are written with no inline comments.

**Every time you open a new terminal:** Activate the venv before running
server commands:

```bash
cd server
source .venv/bin/activate
```

The `source .venv/bin/activate` command tells your shell to use the venv's
Python and packages for that terminal session. Every subsequent command in
this README assumes the venv is active. If you see `command not found` for
something Python-related, the venv is probably not active — run the
activation command above.

Then, three terminals:

**Terminal 1 — Ollama:**

```bash
ollama serve
```

**Terminal 2 — the voice/dialog server:**

```bash
cd server && source .venv/bin/activate && python -m tinytalk.app
```

**Terminal 3 — the CLI test client** (stands in for the phone). Record a
test utterance, then run a full turn, then try a barge-in interrupt:

```bash
cd server && source .venv/bin/activate
say "tell me a story about a brave little fox" -o /tmp/utterance.wav --data-format=LEI16@24000
python tools/test_client.py /tmp/utterance.wav
```

```bash
python tools/test_client.py /tmp/utterance.wav --interrupt-after 0.8
```

```bash
afplay /tmp/reply.wav
```

Run the tests with `cd server && source .venv/bin/activate && pytest`.

### iOS client

One-time setup:

```bash
brew install xcodegen
cd ios/TinyTalkApp
xcodegen generate
open TinyTalkApp.xcodeproj
```

In Xcode: select your iPhone as the run destination (not the Simulator —
mic/VAD/AEC need real hardware), set your team under Signing & Capabilities
so it can be installed via your free Apple ID, and Run. On first launch,
grant microphone access when prompted.

Enter your Mac's LAN IP (find it with `ifconfig | grep inet` on the Mac)
as `ws://<ip>:8765` and tap Connect. The server must already be running
(see "Running the server" above).

**Known limitation:** the VAD probability threshold and hangover window in
`VoiceActivityDetector.swift` are untuned defaults pending real on-device
testing — expect to adjust them by ear.

## Repo layout

- `docs/superpowers/specs/` — design specs, one per sub-project, dated
- `server/` — the voice/dialog pipeline server: Python, pytest, see
  "Running the server" below. `server/.python-version` pins the pyenv
  Python version; `server/.venv` (gitignored) is where all Python
  dependencies actually live — see the Setup section's isolation policy.
- (further implementation directories to follow as sub-projects are built)

## Development

See `CLAUDE.md` for project conventions and context for AI-assisted
development in this repo.

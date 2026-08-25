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

   qwen3.5 defaults to "thinking" mode — a long internal chain-of-thought
   before it ever produces a reply (confirmed on real hardware: 100+
   lines and ~3m19s for one prompt, via `ollama run qwen3.5:9b` directly).
   `config.OLLAMA_THINK` defaults to `False` specifically to disable this
   (see that setting's comment), which is what actually makes this usable
   at real-time latency — a smaller model was tried first and wasn't
   the real fix. With thinking off, 9b gives noticeably better-reasoned
   replies than 4b at acceptable latency on this 16GB Mac; if memory
   pressure becomes a problem again, `TINYTALK_MODEL=qwen3.5:4b` is the
   fallback.
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

If this fails with `address already in use`, Ollama is already running as a
background process (common if it's installed as a menu-bar app or login
item) — that's fine, nothing more to do here. Confirm with
`curl http://127.0.0.1:11434/`, which should reply `Ollama is running`.

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

#### Prerequisites

- Your iPhone and your Mac must be on the **same WiFi network**. Cellular
  data, a guest network, or a VPN on either device will prevent the phone
  from reaching the Mac.
- The server must already be running on the Mac (see "Running the server"
  above — you need Terminal 1 and Terminal 2 up; you don't need the CLI
  test client from Terminal 3 for this).
- An Apple ID (free tier is fine) to sign the app for your device in Xcode.

#### One-time setup

```bash
brew install xcodegen
cd ios/TinyTalkApp
cp Local.xcconfig.example Local.xcconfig
xcodegen generate
open TinyTalkApp.xcodeproj
```

`Local.xcconfig` is gitignored — it's how your own Apple Developer Team ID
stays out of the committed project file. `xcodegen generate` needs the file
to exist (even with its placeholder value untouched) or it fails with an
"Invalid config file" error; you don't need to edit it by hand, since the
next step sets your team from Xcode's UI anyway and that overrides it.

In Xcode: select your iPhone as the run destination (not the Simulator —
mic/VAD/AEC need real hardware), set your team under Signing & Capabilities
so it can be installed via your free Apple ID, and Run. On first launch,
grant microphone access when prompted — the app can't function without it
and will show a clear on-screen error if you deny it (Settings > Privacy >
Microphone to change your mind later).

#### Finding your Mac's address

The app needs your Mac's actual LAN IP, not its hostname and **not your
router's address**. On the Mac:

```bash
ifconfig | grep "inet " | grep -v 127.0.0.1
```

This prints one or more lines like `inet 192.168.1.185 netmask ...` — use
that IP. A common mistake: typing something like `192.168.1.1`, which is
almost always your **router's** gateway address, not your Mac's — the app
will connect to nothing and time out or show "disconnected from server".
If you see more than one `inet` line (e.g. WiFi and Ethernet both active),
use the one on the same subnet as your phone.

#### Connecting

In the app, enter `ws://<your-mac-ip>:8765` (matching `SERVER_PORT` from
`server/tinytalk/config.py`, 8765 by default) as the server address and tap
Connect. On success the state line changes from `idle` to reflect the
conversation as it happens. The address is remembered between launches, so
you only need to type it once per Mac.

#### Troubleshooting

- **"Error: disconnected from server", state stuck at `idle`:**
  - Double-check the IP — this is by far the most common cause. Re-run the
    `ifconfig` command above and compare it exactly to what's typed in the
    app; a stale IP from last time you were on a different WiFi network
    (e.g. a coffee shop) is a frequent trap.
  - Confirm the server is actually running and listening:
    `lsof -i :8765` on the Mac should show a `python3` process with
    `LISTEN` state. If nothing's there, Terminal 2 isn't running or
    crashed — check its output for errors.
  - Confirm both devices are genuinely on the same WiFi network (not one
    on 5GHz-only guest and one on the main network — some routers split
    these into separate subnets that can't reach each other).
  - macOS's firewall (System Settings > Network > Firewall) can silently
    block incoming connections to the Python process — either allow it
    when prompted, or temporarily disable the firewall to confirm this is
    (or isn't) the cause.
- **"could not start audio capture" / a permissions error:** you denied
  the microphone prompt. Go to Settings > Privacy & Security > Microphone
  on the phone, enable it for this app, and relaunch.
- **"failed to load VAD model":** the bundled `silero_vad.onnx` file failed
  to load — this shouldn't happen from a normal build (the file is
  committed and bundled by `project.yml`), so if you hit this, it's worth
  re-running `xcodegen generate` and a clean build
  (Xcode: Product > Clean Build Folder) before digging further.
- **Ollama-related errors in Terminal 2's output:** see the Ollama note in
  "Running the server" above — `address already in use` when starting
  Ollama separately usually just means it's already running.

#### What to actually test

1. **Happy path:** tap Connect, wait for `idle`, then talk. State should
   move `idle` → `listening` while you're talking → `waitingForReply` once
   you stop → `speaking` as the reply plays → back to `idle`. Check "Heard:"
   and "Reply:" show real text each turn.
2. **Barge-in — this is the actual point of this whole sub-project:**
   while the agent is speaking, talk over it. Playback should stop audibly
   *instantly*. Check the on-screen `VAD→stopped` latency list — that
   number is the real, on-device answer to whether barge-in feels instant
   enough for a child, which is something no amount of automated testing
   or Mac-only simulation could tell you in advance.
3. If barge-in doesn't fire, fires late, or falsely triggers on the
   agent's own voice (a sign AEC isn't fully suppressing echo), that's
   real signal — the VAD's probability threshold and hangover window in
   `VoiceActivityDetector.swift` are untuned defaults specifically pending
   this kind of on-device feedback. Expect to adjust them by ear.

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

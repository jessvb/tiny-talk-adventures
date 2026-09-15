# CLAUDE.md

Context for Claude Code sessions working in this repo.

## What this is

A voice-based, collaborative story-writing app for kids (personal pet
project, not a product — single household, no external users, no need to
scale). Full concept, constraints, and architecture: see `README.md`.

The project is being built as a sequence of independent sub-projects, each
with its own design spec under `docs/superpowers/specs/` before any
implementation starts. Don't assume the whole app is being built at once —
check which sub-project is currently active before making architectural
changes.

## Constraints that apply across all sub-projects

- **Free/local models only.** No paid cloud AI APIs. Everything must run on
  the author's own hardware: iPhone 13 Pro / Pixel 3 (phone) and an M1
  MacBook Pro, 16GB RAM (home server), on the same home WiFi.
- **Privacy-first.** The end user is a child. Data stays on the household's
  own devices — phone and home Mac — not third-party servers.
- **Kid-safe content.** Any subsystem that generates or speaks content to
  the child needs safety scaffolding appropriate to that. Don't assume a
  general-purpose model's default behavior is safe for this audience.
- **Pet-project scope.** Don't add production concerns (auth, scaling,
  multi-tenancy, elaborate monitoring/retry logic) that this project
  doesn't need. Optimize for the author learning and for the app working
  well for one family.
- **Isolated environments, always.** Never `pip install` into system or
  global Python. Every Python sub-project pins its interpreter with a
  `.python-version` file (pyenv) and keeps all dependencies in a local
  `.venv` created from it — for the server, see `server/.python-version`
  and README.md's Setup section. Before running any `pip`/`python`/`pytest`
  command, confirm the venv is active (`which python` should resolve inside
  the sub-project's `.venv`, not to a pyenv shim or system path). Docker is
  not used here: Kyutai STT's MLX backend needs native Metal/Neural Engine
  access, which Docker Desktop on macOS can't provide.

## Working process

This project uses the `superpowers` skill set for design and implementation:
1. New sub-projects go through `superpowers:brainstorming` before any code —
   spec lands in `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md`.
2. Specs are approved by the user before moving to implementation planning
   (`superpowers:writing-plans`).
3. Model/library choices that affect feasibility (what runs on this
   hardware, current best free models) should be verified against current
   information rather than assumed — this space moves fast.
4. Commit to worktrees in small, manageable commits as work progresses, rather 
   than batching large chunks of unrelated work into one commit.
5. Create PRs for the user to review before merging features to main (see
   "Testing on-device" below for what to tell them first).

## Testing on-device

Most feature branches live in a git worktree at `.claude/worktrees/<name>/`
(branch `worktree-<name>`) alongside this main checkout — several can
exist at once. Before merging a feature to main, tell the user exactly
what and how to test on-device: the **full path** (`~` for home is fine)
to the exact worktree directory to `cd` into for server commands, the
commands to run the server (and anything else it needs, like `ollama`),
and/or the full path to `open` in Xcode for a phone rebuild. Never a bare
`cd server` or "open the Xcode project" — a relative path resolves to
whichever worktree the shell or Xcode already happens to be in and can
silently test the wrong branch. Example, for a worktree named
`object-recognition`:

```bash
cd ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/object-recognition/server
```
```bash
open ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/object-recognition/ios/TinyTalkApp/TinyTalkApp.xcodeproj
```

The actual run commands (activating the venv, starting Ollama, etc.) live
in README.md's Setup section — keep it up-to-date as the one place they're
documented, rather than duplicating them here.

## Testing changes on-device

There is no CI and no simulator-only coverage for the iOS app's real
audio/network behavior — most changes are only actually verified by the
household running them on the real phone and Mac. After implementing
ANY change, before considering the task done, give explicit, concrete
instructions for testing it on-device — don't wait to be asked, and
don't treat "tests pass" as sufficient on its own. Cover all of these,
every time:

1. **Where the code lives.** Name the exact worktree directory (e.g.
   `.claude/worktrees/<name>/`) — this project works across multiple
   parallel worktrees at once, so "the code" is ambiguous without this.
2. **Does the server need restarting?** `server/tinytalk/app.py` has no
   auto-reload — any change to server Python code requires killing and
   restarting the running `python -m tinytalk.app` process before it
   takes effect. Give the exact commands for that specific worktree
   (`cd server`, that worktree's own `.venv`, `python -m tinytalk.app`),
   not just "restart the server". If the change is test-only or
   docs-only, say so explicitly instead of making the user restart for
   nothing.
3. **Does the iOS app need rebuilding?** Any change under `ios/` needs a
   fresh Build & Run from Xcode onto the device — say so explicitly. If
   the change is server-only, say explicitly that no rebuild is needed
   and the currently-installed build is still fine.
4. **Fresh-worktree gotcha:** `ios/TinyTalkApp/Local.xcconfig`
   (`DEVELOPMENT_TEAM`, gitignored) does not exist in a newly created
   worktree and must be recreated there before Xcode can build it — copy
   the value from that worktree's own `Local.xcconfig.example` (same
   Apple Developer Team ID works across all worktrees; it's the user's
   own account, not a secret).
5. **What to actually do and look for.** A short, concrete test script —
   what to say or tap, and what result confirms it worked (a specific
   log line, a specific UI state) — not just "try it and see."

## Current focus

The voice/dialog pipeline's server (interruptible speech I/O between phone
and Mac server) is implemented and merged to `main` — see
`docs/superpowers/specs/2026-08-12-voice-dialog-pipeline-design.md` for the
approved design. `server/tinytalk/stt_kyutai.py`'s recognizer is a full,
real implementation against `moshi_mlx` (streaming decode via `LmGen`,
correct silence-padding and per-utterance cache resets) — no longer a stub.
The iOS phone client's core loop (Onboarding/Landing/Story/Settings, design
1a) is also implemented and merged — see
`docs/superpowers/specs/2026-09-05-kid-facing-ui-design.md`.

Object recognition (PR #8) and the ditty-resume-backgrounding bug (PR #11
— root cause was `playerNode` not being reset in `rebuildCaptureTap()`)
are both merged and closed.

Storybook persistence (server side) is merged and **on-device verified**:
`server/tinytalk/storybook.py`'s background rewrite pipeline (title/pages/
epilogue from a saved story's transcript, gated by a `REWRITING` session
state so it never runs concurrently with a live story's LLM turns) plus
the arc-stage wire message, story-conclude action, and read/list API in
`story_store.py` are merged (PR #13) — see
`docs/superpowers/specs/2026-09-08-storybook-persistence-design.md`. A
real on-device play-through (2026-09-10) had the kid-safety check flag
content mid-rewrite, which exercised PR #18's retry logic
(`build_and_attach()` retrying up to
`config.STORYBOOK_SAFETY_RETRY_ATTEMPTS` times against the real local
`qwen3.5:9b`) — the rewrite still completed as `rewrite_status: "done"`.
Both the base rewrite pipeline and the safety-retry fix are now confirmed
against real hardware, not just the fakes-based test suite. PR #14 (a
small epilogue-grammar fix) and PR #21 (a second, separate safety-retry
gap — this one in the live "Finish this story" conclude flow rather than
the background rewrite, plus a fix for the empty-reply retry branch
resubmitting an unchanged prompt) are both merged too.

Parent-adjustable story length ("turns per story", "pages in the
storybook", via a new `update_settings` wire message) is implemented and
merged (PR #20) — see
`docs/superpowers/specs/2026-09-09-story-length-settings-design.md`.
Local `main` and `origin/main` are in sync.

Away-from-home demo mode — letting the phone talk to Elsie via cloud APIs
(Groq) when off the home WiFi, gated behind a hidden parent-only Settings
toggle — is implemented and **merged (PR #22)**; see
`docs/superpowers/specs/2026-09-09-away-from-home-demo-mode-design.md`.
Several rounds of real on-device testing found and fixed real bugs (a
dead Groq model id, TTS audio garbling, a voice-matching bug, and —
after 3+ partial buffer-tuning attempts didn't fully resolve audio
stutter — an architectural fix decoupling playback scheduling from
waiting for each buffer to finish) plus added a storyteller voice picker
in Settings. Currently confirmed working, not just merged. That testing
also surfaced gaps now tracked as their own issues rather than fixed
here: #23 (turn history lost after backgrounding), #24 (main's newer
features silently no-op in demo mode, since it bypasses the real
server), #25 (toggle LLM backend outside demo mode too), and #26 (demo
mode has no fallback for storybook page art's image generation, below —
it needs the home Mac's Neural Engine).

Wiring the iOS screens to the real server API (`list_stories`, `get_story`,
`synthesize_page`) instead of `MockStories.swift` is **partially in
flight**: PR #17 is **merged** — it wires The End screen — a "Finish this
story" menu item that sends the existing `conclude_story` action, and
real auto-navigation to The End gated on both `rewriting_started`
arriving and the concluding turn's audio actually finishing local
playback. The Library and Reading screens are still 100% mock-data-only;
wiring those (plus Landing's/StoryView's real "Read Stories" buttons, and
swapping `ReadingView`'s `AVSpeechSynthesizer` stand-in for a real
`synthesize_page` round trip) is unscoped and needs its own
`superpowers:brainstorming` session per "Working process" above before
implementation.

Storybook page art — per-page illustrations via a local Stable Diffusion
1.5 + LoRA + IP-Adapter pipeline (for character consistency across a
story's pages), generated during the same background rewrite — is
implemented and **merged (PR #27)**: see
`docs/superpowers/specs/2026-09-11-storybook-page-art-design.md`. The
real Stable Diffusion/LoRA/IP-Adapter call path had never executed
against real downloaded weights until on-device testing began, so
several real bugs (missing `peft` dependency, an attention-slicing/
IP-Adapter incompatibility, a severe Ollama/Stable-Diffusion memory-
contention slowdown, and an image-quality issue traced to a missing LoRA
trigger phrase) surfaced and were fixed one at a time directly on the
open PR rather than in review or fakes-based tests. Confirmed working on
real hardware, not just merged: a 3-page story's illustrations now
generate in ~3.5 minutes (down from ~90 minutes pre-fix), and image
style reads as storybook-appropriate after the trigger-phrase fix. That
testing also surfaced two issues confirmed unrelated to page art itself:
#34 (a PyTorch MPS segfault during live TTS/STT) and #36 (backgrounding
the app during an ordinary pause between turns can navigate to a stale,
unrelated earlier story's End screen).

For currently open bugs (several filed 2026-09-11 through 2026-09-14 out
of the on-device testing above), check `gh issue list` rather than this
file — issue status changes faster than this doc gets updated.

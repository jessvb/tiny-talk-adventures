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
4. Commit in small, manageable commits as work progresses, rather than
   batching large chunks of unrelated work into one commit.

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
approved design. One piece remains: `server/tinytalk/stt_kyutai.py`'s
recognizer is a deliberate stub pending exploration of the real `moshi_mlx`
API (see README.md's "Known limitation" note). Next up after that: the iOS
phone client.

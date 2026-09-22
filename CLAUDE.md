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
and Mac server) and the iOS phone client's core loop
(Onboarding/Landing/Story/Settings/Library/Reading/The End) are both
implemented, merged, and confirmed on real hardware — see
`docs/superpowers/specs/2026-08-12-voice-dialog-pipeline-design.md` and
`docs/superpowers/specs/2026-09-05-kid-facing-ui-design.md`. All of the
following sub-projects are merged to `main`: object recognition (PR #8),
ditty-resume-backgrounding (PR #11), storybook persistence and its
safety-retry fixes (PR #13/#14/#18/#21), parent-adjustable story length
(PR #20), away-from-home demo mode's original text loop (PR #22),
storybook page art via local Stable Diffusion (PR #27), and wiring the
Library/Reading/The End screens to the real server API instead of
`MockStories.swift` plus muting the mic on every non-story screen (PR
#17/#38/#42, 10/10 on-device). Local `main` and `origin/main` are in
sync.

**Demo mode parity** — closing the gap where away-from-home mode
silently no-op'd everything the other sub-projects had since added
(story-length settings, Finish-this-story, Library, Reading, page art) —
was the household's stated top priority as of 2026-09-19; see
`docs/superpowers/specs/2026-09-19-demo-mode-parity-design.md`. Both
phases are now **merged**: Phase 1 (PR #46) gives `DemoConnection` a real
local storybook (Groq-backed rewrite, file-backed store, the same wire
events a real server would emit) plus sync-to-home, all 7 on-device steps
passing; Phase 2 (PR #51) adds away-from-home illustrations via
Cloudflare Workers AI (FLUX), confirmed on-device across four real
passes after fixing a Cloudflare cold-start timeout, a wrong-animal
drift bug (a stateless per-page LLM call had nothing to stay consistent
with), and a Groq reasoning-model empty-reply gotcha
(`reasoning_effort`). Household's own words on the final pass:
"illustrations look great." One small open item: a one-word wording
amendment to the approved spec ("a *total* time budget" → drawing-phase
only, matching the spec's stated purpose) is still awaiting the
household's sign-off, not yet applied.

A parallel-subagent **bugfix batch**, triaged from the open-issue list
and merged in two rounds (PR #45, then a follow-up PR #50 built on top of
it), landed the same week: #28 (barge-in didn't stop Elsie in server
mode — pipelined playback let the session go idle mid-reply), #34 (a
SIGSEGV in PyTorch's `_lstm_mps` — actually a race in this repo's own
`tts_kokoro.py`, releasing the MPS cache from an unlocked second thread
while a cancelled synthesis was still running), #40/#23 (New Story/Finish
silently no-op'd after a dropped connection; turn history was lost on
backgrounding), #30 (The End's placeholder copy), #29 (The End/"Elsie is
talking" could end early — a hang-guard timer was measured from when a
buffer was *scheduled* instead of when its turn to play actually starts),
and #47/#48 (barging in on the story's final reply could strand the
child with no reply and no End screen; the red error banner never
cleared once its cause was gone). All confirmed on real hardware,
including a same-day second bug found and fixed during that testing (The
End failing to re-arm for a second story on the same session). #39 (mic
goes silent after a demo-mode session) got diagnostics only, no fix yet
— root cause still unknown, needs a fresh on-device repro to read the
new capture-state logging.

For the current bug list (including #24/#25/#26/#32/#33/#36/#41/#49/#52
— each needs its own read before assuming Phase 1/2 above already covers
it), check `gh issue list` rather than this file — issue status changes
faster than this doc gets updated.

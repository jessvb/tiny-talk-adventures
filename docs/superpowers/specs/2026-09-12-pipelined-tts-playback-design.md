# Pipelined TTS Playback — Design Spec

Status: Approved (design confirmed by user 2026-09-12)

## Context

Part of the away-from-home demo mode sub-project (PR #22,
`docs/superpowers/specs/2026-09-09-away-from-home-demo-mode-design.md`),
found during on-device testing rather than planned up front. Away-from-home
mode's on-device TTS (`AVSpeechTts`, backed by `AVSpeechSynthesizer`) was
reported as audibly stuttering — described as "tch tch tch," "slow and
jumpy" on first report. Root-caused across several on-device rounds, each
backed by real debug-log evidence rather than guessed:

1. `AVSpeechSynthesizer.write()`'s buffer callback fires roughly every
   10ms (confirmed: 1142 chunks, 358-558 bytes each, for one 13.25s
   reply). Yielding audio at that native granularity meant
   `SessionCoordinator`'s consuming loop called `RealAudioEngine.play()`
   ~1142 times for a single reply.
2. `RealAudioEngine.play(_:)` fully awaits a scheduled buffer's *real*
   playback completion (`completionCallbackType: .dataPlayedBack`, not
   just hand-off to the render engine) before returning — a deliberate
   choice from earlier work, because `SessionCoordinator.readyToShowTheEnd`
   needs to know audio has genuinely finished, not just been scheduled (a
   past real bug: The End screen appearing while Elsie's last sentence was
   still audibly playing).
3. Because `SessionCoordinator`'s `.audio` case handler calls
   `await audio.play(pcm)` once per event, serially, each of those ~1142
   calls is a full schedule-then-wait-for-real-completion round trip —
   confirmed via on-device timing diagnostics to have a small
   (~50-130ms), *roughly fixed-per-call* overshoot beyond the buffer's own
   audio duration, not proportional to buffer size. On-device synthesis
   was independently ruled out as a bottleneck (12-13s of audio
   synthesized in 0.2-1.0s wall-clock, 10-60x faster than needed).

Two fix rounds already landed against this evidence, each an honest
attempt, each insufficient alone:

- Reuse one `AVAudioConverter` per utterance instead of one per ~10ms
  chunk (fixed a real correctness issue — a fresh resampling filter
  starting cold at every chunk boundary — but did not resolve the
  stutter on its own).
- Coalesce `AVSpeechTts`'s output into ~200ms, then ~1s chunks before
  yielding (cut the call count from ~1142 to ~60, then to ~12-13 per
  reply — each round made it "a lot better," per the user, but never
  fully eliminated it, because the per-call overshoot is fixed-cost, not
  size-proportional: fewer calls only makes the same-sized gap rarer).

This spec covers the actual fix: eliminating the wait between consecutive
buffers within a turn, rather than continuing to reduce how often it's
paid.

## Goals

- Eliminate the audible per-buffer gap in TTS playback by letting
  `RealAudioEngine` accept multiple buffers "ahead" of when they're
  needed, instead of fully awaiting each one's real playback completion
  before the next can even be scheduled.
- Preserve `SessionCoordinator.readyToShowTheEnd`'s existing guarantee —
  it must still only become true once a turn's audio has *genuinely*
  finished being heard, not merely handed off to the render engine.
- Fix this once, in the shared consuming/playback layer
  (`RealAudioEngine` + `SessionCoordinator`), so both the away-from-home
  (Groq/`AVSpeechTts`) path and the real (LAN, Kokoro) server path
  benefit — not just a demo-mode-local workaround.
- Zero behavior change to the waiting ditty's own playback, which already
  works correctly and calls the same underlying engine.

## Non-goals (deferred or explicitly out of scope)

- **Removing or restructuring the existing 3-second scheduleBuffer
  completion timeout.** That workaround exists for a real, independently
  discovered failure mode (`AVAudioEngineConfigurationChange` /
  `engine.stop()` firing mid-render and silently dropping a completion
  callback) unrelated to this stutter. This change reuses that same
  per-buffer safety net unmodified, just aggregates across multiple
  outstanding buffers.
- **Investigating whether the ~50-130ms per-call overshoot has some
  deeper reducible cause** (e.g. `withCheckedContinuation` overhead vs.
  genuine CoreAudio output latency). Treated as likely-inherent hardware/
  API latency that pipelining renders harmless rather than something
  worth chasing further — see Context's evidence for why. This
  investigation is closed for the purposes of this fix; if a future
  regression suggests the overshoot has a different, reducible cause,
  that's a new investigation, not a reason to reopen this one.
- **Changing how the real (LAN) server chunks Kokoro's TTS output.**
  Server-side chunking is untouched; this fix benefits that path only
  through the shared client-side consuming/playback change.
- **A general-purpose "audio queue" abstraction reusable beyond TTS
  reply playback.** Scoped to what `SessionCoordinator`'s `.audio`/
  `turnEnd` handling actually needs.

## Architecture

`RealAudioEngine` gains two new methods (and the `AudioPlaying` protocol
it conforms to gains them alongside): `enqueue(_:)`, which schedules a
buffer and returns as soon as scheduling succeeds — not once the buffer
has actually finished playing — and `waitForPlaybackToFinish()`, which
suspends until every buffer enqueued so far has genuinely finished (or
resolves immediately if none are outstanding). `SessionCoordinator`'s
`.audio` case switches from `await audio.play(pcm)` to
`await audio.enqueue(pcm)`; the one `await audio.waitForPlaybackToFinish()`
moves to the `.message(.turnEnd(_))` case, immediately before
`noteTurnPlaybackFinished()` — preserving the existing "genuinely
finished" guarantee `readyToShowTheEnd` depends on, just checked once per
turn instead of once per buffer.

The existing `play(_:)` method is untouched and keeps its current
semantics (schedule-and-fully-await); the waiting ditty continues to call
it exactly as today, so this change carries zero risk to ditty playback.

## Components

**`PlaybackQueueTracker`** (new, private, inside `AudioEngine.swift`) — a
lock-protected (`NSLock`), `@unchecked Sendable` class, following the
exact idiom `PlaybackCompletionGate` already establishes in this file for
state shared between a completion closure and a detached `Task`. Holds:
- `outstanding: Int` — how many enqueued buffers haven't yet been
  confirmed complete (by real completion or by timeout).
- `waiter: CheckedContinuation<Void, Never>?` — at most one caller
  currently suspended in `waitForPlaybackToFinish()`.

Three operations, all lock-protected:
- `bufferEnqueued()` — increments `outstanding`. Called by `enqueue(_:)`
  right before `scheduleBuffer`.
- `bufferFinished()` — decrements `outstanding`; if it reaches zero and a
  `waiter` is set, take and resume it. Called from the *same* per-buffer
  `PlaybackCompletionGate`-guarded race between the real completion
  handler and the 3-second timeout that `play(_:)` already uses today —
  whichever fires first for a given buffer calls this exactly once.
- `waitForIdle() async` — if `outstanding <= 0`, resumes immediately;
  otherwise stores the continuation as `waiter` and suspends.
- `reset()` — forces `outstanding` to 0 and resumes any `waiter`
  immediately. Called from `stopPlaybackImmediately()`, alongside the
  existing `playerNode.stop()` — see Error handling for why this exists.

**`RealAudioEngine.enqueue(_:)`** — mirrors `play(_:)`'s existing
structure almost exactly (same `ensureEngineRunning()` guard, same
per-buffer `PlaybackCompletionGate` + 3-second-timeout race, same
`.dataPlayedBack` completion type): the only change is that it does not
wrap the `scheduleBuffer` call in `withCheckedContinuation` — it fires the
schedule, starts the buffer's own timeout-fallback `Task`, calls
`bufferEnqueued()` before scheduling and `bufferFinished()` from whichever
of (completion handler, timeout) wins the per-buffer race, and returns.

**`RealAudioEngine.waitForPlaybackToFinish()`** — a thin wrapper around
`tracker.waitForIdle()`.

## Data flow

For one TTS reply, per turn:

1. `SessionCoordinator` receives a `.audio(pcm)` event → `await audio.enqueue(pcm)` → returns quickly (scheduling is synchronous; only `ensureEngineRunning()`'s already-cheap happy-path check is awaited) → loop immediately proceeds to the next event.
2. Repeats for every `.audio` event in the turn — buffers queue on `playerNode` back-to-back, exactly how `AVAudioPlayerNode` is designed to be driven for gapless playback, instead of the current schedule-wait-schedule-wait pattern.
3. `.message(.turnEnd(_))` arrives → `await audio.waitForPlaybackToFinish()` suspends until the *last* enqueued buffer's completion fires (all earlier ones are necessarily already done, since the player node plays them in schedule order) → only then does `noteTurnPlaybackFinished()` run, preserving `readyToShowTheEnd`'s existing timing guarantee.
4. An empty-reply turn (no `.audio` events ever arrive) hits `waitForPlaybackToFinish()` with `outstanding == 0` → resolves immediately, matching today's behavior for that case.

## Error handling

**Barge-in / interrupt mid-turn.** `stopPlaybackImmediately()`
(`playerNode.stop()`) is called from four places in `SessionCoordinator`
today, including interrupt handling. This file already documents,
elsewhere, that `scheduleBuffer`'s completion handler does not reliably
fire once the engine has been stopped or reconfigured mid-render — so
this design does not assume a stopped buffer's completion will ever
arrive. `stopPlaybackImmediately()` therefore also calls
`tracker.reset()`, so any buffers that were outstanding at the moment of
a stop are treated as resolved (not stuck) and any future
`waitForPlaybackToFinish()` call — for a *later* turn — starts from a
clean `outstanding == 0` rather than potentially hanging forever on a
buffer whose completion will never come.

**Engine reconfiguration mid-playback**
(`AVAudioEngineConfigurationChange`). Unchanged from today: each
individual buffer's own 3-second timeout (reused verbatim from `play(_:)`)
still protects against this exact scenario per-buffer; `bufferFinished()`
still gets called exactly once per buffer either way, so the aggregate
tracker degrades the same way the existing single-buffer case already
does, just for however many buffers happen to be outstanding at the time.

**Residual accepted risk.** A narrow race already accepted elsewhere in
this codebase (e.g. `DemoConnection`'s documented residual around
`completeStory()`) has a shape here too: if `stopPlaybackImmediately()`'s
`tracker.reset()` races with a buffer's own completion callback landing
at nearly the same instant, the lock ensures no crash or double-resume,
but which one "wins" is not deterministic. Judged acceptable — the
observable consequence is, at worst, a `waitForPlaybackToFinish()` call
resolving very slightly earlier or later than a theoretically perfect
implementation would, never a hang or a crash.

## Testing approach

`RealAudioEngine` is used through the `AudioPlaying` protocol
(`Interfaces.swift`), which `SessionCoordinatorTests` already exercises
via a fake. Add `enqueue(_:)`/`waitForPlaybackToFinish()` to that
protocol and to the fake, with enough real simulation (record enqueued
buffers; let a test control when each "finishes"; a way to simulate a
stop/reset) to write real `SessionCoordinatorTests` cases for:
- Multiple `.audio` events in one turn all call `enqueue`, not `play` —
  and none of them block on each other.
- `waitForPlaybackToFinish()` (invoked at `turnEnd`) does not resolve
  until every enqueued buffer in that turn has been marked finished by
  the fake.
- An empty-reply turn's `waitForPlaybackToFinish()` resolves immediately.
- An interrupt mid-turn resets the tracker such that a *subsequent*
  turn's `waitForPlaybackToFinish()` isn't affected by the interrupted
  turn's un-finished buffers.

The genuinely-gapless-audio claim itself — the actual point of this
change — can only be confirmed on real hardware, same as every other
playback-timing claim in this file. On-device verification: repeat the
away-from-home Task 16 checklist's step 4 (full-turn TTS playback) and
confirm the debug log's per-`play()`/`enqueue()` timing lines (added
during this investigation) no longer show a compounding pattern of
per-buffer overshoot, and that it's subjectively no longer audibly
stuttering. Also re-verify barge-in (step 5) and The End auto-navigation
timing (once issue #24's gap is separately closed) aren't regressed,
since those most directly depend on the invariants this change touches.

## Open questions / risks

- **Real server (LAN/Kokoro) path re-verification.** This change is
  designed to help both paths (the household's explicit choice — see
  brainstorming discussion), but only the away-from-home path is being
  actively on-device-tested in PR #22 right now. Worth a real-device
  smoke test on the LAN path too before considering this fully done,
  even though Kokoro's own chunk sizes are presumed less affected than
  `AVSpeechSynthesizer`'s were.
- **`ensureEngineRunning()` called on every `enqueue()`.** Same as
  `play(_:)` today (not a new cost this change introduces), but worth
  noting: at ~12-13 calls per reply this is cheap (the happy-path check
  is a single `engine.isRunning` read), but if a future change increases
  call frequency again, this is a spot to look at first.

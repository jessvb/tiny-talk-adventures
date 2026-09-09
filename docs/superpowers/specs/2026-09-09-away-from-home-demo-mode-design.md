# Away-From-Home Demo Mode — Design Spec

## Context

Every sub-project so far assumes the phone and the home Mac server are on
the same WiFi network — that's the whole point of the voice/dialog
pipeline (see `2026-08-12-voice-dialog-pipeline-design.md`). But there are
times the app needs to be shown off (to family, at a demo) without the Mac
present at all: no LAN, no local STT/LLM/TTS.

This spec covers a parent-gated "away from home" mode: the phone connects
directly to Groq's hosted LLM and speech APIs instead of the home server,
for demo purposes only. It intentionally steps outside CLAUDE.md's
"Free/local models only... nothing leaves the household" constraint for
this one feature, by the household's own explicit choice — the same way
`llm_groq.py` already does for A/B-testing. The scope here is broader than
that existing Groq A/B path: a full standalone conversational loop that
runs with no server involved at all, reachable and gated entirely from the
phone.

Existing precedent this design leans on:
- `llm_groq.py` / `TINYTALK_LLM_BACKEND=groq`: Groq is already a swappable
  `LlmEngine`, used today for LAN-side A/B latency testing. Its docstring
  already states the privacy tradeoff explicitly.
- `SettingsView.swift`'s "UNDER THE HOOD" panel: reached only by a 1-second
  long-press, no visible affordance — the exact "not something a curious
  child should stumble into" pattern this feature also needs, already
  proven in this codebase.
- `SessionCoordinator.swift` depends only on the `ServerConnecting`
  protocol (`Interfaces.swift`), never on the concrete websocket — the key
  fact that keeps this feature from needing a second turn-state machine.

## Goals

- A child (with a parent's help) can have a full multi-turn, voice-driven
  story conversation with Elsie with no Mac server reachable at all —
  same safety filtering and narrative-arc pacing as a home session.
- Reaching the feature at all requires the same hidden long-press gesture
  already used for the debug panel, plus a Groq API key a parent must
  type in by hand (Keychain-stored) — a child can't self-activate it.
- A story told away from home ends up in the same story library as home
  stories do, once the phone reconnects to the home server.
- The feature costs nothing to run: every API it calls has a genuine,
  no-card-required free tier.

## Non-goals (deferred or explicitly out of scope)

- Browsing/reading past demo-mode stories while still away (`list_stories`
  / `get_story` against phone-local data). The Library/Reading screens are
  still preview-only against mock data (`SettingsView.swift`'s own
  comment, PR #12) — wiring a second live data source into UI that
  doesn't consume real data anywhere yet is solving a problem that
  doesn't exist.
- Any paid cloud API. Groq's TTS (Orpheus/PlayAI) was considered and
  rejected: confirmed via Groq's own docs
  (`console.groq.com/docs/model/canopylabs/orpheus-v1-english`) at
  $22.00/1M characters, still Preview status, no free tier — it would
  violate the "free" half of this feature's own goals, and adds a second
  live network dependency on the most demo-visible leg of the pipeline
  (voice playback).
- Auto-detecting a return to home WiFi. The parent turns demo mode off and
  taps Connect as usual; that's what triggers the story sync. Auto-switch
  is unneeded complexity for a single-household pet project.
- Android. Already a secondary, not-yet-scoped target for the whole app
  (see README's Status section).
- Any change to the real server (`server/tinytalk/`). This feature is
  entirely phone-side except for one new, small sync endpoint (see Data
  flow).

## Architecture

`SessionCoordinator` never talks to the websocket directly — it depends
only on the `ServerConnecting` protocol (`Interfaces.swift`): `send(_:
ClientMessage)`, `send(audio:)`, `events() -> AsyncStream
<ServerConnectionEvent>`, `close()`. Today `ServerConnection` is the only
conformer, backed by a real websocket to the Mac. This design adds a
second conformer, `DemoConnection`, backed by direct HTTPS calls to Groq
plus on-device speech APIs — fulfilling the exact same `ClientMessage`/
`ServerEvent` vocabulary from `protocol.py` (`speech_start`/`speech_end`/
`interrupt`/`transcript_final`/`response_text`/`turn_end`/`error`/
`arc_stage`) so that `SessionCoordinator`'s turn-state machine, VAD wiring,
barge-in handling, latency tracking, and debug log are all reused
completely unchanged. `AppModel` decides which conformer to hand
`SessionCoordinator` based on whether away-from-home mode is active.

Two small, deterministic server modules get ported to Swift, since
`DemoConnection` now stands in for everything `SessionRunner` does
server-side:

- `safety.py` → `Safety.swift`: same denylist-regex approach, same
  safe-phrase masking, same `SAFE_FALLBACK` text. Pure logic, no
  dependencies — a direct, low-risk port.
- `story_arc.py` → `StoryArc.swift`: same stage enum, same turn-budget
  math, same forced-conclusion/child-stop/natural-conclusion detection.
  Also pure logic, no dependencies.

`session.py`'s `_STT_FAILURE_GUIDANCE` text also gets ported alongside
`safety.py`, so an empty/failed transcript is handled the same way it is
today.

### Known implementation risk (flagged, not resolved here)

The wire protocol's audio is 24kHz mono PCM16 LE end to end (mic in and
TTS out). `AVSpeechSynthesizer`'s native output buffer format won't
automatically match that — some resampling/format conversion is needed on
the TTS output path before handing audio to the existing `AudioPlaying`
consumer. This should be verified early in implementation, not assumed to
just work.

## Components

### `DemoConnection` (new, `TinyTalkCore`)

Conforms to `ServerConnecting`. Owns one turn's lifecycle:

1. `send(.speechStart(turnId))` — begin buffering mic PCM (mirrors the
   real server only accepting audio while LISTENING).
2. `send(audio:)` — append to the buffer.
3. `send(.speechEnd)` — package the buffered PCM as a WAV file, POST to
   Groq's Whisper transcription endpoint, emit `.message(.transcriptFinal
   (text, turnId))`. No `transcript_partial` — Whisper's REST endpoint
   isn't streaming, and that message is optional.
4. Run `StoryArc.recordTurn(childText)` for stage guidance, build the
   messages array (system prompt + guidance + conversation history —
   same shape `session.py` builds), call Groq's chat-completions endpoint
   (same request shape as `llm_groq.py`, ported to a small Swift HTTP
   client), accumulate the streamed reply.
5. Run `Safety.filterReply(text)` on the full reply before doing anything
   else with it.
6. `StoryArc.recordReply(filteredText)` — updates `isDone`.
7. Emit `.message(.responseText(filteredText, turnId))`, then synthesize
   via `AVSpeechSynthesizer` and emit the result as `.audio(Data)` events,
   then `.message(.turnEnd(turnId))`.
8. If `StoryArc.isDone`, write the completed story to local phone storage
   (see Data flow) and reset arc/conversation state for a fresh story.

`send(.interrupt(turnId))` cancels whatever Groq/TTS async work is in
flight for the current turn and starts fresh, same semantics as a real
barge-in.

### `Safety.swift`, `StoryArc.swift` (new, `TinyTalkCore`)

Direct ports of `safety.py`/`story_arc.py`. No new behavior — the goal is
byte-for-byte equivalent decisions, verified by mirroring the existing
Python test cases (see Testing approach).

### Groq HTTP clients (new, `TinyTalkCore`)

Small Swift wrappers for: chat completions (streaming SSE, same shape as
`llm_groq.py`), Whisper transcription (multipart file upload). Both take
the API key and raise a typed error on non-200 responses, mirroring
`llm_groq.py`'s `EngineError` wrapping.

### `SettingsView.swift` changes

A new "AWAY FROM HOME" card, added inside the same long-press-revealed
area as "UNDER THE HOOD" (not a new discovery vector — nothing becomes
more discoverable than what's already there today):

- A masked `SecureField` for the Groq API key, stored in iOS Keychain
  (never `UserDefaults` or plaintext).
- A toggle, interactive only once a key is actually stored. Persists
  across launches (useful for a real multi-day trip).

When away-from-home mode is active, the existing "Elsie's brain lives
on..." copy on the server card changes to make that plainly visible
outside Settings too (e.g. on the Landing/Story screens) — not just
buried behind the long-press. That visibility, not a timeout, is the
safeguard against the mode silently staying on for weeks unnoticed.

### `story_store` sync (small server-side addition)

A new `ClientMessage` variant, `SyncDemoStories`, carrying one or more
story JSON payloads in the exact shape `story_store.save_story()` already
writes (`id`/`created_at`/`turns[speaker,text,interrupted]`). The server
writes each directly into `stories_dir` (reusing `save_story`'s write
path) and acknowledges; the client deletes its local pending copies once
acknowledged. This is the only server-side change in this feature.

## Data flow

**Live turn (away from home):** mic PCM → `DemoConnection` buffer →
Whisper transcription → `StoryArc.recordTurn` guidance → Groq chat
completion → `Safety.filterReply` → `StoryArc.recordReply` →
`AVSpeechSynthesizer` → playback, exactly mirroring the shape of a home
turn (STT → arc guidance → LLM → safety filter → arc update → TTS) one
level up the stack, in Swift instead of Python.

**Story completion (away from home):** on `StoryArc.isDone`, the turn's
full JSON (same shape as `story_store.save_story()`) is written to a
pending-stories directory in the app's local container.

**Sync (back home):** parent turns away-from-home mode off, taps Connect
as usual. On successful connection, the client sends `SyncDemoStories`
with any pending story JSON. The server writes them via `save_story`'s
path and acknowledges. The client deletes its local pending copies.

## Error handling

Reuses the existing `error` wire-message type — `SessionCoordinator`
already has to handle it for the real server path (network drops, engine
failures), so no new UI states are needed, only a new source that emits
it:

- Groq unreachable, non-200, or rate-limited (429): a kid-appropriate
  `error` event (e.g. "Elsie's cloud brain is having trouble — let's try
  again in a moment"), mirroring `llm_groq.py`'s existing `EngineError`
  wrapping.
- Empty/failed transcript: `_STT_FAILURE_GUIDANCE` steers the LLM the
  same way it does on the real server today, rather than confusing the
  child with a reply to nothing.
- `interrupt` mid-call: cancels the in-flight Groq/TTS async work.
- On-device TTS failure: `AVSpeechSynthesizer` is local and reliable, but
  on failure this must not crash or silently produce a turn with no audio
  and no indication anything happened — at minimum, log a debug entry
  (same debug log the backgrounding-bug investigation already uses) so a
  silent failure is diagnosable rather than mysterious.
- Return to home WiFi mid-trip: not auto-detected (see Non-goals).

## Testing approach

- **Unit (XCTest):** `Safety.swift` and `StoryArc.swift` get the same
  test cases already used for `safety.py`/`story_arc.py` (word-boundary
  matching, safe-phrase masking, stage transitions at the turn-budget
  boundaries, forced-conclusion ceiling, child-stop/natural-conclusion
  detection) — parity with the server's behavior is verified, not
  assumed.
- **Unit (XCTest):** `DemoConnection`'s turn logic gets tested against a
  fake Groq HTTP client, following the same "protocol seams tested with
  fakes" convention `SessionCoordinator`'s other dependencies
  (`AudioPlaying`, `VoiceActivityDetecting`) already use — no real network
  calls in the suite.
- **On-device:** a full concrete test script (server killed or Mac WiFi
  off, full multi-turn story including a barge-in, forced conclusion,
  and library sync on reconnect) gets written once implementation is
  complete, per this repo's usual "Testing changes on-device" convention
  — not before, since the exact UI entry points don't exist yet.

## Open questions / risks

- **AVSpeechSynthesizer output format vs the 24kHz PCM16 LE wire format.**
  Flagged above under Architecture; needs early verification during
  implementation, not assumed.
- **Voice quality gap.** `AVSpeechSynthesizer`'s built-in voices are
  noticeably more robotic than Kokoro's. Accepted for now, given the
  alternative (Groq TTS) isn't free — worth a real on-device listen
  before deciding whether this is good enough for actual demo use.
- **Groq's free-tier limits under real demo conditions** (30 requests/
  minute, per Groq's documented free tier) haven't been tested against a
  real multi-turn story session — should be a quick on-device check
  during implementation rather than an assumption carried into the plan.

# Server-Mode LLM Backend Toggle (Ollama vs Groq) — Design Notes

Status: Approved in brainstorming 2026-09-22, awaiting written-spec review.
Tracks issue #25.

## Context

In normal (home-server) mode the Mac server makes every LLM call: live
story replies (`session.py`'s `_run_turn`), the end-of-story storybook
rewrite (`storybook.build_and_attach`), and illustration scene-prompt
extraction (`illustrations._extract_scene_prompt`). All three share one
`LlmEngine` instance, `SessionRunner._llm`.

A Groq backend already exists server-side: `llm_groq.py`'s `GroqLlm`
implements the same `LlmEngine` protocol as `OllamaLlm`, added for
latency A/B-testing. It is chosen **once, at server startup**, by
`TINYTALK_LLM_BACKEND=groq` + `GROQ_API_KEY` (`app.py`'s `build_llm()`).
There is no way to switch from the phone.

Away-from-home demo mode (PR #22, `2026-09-09-away-from-home-demo-mode-design.md`)
is a different thing: it bypasses the server entirely and the phone talks
to Groq itself. This spec does not change demo mode.

## Goals

- From the phone, a parent can choose which LLM the **home server** uses
  for stories: local Ollama or Groq.
- The choice persists on the phone and applies to **the next story** —
  never mid-story — exactly like the story-length settings
  (`2026-09-09-story-length-settings-design.md`).
- One story = one model, end to end: its live turns, its storybook
  rewrite, and its illustration prompts all use the model that was in
  force when the story began.
- The parent can see which backend the Mac is *actually* using (e.g. if
  Groq was requested but the Mac has no key).

## Non-goals

- Sending the Groq API key from the phone to the server. The key stays
  server-side in `GROQ_API_KEY` (household decision, 2026-09-22). The
  phone's Keychain key remains demo-mode-only.
- Automatic fallback from Groq to Ollama mid-story on a Groq error. A Groq
  failure surfaces exactly like an Ollama failure does today
  (`EngineError` → `_fail_turn`).
- Switching STT or TTS. Speech recognition (Kyutai) and voices (Kokoro)
  stay local on the Mac regardless of this setting.
- Any change to away-from-home demo mode's behavior.

## Decisions (from brainstorming)

| Question (from issue #25) | Decision |
|---|---|
| How does the key reach the server? | Server env var `GROQ_API_KEY` only; phone sends just the choice. |
| Per-story or persistent? | Persistent parent setting, applied to the next story. |
| Same kid-safety scaffolding? | Yes, automatically — see "Safety" below. No new code. |
| Which UI entry point? | Inside the existing hidden tap-to-reveal parent card, renamed. |

## Wire protocol

**Phone → server:** `update_settings` gains one optional field:

```json
{"type": "update_settings", "target_turns": 7, "page_count": 5, "llm_backend": "groq"}
```

- Allowed values: `"ollama"`, `"groq"`. Any other value (including
  non-string) is a `ProtocolError`, same as a non-integer `target_turns`.
- Field absent → server keeps its current preference (so an older phone
  build, or demo mode's own messages, change nothing). The server's
  startup preference is `config.LLM_BACKEND` (`TINYTALK_LLM_BACKEND`,
  default `"ollama"`), which keeps its meaning as the default.
- `protocol.py`'s `UpdateSettings` gets `llm_backend: str | None = None`.

**Server → phone:** one new event, sent in reply to every
`update_settings` that carries `llm_backend`:

```json
{"type": "llm_backend", "requested": "groq", "active": "ollama", "groq_available": false}
```

- `requested`: the preference just stored.
- `active`: the backend the *next* story will actually use (`"ollama"` if
  Groq was requested but is unavailable).
- `groq_available`: whether the server has a usable Groq engine (i.e.
  `GROQ_API_KEY` was set at startup).
- No `turn_id` — like `story_list`, this isn't part of live turn-taking.
  Sent unbuffered (`_send_text_unbuffered`).

## Server design

**Engines.** `app.py` builds both engines up front and passes them to
`SessionRunner`:

- `OllamaLlm()` — always.
- `GroqLlm()` — only if `config.GROQ_API_KEY` is non-empty; otherwise
  `None`. (`GroqLlm.__init__` already raises `EngineError` without a key;
  `app.py` checks first rather than catching.)

`build_llm()` is replaced by `build_llms()` returning
`(OllamaLlm(), GroqLlm() | None)`. `SessionRunner`'s signature stays
backward-compatible: `llm=` keeps meaning the local (Ollama) engine, plus
two new optional keyword args, `groq_llm: LlmEngine | None = None` and
`llm_backend: str = "ollama"` (the startup preference, from
`config.LLM_BACKEND`). The ~90 existing test call sites that pass one
fake `llm=` are unchanged and behave exactly as today.

**Preference vs. story engine.**

- `self._llm_backend: str` — the parent's preference, updated by
  `handle_update_settings`.
- `self._story_llm: LlmEngine` and `self._story_llm_name: str` — captured
  in `_begin_story()`, alongside `_story_arc` and `_story_page_count`.
  Resolution: the preferred engine if it exists, else Ollama (logging a
  warning once per story start when Groq was preferred but unavailable).
- Live turns (`_run_turn`'s `stream_reply`) read `self._story_llm`.

`handle_update_settings` already calls `_begin_story()` when the arc
hasn't started, so a change made between stories reaches the next one
with no new mechanism. A change mid-story updates only the preference.

**Rewrite uses the concluded story's settings (targeted fix).** Today
`_run_turn`'s conclusion block calls `_begin_story()` *before*
`_run_rewrite` starts, and `_run_rewrite` reads `self._story_page_count`
— which by then already holds the **next** story's value. That's a
latent bug today (a page-count change made mid-story is applied to the
story that was in progress when it concludes), and it would become a model
mix-up with this feature. Fix: capture `page_count` and `llm` into locals
before `_begin_story()` and pass them into `_run_rewrite(story_id, turns,
shared_facts, llm=..., page_count=...)` explicitly. The illustration
pass inherits the same `llm` through `storybook.build_and_attach`.

**Synced demo stories** (`_run_synced_rewrite`) use the engine for the
current preference (resolved the same way as `_begin_story`). They have
no "story start" on this server to anchor to, and the current preference
is what the parent last chose.

**`_release_ollama_memory`** (illustrations) stays unconditional — asking
Ollama to unload when it's idle is harmless, and skipping it would need
backend-awareness in `illustrations.py` for no real gain.

**Groq `reasoning_effort`.** The phone's `GroqChatClient` had to send
`reasoning_effort: "low"` for illustration-prompt extraction with
`openai/gpt-oss-20b` (a Phase 2 empty-reply bug). The server's `GroqLlm`
sends no `reasoning_effort` today. The implementation plan includes a step
to check whether the server path shows the same symptom (empty scene
prompt) and, if so, to add an optional `reasoning_effort` parameter to
`GroqLlm` used only by `_extract_scene_prompt` — the same scope as the
phone's fix.

**Logging.** `handle_update_settings`'s existing log line adds
`llm_backend=<requested> (active=<name>)`. `_begin_story()` logs
`story llm: <name>` so an on-device test can confirm the switch from the
server log alone. The startup banner in `app.py` reports the startup
preference and whether Groq is available.

## Safety

Unchanged and backend-agnostic. Every live reply passes
`safety.filter_reply()` (`session.py`) and every storybook rewrite passes
`safety.find_blocked()` / the PR #18 safety-retry loop (`storybook.py`),
applied to the raw model output regardless of which engine produced it.
System prompts and story-arc guidance are the same messages for either
engine. No new safety code — tests assert the filter still runs when the
story engine is Groq.

## Privacy

Choosing Groq sends story conversation text (the transcribed child
speech and Elsie's replies) to Groq's cloud. Audio does not leave the
Mac. This is a household-chosen, off-by-default trade-off. Concretely:

- Default stays Ollama (phone default `"ollama"`; server default
  `TINYTALK_LLM_BACKEND`, itself `"ollama"`).
- The picker's caption says plainly what leaves the house.
- `llm_groq.py`'s module docstring ("Testing-only… not intended for real
  use with a child") is updated to describe it as a parent-chosen,
  off-by-default option with that privacy trade-off.

## Phone design

**`TinyTalkCore/Protocol.swift`:** `.updateSettings(targetTurns:pageCount:)`
gains `llmBackend: String?` (omitted from the JSON when nil). A new
`ServerEvent` case `.llmBackend(requested:active:groqAvailable:)` is
decoded from the new event. `DemoConnection` ignores the new field (it's
always Groq).

**`AppModel`:** `@Published var llmBackend: String` persisted in
UserDefaults (`"llmBackend"`, default `"ollama"`), sent on every
existing `updateSettings` call site. `setLlmBackend(_:)` persists it and,
if connected in home mode, sends `updateSettings` immediately.
`@Published var serverLlmStatus` holds the latest `.llmBackend` event
(nil until the server reports one — e.g. an older server).

**`SettingsView` hidden card:** `awayFromHomeCard` is renamed (working
title **"Elsie's Brain"**, final wording the household's call) and keeps
its reveal gesture. It gains, above the away-from-home controls:

- A segmented picker **"At home, Elsie thinks with: Mac (local) · Groq
  cloud"**, bound through `setLlmBackend`.
- Caption: *"Applies from the next story. With Groq, story text goes to
  Groq's cloud; listening and voices stay on your Mac. Needs
  GROQ_API_KEY set on the Mac."*
- A status line from `serverLlmStatus`: e.g. *"Mac will use: Groq"*, or
  *"Mac will use: Mac (local) — no Groq key set on the Mac"* when
  `requested == "groq"` and `!groqAvailable`. Hidden when disconnected
  or in away-from-home mode.

The existing Groq API key field and away-from-home toggle stay as they
are, with a small subheading so the two sections read as separate.

**`StoryView` status line:** unchanged. (Considered adding "· Groq",
but the only signal the phone has is `active`, which describes the *next*
story — right after a mid-story switch it would mislabel the story in
progress. The hidden card plus the server's `story llm:` log line are
enough.)

## Error handling

| Situation | Behavior |
|---|---|
| Groq requested, no `GROQ_API_KEY` on Mac | Server stays on Ollama, logs a warning, replies `active: "ollama", groq_available: false`; card shows why. |
| Groq call fails mid-turn (network, rate limit, bad key) | Existing `EngineError` → `_fail_turn` path: error banner, turn retryable. No silent fallback. |
| Invalid `llm_backend` value on the wire | `ProtocolError`, same as other malformed `update_settings`. |
| Older server (no `llm_backend` support) | It ignores the unknown field; phone never gets an `llm_backend` event; status line stays hidden. |
| Older phone (never sends the field) | Server uses `TINYTALK_LLM_BACKEND`, as today. |

## Testing

**Server (pytest):**
- `decode_client_message`: `llm_backend` present/valid, absent (→ `None`),
  invalid string, non-string.
- `encode_llm_backend` shape.
- `handle_update_settings`: between stories → next story's `_story_llm` is
  the chosen engine; mid-story → current story's engine unchanged, next
  story's changes; Groq requested with no Groq engine → Ollama +
  `groq_available: false` event.
- Conclusion → rewrite gets the **concluded** story's engine and page
  count even if both changed mid-story (covers the targeted fix).
- Safety filter still applied when the story engine is a fake "groq"
  engine emitting a blocked word.

**Phone (swift test):** `.updateSettings` encode with and without
`llmBackend`; `.llmBackend` event decode.

**On-device script** (full commands go in the PR per CLAUDE.md):
1. Start the server with `GROQ_API_KEY` exported; confirm the startup
   banner says Groq is available.
2. In Settings, reveal the hidden card, pick Groq. Server log shows
   `update_settings: … llm_backend=groq (active=groq)`; card shows
   "Mac will use: Groq".
3. Start a new story. Server log shows `story llm: groq`; the first reply
   arrives noticeably faster.
4. Mid-story, switch back to Mac (local). Current story keeps going on
   Groq (log shows no new `story llm` line) and its storybook/illustrations
   complete normally.
5. Next story: log shows `story llm: ollama`.
6. Restart the server *without* `GROQ_API_KEY`, pick Groq: card shows
   "no Groq key set on the Mac"; story runs on Ollama.

# On-Device Object Recognition — Design Spec

Status: Approved (design confirmed by user 2026-08-29)

## Context

Fifth sub-project of Tiny Talk Adventures, following the voice/dialog
pipeline (server + iOS phone client), the story generation engine, and
animal facts retrieval — all merged to `main`. Next item on the README's
roadmap, ahead of illustration sourcing and storybook persistence.

The server today (`server/tinytalk/session.py`) runs a working LLM-backed
storytelling loop, steered by two existing guidance sources that both feed
the same turn's LLM call: `StoryArc` (narrative stage) and
`AnimalFactTracker` (real animal facts, woven in when the child mentions a
known animal). This sub-project adds a third: letting the child bring
their immediate physical environment into the story by taking a photo of
something nearby — a toy, the couch, whatever's around — and having it
become part of what happens next.

Personal pet project, single household — see root `CLAUDE.md` for the
constraints that apply project-wide (free/local models only,
privacy-first, kid-safe content, no production concerns beyond what this
family's use actually needs).

## Goals

- Let the child, via an explicit on-screen camera button, take a photo of
  something nearby and have it become inspiration for the story.
- Recognition runs entirely on-device, using iOS's built-in Vision
  framework (`VNClassifyImageRequest`) — the photo itself never leaves the
  phone, only a short text label does. Matches this project's
  privacy-first constraint and doesn't compete with Ollama/Kokoro/STT for
  the M1 server's tight 16GB.
- The recognized object doesn't have to appear literally in the story —
  the LLM has creative license to transform it (a teddy bear could become
  a real bear character, a couch could become a mountain shaped like one,
  a computer could become a robot).
- Reuse the existing guidance-injection mechanism
  (`story_arc.py`/`animal_facts.py`'s pattern) rather than building a new
  one — this is strictly an additional guidance source feeding the same
  turn's LLM call, alongside the existing two.
- Never let a failed or ambiguous photo attempt (bad lighting, low
  classifier confidence, a camera error) block or degrade the core voice
  turn.

## Non-goals (deferred or explicitly out of scope)

- **Voice-triggered camera activation** (e.g. the child saying "look at
  this!"). Considered and deferred — would need new server-to-phone
  signaling that doesn't exist yet, plus phrase-detection false-positive
  risk. On-screen button only for v1.
- **Always-on or periodic automatic camera sampling.** Deliberately
  rejected as too privacy-intrusive for a kid-facing app — the camera is
  off except for the single moment the child explicitly takes a photo.
- **Fetching "real facts" about the recognized object**, unlike
  `animal_facts.py`. Arbitrary household objects don't have a meaningful
  facts API, and the point here is creative inspiration, not grounding in
  reality — no cache, no external API for this feature at all.
- **A custom or bundled CoreML object-detection model.**
  `VNClassifyImageRequest`'s built-in ~1300-category classifier is free,
  ships with iOS, fully on-device, and sufficient for v1. Revisit only if
  real-use classification quality proves inadequate.
- **Routing recognized animals (e.g. the family pet) through the existing
  `animal_facts.py` fact-weaving system.** A plausible future enhancement,
  not needed for v1 — `VNRecognizeAnimalsRequest` only covers cats and
  dogs anyway, a narrow win for the added branching.
- **Android support.** The phone client is iOS-only so far (no Android
  code exists in this repo yet); this sub-project follows that existing
  scope rather than expanding it.
- **Persisting photos or recognized labels beyond the current story
  session.** No photo history or storybook integration yet — that's a
  separate, later roadmap item (storybook persistence).

## Architecture

**iOS side (new):** a camera button in the UI opens the standard system
camera via `UIImagePickerController` — not a custom live-preview capture
pipeline, since this is a single on-demand photo, not a continuous view.
Once a photo is taken, a new `ObjectRecognizer` component (in
`TinyTalkPlatform`, parallel to `AudioEngine`) runs it through
`VNClassifyImageRequest` locally and extracts the top label above a
confidence threshold. Only that label — never the photo — gets sent to the
server, as a new small JSON message over the existing WebSocket connection
(the same channel `speech_start`/`speech_end`/etc. already use).

**Server side (new):** a new `object_recognition.py` module, structurally
parallel to `animal_facts.py` but considerably simpler — no cache, no
external API, since there's no "real fact" to look up for an arbitrary
household object. It takes a label, passes it through the existing
`safety.is_safe()` filter, and produces guidance text asking the LLM to
let the object inspire what happens next (literally or transformed) — fed
into the same turn's LLM call exactly like `animal_facts.py` already does.

**Timing:** taking a photo is a distinct action from speaking, not tied to
a specific turn boundary — it can happen whenever the child isn't
mid-utterance. `SessionRunner` holds the most recent unconsumed label in a
small tracker (mirroring `AnimalFactTracker`'s pending-state pattern) and
weaves it into the *next* turn's guidance, then clears it. It does not
interrupt an in-flight agent turn — no new barge-in semantics needed.

## Components

**iOS — `ObjectRecognizer.swift`** (new, in `TinyTalkPlatform`, parallel
to `AudioEngine.swift`):

```swift
struct RecognizedObject {
    let label: String
    let confidence: Float
}

final class VisionObjectRecognizer {
    func recognize(image: UIImage) async throws -> RecognizedObject?
    // Runs VNClassifyImageRequest, returns the top result above a
    // confidence threshold (default ~0.3, tuned during implementation --
    // same "reasonable default, easy to retune" treatment as
    // STORY_TARGET_TURNS), or nil if nothing clears it.
}
```

**iOS — UI wiring:** a camera button (in `ContentView.swift` or wherever
the session UI lives) presents the system camera via
`UIImagePickerController`. On a successful photo, `ObjectRecognizer`
classifies it; if a label comes back, it's sent to the server as a new
small message. If nothing clears the confidence threshold, nothing is
sent — the UI just shows a brief "couldn't quite tell what that is, try
again?" hint locally, no round-trip needed for that case.

**Protocol addition:** a new client→server message, e.g.
`{"type": "object_seen", "label": "teddy bear"}`. Deliberately no
`turn_id` — unlike `speech_start`/`interrupt`, taking a photo isn't tied
to a specific turn; it's queued and woven into whichever turn happens
next.

**Server — `object_recognition.py`** (new, structurally parallel to
`animal_facts.py` but much smaller — no cache, no external API):

```python
_WEAVE_IN_TEMPLATE = (
    "The child just showed you a photo of a {label}. Let it inspire what "
    "happens next -- it doesn't have to appear literally. A teddy bear "
    "could become a real bear character, a couch could become a "
    "mountain shaped like one, a computer could become a robot. Weave "
    "something inspired by it naturally into the action, not as an aside."
)

class ObjectTracker:
    def record_seen(self, label: str) -> None:
        """Called when an object_seen message arrives. Runs the label
        through safety.is_safe(); if it passes, stores it as the pending
        label (overwriting any earlier still-unconsumed one -- if the
        child snaps two photos before either gets woven in, only the
        most recent matters). Fails safety -> discarded silently."""

    def consume_guidance(self) -> str:
        """Call once per turn, alongside StoryArc/AnimalFactTracker.
        Returns weave-in guidance for the pending label and clears it,
        or "" if nothing is pending."""
```

**`session.py` wiring:** a new `handle_object_seen` method (parallel to
`handle_text`/`handle_audio`) feeds `ObjectTracker.record_seen`;
`_run_turn` appends `consume_guidance()` to the same guidance string
`story_arc`/`animal_facts` already build; `ObjectTracker` resets alongside
`_conversation`/`_story_arc`/`_animal_facts` at the existing per-story
reset site.

## Data flow

```
child taps camera button
  -> UIImagePickerController opens, child takes a photo
  -> VisionObjectRecognizer.recognize(image)          [entirely on-device]
     -> VNClassifyImageRequest -> top label + confidence
     -> below threshold: nil -> local "try again?" hint, nothing sent
     -> above threshold: RecognizedObject(label, confidence)
  -> {"type": "object_seen", "label": "teddy bear"} sent to server
       (photo itself never leaves the phone)

server: handle_object_seen(raw)
  -> ObjectTracker.record_seen(label)
     -> safety.is_safe(label)?
          no  -> discarded silently
          yes -> stored as the pending label (overwrites any earlier
                 unconsumed one)

... later, on whichever turn happens next (unrelated to the photo) ...

child speaks
  -> STT transcript
  -> StoryArc.record_turn(transcript)                  [unchanged]
  -> AnimalFactTracker.record_turn(transcript, stage)   [unchanged]
  -> ObjectTracker.consume_guidance()
     -> pending label present: weave-in guidance, then cleared
     -> nothing pending: ""
  -> LLM call with system_prompt + story guidance + fact guidance
       + object guidance
  -> reply text
  -> safety.filter_reply(reply)                         [unchanged]
  -> StoryArc.record_reply(filtered reply)               [unchanged]
  -> TTS + send to child                                  [unchanged]
```

## Error handling

Guiding principle, same as `animal_facts.py`'s: a failed or ambiguous
photo attempt must never block or degrade the core voice turn. Recognition
is fully local and near-instant (no network call, so none of animal
facts' slow-API/timeout concerns even apply here).

- **Camera permission denied / no camera available** (e.g. Simulator):
  checked before presenting the picker; button is disabled or shows a
  message pointing to Settings rather than presenting a picker that can't
  work.
- **Vision framework throws** (e.g. corrupt image data): caught, treated
  the same as "nothing recognized" — local hint, nothing sent to the
  server. Never crashes the app.
- **Below confidence threshold:** already covered in Data flow — local
  "try again?" hint, no server round-trip.
- **Label fails the safety filter:** discarded silently server-side, same
  as animal facts' "no fact available" case — the story just continues
  with no object reference. No error surfaced to the child; a confusing
  "that's not allowed" message to a five-year-old is worse than silently
  skipping it.
- **Malformed `object_seen` message** (e.g. missing `label`): handled the
  same way other malformed protocol messages already are (`ProtocolError`)
  — no new error path invented.
- **Photo taken but no turn ever follows** (child snaps a photo, then the
  session ends): the pending label just sits in memory and is discarded
  at the next per-story reset. Harmless no-op, not an error.
- **Connection drops right as the message is sent:** no new concern —
  rides on the same reconnect/resend resilience already built for the
  rest of the protocol this session.

## Testing approach

- **`ObjectRecognizer` (iOS):** unit tests inject a fake
  `VNClassifyImageRequest` result (can't run real Vision inference in CI)
  to test the threshold logic — above/below/exactly-at cutoff, empty
  results — same seam-injection style already used for
  `AudioEngine`/`SessionCoordinator` tests.
- **`object_recognition.py` (server):** pure Python, deterministic, no
  mocking needed at all (no cache, no API) — simpler than
  `animal_facts.py`'s tests. Cover: a safe label produces weave-in
  guidance and clears pending state; an unsafe label is discarded and
  produces no guidance; no pending label produces `""`; a second
  `record_seen` before consumption overwrites the first.
- **`session.py` integration:** extend the existing pattern
  (`test_animal_mention_adds_fact_guidance_to_the_llm_call` and friends)
  with a couple of new cases — an `object_seen` message followed by a
  turn includes the guidance in that turn's LLM call; the tracker resets
  on story completion alongside the others.

## Open questions / risks

- **Exact confidence threshold value** is deferred to implementation and
  real-device tuning — ~0.3 is a starting point, not a validated number.
- **Classifier label quality:** `VNClassifyImageRequest`'s ~1300-category
  taxonomy occasionally produces abstract or awkward labels (e.g.
  "furniture" instead of "couch") rather than concrete, story-friendly
  nouns. No code-level mitigation planned for v1 beyond the confidence
  threshold — worth a real-device pass with actual household objects
  before considering this done.
- **`UIImagePickerController` and the audio session:** presenting a modal
  camera picker's interaction with the existing `AudioEngine`/session
  lifecycle hasn't been verified. Given how much careful work went into
  backgrounding/audio-engine resilience already this session, this is
  worth explicitly checking on a real device during implementation, not
  assuming it's a non-issue.

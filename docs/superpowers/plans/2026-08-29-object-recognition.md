# On-Device Object Recognition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the child take a photo of something nearby (a toy, the couch,
whatever's around), classify it entirely on-device via iOS's Vision
framework, and weave creative inspiration from it into the next turn of
the story — mirroring how `animal_facts.py` and `story_arc.py` already
inject guidance into the same turn's LLM call, but simpler (no cache, no
external API, no "real fact" to look up).

**Architecture:** A new client→server protocol message (`object_seen`)
carries only a plain-text label — never the photo itself, which stays on
the phone. Server-side, a new `object_recognition.py` module (structurally
parallel to `animal_facts.py` but much smaller: no cache, no API, no
`async`) holds one pending label at a time and hands back weave-in
guidance the next time a turn runs, then clears it. Client-side, a new
`ObjectRecognizer.swift` (`TinyTalkPlatform`, parallel to
`AudioEngine.swift`) wraps `VNClassifyImageRequest`; its
confidence-threshold selection logic is split into a small pure function
in `TinyTalkCore` (unit-testable via plain `swift test`) from the
Vision/`UIImage`-touching wrapper in `TinyTalkPlatform` (iOS-only,
manually verified on-device — this project has no `TinyTalkPlatformTests`
target, and Vision inference can't run in a macOS unit test target
either way; see Task 6). A camera button in `ContentView.swift` drives a
standard system camera via `UIImagePickerController`.

**Tech Stack:** Python 3.12 (server, unchanged deps), Swift 6 /
`Vision.framework` / `UIImagePickerController` (iOS, unchanged deps — no
new package dependency).

**Spec:** `docs/superpowers/specs/2026-08-29-object-recognition-design.md`

## Global Constraints

- Full spec: `docs/superpowers/specs/2026-08-29-object-recognition-design.md`.
- Free/local models only — Vision's on-device classifier, no network call
  of any kind for recognition itself, per the spec's Goals.
- Privacy-first: only a short text label ever leaves the phone. The photo
  itself is never transmitted, stored, or referenced beyond the
  synchronous `recognize()` call that classifies it.
- A failed or ambiguous photo attempt (bad lighting, low confidence, no
  camera, denied permission, a Vision error) must never block or degrade
  the core voice turn — same guiding principle as `animal_facts.py`.
- No persistence beyond the current story session — no photo history, no
  storybook integration (explicitly out of scope; see the spec's
  Non-goals).
- Server: before running any `pytest`/`python` command, confirm the venv
  is active (`which python` resolves inside `server/.venv`, not a pyenv
  shim or system path) and run commands from the `server/` directory.
- iOS: `TinyTalkCore`'s test target (`TinyTalkCoreTests`) builds and runs
  via plain `swift test` on this Mac — no Xcode project needed. Any file
  referencing `UIImage`, `UIImagePickerController`, or other UIKit/
  Vision-on-`UIImage` APIs cannot be part of that target and must live in
  `TinyTalkPlatform` behind `#if os(iOS)`, same as `AudioEngine.swift`/
  `VoiceActivityDetector.swift` — see Task 6's Interfaces section for
  exactly where the line is drawn.
- iOS wire encoding stays hand-rolled (no `JSONEncoder`), matching
  `Protocol.swift`'s existing style — see Task 4.

---

### Task 1: `object_recognition.py` — `ObjectTracker`

**Files:**
- Create: `server/tinytalk/object_recognition.py`
- Test: `server/tests/test_object_recognition.py`

**Interfaces:**
- Consumes: `safety.is_safe(text: str) -> bool` (already exists).
- Produces (used by Task 3):
  - `class ObjectTracker`:
    - `__init__(self) -> None`
    - `def record_seen(self, label: str) -> None` — call when an
      `object_seen` message arrives. **Synchronous**, unlike
      `AnimalFactTracker.record_turn` — there is no cache or API call
      here, so nothing to `await`.
    - `def consume_guidance(self) -> str` — call once per turn, alongside
      `StoryArc.record_turn()`/`AnimalFactTracker.record_turn()`. Returns
      guidance to append to the system prompt for this turn and clears
      the pending label, or `""` if nothing is pending. Also synchronous.

- [ ] **Step 1: Write the failing tests**

Create `server/tests/test_object_recognition.py`:

```python
from tinytalk.object_recognition import ObjectTracker


def test_record_seen_then_consume_returns_weave_in_guidance():
    tracker = ObjectTracker()
    tracker.record_seen("teddy bear")

    guidance = tracker.consume_guidance()

    assert "teddy bear" in guidance
    assert "inspire" in guidance.lower()


def test_consume_guidance_returns_empty_string_when_nothing_pending():
    tracker = ObjectTracker()

    assert tracker.consume_guidance() == ""


def test_consume_guidance_clears_the_pending_label():
    tracker = ObjectTracker()
    tracker.record_seen("teddy bear")

    tracker.consume_guidance()

    assert tracker.consume_guidance() == ""


def test_second_record_seen_before_consumption_overwrites_the_first():
    tracker = ObjectTracker()
    tracker.record_seen("teddy bear")
    tracker.record_seen("couch")

    guidance = tracker.consume_guidance()

    assert "couch" in guidance
    assert "teddy bear" not in guidance


def test_unsafe_label_is_discarded_and_produces_no_guidance():
    tracker = ObjectTracker()
    tracker.record_seen("a bloody knife")

    assert tracker.consume_guidance() == ""


def test_unsafe_label_does_not_clear_an_already_pending_safe_label():
    # record_seen's job on an unsafe candidate is to discard THAT
    # candidate, not to wipe out whatever safe label was already pending
    # from an earlier photo -- see object_recognition.py's own doc
    # comment on record_seen for the reasoning.
    tracker = ObjectTracker()
    tracker.record_seen("teddy bear")
    tracker.record_seen("a bloody knife")

    guidance = tracker.consume_guidance()

    assert "teddy bear" in guidance
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd server && .venv/bin/python -m pytest tests/test_object_recognition.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'tinytalk.object_recognition'`.

- [ ] **Step 3: Create the module**

Create `server/tinytalk/object_recognition.py`:

```python
"""Deterministic tracking of a single "object the child just showed the
camera" -- weaves creative inspiration from a recognized household object
into the story's action, via guidance text appended to the same turn's LLM
call (no extra model call), the same mechanism story_arc.py/
animal_facts.py already use. Unlike animal_facts.py, there is no cache and
no external API here: an arbitrary household object has no "real fact" to
look up, and the point is creative inspiration, not grounding in reality.
See docs/superpowers/specs/2026-08-29-object-recognition-design.md for the
full design.
"""

from __future__ import annotations

from . import safety

_WEAVE_IN_TEMPLATE = (
    "The child just showed you a photo of a {label}. Let it inspire what "
    "happens next -- it doesn't have to appear literally. A teddy bear "
    "could become a real bear character, a couch could become a "
    "mountain shaped like one, a computer could become a robot. Weave "
    "something inspired by it naturally into the action, not as an aside."
)


class ObjectTracker:
    """Per-story tracker, constructed fresh alongside StoryArc/
    AnimalFactTracker and replaced whenever a story finishes and a new
    Conversation/StoryArc pair is created -- so a label seen in a
    finished story never leaks into the next one."""

    def __init__(self) -> None:
        self._pending_label: str | None = None

    def record_seen(self, label: str) -> None:
        """Called when an object_seen message arrives. Runs label through
        safety.is_safe(); if it passes, stores it as the pending label --
        overwriting any earlier still-unconsumed one, since only the most
        recent photo matters if the child snaps two before either gets
        woven in. A label that FAILS the safety check is discarded on its
        own -- it does not clear an already-pending safe label from an
        earlier photo. No error is surfaced either way: a confusing
        "that's not allowed" message to a five-year-old is worse than the
        story just continuing with no object reference (same reasoning as
        animal_facts.py's "no fact available" case)."""
        if safety.is_safe(label):
            self._pending_label = label

    def consume_guidance(self) -> str:
        """Call once per turn, alongside StoryArc.record_turn()/
        AnimalFactTracker.record_turn(). Returns guidance to append to the
        system prompt for this turn, clearing the pending label -- "" if
        nothing is pending."""
        if self._pending_label is None:
            return ""
        guidance = _WEAVE_IN_TEMPLATE.format(label=self._pending_label)
        self._pending_label = None
        return guidance
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd server && .venv/bin/python -m pytest tests/test_object_recognition.py -v`
Expected: PASS — all 6 tests.

- [ ] **Step 5: Commit**

```bash
cd server
git add tinytalk/object_recognition.py tests/test_object_recognition.py
git commit -m "feat(server): ObjectTracker weaves a recognized object into the next turn"
```

---

### Task 2: Server protocol — add the `object_seen` client message

**Files:**
- Modify: `server/tinytalk/protocol.py`
- Test: `server/tests/test_protocol.py`

**Interfaces:**
- Consumes: nothing new.
- Produces (used by Task 3):
  - `@dataclass(frozen=True) class ObjectSeen: label: str`, added to the
    `ClientMessage` union.
  - `decode_client_message` now also accepts `{"type": "object_seen",
    "label": "<text>"}`, raising `ProtocolError` if `label` is missing,
    non-string, or blank.

- [ ] **Step 1: Write the failing tests**

Add to `server/tests/test_protocol.py`. First, add `ObjectSeen` to the
existing import block at the top of the file (alongside `Interrupt`,
`SpeechEnd`, `SpeechStart`), then extend the existing parametrized
decode test and add new cases:

```python
from tinytalk.protocol import (
    Interrupt,
    ObjectSeen,
    ProtocolError,
    SpeechEnd,
    SpeechStart,
    decode_client_message,
    encode_error,
    encode_response_text,
    encode_transcript_final,
    encode_transcript_partial,
    encode_turn_end,
)


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ('{"type": "speech_start", "turn_id": 3}', SpeechStart(turn_id=3)),
        ('{"type": "speech_end"}', SpeechEnd()),
        ('{"type": "interrupt", "turn_id": 7}', Interrupt(turn_id=7)),
        ('{"type": "object_seen", "label": "teddy bear"}', ObjectSeen(label="teddy bear")),
    ],
)
def test_decodes_each_client_message_type(raw, expected):
    assert decode_client_message(raw) == expected


def test_decode_rejects_object_seen_missing_label():
    with pytest.raises(ProtocolError, match="label"):
        decode_client_message('{"type": "object_seen"}')


def test_decode_rejects_object_seen_non_string_label():
    with pytest.raises(ProtocolError, match="label"):
        decode_client_message('{"type": "object_seen", "label": 5}')


def test_decode_rejects_object_seen_blank_label():
    with pytest.raises(ProtocolError, match="label"):
        decode_client_message('{"type": "object_seen", "label": "   "}')
```

(Replace the existing `test_decodes_each_client_message_type` definition
in place — do not leave two copies of it in the file.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd server && .venv/bin/python -m pytest tests/test_protocol.py -v`
Expected: FAIL — `ImportError: cannot import name 'ObjectSeen'`.

- [ ] **Step 3: Add `ObjectSeen` and its decode branch**

In `server/tinytalk/protocol.py`, add the new dataclass immediately after
`Interrupt`:

```python
@dataclass(frozen=True)
class ObjectSeen:
    """The child took a photo and on-device Vision classified it; label is
    the recognized object's plain-English name (e.g. "teddy bear").
    Deliberately carries no turn_id, unlike SpeechStart/Interrupt -- taking
    a photo isn't tied to a specific turn boundary, it's queued and woven
    into whichever turn happens next. See
    docs/superpowers/specs/2026-08-29-object-recognition-design.md."""

    label: str
```

Update the union type and the type-lookup table just below it:

```python
ClientMessage = SpeechStart | SpeechEnd | Interrupt | ObjectSeen

_CLIENT_MESSAGE_TYPES: dict[str, type] = {
    "speech_start": SpeechStart,
    "speech_end": SpeechEnd,
    "interrupt": Interrupt,
    "object_seen": ObjectSeen,
}
```

Add a branch to `decode_client_message`, after the existing
`_TYPES_REQUIRING_TURN_ID` branch and before the final `return
message_type()`:

```python
    if message_type in _TYPES_REQUIRING_TURN_ID:
        turn_id = payload.get("turn_id")
        if not isinstance(turn_id, int):
            raise ProtocolError(f"{kind} requires an integer turn_id: {raw!r}")
        return message_type(turn_id=turn_id)
    if message_type is ObjectSeen:
        label = payload.get("label")
        if not isinstance(label, str) or not label.strip():
            raise ProtocolError(f"object_seen requires a non-empty string label: {raw!r}")
        return ObjectSeen(label=label)
    return message_type()
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd server && .venv/bin/python -m pytest tests/test_protocol.py -v`
Expected: PASS — all tests, including the new ones.

- [ ] **Step 5: Commit**

```bash
cd server
git add tinytalk/protocol.py tests/test_protocol.py
git commit -m "feat(server): add the object_seen client protocol message"
```

---

### Task 3: Wire `ObjectTracker` into `SessionRunner`

**Files:**
- Modify: `server/tinytalk/session.py`
- Test: `server/tests/test_session.py`

**Interfaces:**
- Consumes: `ObjectTracker` (Task 1), `ObjectSeen` (Task 2) — both already
  in place.
- Produces: no new public interface — only `SessionRunner`'s internal
  turn flow and `handle_text`'s message dispatch change.

- [ ] **Step 1: Write the failing integration tests**

Add to `server/tests/test_session.py`, using the file's existing
`make_session`/`run_full_turn`/`FakeLlm` helpers already defined at the
top:

```python
OBJECT_SEEN = '{"type": "object_seen", "label": "teddy bear"}'


async def test_object_seen_adds_weave_in_guidance_to_the_next_turns_llm_call(transport):
    llm = FakeLlm()
    session = make_session(transport, llm=llm)

    await session.handle_text(OBJECT_SEEN)
    await run_full_turn(session)

    system_message = llm.calls[0][0]
    assert "teddy bear" in system_message["content"]
    assert "inspire" in system_message["content"].lower()


async def test_object_seen_guidance_is_only_used_once(transport):
    llm = FakeLlm()
    session = make_session(transport, llm=llm)

    await session.handle_text(OBJECT_SEEN)
    await run_full_turn(session)

    llm.chunks = ["A dragon then!"]
    await session.handle_text('{"type": "speech_start", "turn_id": 2}')
    await session.handle_audio(b"\x03\x04")
    await session.handle_text(SPEECH_END)
    await session.wait_for_turn()

    second_system_message = llm.calls[1][0]
    assert "teddy bear" not in second_system_message["content"]


async def test_no_object_seen_message_sends_no_object_guidance(transport):
    llm = FakeLlm()
    session = make_session(transport, llm=llm)

    await run_full_turn(session)

    system_message = llm.calls[0][0]
    assert "showed you a photo" not in system_message["content"]


async def test_unsafe_object_label_is_discarded(transport):
    llm = FakeLlm()
    session = make_session(transport, llm=llm)

    await session.handle_text('{"type": "object_seen", "label": "a bloody knife"}')
    await run_full_turn(session)

    system_message = llm.calls[0][0]
    assert "knife" not in system_message["content"]


async def test_reaching_story_done_resets_the_object_tracker(transport, monkeypatch):
    monkeypatch.setattr(
        "tinytalk.session.story_store.save_story",
        lambda conversation, **kwargs: None,
    )
    llm = FakeLlm(chunks=["And they all lived ", "happily ever after."])
    session = make_session(transport, llm=llm)

    await session.handle_text(OBJECT_SEEN)
    await run_full_turn(session)

    assert session._object_recognition._pending_label is None, (
        "a story-ending turn must reset the object tracker to a fresh instance, "
        "same as _conversation/_story_arc/_animal_facts"
    )
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd server && .venv/bin/python -m pytest tests/test_session.py -k object_seen -v`
Expected: FAIL — `object_seen` isn't handled yet
(`test_no_object_seen_message_sends_no_object_guidance` passes trivially
already; the others fail: `handle_text` raises no error, but no guidance
ever appears, and `session._object_recognition` doesn't exist yet).

- [ ] **Step 3: Wire `ObjectTracker` into `SessionRunner`**

In `server/tinytalk/session.py`:

Add the import near the top, alongside the existing `from .animal_facts
import AnimalFactTracker`:

```python
from .object_recognition import ObjectTracker
```

Also add `ObjectSeen` to the existing `from .protocol import (...)` block:

```python
from .protocol import (
    Interrupt,
    ObjectSeen,
    ProtocolError,
    SpeechEnd,
    SpeechStart,
    decode_client_message,
    encode_error,
    encode_response_text,
    encode_transcript_final,
    encode_transcript_partial,
    encode_turn_end,
)
```

In `__init__`, immediately after `self._animal_facts =
AnimalFactTracker()`:

```python
        self._object_recognition = ObjectTracker()
```

In `handle_text`, add a case to the `match message:` block. `record_seen`
is synchronous and has no state-machine interaction (unlike
`SpeechStart`/`SpeechEnd`/`Interrupt`, which all delegate to a private
`_start_listening`/`_finish_listening`/`_interrupt` method for that
reason) — so this calls straight through with no wrapper method:

```python
        match message:
            case SpeechStart(turn_id=turn_id):
                await self._start_listening(turn_id)
            case SpeechEnd():
                await self._finish_listening()
            case Interrupt(turn_id=turn_id):
                await self._interrupt(turn_id)
            case ObjectSeen(label=label):
                self._object_recognition.record_seen(label)
```

In `_run_turn`, immediately after the existing block that adds
`fact_guidance`:

```python
            fact_guidance = await self._animal_facts.record_turn(
                transcript, self._story_arc.stage
            )
            if fact_guidance:
                guidance = f"{guidance}\n\n{fact_guidance}"
            object_guidance = self._object_recognition.consume_guidance()
            if object_guidance:
                guidance = f"{guidance}\n\n{object_guidance}"
```

Wherever `self._conversation = Conversation()`, `self._story_arc =
StoryArc()`, and `self._animal_facts = AnimalFactTracker()` are reset
together on story completion, add the fourth line immediately after them:

```python
                self._object_recognition = ObjectTracker()
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd server && .venv/bin/python -m pytest tests/test_session.py -v`
Expected: PASS — the five new tests, and every existing test in this file.

- [ ] **Step 5: Run the full server test suite**

Run: `cd server && .venv/bin/python -m pytest -v`
Expected: PASS, all tests across every file.

- [ ] **Step 6: Commit**

```bash
cd server
git add tinytalk/session.py tests/test_session.py
git commit -m "feat(server): wire ObjectTracker into the per-turn flow"
```

---

### Task 4: iOS protocol — add `.objectSeen(label:)`

**Files:**
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/ProtocolTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (used by Task 5): `ClientMessage.objectSeen(label: String)`,
  encoding to `{"type":"object_seen","label":"<escaped text>"}`. No
  `decodeServerEvent` change — `object_seen` is client→server only, the
  client never receives one back.

- [ ] **Step 1: Write the failing tests**

Add to `ios/TinyTalkCore/Tests/TinyTalkCoreTests/ProtocolTests.swift`,
alongside the existing `test...EncodesExactType` tests:

```swift
    func testObjectSeenEncodesTheLabel() {
        XCTAssertEqual(
            ClientMessage.objectSeen(label: "teddy bear").encode(),
            #"{"type":"object_seen","label":"teddy bear"}"#
        )
    }

    func testObjectSeenEscapesQuotesAndBackslashesInTheLabel() {
        // Vision's ~1300-category taxonomy is plain English words in
        // practice, but the encoder must still produce valid JSON for
        // any string -- this is the one field on the wire (unlike
        // turn_id, always an Int) that isn't safe to interpolate
        // unescaped.
        XCTAssertEqual(
            ClientMessage.objectSeen(label: #"a "cool" robot\thing"#).encode(),
            #"{"type":"object_seen","label":"a \"cool\" robot\\thing"}"#
        )
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ios/TinyTalkCore && swift test --filter ProtocolTests`
Expected: FAIL to build — `ClientMessage` has no member `objectSeen`.

- [ ] **Step 3: Add the case, escaping, and encode() arm**

In `ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift`, add the new
case to `ClientMessage`:

```swift
public enum ClientMessage: Sendable, Equatable {
    case speechStart(turnId: Int)
    case speechEnd
    case interrupt(turnId: Int)
    /// See object_recognition.py / this file's `ClientMessage` mirror --
    /// deliberately no turn_id, matching protocol.py's ObjectSeen.
    case objectSeen(label: String)

    public func encode() -> String {
        // Field order and separators are fixed here (no JSONEncoder) so the
        // wire bytes are exact and predictable.
        switch self {
        case .speechStart(let turnId):
            return #"{"type":"speech_start","turn_id":\#(turnId)}"#
        case .speechEnd:
            return #"{"type":"speech_end"}"#
        case .interrupt(let turnId):
            return #"{"type":"interrupt","turn_id":\#(turnId)}"#
        case .objectSeen(let label):
            return #"{"type":"object_seen","label":"\#(Self.jsonEscaped(label))"}"#
        }
    }

    /// Escapes the two characters that would otherwise break JSON's
    /// string-literal syntax. label is the only free-text field this
    /// file ever puts on the wire (every other field is a fixed type
    /// string or an Int) -- this keeps the file's "no JSONEncoder, exact
    /// wire bytes" style while still producing valid JSON for arbitrary
    /// text, rather than assuming Vision's labels never contain a quote
    /// or backslash.
    private static func jsonEscaped(_ s: String) -> String {
        var result = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ios/TinyTalkCore && swift test --filter ProtocolTests`
Expected: PASS — all `ProtocolTests`.

- [ ] **Step 5: Run the full TinyTalkCore test suite**

Run: `cd ios/TinyTalkCore && swift test`
Expected: PASS, all tests (nothing else references `ClientMessage`'s
exhaustive switch outside this file, so no other file needs a change for
Swift's exhaustiveness check to keep passing).

- [ ] **Step 6: Commit**

```bash
cd ios/TinyTalkCore
git add Sources/TinyTalkCore/Protocol.swift Tests/TinyTalkCoreTests/ProtocolTests.swift
git commit -m "feat(ios): add the object_seen client protocol message"
```

---

### Task 5: `SessionCoordinator.sendObjectSeen(label:)`

**Files:**
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/SessionCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ClientMessage.objectSeen(label:)` (Task 4).
- Produces (used by Task 7): `public func sendObjectSeen(label: String)
  async` on `SessionCoordinator`.

- [ ] **Step 1: Write the failing test**

Add to `ios/TinyTalkCore/Tests/TinyTalkCoreTests/SessionCoordinatorTests.swift`:

```swift
    func testSendObjectSeenSendsTheLabelToTheServer() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)

        await coordinator.sendObjectSeen(label: "teddy bear")

        XCTAssertEqual(connection.sentMessages, [.objectSeen(label: "teddy bear")])
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd ios/TinyTalkCore && swift test --filter SessionCoordinatorTests`
Expected: FAIL to build — `SessionCoordinator` has no member
`sendObjectSeen`.

- [ ] **Step 3: Add the method**

In `ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift`, add a
new public method. A good location is right after `setMuted(_:)`, since
both are simple client-initiated actions independent of the turn/VAD event
loops:

```swift
    /// Sends a recognized object's label to the server, to be woven into
    /// whichever turn happens next -- see object_recognition.py's
    /// ObjectTracker for how the server queues it. Deliberately not
    /// gated on `machine.state`: taking a photo is not tied to a turn
    /// boundary (per the design spec), so this is safe to call from
    /// .idle, .listening, .waitingForReply, or .speaking alike. Best
    /// effort, same as every other outgoing send in this file -- a
    /// failure here must not surface as a user-facing error; the child
    /// can just try the camera again.
    public func sendObjectSeen(label: String) async {
        try? await connection.send(.objectSeen(label: label))
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd ios/TinyTalkCore && swift test --filter SessionCoordinatorTests`
Expected: PASS — all `SessionCoordinatorTests`.

- [ ] **Step 5: Run the full TinyTalkCore test suite**

Run: `cd ios/TinyTalkCore && swift test`
Expected: PASS, all tests.

- [ ] **Step 6: Commit**

```bash
cd ios/TinyTalkCore
git add Sources/TinyTalkCore/SessionCoordinator.swift Tests/TinyTalkCoreTests/SessionCoordinatorTests.swift
git commit -m "feat(ios): SessionCoordinator.sendObjectSeen forwards a recognized label"
```

---

### Task 6: `ObjectRecognizer` — pure selection logic + Vision wrapper

**Files:**
- Create: `ios/TinyTalkCore/Sources/TinyTalkCore/ObjectRecognition.swift`
  (pure, cross-platform — the part that CAN be unit tested)
- Create: `ios/TinyTalkCore/Sources/TinyTalkPlatform/ObjectRecognizer.swift`
  (iOS-only, wraps `VNClassifyImageRequest` — the part that CANNOT)
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/ObjectRecognitionTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces (used by Task 7):
  - `TinyTalkCore`: `struct ClassificationCandidate: Sendable, Equatable {
    let label: String; let confidence: Float }`, `struct RecognizedObject:
    Sendable, Equatable { let label: String; let confidence: Float }`,
    `func selectTopClassification(_ candidates: [ClassificationCandidate],
    threshold: Float) -> RecognizedObject?`.
  - `TinyTalkPlatform`: `final class VisionObjectRecognizer` with `func
    recognize(image: UIImage) async throws -> RecognizedObject?` and
    `static let defaultConfidenceThreshold: Float`.

Why the split: the design spec's own Testing section says to "inject a
fake `VNClassifyImageRequest` result (can't run real Vision inference in
CI) to test the threshold logic." This project's `Package.swift` has no
`TinyTalkPlatformTests` target at all — `AudioEngine.swift` and
`VoiceActivityDetector.swift` (the two existing `TinyTalkPlatform`
components) are entirely untested by `swift test`, verified manually
on-device instead (see the ios-phone-client plan's Task 8). `UIImage`
itself is UIKit-only and unavailable on macOS, so anything touching it
can never join `TinyTalkCoreTests` regardless of Vision itself being
cross-platform. Pulling the threshold-selection decision out into a plain
function over `(label, confidence)` pairs — no `UIImage`, no `Vision`
import — is what actually makes it testable, consistent with this
project's existing pattern of keeping deterministic decision logic
separate from the I/O or hardware/framework call that feeds it (e.g.
`protocol.py`'s decode functions vs. `session.py`'s I/O, or
`animal_facts.py`'s pure helpers vs. its `httpx` calls).

- [ ] **Step 1: Write the failing tests**

Create `ios/TinyTalkCore/Tests/TinyTalkCoreTests/ObjectRecognitionTests.swift`:

```swift
import XCTest
@testable import TinyTalkCore

final class ObjectRecognitionTests: XCTestCase {
    func testPicksTheHighestConfidenceCandidateAboveThreshold() {
        let candidates = [
            ClassificationCandidate(label: "teddy bear", confidence: 0.62),
            ClassificationCandidate(label: "toy", confidence: 0.41),
        ]

        let result = selectTopClassification(candidates, threshold: 0.3)

        XCTAssertEqual(result, RecognizedObject(label: "teddy bear", confidence: 0.62))
    }

    func testReturnsNilWhenTheTopCandidateIsBelowThreshold() {
        let candidates = [ClassificationCandidate(label: "blur", confidence: 0.2)]

        XCTAssertNil(selectTopClassification(candidates, threshold: 0.3))
    }

    func testIncludesACandidateExactlyAtTheThreshold() {
        let candidates = [ClassificationCandidate(label: "couch", confidence: 0.3)]

        XCTAssertEqual(
            selectTopClassification(candidates, threshold: 0.3),
            RecognizedObject(label: "couch", confidence: 0.3)
        )
    }

    func testReturnsNilForEmptyCandidates() {
        XCTAssertNil(selectTopClassification([], threshold: 0.3))
    }

    func testTiesKeepWhicheverCandidateVisionRankedFirst() {
        // Vision's own results already come sorted by confidence
        // descending, so "first-seen wins a tie" naturally matches
        // Vision's own ranking rather than introducing a second,
        // independent tiebreak.
        let candidates = [
            ClassificationCandidate(label: "teddy bear", confidence: 0.5),
            ClassificationCandidate(label: "stuffed animal", confidence: 0.5),
        ]

        XCTAssertEqual(selectTopClassification(candidates, threshold: 0.3)?.label, "teddy bear")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd ios/TinyTalkCore && swift test --filter ObjectRecognitionTests`
Expected: FAIL to build — no such types/function exist yet.

- [ ] **Step 3: Add the pure selection logic**

Create `ios/TinyTalkCore/Sources/TinyTalkCore/ObjectRecognition.swift`:

```swift
/// Pure, cross-platform half of on-device object recognition -- the
/// confidence-threshold decision, with no dependency on Vision or
/// UIImage (both iOS-only / TinyTalkPlatform-only). See
/// TinyTalkPlatform/ObjectRecognizer.swift for the Vision-framework
/// wrapper that calls into this. Mirrors
/// server/tinytalk/object_recognition.py conceptually (deterministic,
/// no I/O) though the two don't share a protocol -- the server only
/// ever sees the final label, never candidate scores.
import Foundation

public struct ClassificationCandidate: Sendable, Equatable {
    public let label: String
    public let confidence: Float

    public init(label: String, confidence: Float) {
        self.label = label
        self.confidence = confidence
    }
}

public struct RecognizedObject: Sendable, Equatable {
    public let label: String
    public let confidence: Float

    public init(label: String, confidence: Float) {
        self.label = label
        self.confidence = confidence
    }
}

/// Picks the highest-confidence candidate, if any clears `threshold`.
/// candidates is expected in Vision's own already-sorted (descending
/// confidence) order, but this does not assume that -- it scans for the
/// max explicitly, keeping the FIRST-seen candidate on an exact tie
/// (see testTiesKeepWhicheverCandidateVisionRankedFirst).
public func selectTopClassification(
    _ candidates: [ClassificationCandidate], threshold: Float
) -> RecognizedObject? {
    guard var best = candidates.first else { return nil }
    for candidate in candidates.dropFirst() where candidate.confidence > best.confidence {
        best = candidate
    }
    guard best.confidence >= threshold else { return nil }
    return RecognizedObject(label: best.label, confidence: best.confidence)
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd ios/TinyTalkCore && swift test --filter ObjectRecognitionTests`
Expected: PASS — all 5 tests.

- [ ] **Step 5: Add the Vision wrapper (not unit-tested — see this task's Interfaces note)**

Create `ios/TinyTalkCore/Sources/TinyTalkPlatform/ObjectRecognizer.swift`:

```swift
/// Real on-device object classification via Vision's VNClassifyImageRequest
/// -- iOS-only because its public API takes a UIImage, which does not
/// exist on macOS (Vision.framework itself is cross-platform, but that
/// doesn't matter here; see AudioEngine.swift's file-level doc comment
/// for the same #if os(iOS) reasoning applied to a different framework).
/// The confidence-threshold decision itself lives in the pure, tested
/// selectTopClassification (TinyTalkCore/ObjectRecognition.swift) -- this
/// file's only job is mapping VNClassifyImageRequest's real output into
/// that function's plain input type. Not covered by swift test: this
/// project has no TinyTalkPlatformTests target (AudioEngine.swift/
/// VoiceActivityDetector.swift aren't either), and Vision inference can't
/// run in CI regardless -- verified manually on a real device instead
/// (Task 7).
#if os(iOS)
import TinyTalkCore
import UIKit
import Vision

public enum ObjectRecognizerError: Error {
    case noImageData
    case classificationFailed(any Error)
}

public final class VisionObjectRecognizer: @unchecked Sendable {
    /// Starting point per the design spec, not a validated number --
    /// tune against real household objects during on-device testing
    /// (Task 7). Same "reasonable default, easy to retune" treatment as
    /// STORY_TARGET_TURNS/the animal facts confidence choices.
    public static let defaultConfidenceThreshold: Float = 0.3

    private let threshold: Float

    public init(confidenceThreshold: Float = Self.defaultConfidenceThreshold) {
        self.threshold = confidenceThreshold
    }

    /// Runs the classifier entirely on-device (no network call). Returns
    /// nil if nothing clears the confidence threshold or Vision found no
    /// candidates -- treated the same as a thrown error by every caller
    /// in this app (see AppModel.handlePhotoTaken in Task 7): a failed or
    /// ambiguous photo attempt must never block or degrade the core voice
    /// turn, per the design spec's error-handling goal.
    public func recognize(image: UIImage) async throws -> RecognizedObject? {
        guard let cgImage = image.cgImage else {
            throw ObjectRecognizerError.noImageData
        }
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ObjectRecognizerError.classificationFailed(error)
        }
        let candidates = (request.results ?? []).map {
            ClassificationCandidate(label: $0.identifier, confidence: $0.confidence)
        }
        return selectTopClassification(candidates, threshold: threshold)
    }
}
#endif
```

- [ ] **Step 6: Run the full TinyTalkCore test suite**

Run: `cd ios/TinyTalkCore && swift test`
Expected: PASS, all tests (the new `ObjectRecognizer.swift` is entirely
inside `#if os(iOS)`, so it compiles to nothing on macOS and cannot break
this build — same as `AudioEngine.swift`/`VoiceActivityDetector.swift`
already don't).

- [ ] **Step 7: Commit**

```bash
cd ios/TinyTalkCore
git add Sources/TinyTalkCore/ObjectRecognition.swift Sources/TinyTalkPlatform/ObjectRecognizer.swift Tests/TinyTalkCoreTests/ObjectRecognitionTests.swift
git commit -m "feat(ios): VisionObjectRecognizer classifies a photo on-device"
```

---

### Task 7: Camera button, UI wiring, and camera permission

**Files:**
- Modify: `ios/TinyTalkApp/TinyTalkApp/ContentView.swift`
- Modify: `ios/TinyTalkApp/TinyTalkApp/Info.plist`
- Modify: `ios/TinyTalkApp/project.yml`

**Interfaces:**
- Consumes: `SessionCoordinator.sendObjectSeen(label:)` (Task 5),
  `VisionObjectRecognizer` (Task 6).
- Produces: nothing further downstream — this is the last task.

Not unit-testable via `swift test` for the same reason as the rest of
`ContentView.swift`/`AppModel` (no existing tests target SwiftUI views or
`AppModel` either — this file has zero automated tests today).
Verification is manual, on a real device, per this task's last step and
the spec's own flagged open question about `UIImagePickerController`'s
interaction with the audio session.

- [ ] **Step 1: Add `NSCameraUsageDescription`**

In `ios/TinyTalkApp/TinyTalkApp/Info.plist`, add a new key/string pair
immediately after the existing `NSMicrophoneUsageDescription` entry:

```xml
	<key>NSCameraUsageDescription</key>
	<string>Tiny Talk Adventures needs the camera so you can show it something to put in the story.</string>
```

In `ios/TinyTalkApp/project.yml`, add the matching entry to
`targets.TinyTalkApp.info.properties`, alongside the existing
`NSMicrophoneUsageDescription` line:

```yaml
        NSCameraUsageDescription: "Tiny Talk Adventures needs the camera so you can show it something to put in the story."
```

- [ ] **Step 2: Add `AppModel` state and the photo-handling method**

In `ios/TinyTalkApp/TinyTalkApp/ContentView.swift`, add `import
AVFoundation` to the top import block (needed for
`AVCaptureDevice.authorizationStatus`):

```swift
import AVFoundation
import SwiftUI
import TinyTalkCore
import TinyTalkPlatform
import UIKit
```

In `AppModel`, add a new published property alongside the existing ones
and a recognizer instance alongside `coordinator`/`audioEngine`:

```swift
    @Published var objectRecognitionHint: String?

    private var coordinator: SessionCoordinator?
    private var audioEngine: RealAudioEngine?
    private let objectRecognizer = VisionObjectRecognizer()
```

Add two new methods to `AppModel` (a reasonable spot is right after
`toggleMute()`):

```swift
    /// Checks camera permission/availability before presenting the
    /// picker -- per the design spec's error handling, the button must
    /// be disabled or point to Settings rather than presenting a picker
    /// that can't work (e.g. no camera on the Simulator, or a denied
    /// permission).
    func requestCameraAccessAndShowPicker() async -> Bool {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            lastErrorMessage = "no camera available on this device."
            return false
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            lastErrorMessage = "camera access denied. Check Settings > Privacy > Camera > TinyTalkApp."
            return false
        }
    }

    /// Runs on-device classification and, on success, forwards the label
    /// to the server. Every failure path here (no confident label,
    /// Vision throwing, no active coordinator) ends in the same local
    /// "try again" hint rather than an error -- per the design spec, a
    /// failed or ambiguous photo attempt must never block or degrade the
    /// core voice turn, and a confusing error is worse than just letting
    /// the child try again.
    func handlePhotoTaken(_ image: UIImage) async {
        objectRecognitionHint = nil
        guard let coordinator else { return }
        do {
            guard let recognized = try await objectRecognizer.recognize(image: image) else {
                objectRecognitionHint = "Couldn't quite tell what that is -- try again?"
                return
            }
            print("AppModel: recognized \(recognized.label) (confidence=\(recognized.confidence))")
            await coordinator.sendObjectSeen(label: recognized.label)
        } catch {
            print("AppModel: object recognition failed: \(error)")
            objectRecognitionHint = "Couldn't quite tell what that is -- try again?"
        }
    }
```

- [ ] **Step 3: Add the `UIImagePickerController` wrapper**

In `ios/TinyTalkApp/TinyTalkApp/ContentView.swift`, add a new
`UIViewControllerRepresentable` (a reasonable spot is right before
`struct ContentView: View`):

```swift
/// Thin SwiftUI wrapper around the standard system camera --
/// UIImagePickerController, not a custom AVCaptureSession preview, since
/// this is a single on-demand photo per the design spec, not a
/// continuous live view.
struct CameraPicker: UIViewControllerRepresentable {
    let onImagePicked: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            picker.dismiss(animated: true)
            guard let image = info[.originalImage] as? UIImage else {
                parent.onCancel()
                return
            }
            parent.onImagePicked(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            parent.onCancel()
        }
    }
}
```

- [ ] **Step 4: Add the camera button and hint text to `ContentView`**

In `ContentView`, add a new `@State` property alongside `@StateObject
private var model`:

```swift
struct ContentView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingCamera = false
```

Add a camera button immediately after the existing mute button's closing
`.tint(...)` line (inside the same `if model.isConnected { ... }` block is
fine, added as a sibling to the mute `Button`):

```swift
            if model.isConnected {
                Button {
                    model.toggleMute()
                } label: {
                    Label(
                        model.isMicMuted ? "Muted" : "Mute Mic",
                        systemImage: model.isMicMuted ? "mic.slash.fill" : "mic.fill"
                    )
                }
                .tint(model.isMicMuted ? .red : .accentColor)

                Button {
                    Task {
                        guard await model.requestCameraAccessAndShowPicker() else { return }
                        showingCamera = true
                    }
                } label: {
                    Label("Show Me Something", systemImage: "camera.fill")
                }
            }
```

Add the hint text right after the existing `if let error =
model.lastErrorMessage { ... }` block:

```swift
            if let error = model.lastErrorMessage {
                Text("Error: \(error)").foregroundColor(.red)
            }

            if let hint = model.objectRecognitionHint {
                Text(hint).foregroundColor(.secondary)
            }
```

Add the `.sheet` modifier alongside the existing `.onChange(of:
scenePhase)` modifier, at the end of `body`'s modifier chain:

```swift
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                Task { await model.handleAppBackgrounded() }
            case .active:
                Task { await model.handleAppForegrounded() }
            default:
                break
            }
        }
        .sheet(isPresented: $showingCamera) {
            CameraPicker(
                onImagePicked: { image in
                    showingCamera = false
                    Task { await model.handlePhotoTaken(image) }
                },
                onCancel: { showingCamera = false }
            )
            .ignoresSafeArea()
        }
```

- [ ] **Step 5: Regenerate the Xcode project and build**

Run:

```bash
cd ios/TinyTalkApp
xcodegen generate
xcodebuild -project TinyTalkApp.xcodeproj -scheme TinyTalkApp -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

Expected: build succeeds. This is also the first point anything in Task 6
(`ObjectRecognizer.swift`, entirely behind `#if os(iOS)`) gets compiled
for iOS at all — `swift test` never builds it, per Task 6's Interfaces
note.

- [ ] **Step 6: Manual on-device verification**

No automated test covers this file (see this task's own note above) or
`ObjectRecognizer.swift` (see Task 6). On a real iPhone, with the server
running:

- Grant camera permission on first tap of "Show Me Something"; confirm a
  denied permission shows the Settings-pointing message instead of a
  broken picker.
- Take a photo of a real, recognizable object (a stuffed animal, a mug);
  confirm the *next* story turn's reply is inspired by it, not the
  current one already in flight.
- Take a photo of something ambiguous (a blank wall, a blurry shot);
  confirm the local "couldn't quite tell" hint appears and no
  `object_seen` message reaches the server (check server logs).
- Take two photos before speaking again; confirm only the second's label
  ends up woven into the story.
- Try a handful of real household objects and note whether
  `VNClassifyImageRequest` returns concrete, story-friendly nouns (e.g.
  "teddy bear") or abstract/awkward ones (e.g. "furniture") — the spec
  flags this as unverified. No code-level mitigation is planned for v1;
  just note what actually comes back so a follow-up can decide whether
  the ~1300-category classifier is good enough.
- If real testing shows the ~0.3 confidence threshold
  (`VisionObjectRecognizer.defaultConfidenceThreshold` in
  `ObjectRecognizer.swift`) is clearly too strict (rejecting obvious
  objects) or too loose (accepting nothing coherent), retune that one
  constant — it was a starting point, not a validated number, per the
  spec.
- Specifically check the open question the design spec flags: does
  presenting the camera picker (which suspends the app's own UI) disrupt
  `RealAudioEngine`'s mic capture or an in-progress reply's playback? If
  it does, note the failure mode for a follow-up fix — this plan does not
  attempt to solve that pre-emptively without a confirmed real symptom to
  design against.
- Confirm the recognized label doesn't clash with the story's realism
  rule (`config.SYSTEM_PROMPT`'s "keep the story grounded in the real
  world" line, added by the story generation engine plan) in an obviously
  bad way — e.g. a photo of a toy dinosaur inspiring a *talking*
  dinosaur character is fine per that rule's own carve-out for animal
  characters; flag anything that reads as a clash rather than guessing
  at a fix.

- [ ] **Step 7: Commit**

```bash
cd ios/TinyTalkApp
git add TinyTalkApp/ContentView.swift TinyTalkApp/Info.plist project.yml
git commit -m "feat(ios): camera button lets the child show the story something"
```

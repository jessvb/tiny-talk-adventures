"""Wire protocol between the phone client and this server.

Control messages are JSON text frames. Audio travels as binary frames and is
not represented here: mic audio in and TTS audio out are both 24 kHz mono
PCM16 LE -- one consistent sample rate, matching what Kyutai's STT model and
Mimi audio codec natively expect, so nothing needs resampling.

Ordering requirement: the server only accepts mic audio frames while it is
LISTENING, which it enters on `speech_start` or `interrupt`. A client must
therefore send the control frame (`speech_start` for a fresh utterance,
`interrupt` for a barge-in) *before* any audio frames for that utterance.
Audio that arrives outside LISTENING (e.g. a frame sent before the control
frame, or one still in flight when an utterance ended) is silently dropped —
no error is surfaced. Getting this ordering wrong on a barge-in would lose
the first word of what the child says.

turn_id: the client assigns a new turn_id every time it starts a fresh
listening turn (speech_start or interrupt) and echoes it on nothing else --
the server just remembers whichever turn_id it was most recently told and
stamps every one of its own events (transcript_partial/transcript_final/
response_text/turn_end/error) with that value, until superseded by the next
speech_start/interrupt. This exists because the server's read loop is
strictly serial and STT can take several real seconds per utterance: if the
child interrupts and starts a new utterance while the server is still
finishing the previous one, that stale reply arrives *after* the client has
already moved on to a newer turn. Without turn_id, the client has no way to
tell a late reply for an old, already-abandoned utterance apart from a
legitimate reply for its current one -- confirmed on real hardware to cause
a reply being silently misattributed to the wrong turn, or dropped
entirely, when the child spoke faster than the server could keep up.

`object_seen` is deliberately exempt from both the turn_id contract above
and the speech_start/interrupt ordering requirement -- see the ObjectSeen
dataclass's own docstring for why.
"""

from __future__ import annotations

import json
from dataclasses import dataclass


class ProtocolError(ValueError):
    """Raised when an incoming control message is malformed or unknown."""


LLM_BACKENDS = ("ollama", "groq")


@dataclass(frozen=True)
class SpeechStart:
    """The client's VAD detected speech onset; audio frames follow."""

    turn_id: int


@dataclass(frozen=True)
class SpeechEnd:
    """The client's VAD detected speech offset; finalize the transcript."""


@dataclass(frozen=True)
class Interrupt:
    """The child barged in. Abort the in-flight turn and start listening."""

    turn_id: int


@dataclass(frozen=True)
class ObjectSeen:
    """The child took a photo and on-device Vision classified it; label is
    the recognized object's plain-English name (e.g. "teddy bear").
    Deliberately carries no turn_id, unlike SpeechStart/Interrupt -- taking
    a photo isn't tied to a specific turn boundary, it's queued and woven
    into whichever turn happens next. See
    docs/superpowers/specs/2026-08-29-object-recognition-design.md."""

    label: str


@dataclass(frozen=True)
class NewStory:
    """The client wants to abandon the current story and start a fresh
    one, without tearing down the connection or session -- see
    SessionRunner.handle_new_story(). No turn_id: unlike speech_start/
    interrupt, this isn't itself the start of a turn, so there is nothing
    for it to be echoed back against."""


@dataclass(frozen=True)
class ListStories:
    """Request the saved-story list for the Library screen. No turn_id --
    browsing saved stories is unrelated to live turn-taking."""


@dataclass(frozen=True)
class GetStory:
    """Request one saved story's rewritten pages for the Reading
    screen."""

    story_id: str


@dataclass(frozen=True)
class SynthesizePage:
    """Request on-demand TTS audio for one page of a saved story (the
    Reading screen's per-page replay button). Audio streams through the
    same binary-frame pathway as live TTS, followed by a
    page_audio_done marker."""

    story_id: str
    page_index: int


@dataclass(frozen=True)
class GetPageImage:
    """Request the generated illustration for one page of a saved story
    (the Reading screen's page art). Image bytes stream through the same
    binary-frame pathway as SynthesizePage's audio, followed by a
    page_image_done marker whose has_image field tells the client
    whether a binary frame was actually sent -- a page with no
    illustration (not yet generated, or dropped by the safety check)
    sends the marker only, no binary frame."""

    story_id: str
    page_index: int


@dataclass(frozen=True)
class ConcludeStory:
    """The child (or parent) asked to finish the current story right now
    (the design's "Finish this story" menu item). Carries a turn_id like
    SpeechStart/Interrupt: it results in one more real
    response_text/turn_end pair the client must be able to attribute to a
    turn."""

    turn_id: int


@dataclass(frozen=True)
class SyncDemoStories:
    """The phone hands over stories completed away from home (see
    docs/superpowers/specs/2026-09-09-away-from-home-demo-mode-design.md)
    once it reconnects to the home server. No turn_id -- this isn't part
    of live turn-taking, same reasoning as ListStories/GetStory."""

    stories: tuple[dict, ...]


@dataclass(frozen=True)
class UpdateSettings:
    """Parent-adjustable settings from the Settings screen -- persisted
    client-side, sent once after connecting and again whenever changed
    while connected. Applied to the next story construction, not
    retroactively to one already in progress -- see SessionRunner's
    handle_update_settings().

    llm_backend is optional (docs/superpowers/specs/
    2026-09-22-server-llm-backend-toggle-design.md): absent means "keep
    whatever the server is already using", so an older phone build or
    demo mode's own messages change nothing."""

    target_turns: int
    page_count: int
    llm_backend: str | None = None


ClientMessage = (
    SpeechStart
    | SpeechEnd
    | Interrupt
    | ObjectSeen
    | NewStory
    | ListStories
    | GetStory
    | SynthesizePage
    | GetPageImage
    | ConcludeStory
    | SyncDemoStories
    | UpdateSettings
)

_CLIENT_MESSAGE_TYPES: dict[str, type] = {
    "speech_start": SpeechStart,
    "speech_end": SpeechEnd,
    "interrupt": Interrupt,
    "object_seen": ObjectSeen,
    "new_story": NewStory,
    "list_stories": ListStories,
    "get_story": GetStory,
    "synthesize_page": SynthesizePage,
    "get_page_image": GetPageImage,
    "conclude_story": ConcludeStory,
    "sync_demo_stories": SyncDemoStories,
    "update_settings": UpdateSettings,
}
_TYPES_REQUIRING_TURN_ID = (SpeechStart, Interrupt, ConcludeStory)


def decode_client_message(raw: str) -> ClientMessage:
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ProtocolError(f"control frame is not valid JSON: {raw!r}") from exc

    if not isinstance(payload, dict):
        raise ProtocolError(
            f"control frame must be a JSON object, got {type(payload).__name__}"
        )

    kind = payload.get("type")
    message_type = _CLIENT_MESSAGE_TYPES.get(kind)
    if message_type is None:
        raise ProtocolError(f"unknown client message type: {kind!r}")
    if message_type in _TYPES_REQUIRING_TURN_ID:
        turn_id = payload.get("turn_id")
        if not isinstance(turn_id, int):
            raise ProtocolError(f"{kind} requires an integer turn_id: {raw!r}")
        return message_type(turn_id=turn_id)
    if message_type is ObjectSeen:
        label = payload.get("label")
        if not isinstance(label, str) or not label.strip():
            raise ProtocolError(f"object_seen requires a non-empty string label: {raw!r}")
        return ObjectSeen(label=label.strip())
    if message_type is GetStory:
        story_id = payload.get("story_id")
        if not isinstance(story_id, str) or not story_id.strip():
            raise ProtocolError(f"get_story requires a non-empty string story_id: {raw!r}")
        return GetStory(story_id=story_id.strip())
    if message_type is SynthesizePage:
        story_id = payload.get("story_id")
        page_index = payload.get("page_index")
        if not isinstance(story_id, str) or not story_id.strip():
            raise ProtocolError(
                f"synthesize_page requires a non-empty string story_id: {raw!r}"
            )
        if not isinstance(page_index, int):
            raise ProtocolError(f"synthesize_page requires an integer page_index: {raw!r}")
        return SynthesizePage(story_id=story_id.strip(), page_index=page_index)
    if message_type is GetPageImage:
        story_id = payload.get("story_id")
        page_index = payload.get("page_index")
        if not isinstance(story_id, str) or not story_id.strip():
            raise ProtocolError(
                f"get_page_image requires a non-empty string story_id: {raw!r}"
            )
        if not isinstance(page_index, int):
            raise ProtocolError(f"get_page_image requires an integer page_index: {raw!r}")
        return GetPageImage(story_id=story_id.strip(), page_index=page_index)
    if message_type is SyncDemoStories:
        stories = payload.get("stories")
        if not isinstance(stories, list) or not all(isinstance(s, dict) for s in stories):
            raise ProtocolError(f"sync_demo_stories requires a list of story objects: {raw!r}")
        return SyncDemoStories(stories=tuple(stories))
    if message_type is UpdateSettings:
        target_turns = payload.get("target_turns")
        page_count = payload.get("page_count")
        if not isinstance(target_turns, int):
            raise ProtocolError(
                f"update_settings requires an integer target_turns: {raw!r}"
            )
        if not isinstance(page_count, int):
            raise ProtocolError(
                f"update_settings requires an integer page_count: {raw!r}"
            )
        llm_backend = payload.get("llm_backend")
        if llm_backend is not None and llm_backend not in LLM_BACKENDS:
            raise ProtocolError(
                f"update_settings llm_backend must be one of {LLM_BACKENDS}: {raw!r}"
            )
        return UpdateSettings(
            target_turns=target_turns, page_count=page_count, llm_backend=llm_backend
        )
    return message_type()


def encode_transcript_partial(text: str, turn_id: int) -> str:
    return json.dumps({"type": "transcript_partial", "text": text, "turn_id": turn_id})


def encode_transcript_final(text: str, turn_id: int) -> str:
    return json.dumps({"type": "transcript_final", "text": text, "turn_id": turn_id})


def encode_response_text(text: str, turn_id: int) -> str:
    return json.dumps({"type": "response_text", "text": text, "turn_id": turn_id})


def encode_turn_end(turn_id: int) -> str:
    return json.dumps({"type": "turn_end", "turn_id": turn_id})


def encode_error(message: str, turn_id: int) -> str:
    return json.dumps({"type": "error", "message": message, "turn_id": turn_id})


def encode_arc_stage(stage: str, turn_id: int) -> str:
    return json.dumps({"type": "arc_stage", "stage": stage, "turn_id": turn_id})


def encode_story_list(stories: list[dict]) -> str:
    return json.dumps({"type": "story_list", "stories": stories})


def encode_story_detail(story: dict) -> str:
    return json.dumps({"type": "story_detail", **story})


def encode_page_audio_done(story_id: str, page_index: int) -> str:
    return json.dumps(
        {"type": "page_audio_done", "story_id": story_id, "page_index": page_index}
    )


def encode_page_image_done(story_id: str, page_index: int, has_image: bool) -> str:
    return json.dumps(
        {
            "type": "page_image_done",
            "story_id": story_id,
            "page_index": page_index,
            "has_image": has_image,
        }
    )


def encode_rewriting_started(
    story_id: str | None = None, epilogue: str | None = None
) -> str:
    """`story_id` names the story being rewritten; `epilogue` is its
    fact line (storybook.early_epilogue()), sent now so The End can show
    it without waiting on the whole rewrite (issue #77). Each key is
    omitted when None, so an older client sees the same bare message."""
    payload: dict = {"type": "rewriting_started"}
    if story_id is not None:
        payload["story_id"] = story_id
    if epilogue is not None:
        payload["epilogue"] = epilogue
    return json.dumps(payload)


def encode_rewriting_done() -> str:
    return json.dumps({"type": "rewriting_done"})


def encode_llm_backend(requested: str, active: str, groq_available: bool) -> str:
    """Reply to an update_settings carrying llm_backend -- `active` is what
    the NEXT story will actually use (ollama if groq was requested but this
    server has no GROQ_API_KEY). No turn_id: not part of live turn-taking,
    same as story_list."""
    return json.dumps(
        {
            "type": "llm_backend",
            "requested": requested,
            "active": active,
            "groq_available": groq_available,
        }
    )

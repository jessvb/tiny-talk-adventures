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


ClientMessage = SpeechStart | SpeechEnd | Interrupt | ObjectSeen

_CLIENT_MESSAGE_TYPES: dict[str, type] = {
    "speech_start": SpeechStart,
    "speech_end": SpeechEnd,
    "interrupt": Interrupt,
    "object_seen": ObjectSeen,
}
_TYPES_REQUIRING_TURN_ID = (SpeechStart, Interrupt)


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

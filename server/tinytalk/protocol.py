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
"""

from __future__ import annotations

import json
from dataclasses import dataclass


class ProtocolError(ValueError):
    """Raised when an incoming control message is malformed or unknown."""


@dataclass(frozen=True)
class SpeechStart:
    """The client's VAD detected speech onset; audio frames follow."""


@dataclass(frozen=True)
class SpeechEnd:
    """The client's VAD detected speech offset; finalize the transcript."""


@dataclass(frozen=True)
class Interrupt:
    """The child barged in. Abort the in-flight turn and start listening."""


ClientMessage = SpeechStart | SpeechEnd | Interrupt

_CLIENT_MESSAGE_TYPES: dict[str, type] = {
    "speech_start": SpeechStart,
    "speech_end": SpeechEnd,
    "interrupt": Interrupt,
}


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
    return message_type()


def encode_transcript_partial(text: str) -> str:
    return json.dumps({"type": "transcript_partial", "text": text})


def encode_transcript_final(text: str) -> str:
    return json.dumps({"type": "transcript_final", "text": text})


def encode_response_text(text: str) -> str:
    return json.dumps({"type": "response_text", "text": text})


def encode_turn_end() -> str:
    return json.dumps({"type": "turn_end"})


def encode_error(message: str) -> str:
    return json.dumps({"type": "error", "message": message})

import json

import pytest

from storyadventure.protocol import (
    Interrupt,
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
        ('{"type": "speech_start"}', SpeechStart()),
        ('{"type": "speech_end"}', SpeechEnd()),
        ('{"type": "interrupt"}', Interrupt()),
    ],
)
def test_decodes_each_client_message_type(raw, expected):
    assert decode_client_message(raw) == expected


def test_decode_rejects_invalid_json():
    with pytest.raises(ProtocolError):
        decode_client_message("not json at all")


def test_decode_rejects_non_object_json():
    with pytest.raises(ProtocolError):
        decode_client_message('["speech_start"]')


def test_decode_rejects_unknown_type():
    with pytest.raises(ProtocolError):
        decode_client_message('{"type": "launch_rocket"}')


def test_encoders_produce_expected_payloads():
    assert json.loads(encode_transcript_partial("a fox")) == {
        "type": "transcript_partial",
        "text": "a fox",
    }
    assert json.loads(encode_transcript_final("a fox ran")) == {
        "type": "transcript_final",
        "text": "a fox ran",
    }
    assert json.loads(encode_response_text("Once upon a time")) == {
        "type": "response_text",
        "text": "Once upon a time",
    }
    assert json.loads(encode_turn_end()) == {"type": "turn_end"}
    assert json.loads(encode_error("ollama is not running")) == {
        "type": "error",
        "message": "ollama is not running",
    }

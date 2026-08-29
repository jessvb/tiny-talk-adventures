import json

import pytest

from tinytalk.protocol import (
    Interrupt,
    NewStory,
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
        ('{"type": "new_story"}', NewStory()),
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


@pytest.mark.parametrize("raw", ['{"type": "speech_start"}', '{"type": "interrupt"}'])
def test_decode_rejects_speech_start_and_interrupt_missing_turn_id(raw):
    with pytest.raises(ProtocolError, match="turn_id"):
        decode_client_message(raw)


@pytest.mark.parametrize(
    "raw", ['{"type": "speech_start", "turn_id": "3"}', '{"type": "interrupt", "turn_id": 3.5}']
)
def test_decode_rejects_non_integer_turn_id(raw):
    with pytest.raises(ProtocolError, match="turn_id"):
        decode_client_message(raw)


def test_encoders_produce_expected_payloads():
    assert json.loads(encode_transcript_partial("a fox", 1)) == {
        "type": "transcript_partial",
        "text": "a fox",
        "turn_id": 1,
    }
    assert json.loads(encode_transcript_final("a fox ran", 1)) == {
        "type": "transcript_final",
        "text": "a fox ran",
        "turn_id": 1,
    }
    assert json.loads(encode_response_text("Once upon a time", 1)) == {
        "type": "response_text",
        "text": "Once upon a time",
        "turn_id": 1,
    }
    assert json.loads(encode_turn_end(1)) == {"type": "turn_end", "turn_id": 1}
    assert json.loads(encode_error("ollama is not running", 1)) == {
        "type": "error",
        "message": "ollama is not running",
        "turn_id": 1,
    }

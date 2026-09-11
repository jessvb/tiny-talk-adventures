import json

import pytest

from tinytalk.protocol import (
    ConcludeStory,
    GetPageImage,
    GetStory,
    Interrupt,
    ListStories,
    NewStory,
    ObjectSeen,
    ProtocolError,
    SpeechEnd,
    SpeechStart,
    SynthesizePage,
    UpdateSettings,
    decode_client_message,
    encode_arc_stage,
    encode_error,
    encode_page_audio_done,
    encode_page_image_done,
    encode_response_text,
    encode_rewriting_done,
    encode_rewriting_started,
    encode_story_detail,
    encode_story_list,
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
        ('{"type": "new_story"}', NewStory()),
        ('{"type": "list_stories"}', ListStories()),
        ('{"type": "get_story", "story_id": "abcd1234"}', GetStory(story_id="abcd1234")),
        ('{"type": "synthesize_page", "story_id": "abcd1234", "page_index": 2}',
         SynthesizePage(story_id="abcd1234", page_index=2)),
        ('{"type": "get_page_image", "story_id": "abcd1234", "page_index": 1}',
         GetPageImage(story_id="abcd1234", page_index=1)),
        ('{"type": "conclude_story", "turn_id": 5}', ConcludeStory(turn_id=5)),
        ('{"type": "update_settings", "target_turns": 8, "page_count": 6}',
         UpdateSettings(target_turns=8, page_count=6)),
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


def test_decode_rejects_get_story_missing_story_id():
    with pytest.raises(ProtocolError, match="story_id"):
        decode_client_message('{"type": "get_story"}')


def test_decode_rejects_get_story_blank_story_id():
    with pytest.raises(ProtocolError, match="story_id"):
        decode_client_message('{"type": "get_story", "story_id": "   "}')


def test_decode_rejects_synthesize_page_missing_page_index():
    with pytest.raises(ProtocolError, match="page_index"):
        decode_client_message('{"type": "synthesize_page", "story_id": "a"}')


def test_decode_rejects_get_page_image_missing_page_index():
    with pytest.raises(ProtocolError):
        decode_client_message('{"type": "get_page_image", "story_id": "a"}')


def test_decode_rejects_get_page_image_missing_story_id():
    with pytest.raises(ProtocolError):
        decode_client_message('{"type": "get_page_image", "page_index": 0}')


def test_encode_page_image_done_with_image():
    raw = encode_page_image_done("abcd1234", 2, has_image=True)
    assert json.loads(raw) == {
        "type": "page_image_done", "story_id": "abcd1234", "page_index": 2, "has_image": True,
    }


def test_encode_page_image_done_without_image():
    raw = encode_page_image_done("abcd1234", 2, has_image=False)
    assert json.loads(raw)["has_image"] is False


def test_decode_rejects_conclude_story_missing_turn_id():
    with pytest.raises(ProtocolError, match="turn_id"):
        decode_client_message('{"type": "conclude_story"}')


def test_decode_rejects_update_settings_missing_target_turns():
    with pytest.raises(ProtocolError, match="target_turns"):
        decode_client_message('{"type": "update_settings", "page_count": 5}')


def test_decode_rejects_update_settings_missing_page_count():
    with pytest.raises(ProtocolError, match="page_count"):
        decode_client_message('{"type": "update_settings", "target_turns": 7}')


def test_decode_rejects_update_settings_non_integer_target_turns():
    with pytest.raises(ProtocolError, match="target_turns"):
        decode_client_message(
            '{"type": "update_settings", "target_turns": "seven", "page_count": 5}'
        )


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


def test_new_server_encoders_produce_expected_payloads():
    assert json.loads(encode_arc_stage("setup", 1)) == {
        "type": "arc_stage",
        "stage": "setup",
        "turn_id": 1,
    }
    assert json.loads(encode_story_list([{"id": "a", "title": None}])) == {
        "type": "story_list",
        "stories": [{"id": "a", "title": None}],
    }
    assert json.loads(encode_story_detail({"id": "a", "title": "Pip"})) == {
        "type": "story_detail",
        "id": "a",
        "title": "Pip",
    }
    assert json.loads(encode_page_audio_done("a", 2)) == {
        "type": "page_audio_done",
        "story_id": "a",
        "page_index": 2,
    }
    assert json.loads(encode_rewriting_started()) == {"type": "rewriting_started"}
    assert json.loads(encode_rewriting_done()) == {"type": "rewriting_done"}

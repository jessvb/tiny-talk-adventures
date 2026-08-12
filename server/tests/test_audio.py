import numpy as np
import pytest

from tinytalk.audio import (
    MIC_SAMPLE_RATE,
    TTS_SAMPLE_RATE,
    float32_to_pcm16,
    pcm16_to_float32,
    split_sentences,
)


def test_sample_rates_match_the_wire_format():
    assert MIC_SAMPLE_RATE == 16000
    assert TTS_SAMPLE_RATE == 24000


def test_float32_to_pcm16_encodes_little_endian_int16():
    encoded = float32_to_pcm16(np.array([0.0, 1.0, -1.0], dtype=np.float32))
    assert encoded == b"\x00\x00\xff\x7f\x01\x80"


def test_float32_to_pcm16_clips_out_of_range_samples():
    encoded = float32_to_pcm16(np.array([2.5, -2.5], dtype=np.float32))
    assert encoded == b"\xff\x7f\x01\x80"


def test_pcm16_round_trips_back_to_float():
    original = np.array([0.0, 0.5, -0.5], dtype=np.float32)
    restored = pcm16_to_float32(float32_to_pcm16(original))
    np.testing.assert_allclose(restored, original, atol=1e-4)


def test_pcm16_to_float32_handles_empty_input():
    assert len(pcm16_to_float32(b"")) == 0


def test_split_sentences_splits_on_terminal_punctuation():
    assert split_sentences("The fox ran. It was fast! Was it? Yes.") == [
        "The fox ran.",
        "It was fast!",
        "Was it?",
        "Yes.",
    ]


def test_split_sentences_keeps_unterminated_trailing_text():
    assert split_sentences("The fox ran. Then he") == ["The fox ran.", "Then he"]


@pytest.mark.parametrize("text", ["", "   ", "\n\n"])
def test_split_sentences_returns_empty_for_blank_input(text):
    assert split_sentences(text) == []

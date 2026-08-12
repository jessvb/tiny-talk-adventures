import numpy as np
import pytest

from tinytalk.audio import float32_to_pcm16
from tinytalk.engines import EngineError
from tinytalk.stt_kyutai import KyutaiStt


class FakeRecognizer:
    """Stands in for the moshi_mlx recognizer: float samples in, text out."""

    def __init__(self, hf_repo: str) -> None:
        self.hf_repo = hf_repo
        self.transcribe_calls: list[int] = []

    def transcribe(self, samples: np.ndarray) -> str:
        self.transcribe_calls.append(len(samples))
        return "the fox ran"


class ExplodingRecognizer:
    def __init__(self, hf_repo: str) -> None:
        pass

    def transcribe(self, samples: np.ndarray) -> str:
        raise RuntimeError("mlx backend unavailable")


def pcm(*values: float) -> bytes:
    return float32_to_pcm16(np.array(values, dtype=np.float32))


def test_finish_returns_transcript_of_all_fed_audio():
    recognizer = FakeRecognizer("repo")
    stt = KyutaiStt(recognizer_factory=lambda repo: recognizer)

    stt.feed(pcm(0.1, 0.2))
    stt.feed(pcm(0.3, 0.4))

    assert stt.finish() == "the fox ran"
    assert recognizer.transcribe_calls == [4]


def test_finish_with_no_audio_returns_empty_string_without_calling_model():
    recognizer = FakeRecognizer("repo")
    stt = KyutaiStt(recognizer_factory=lambda repo: recognizer)

    assert stt.finish() == ""
    assert recognizer.transcribe_calls == []


def test_finish_clears_the_buffer_for_the_next_utterance():
    recognizer = FakeRecognizer("repo")
    stt = KyutaiStt(recognizer_factory=lambda repo: recognizer)

    stt.feed(pcm(0.1, 0.2))
    stt.finish()
    stt.feed(pcm(0.5))
    stt.finish()

    assert recognizer.transcribe_calls == [2, 1]


def test_reset_discards_buffered_audio():
    recognizer = FakeRecognizer("repo")
    stt = KyutaiStt(recognizer_factory=lambda repo: recognizer)

    stt.feed(pcm(0.1, 0.2))
    stt.reset()

    assert stt.finish() == ""
    assert recognizer.transcribe_calls == []


def test_model_failure_is_reported_as_engine_error():
    stt = KyutaiStt(recognizer_factory=ExplodingRecognizer)
    stt.feed(pcm(0.1))
    with pytest.raises(EngineError, match="Kyutai"):
        stt.finish()

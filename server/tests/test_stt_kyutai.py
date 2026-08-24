import numpy as np
import pytest

from tinytalk.audio import float32_to_pcm16
from tinytalk.engines import EngineError
from tinytalk.stt_kyutai import KyutaiStt


class FakeUtterance:
    """Stands in for a real streaming session (one per utterance, mirroring
    _StreamingUtterance's one-LmGen-per-utterance shape): feed() returns
    caller-supplied canned partial text, finish() returns canned final text.
    """

    def __init__(self, feed_results: list[str] | None = None, final_text: str = "") -> None:
        self._feed_results = list(feed_results or [])
        self._final_text = final_text
        self.fed_sample_counts: list[int] = []
        self.finish_called = False

    def feed(self, samples: np.ndarray) -> str:
        self.fed_sample_counts.append(len(samples))
        return self._feed_results.pop(0) if self._feed_results else ""

    def finish(self) -> str:
        self.finish_called = True
        return self._final_text


class FakeRecognizer:
    """Stands in for the real _Recognizer: start_session() hands out a fresh
    FakeUtterance per call, mirroring one LmGen constructed per utterance."""

    def __init__(
        self, hf_repo: str, *, feed_results: list[str] | None = None, final_text: str = "the fox ran"
    ) -> None:
        self.hf_repo = hf_repo
        self._feed_results = feed_results
        self._final_text = final_text
        self.sessions: list[FakeUtterance] = []

    def start_session(self) -> FakeUtterance:
        session = FakeUtterance(feed_results=self._feed_results, final_text=self._final_text)
        self.sessions.append(session)
        return session


class ExplodingUtterance:
    def feed(self, samples: np.ndarray) -> str:
        return ""

    def finish(self) -> str:
        raise RuntimeError("mlx backend unavailable")


class ExplodingRecognizer:
    def __init__(self, hf_repo: str) -> None:
        pass

    def start_session(self) -> ExplodingUtterance:
        return ExplodingUtterance()


class ExplodingFeedUtterance:
    def feed(self, samples: np.ndarray) -> str:
        raise RuntimeError("mlx backend unavailable")

    def finish(self) -> str:
        return ""


class ExplodingFeedRecognizer:
    def __init__(self, hf_repo: str) -> None:
        pass

    def start_session(self) -> ExplodingFeedUtterance:
        return ExplodingFeedUtterance()


def pcm(*values: float) -> bytes:
    return float32_to_pcm16(np.array(values, dtype=np.float32))


def test_finish_returns_transcript_of_all_fed_audio():
    recognizer = FakeRecognizer("repo")
    stt = KyutaiStt(recognizer_factory=lambda repo: recognizer)

    stt.feed(pcm(0.1, 0.2))
    stt.feed(pcm(0.3, 0.4))

    assert stt.finish() == "the fox ran"
    assert len(recognizer.sessions) == 1
    assert recognizer.sessions[0].fed_sample_counts == [2, 2]


def test_finish_with_no_audio_returns_empty_string_without_starting_a_session():
    recognizer = FakeRecognizer("repo")
    stt = KyutaiStt(recognizer_factory=lambda repo: recognizer)

    assert stt.finish() == ""
    assert recognizer.sessions == []


def test_finish_starts_a_fresh_session_for_the_next_utterance():
    recognizer = FakeRecognizer("repo")
    stt = KyutaiStt(recognizer_factory=lambda repo: recognizer)

    stt.feed(pcm(0.1, 0.2))
    stt.finish()
    stt.feed(pcm(0.5))
    stt.finish()

    assert len(recognizer.sessions) == 2
    assert recognizer.sessions[0].fed_sample_counts == [2]
    assert recognizer.sessions[1].fed_sample_counts == [1]


def test_reset_discards_the_in_progress_session():
    recognizer = FakeRecognizer("repo")
    stt = KyutaiStt(recognizer_factory=lambda repo: recognizer)

    stt.feed(pcm(0.1, 0.2))
    stt.reset()

    assert stt.finish() == ""
    # The reset session never had finish() called on it, and no new session
    # was started since nothing was fed after the reset.
    assert recognizer.sessions[0].finish_called is False
    assert len(recognizer.sessions) == 1


def test_feed_starts_a_session_lazily_on_first_real_audio():
    recognizer = FakeRecognizer("repo")
    stt = KyutaiStt(recognizer_factory=lambda repo: recognizer)

    assert recognizer.sessions == []
    stt.feed(pcm(0.1))
    assert len(recognizer.sessions) == 1


def test_feed_with_empty_audio_does_not_start_a_session():
    recognizer = FakeRecognizer("repo")
    stt = KyutaiStt(recognizer_factory=lambda repo: recognizer)

    assert stt.feed(b"") is None
    assert recognizer.sessions == []


def test_feed_returns_incremental_partial_text_as_it_becomes_available():
    recognizer = FakeRecognizer("repo", feed_results=["The ", "", "fox"])
    stt = KyutaiStt(recognizer_factory=lambda repo: recognizer)

    assert stt.feed(pcm(0.1)) == "The "
    assert stt.feed(pcm(0.2)) is None
    assert stt.feed(pcm(0.3)) == "fox"


def test_model_failure_during_finish_is_reported_as_engine_error():
    stt = KyutaiStt(recognizer_factory=ExplodingRecognizer)
    stt.feed(pcm(0.1))
    with pytest.raises(EngineError, match="Kyutai"):
        stt.finish()


def test_model_failure_during_feed_is_reported_as_engine_error():
    stt = KyutaiStt(recognizer_factory=ExplodingFeedRecognizer)
    with pytest.raises(EngineError, match="Kyutai"):
        stt.feed(pcm(0.1))

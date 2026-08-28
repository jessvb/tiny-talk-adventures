import numpy as np
import pytest
import torch
from phonemizer.backend.espeak.wrapper import EspeakWrapper

from tinytalk.audio import float32_to_pcm16
from tinytalk.engines import EngineError
from tinytalk.tts_kokoro import KokoroTts, _configure_espeak_from_homebrew


def _make_fake_homebrew_layout(tmp_path):
    """Builds a fake `brew install espeak-ng` layout under tmp_path:
    <tmp_path>/bin/espeak-ng (what shutil.which would find) plus the
    stable opt/espeak-ng/{lib,share} alias structure alongside it."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    espeak_bin = bin_dir / "espeak-ng"
    espeak_bin.touch()
    lib_dir = tmp_path / "opt" / "espeak-ng" / "lib"
    lib_dir.mkdir(parents=True)
    library = lib_dir / "libespeak-ng.dylib"
    library.touch()
    data_dir = tmp_path / "opt" / "espeak-ng" / "share" / "espeak-ng-data"
    data_dir.mkdir(parents=True)
    return espeak_bin, library, data_dir


def test_configure_espeak_points_the_wrapper_at_the_homebrew_install(monkeypatch, tmp_path):
    espeak_bin, library, data_dir = _make_fake_homebrew_layout(tmp_path)
    monkeypatch.setattr("shutil.which", lambda name: str(espeak_bin))
    calls = {}
    monkeypatch.setattr(EspeakWrapper, "set_library", lambda lib: calls.__setitem__("library", lib))
    monkeypatch.setattr(EspeakWrapper, "set_data_path", lambda path: calls.__setitem__("data_path", path))

    _configure_espeak_from_homebrew()

    assert calls == {"library": str(library), "data_path": str(data_dir)}


def test_configure_espeak_raises_when_not_on_path(monkeypatch):
    monkeypatch.setattr("shutil.which", lambda name: None)

    with pytest.raises(EngineError, match="brew install espeak-ng"):
        _configure_espeak_from_homebrew()


def test_configure_espeak_raises_when_homebrew_layout_is_incomplete(monkeypatch, tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    espeak_bin = bin_dir / "espeak-ng"
    espeak_bin.touch()
    monkeypatch.setattr("shutil.which", lambda name: str(espeak_bin))

    with pytest.raises(EngineError, match="brew reinstall espeak-ng"):
        _configure_espeak_from_homebrew()


class FakePipeline:
    """Stands in for kokoro.KPipeline: a blocking generator of result tuples."""

    def __init__(self, lang_code: str) -> None:
        self.lang_code = lang_code
        self.calls: list[tuple[str, str]] = []

    def __call__(self, text: str, voice: str):
        self.calls.append((text, voice))
        yield ("graphemes", "phonemes", np.array([0.0, 0.5], dtype=np.float32))
        yield ("graphemes", "phonemes", np.array([-0.5, 0.0], dtype=np.float32))


class ExplodingPipeline:
    def __init__(self, lang_code: str) -> None:
        pass

    def __call__(self, text: str, voice: str):
        raise RuntimeError("espeak-ng is not installed")
        yield  # pragma: no cover - unreachable, marks this a generator


async def test_synthesize_yields_pcm16_chunks_in_order():
    pipeline = FakePipeline("a")
    tts = KokoroTts(lang_code="a", voice="af_heart", pipeline_factory=lambda code: pipeline)

    chunks = [chunk async for chunk in tts.synthesize("The fox ran.")]

    assert chunks == [
        float32_to_pcm16(np.array([0.0, 0.5], dtype=np.float32)),
        float32_to_pcm16(np.array([-0.5, 0.0], dtype=np.float32)),
    ]
    assert pipeline.calls == [("The fox ran.", "af_heart")]


async def test_synthesize_skips_blank_text_without_calling_the_model():
    pipeline = FakePipeline("a")
    tts = KokoroTts(pipeline_factory=lambda code: pipeline)

    chunks = [chunk async for chunk in tts.synthesize("   ")]

    assert chunks == []
    assert pipeline.calls == []


async def test_pipeline_is_built_once_and_reused():
    built: list[str] = []

    def factory(lang_code: str):
        built.append(lang_code)
        return FakePipeline(lang_code)

    tts = KokoroTts(lang_code="a", pipeline_factory=factory)
    [chunk async for chunk in tts.synthesize("One.")]
    [chunk async for chunk in tts.synthesize("Two.")]

    assert built == ["a"]


async def test_model_failure_is_reported_as_engine_error():
    tts = KokoroTts(pipeline_factory=ExplodingPipeline)
    with pytest.raises(EngineError, match="Kokoro"):
        [chunk async for chunk in tts.synthesize("The fox ran.")]


async def test_synthesize_releases_mps_cache_after_each_call(monkeypatch):
    # PyTorch's MPS caching allocator holds memory for reuse within this
    # process rather than returning it to the OS -- on a machine also
    # running Ollama and STT, an unreleased cache was found (real
    # on-device testing) to make each LATER turn in a session
    # progressively worse than the first, as Kokoro's footprint grows and
    # leaves less memory for Ollama.
    calls = []
    monkeypatch.setattr(torch.mps, "empty_cache", lambda: calls.append(True))
    pipeline = FakePipeline("a")
    tts = KokoroTts(pipeline_factory=lambda code: pipeline)

    [chunk async for chunk in tts.synthesize("The fox ran.")]

    assert calls == [True]


async def test_synthesize_releases_mps_cache_even_when_synthesis_fails(monkeypatch):
    calls = []
    monkeypatch.setattr(torch.mps, "empty_cache", lambda: calls.append(True))
    tts = KokoroTts(pipeline_factory=ExplodingPipeline)

    with pytest.raises(EngineError):
        [chunk async for chunk in tts.synthesize("The fox ran.")]

    assert calls == [True]


async def test_blank_text_does_not_touch_the_mps_cache(monkeypatch):
    calls = []
    monkeypatch.setattr(torch.mps, "empty_cache", lambda: calls.append(True))
    pipeline = FakePipeline("a")
    tts = KokoroTts(pipeline_factory=lambda code: pipeline)

    [chunk async for chunk in tts.synthesize("   ")]

    assert calls == []

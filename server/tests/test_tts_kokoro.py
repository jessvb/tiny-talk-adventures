import numpy as np
import pytest

from storyadventure.audio import float32_to_pcm16
from storyadventure.engines import EngineError
from storyadventure.tts_kokoro import KokoroTts


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

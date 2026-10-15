import asyncio
import logging
import sys
import threading
import time
import types

import numpy as np
import pytest
import torch
from phonemizer.backend.espeak.wrapper import EspeakWrapper

from tinytalk import config
from tinytalk.audio import float32_to_pcm16
from tinytalk.engines import EngineError
from tinytalk.tts_kokoro import KokoroTts, _configure_espeak_from_homebrew, _default_pipeline_factory


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


async def test_set_voice_applies_to_the_next_synthesis():
    pipeline = FakePipeline("a")
    tts = KokoroTts(lang_code="a", voice="af_heart", pipeline_factory=lambda code: pipeline)

    [chunk async for chunk in tts.synthesize("One.")]
    tts.set_voice("am_puck")
    [chunk async for chunk in tts.synthesize("Two.")]

    assert pipeline.calls == [("One.", "af_heart"), ("Two.", "am_puck")]


async def test_british_voice_gets_a_british_pipeline_sharing_the_loaded_model():
    # Kokoro's G2P is per-pipeline (lang_code 'a' = American, 'b' =
    # British); a bf_/bm_ voice read through the American pipeline would
    # get American pronunciations. The second pipeline must reuse the
    # first one's model weights rather than load a second ~330MB copy.
    built: list[tuple[str, object]] = []
    shared_model = object()

    def factory(lang_code: str, model=None):
        built.append((lang_code, model))
        pipeline = FakePipeline(lang_code)
        pipeline.model = model or shared_model
        return pipeline

    tts = KokoroTts(lang_code="a", voice="af_heart", pipeline_factory=factory)
    [chunk async for chunk in tts.synthesize("One.")]
    tts.set_voice("bf_emma")
    [chunk async for chunk in tts.synthesize("Two.")]
    tts.set_voice("am_puck")
    [chunk async for chunk in tts.synthesize("Three.")]
    [chunk async for chunk in tts.synthesize("Four.")]

    assert built == [("a", None), ("b", shared_model)]


def test_default_factory_reuses_a_given_model(monkeypatch):
    built: dict = {}

    class FakeKPipeline:
        def __init__(self, lang_code: str, device: str, model=True) -> None:
            built.update(lang_code=lang_code, model=model)
            self.model = types.SimpleNamespace(device=torch.device("cpu"))

    fake_kokoro = types.ModuleType("kokoro")
    fake_kokoro.KPipeline = FakeKPipeline
    monkeypatch.setitem(sys.modules, "kokoro", fake_kokoro)
    monkeypatch.setattr("tinytalk.tts_kokoro._configure_espeak_from_homebrew", lambda: None)
    existing = object()

    _default_pipeline_factory("b", model=existing)

    assert built == {"lang_code": "b", "model": existing}


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


class TrackingPipeline:
    """Records the [start, end) wall-clock window each call actually ran
    in, so a test can assert two calls never overlapped."""

    def __init__(self, lang_code: str, delay: float = 0.05) -> None:
        self.delay = delay
        self.windows: list[tuple[float, float]] = []
        self._windows_lock = threading.Lock()

    def __call__(self, text: str, voice: str):
        start = time.monotonic()
        time.sleep(self.delay)
        end = time.monotonic()
        with self._windows_lock:
            self.windows.append((start, end))
        yield ("graphemes", "phonemes", np.array([0.0], dtype=np.float32))


async def test_concurrent_synthesize_calls_never_overlap_in_the_pipeline():
    # Real bug, confirmed on real hardware (2026-08-28): a cancelled turn's
    # TTS call keeps running on its worker thread even after asyncio
    # considers it cancelled (Python cannot stop an already-started
    # thread-pool call), so a NEW turn's synthesize() could start a second
    # concurrent call into the same shared KPipeline instance -- and
    # PyTorch's MPS backend crashed the whole process when that happened.
    # This proves _run_pipeline's threading.Lock actually serializes
    # concurrent calls rather than letting them race.
    pipeline = TrackingPipeline("a", delay=0.05)
    tts = KokoroTts(pipeline_factory=lambda code: pipeline)

    async def run():
        return [chunk async for chunk in tts.synthesize("hello")]

    await asyncio.gather(run(), run())

    assert len(pipeline.windows) == 2
    (start1, end1), (start2, end2) = sorted(pipeline.windows)
    assert end1 <= start2, f"pipeline calls overlapped: {pipeline.windows}"


class BlockingPipeline:
    """Holds a call open until the test releases it, so a test can act while
    that call is provably mid-flight on its worker thread."""

    def __init__(self, lang_code: str) -> None:
        self.entered = threading.Event()
        self.release = threading.Event()
        self.in_call = False

    def __call__(self, text: str, voice: str):
        self.in_call = True
        try:
            self.entered.set()
            assert self.release.wait(timeout=5)
            yield ("graphemes", "phonemes", np.array([0.0], dtype=np.float32))
        finally:
            self.in_call = False


async def test_cancelled_synthesis_does_not_clear_the_mps_cache_under_its_orphaned_call(monkeypatch):
    # Issue #34, reproduced on real hardware (2026-09-19): cancelling a turn
    # mid-synthesis (barge-in, new utterance, disconnect) orphans the
    # pipeline call on its worker thread, and the old `finally` then ran
    # torch.mps.empty_cache() on a SECOND worker thread while that call was
    # still inside the MPS backend. empty_cache() also tears down PyTorch's
    # process-wide MPSGraph cache, so the running kernel's graph was freed
    # underneath it -- SIGSEGV in _lstm_mps (or, next run, an ObjC "cannot
    # form weak reference to MPSGraph" abort), no Python traceback. The
    # release must wait for the orphaned call to actually finish.
    pipeline = BlockingPipeline("a")
    cleared_while_call_running: list[bool] = []
    monkeypatch.setattr(
        torch.mps, "empty_cache", lambda: cleared_while_call_running.append(pipeline.in_call)
    )
    tts = KokoroTts(pipeline_factory=lambda code: pipeline)

    async def run():
        return [chunk async for chunk in tts.synthesize("hello")]

    task = asyncio.create_task(run())
    assert await asyncio.to_thread(pipeline.entered.wait, 5)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    await asyncio.sleep(0.1)  # long enough for a racing release to have fired mid-call
    pipeline.release.set()  # the orphaned worker thread now runs to completion
    for _ in range(100):
        if cleared_while_call_running:
            break
        await asyncio.sleep(0.02)

    # Still released exactly once (memory footprint must not creep back up),
    # but only after the orphaned call was done with the MPS backend.
    assert cleared_while_call_running == [False]


class TrackingCache:
    """Stands in for torch.mps.empty_cache, recording each call's wall-clock
    window so a test can assert it never overlapped a pipeline call."""

    def __init__(self, delay: float = 0.05) -> None:
        self.delay = delay
        self.windows: list[tuple[float, float]] = []
        self._windows_lock = threading.Lock()

    def __call__(self) -> None:
        start = time.monotonic()
        time.sleep(self.delay)
        end = time.monotonic()
        with self._windows_lock:
            self.windows.append((start, end))


async def test_mps_cache_release_never_overlaps_any_pipeline_call(monkeypatch):
    # Same bug from the other direction: with two synthesize() calls in
    # flight, the first one's cache release must not run alongside the
    # second one's pipeline call either.
    pipeline = TrackingPipeline("a", delay=0.05)
    cache = TrackingCache(delay=0.05)
    monkeypatch.setattr(torch.mps, "empty_cache", cache)
    tts = KokoroTts(pipeline_factory=lambda code: pipeline)

    async def run():
        return [chunk async for chunk in tts.synthesize("hello")]

    await asyncio.gather(run(), run())

    assert len(pipeline.windows) == 2 and len(cache.windows) == 2
    windows = sorted(pipeline.windows + cache.windows)
    for (_, earlier_end), (later_start, _) in zip(windows, windows[1:]):
        assert earlier_end <= later_start, (
            f"GPU work overlapped: pipeline={pipeline.windows} cache={cache.windows}"
        )


async def test_cpu_device_never_touches_the_mps_cache(monkeypatch):
    # TINYTALK_TTS_DEVICE=cpu is the fallback if MPS ever misbehaves again:
    # it must take the MPS backend (and its process-wide graph cache) out of
    # Kokoro's path entirely, not just run the model elsewhere.
    monkeypatch.setattr(config, "KOKORO_DEVICE", "cpu")
    calls = []
    monkeypatch.setattr(torch.mps, "empty_cache", lambda: calls.append(True))
    tts = KokoroTts(pipeline_factory=lambda code: FakePipeline(code))

    [chunk async for chunk in tts.synthesize("The fox ran.")]

    assert calls == []


def test_startup_log_names_the_configured_device(monkeypatch, caplog):
    monkeypatch.setattr(config, "KOKORO_DEVICE", "cpu")

    with caplog.at_level(logging.INFO, logger="tinytalk.tts_kokoro"):
        KokoroTts(pipeline_factory=lambda code: FakePipeline(code))

    assert "device=cpu" in caplog.text


@pytest.mark.parametrize("device", ["cpu", "mps"])
def test_default_factory_builds_the_pipeline_on_the_configured_device(monkeypatch, caplog, device):
    built: dict = {}

    class FakeKPipeline:
        def __init__(self, lang_code: str, device: str) -> None:
            built.update(lang_code=lang_code, device=device)
            # What the real KModel reports once .to(device) has run.
            self.model = types.SimpleNamespace(device=torch.device(device))

    fake_kokoro = types.ModuleType("kokoro")
    fake_kokoro.KPipeline = FakeKPipeline
    monkeypatch.setitem(sys.modules, "kokoro", fake_kokoro)
    monkeypatch.setattr("tinytalk.tts_kokoro._configure_espeak_from_homebrew", lambda: None)
    monkeypatch.setattr(config, "KOKORO_DEVICE", device)

    with caplog.at_level(logging.INFO, logger="tinytalk.tts_kokoro"):
        pipeline = _default_pipeline_factory("a")

    assert built == {"lang_code": "a", "device": device}
    assert isinstance(pipeline, FakeKPipeline)
    # The log names the device the loaded model REPORTS, not just what was
    # asked for, so it confirms which path is really live.
    assert f"loaded on device={device}" in caplog.text

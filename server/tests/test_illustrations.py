from typing import AsyncIterator

import httpx
from PIL import Image

from tinytalk import config
from tinytalk.engines import EngineError
from tinytalk.illustrations import _release_ollama_memory, generate_and_attach
from tinytalk.story_store import load_story, save_story, story_id_from_path, update_story_rewrite
from tinytalk.conversation import Conversation


class FakeExtractionLlm:
    """Returns a fixed scene-prompt string for every prompt-extraction
    call, one per page in order. Optionally appends to a shared
    `call_order` list (tagged "llm") so a test can assert ordering
    relative to a FakeImageBackend sharing the same list."""

    def __init__(self, prompts: list[str] | None = None, call_order: list | None = None) -> None:
        self.prompts = prompts
        self.calls: list[list[dict[str, str]]] = []
        self._call_order = call_order

    async def stream_reply(self, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        self.calls.append(messages)
        if self._call_order is not None:
            self._call_order.append("llm")
        if self.prompts is not None:
            index = min(len(self.calls) - 1, len(self.prompts) - 1)
            yield self.prompts[index]
        else:
            yield "a fox in a forest"


class FakeImageBackend:
    """Records every generate() call; returns a tiny real PIL image
    unless that call index is in `flagged_indices`, in which case it
    returns None (simulating a safety-checker drop). Optionally appends
    to a shared `call_order` list (tagged "image") -- see
    FakeExtractionLlm."""

    def __init__(self, flagged_indices: set[int] | None = None, call_order: list | None = None) -> None:
        self.calls: list[tuple[str, object]] = []
        self.flagged_indices = flagged_indices or set()
        self._call_order = call_order

    def generate(self, prompt, *, reference_image):
        index = len(self.calls)
        self.calls.append((prompt, reference_image))
        if self._call_order is not None:
            self._call_order.append("image")
        if index in self.flagged_indices:
            return None
        return Image.new("RGB", (8, 8), color=(255, 0, 0))


class FakeRaisingExtractionLlm:
    """Behaves like FakeExtractionLlm, but raises EngineError on the
    call at `raise_on_index` (0-indexed, one call per page) instead of
    yielding a prompt -- simulating a local-LLM hiccup on one page's
    prompt-extraction call specifically, not a whole-pass failure."""

    def __init__(self, raise_on_index: int) -> None:
        self.raise_on_index = raise_on_index
        self.calls: list[list[dict[str, str]]] = []

    async def stream_reply(self, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        self.calls.append(messages)
        if len(self.calls) - 1 == self.raise_on_index:
            raise EngineError("local LLM hiccup")
        yield "a fox in a forest"


class FakeRaisingImageBackend:
    """Behaves like FakeImageBackend, but raises on the generate() call at
    `raise_on_index` (0-indexed, one call per page) instead of returning
    an image or None -- simulating a real backend failure (e.g. an MPS
    allocation error under memory pressure) on one page specifically, not
    a whole-pass failure."""

    def __init__(self, raise_on_index: int) -> None:
        self.raise_on_index = raise_on_index
        self.calls: list[tuple[str, object]] = []

    def generate(self, prompt, *, reference_image):
        index = len(self.calls)
        self.calls.append((prompt, reference_image))
        if index == self.raise_on_index:
            raise RuntimeError("simulated MPS allocation failure")
        return Image.new("RGB", (8, 8), color=(0, 0, 255))


def _saved_story_with_pages(tmp_path, pages):
    conversation = Conversation()
    conversation.add_child("hello")
    path = save_story(conversation, stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    update_story_rewrite(
        story_id, title="A Story", pages=pages, epilogue=None,
        rewrite_status="done", stories_dir=tmp_path,
    )
    return story_id


async def test_generates_one_image_per_page_in_order(tmp_path):
    pages = [{"text": "Page one."}, {"text": "Page two."}, {"text": "Page three."}]
    story_id = _saved_story_with_pages(tmp_path, pages)
    backend = FakeImageBackend()

    await generate_and_attach(
        story_id, pages, llm=FakeExtractionLlm(), image_backend=backend, stories_dir=tmp_path
    )

    assert len(backend.calls) == 3
    story = load_story(story_id, stories_dir=tmp_path)
    assert story["illustrations_status"] == "done"
    for page in story["pages"]:
        assert page["image_path"] is not None
        assert (tmp_path / page["image_path"]).exists()


async def test_page_one_generates_reference_free_later_pages_use_it(tmp_path):
    pages = [{"text": "Page one."}, {"text": "Page two."}]
    story_id = _saved_story_with_pages(tmp_path, pages)
    backend = FakeImageBackend()

    await generate_and_attach(
        story_id, pages, llm=FakeExtractionLlm(), image_backend=backend, stories_dir=tmp_path
    )

    first_prompt, first_reference = backend.calls[0]
    second_prompt, second_reference = backend.calls[1]
    assert first_reference is None
    assert second_reference is not None  # page 1's own generated image


async def test_flagged_page_gets_no_image_but_others_still_do(tmp_path):
    pages = [{"text": "Page one."}, {"text": "Page two."}, {"text": "Page three."}]
    story_id = _saved_story_with_pages(tmp_path, pages)
    backend = FakeImageBackend(flagged_indices={1})

    await generate_and_attach(
        story_id, pages, llm=FakeExtractionLlm(), image_backend=backend, stories_dir=tmp_path
    )

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["illustrations_status"] == "partial"
    assert story["pages"][0]["image_path"] is not None
    assert story["pages"][1]["image_path"] is None
    assert story["pages"][2]["image_path"] is not None


async def test_every_page_flagged_marks_failed(tmp_path):
    pages = [{"text": "Page one."}]
    story_id = _saved_story_with_pages(tmp_path, pages)
    backend = FakeImageBackend(flagged_indices={0})

    await generate_and_attach(
        story_id, pages, llm=FakeExtractionLlm(), image_backend=backend, stories_dir=tmp_path
    )

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["illustrations_status"] == "failed"
    assert story["pages"][0]["image_path"] is None


async def test_llm_failure_on_one_page_degrades_only_that_page(tmp_path):
    # A prompt-extraction failure on one page (e.g. the local LLM
    # raising EngineError) must degrade only that page -- the same way
    # image_backend.generate() returning None already does -- not abort
    # the whole pass and discard already-generated pages.
    pages = [{"text": "Page one."}, {"text": "Page two."}, {"text": "Page three."}]
    story_id = _saved_story_with_pages(tmp_path, pages)
    backend = FakeImageBackend()
    llm = FakeRaisingExtractionLlm(raise_on_index=1)

    await generate_and_attach(
        story_id, pages, llm=llm, image_backend=backend, stories_dir=tmp_path
    )

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["illustrations_status"] == "partial"
    assert story["pages"][0]["image_path"] is not None
    assert story["pages"][1]["image_path"] is None
    assert story["pages"][2]["image_path"] is not None
    # Page 2 still got the benefit of page 0's reference image, since
    # page 0 succeeded before page 1's failure.
    assert backend.calls[-1][1] is not None


async def test_image_backend_failure_on_one_page_degrades_only_that_page_and_continues(tmp_path):
    # A real backend failure (image_backend.generate() raising, not just
    # returning None) on ONE page must degrade only that page and leave
    # every earlier page's already-saved image intact -- not propagate to
    # the outer try/except, which would wipe image_filenames to all-None
    # and destroy already-succeeded pages' files. Later pages must still
    # be attempted (not abandoned once one page fails).
    pages = [
        {"text": "Page one."}, {"text": "Page two."}, {"text": "Page three."},
        {"text": "Page four."}, {"text": "Page five."},
    ]
    story_id = _saved_story_with_pages(tmp_path, pages)
    backend = FakeRaisingImageBackend(raise_on_index=2)

    await generate_and_attach(
        story_id, pages, llm=FakeExtractionLlm(), image_backend=backend, stories_dir=tmp_path
    )

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["illustrations_status"] == "partial"
    assert story["pages"][0]["image_path"] is not None
    assert (tmp_path / story["pages"][0]["image_path"]).exists()
    assert story["pages"][1]["image_path"] is not None
    assert (tmp_path / story["pages"][1]["image_path"]).exists()
    assert story["pages"][2]["image_path"] is None
    # Pages after the failing one are still attempted and still succeed.
    assert story["pages"][3]["image_path"] is not None
    assert (tmp_path / story["pages"][3]["image_path"]).exists()
    assert story["pages"][4]["image_path"] is not None
    assert (tmp_path / story["pages"][4]["image_path"]).exists()
    assert len(backend.calls) == 5


async def test_prompt_extraction_uses_each_pages_own_text(tmp_path):
    pages = [{"text": "Page one."}, {"text": "Page two."}]
    story_id = _saved_story_with_pages(tmp_path, pages)
    llm = FakeExtractionLlm()

    await generate_and_attach(
        story_id, pages, llm=llm, image_backend=FakeImageBackend(), stories_dir=tmp_path
    )

    assert len(llm.calls) == 2
    assert "Page one." in llm.calls[0][0]["content"]
    assert "Page two." in llm.calls[1][0]["content"]


async def test_sets_pending_status_before_generation_completes(tmp_path):
    # A slow-generating backend should still leave the story readable
    # with a "pending" status mid-pass, not the pre-illustration None --
    # verified here by checking the status set at the very start, since
    # this fake backend completes synchronously (there is no real
    # concurrency to race against in this fake-based test).
    pages = [{"text": "Page one."}]
    story_id = _saved_story_with_pages(tmp_path, pages)
    statuses_seen = []

    class RecordingBackend(FakeImageBackend):
        def generate(self, prompt, *, reference_image):
            statuses_seen.append(load_story(story_id, stories_dir=tmp_path)["illustrations_status"])
            return super().generate(prompt, reference_image=reference_image)

    await generate_and_attach(
        story_id, pages, llm=FakeExtractionLlm(), image_backend=RecordingBackend(),
        stories_dir=tmp_path,
    )

    assert statuses_seen == ["pending"]


async def test_all_prompt_extraction_happens_before_any_image_generation(tmp_path):
    # Real-hardware finding (2026-09-14): interleaving one LLM call per
    # page with that page's image generation keeps Ollama's ~6-7GB
    # resident (each call refreshes its keep-alive timer) for the ENTIRE
    # illustration pass, directly competing with Stable Diffusion for the
    # same 16GB unified memory and causing severe swap thrashing
    # (measured: per-step generation time jumped from ~18s to ~217s, a
    # 12x cliff). All scene-prompt extraction must happen in one burst
    # before any image generation starts, so Ollama's memory can be
    # released (see _release_ollama_memory) before the compute-heavy
    # phase begins.
    pages = [{"text": "Page one."}, {"text": "Page two."}, {"text": "Page three."}]
    story_id = _saved_story_with_pages(tmp_path, pages)
    call_order: list = []
    llm = FakeExtractionLlm(call_order=call_order)
    backend = FakeImageBackend(call_order=call_order)

    await generate_and_attach(
        story_id, pages, llm=llm, image_backend=backend, stories_dir=tmp_path
    )

    assert call_order == ["llm", "llm", "llm", "image", "image", "image"]


async def test_release_ollama_memory_posts_keep_alive_zero_for_ollama_backend(monkeypatch):
    monkeypatch.setattr(config, "LLM_BACKEND", "ollama")
    monkeypatch.setattr(config, "OLLAMA_HOST", "http://localhost:11434")
    monkeypatch.setattr(config, "OLLAMA_MODEL", "qwen3.5:9b")
    requests = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(200, json={})

    await _release_ollama_memory(transport=httpx.MockTransport(handler))

    assert len(requests) == 1
    assert requests[0].url == "http://localhost:11434/api/generate"
    import json

    body = json.loads(requests[0].content)
    assert body == {"model": "qwen3.5:9b", "keep_alive": 0}


async def test_release_ollama_memory_posts_even_when_config_backend_is_groq(monkeypatch):
    # The phone's per-story LLM choice (issue #25) can leave
    # config.LLM_BACKEND (the startup preference) pointing at "groq" even
    # though the story just illustrated actually ran on Ollama -- this
    # call must stay unconditional (see its own doc comment) rather than
    # gated on that flag, or a real release would get skipped.
    monkeypatch.setattr(config, "LLM_BACKEND", "groq")
    monkeypatch.setattr(config, "OLLAMA_HOST", "http://localhost:11434")
    monkeypatch.setattr(config, "OLLAMA_MODEL", "qwen3.5:9b")
    requests = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(200, json={})

    await _release_ollama_memory(transport=httpx.MockTransport(handler))

    assert len(requests) == 1
    assert requests[0].url == "http://localhost:11434/api/generate"


async def test_release_ollama_memory_failure_is_logged_not_raised(monkeypatch):
    monkeypatch.setattr(config, "LLM_BACKEND", "ollama")

    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    # Must not raise -- this is a best-effort optimization, never a
    # correctness requirement (see its own doc comment).
    await _release_ollama_memory(transport=httpx.MockTransport(handler))

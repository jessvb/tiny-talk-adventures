# Storybook Page Art Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate one Stable Diffusion illustration per storybook page, in the background rewrite window, and show it in the Reading screen for a just-finished story.

**Architecture:** A new `illustrations.py` module runs as a second phase inside `storybook.py`'s existing background rewrite job (same `REWRITING` gate): for each page in order, a local LLM call condenses the page's prose into a short scene prompt, then a local Stable Diffusion 1.5 pipeline (a storybook-style LoRA, IP-Adapter conditioned on page 1's own output for every later page) generates the image. A new `GetPageImage` wire message streams a page's PNG bytes to the phone on demand, and `ReadingView` renders it in place of its current placeholder, scoped to the one real-data path that already exists (The End → "Read it now").

**Tech Stack:** Python 3.12 (server, existing), Hugging Face `diffusers` on the PyTorch `mps` backend (new — see Task 2 for why this supersedes the spec's provisional Core ML mention), Swift/SwiftUI (iOS client, existing).

**Spec:** `docs/superpowers/specs/2026-09-11-storybook-page-art-design.md`

## Global Constraints

- Free/local models only; no paid cloud APIs. The SD 1.5 checkpoint, LoRA, and IP-Adapter weights are downloaded once from the Hugging Face Hub (a public, free, unauthenticated download, same as Ollama pulling `qwen3.5:9b` or Kyutai's STT weights) and then run entirely on-device — never a per-request cloud call.
- Kid-safe content: the negative prompt and Stable Diffusion's built-in safety checker are both required. **Never pass `safety_checker=None`** when constructing the pipeline — a common example online, but it would silently disable the one safety backstop this feature has.
- Python version is pinned via `server/.python-version` (3.12.12); all new dependencies install into `server/.venv` via `pip install -e ".[dev]"` — never system/global Python.
- Illustration generation must never run concurrently with a live turn's own LLM call — it shares `storybook.py`'s existing `REWRITING` gate, sequenced strictly after the text rewrite, not a separate gate.
- iOS scope is deliberately narrow: only the real-data path that already exists today (The End → "Read it now" → real `SavedStoryDetail`, from PR #17). Library's story list stays mock, untouched.
- Away-from-home demo mode is explicitly out of scope (GitHub issue #26) — do not add any cloud-image-API fallback in this plan.

---

## Task 1: `story_store.py` — persist per-page images and illustration status

**Files:**
- Modify: `server/tinytalk/story_store.py`
- Test: `server/tests/test_story_store.py`

**Interfaces:**
- Produces: `update_story_illustrations(story_id: str, *, image_filenames: list[str | None], illustrations_status: str, stories_dir: Path = STORIES_DIR) -> bool`; `read_page_image(story_id: str, page_index: int, *, stories_dir: Path = STORIES_DIR) -> bytes | None`. `save_story()`'s payload gains `"illustrations_status": None`.

- [ ] **Step 1: Write the failing tests**

Add `update_story_illustrations` and `read_page_image` to the existing `from tinytalk.story_store import (...)` block (`server/tests/test_story_store.py:4-9`), and add these tests, reusing that file's existing `make_conversation()` helper (`server/tests/test_story_store.py:12-16`) rather than constructing a `Conversation` inline:

```python
def test_save_story_defaults_illustrations_status_to_none(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    payload = json.loads(path.read_text())
    assert payload["illustrations_status"] is None


def test_update_story_illustrations_patches_pages_and_status(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    update_story_rewrite(
        story_id,
        title="A Story",
        pages=[{"text": "Page one."}, {"text": "Page two."}],
        epilogue=None,
        rewrite_status="done",
        stories_dir=tmp_path,
    )

    ok = update_story_illustrations(
        story_id,
        image_filenames=[f"{story_id}-page-0.png", None],
        illustrations_status="partial",
        stories_dir=tmp_path,
    )

    assert ok is True
    story = load_story(story_id, stories_dir=tmp_path)
    assert story["pages"][0]["image_path"] == f"{story_id}-page-0.png"
    assert story["pages"][1]["image_path"] is None
    assert story["illustrations_status"] == "partial"


def test_update_story_illustrations_returns_false_for_unknown_story(tmp_path):
    ok = update_story_illustrations(
        "nope1234", image_filenames=[], illustrations_status="failed", stories_dir=tmp_path
    )
    assert ok is False


def test_read_page_image_returns_bytes_when_present(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    update_story_rewrite(
        story_id, title="A Story", pages=[{"text": "Page one."}], epilogue=None,
        rewrite_status="done", stories_dir=tmp_path,
    )
    filename = f"{story_id}-page-0.png"
    (tmp_path / filename).write_bytes(b"fake-png-bytes")
    update_story_illustrations(
        story_id, image_filenames=[filename], illustrations_status="done", stories_dir=tmp_path
    )

    data = read_page_image(story_id, 0, stories_dir=tmp_path)

    assert data == b"fake-png-bytes"


def test_read_page_image_returns_none_when_no_image(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    update_story_rewrite(
        story_id, title="A Story", pages=[{"text": "Page one."}], epilogue=None,
        rewrite_status="done", stories_dir=tmp_path,
    )

    assert read_page_image(story_id, 0, stories_dir=tmp_path) is None


def test_read_page_image_returns_none_for_out_of_range_page(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    update_story_rewrite(
        story_id, title="A Story", pages=[{"text": "Page one."}], epilogue=None,
        rewrite_status="done", stories_dir=tmp_path,
    )

    assert read_page_image(story_id, 5, stories_dir=tmp_path) is None
```

Add the new names to that test file's existing import line from `tinytalk.story_store` (it already imports `save_story`, `load_story`, `story_id_from_path`, `update_story_rewrite` — add `update_story_illustrations` and `read_page_image` alongside them).

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && source .venv/bin/activate && pytest tests/test_story_store.py -k illustrations -v`
Expected: FAIL with `ImportError` (names don't exist yet).

- [ ] **Step 3: Implement**

In `server/tinytalk/story_store.py`, add `"illustrations_status": None,` to `save_story()`'s payload dict (`server/tinytalk/story_store.py:56-58`, right after the existing `"rewrite_status": "pending",` line):

```python
        "title": None,
        "pages": None,
        "epilogue": None,
        "rewrite_status": "pending",
        "illustrations_status": None,
```

Then add these two functions after `update_story_rewrite` (end of file):

```python
def update_story_illustrations(
    story_id: str,
    *,
    image_filenames: list[str | None],
    illustrations_status: str,
    stories_dir: Path = STORIES_DIR,
) -> bool:
    """Patches illustrations.py's per-page image filenames and pass status
    into an already-saved, already-rewritten story file. image_filenames
    is positional with the story's existing `pages` list (index i's
    filename becomes pages[i]["image_path"]). Logged, not raised, on any
    failure -- same reasoning as update_story_rewrite()."""
    path = _find_story_path(story_id, stories_dir=stories_dir)
    if path is None:
        logger.error("cannot update illustrations -- no saved story with id %r", story_id)
        return False
    try:
        payload = json.loads(path.read_text())
        pages = payload.get("pages") or []
        for page, filename in zip(pages, image_filenames):
            page["image_path"] = filename
        payload["pages"] = pages
        payload["illustrations_status"] = illustrations_status
        path.write_text(json.dumps(payload, indent=2))
        return True
    except (OSError, json.JSONDecodeError, UnicodeDecodeError, KeyError) as exc:
        logger.error("failed to update illustrations for story %s: %s", story_id, exc)
        return False


def read_page_image(
    story_id: str, page_index: int, *, stories_dir: Path = STORIES_DIR
) -> bytes | None:
    """Raw PNG bytes for one page's illustration, or None if that story or
    page doesn't exist, that page has no image, or the file can't be
    read."""
    story = load_story(story_id, stories_dir=stories_dir)
    pages = story.get("pages") if story else None
    if not pages or page_index < 0 or page_index >= len(pages):
        return None
    filename = pages[page_index].get("image_path")
    if not filename:
        return None
    try:
        return (stories_dir / filename).read_bytes()
    except OSError as exc:
        logger.error(
            "failed to read page image for story %s page %d: %s", story_id, page_index, exc
        )
        return None
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && source .venv/bin/activate && pytest tests/test_story_store.py -v`
Expected: PASS (all tests in the file, including the pre-existing ones).

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/story_store.py server/tests/test_story_store.py
git commit -m "feat(server): persist per-page illustration paths and status"
```

---

## Task 2: `image_gen.py` — the Stable Diffusion backend

**Files:**
- Create: `server/tinytalk/image_gen.py`
- Modify: `server/tinytalk/config.py`
- Modify: `server/pyproject.toml`
- Test: `server/tests/test_image_gen.py`

**Interfaces:**
- Produces: `ImageGenBackend` (a `Protocol` with `generate(self, prompt: str, *, reference_image: "PIL.Image.Image | None") -> "PIL.Image.Image | None"`), `StableDiffusionBackend` (the real implementation of it).
- Consumes: `config.IMAGE_GEN_MODEL`, `config.IMAGE_GEN_LORA`, `config.IMAGE_GEN_IP_ADAPTER_REPO`, `config.IMAGE_GEN_IP_ADAPTER_WEIGHT`, `config.IMAGE_GEN_IP_ADAPTER_SCALE` (all new).

This backend cannot be meaningfully unit-tested without real model weights and Metal hardware (same reason `stt_kyutai.py`/`tts_kokoro.py` have no from-scratch unit tests) — this task's automated tests cover only what's genuinely testable without those: lazy loading, and the negative-prompt content. Real image quality and timing are verified on-device later (see the plan's closing "On-device verification" section).

- [ ] **Step 1: Write the failing tests**

Create `server/tests/test_image_gen.py`:

```python
from tinytalk.image_gen import NEGATIVE_PROMPT, StableDiffusionBackend


def test_backend_does_not_load_the_model_at_construction():
    backend = StableDiffusionBackend()
    assert backend._pipeline is None


def test_negative_prompt_excludes_unsafe_content():
    for term in ("violence", "gore", "nudity"):
        assert term in NEGATIVE_PROMPT
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && source .venv/bin/activate && pytest tests/test_image_gen.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'tinytalk.image_gen'`.

- [ ] **Step 3: Add dependencies**

In `server/pyproject.toml`, add to the `dependencies` list (`server/pyproject.toml:6-14`):

```toml
    "diffusers>=0.34.0,<0.35.0",
    "transformers",
    "accelerate",
    "torch>=2.0",
    "pillow",
```

**Pin note (ruled during Task 2 execution, not originally in this plan):** `diffusers>=0.38.0` requires `safetensors>=0.8.0-rc.0`, which conflicts with the already-installed `moshi_mlx==0.3.0` (used for Kyutai STT), which requires `safetensors<0.6`. A first correction to `>=0.37.0,<0.38.0` (compatible on `safetensors`) turned out to hit a second, independent conflict: `diffusers==0.37.0` requires `huggingface-hub>=0.34.0`, but `moshi_mlx` requires `huggingface-hub<0.29`. `diffusers==0.34.0` is compatible with both constraints (`safetensors>=0.3.1`, `huggingface-hub>=0.27.0`) — verified via a full `pip install` + `pip check` (no broken requirements) in this exact venv. The IP-Adapter/safety-checker API this plan uses (`load_ip_adapter`, `set_ip_adapter_scale`, `nsfw_content_detected`) was independently confirmed present on the installed 0.34.0.

Run: `cd server && source .venv/bin/activate && pip install -e ".[dev]"`
Expected: installs successfully (this will take a while — `torch` is a large download).

- [ ] **Step 4: Implement**

In `server/tinytalk/config.py`, add after `CONCLUDE_SAFETY_RETRY_ATTEMPTS` (`server/tinytalk/config.py:153-155`), before `SYSTEM_PROMPT`:

```python
# Stable Diffusion 1.5 base checkpoint used for storybook page
# illustrations (image_gen.py) -- pinned explicitly, same reasoning as
# STT_HF_REPO above: a change here is a deliberate choice, not something
# that should silently drift.
IMAGE_GEN_MODEL = os.environ.get(
    "TINYTALK_IMAGE_GEN_MODEL", "stable-diffusion-v1-5/stable-diffusion-v1-5"
)

# A storybook-illustration-style LoRA applied on top of the base
# checkpoint so generated pages read as children's-book art rather than
# photorealistic output. See the page-art design spec's "Feasibility"
# section for why this specific one was chosen.
IMAGE_GEN_LORA = os.environ.get(
    "TINYTALK_IMAGE_GEN_LORA",
    "artificialguybr/storybookredmond-1-5-version-storybook-kids-lora-style-for-sd-1-5",
)

# IP-Adapter reference-image conditioning, used for every page after the
# first so the story's animal stays visually consistent -- see the
# page-art design spec's "Character consistency" section. SD-1.5-specific
# checkpoint id; SDXL uses a different subfolder/filename, don't mix them
# up if this is ever changed.
IMAGE_GEN_IP_ADAPTER_REPO = os.environ.get("TINYTALK_IMAGE_GEN_IP_ADAPTER_REPO", "h94/IP-Adapter")
IMAGE_GEN_IP_ADAPTER_WEIGHT = os.environ.get(
    "TINYTALK_IMAGE_GEN_IP_ADAPTER_WEIGHT", "ip-adapter_sd15.bin"
)
IMAGE_GEN_IP_ADAPTER_SCALE = float(os.environ.get("TINYTALK_IMAGE_GEN_IP_ADAPTER_SCALE", "0.5"))
```

Create `server/tinytalk/image_gen.py`:

```python
"""Local Stable Diffusion 1.5 + IP-Adapter backend for illustrations.py.

Uses Hugging Face `diffusers` on the PyTorch `mps` backend, NOT Apple's
Core ML tooling -- the page-art design spec's provisional "Core ML
Stable Diffusion" framing was superseded during plan-writing (as that
spec explicitly anticipated) once research confirmed Apple's own
ml-stable-diffusion has no IP-Adapter support, which this feature
requires for character consistency across pages.

Heavy imports (torch, diffusers) happen inside load(), not at module
level, so importing this module -- e.g. from illustrations.py, or this
module's own tests -- stays fast and doesn't require the multi-second
torch import just to exercise the parts that don't need it. Same
lazy-loading reasoning as KyutaiStt/KokoroTts (see app.py's comment on
why those are constructed once and cache their model on first use).
"""

from __future__ import annotations

import logging
from typing import Protocol

from PIL import Image

from . import config

logger = logging.getLogger(__name__)

# A fixed negative prompt applied to every generation, matching this
# project's "don't assume default model behavior is safe" rule (see
# CLAUDE.md and the page-art design spec's "Image safety" section) --
# steers the model away from unsafe content up front, on top of (not
# instead of) the pipeline's own built-in safety checker in generate()
# below.
NEGATIVE_PROMPT = (
    "violence, weapons, blood, gore, death, scary, frightening, "
    "disturbing, horror, nudity, sexual content, realistic human "
    "anatomy, photorealistic"
)


class ImageGenBackend(Protocol):
    def generate(
        self, prompt: str, *, reference_image: Image.Image | None
    ) -> Image.Image | None:
        """Generates one illustration for `prompt`. If `reference_image`
        is given, conditions generation on it via IP-Adapter so the
        subject stays visually consistent with it. Returns None if the
        backend's safety checker flagged the result, or generation
        failed outright -- either way, illustrations.py treats this page
        as having no illustration, never a retry (see the design spec's
        "Image safety" section for why)."""
        ...


class StableDiffusionBackend:
    """Real backend: SD 1.5 + a storybook-illustration LoRA on the Apple
    Silicon `mps` backend, with IP-Adapter loaded for the reference-image
    case. The model loads lazily on first use (see load()), not at
    construction -- constructing this backend at server startup (see
    app.py) must not itself pay the multi-second-plus model-load cost
    before it's ever needed."""

    def __init__(self) -> None:
        self._pipeline = None

    def load(self) -> None:
        import torch
        from diffusers import StableDiffusionPipeline

        logger.info("loading Stable Diffusion pipeline: %s", config.IMAGE_GEN_MODEL)
        pipeline = StableDiffusionPipeline.from_pretrained(
            config.IMAGE_GEN_MODEL,
            torch_dtype=torch.float16,
            variant="fp16",
            use_safetensors=True,
            # Deliberately NOT passing safety_checker=None -- see this
            # module's docstring and the Global Constraints section of
            # this plan. The default built-in safety checker is required.
        ).to("mps")
        # Recommended by Hugging Face's own MPS guide for any machine
        # with less than 64GB unified memory -- this M1 (16GB) qualifies.
        pipeline.enable_attention_slicing()
        pipeline.load_lora_weights(config.IMAGE_GEN_LORA)
        pipeline.load_ip_adapter(
            config.IMAGE_GEN_IP_ADAPTER_REPO,
            subfolder="models",
            weight_name=config.IMAGE_GEN_IP_ADAPTER_WEIGHT,
        )
        pipeline.set_ip_adapter_scale(config.IMAGE_GEN_IP_ADAPTER_SCALE)
        self._pipeline = pipeline
        logger.info("Stable Diffusion pipeline loaded")

    def generate(
        self, prompt: str, *, reference_image: Image.Image | None
    ) -> Image.Image | None:
        if self._pipeline is None:
            self.load()
        kwargs: dict = {"prompt": prompt, "negative_prompt": NEGATIVE_PROMPT}
        if reference_image is not None:
            kwargs["ip_adapter_image"] = reference_image
        result = self._pipeline(**kwargs)
        flagged = bool(result.nsfw_content_detected and result.nsfw_content_detected[0])
        if flagged:
            logger.warning("Stable Diffusion safety checker flagged a generated image")
            return None
        return result.images[0]
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd server && source .venv/bin/activate && pytest tests/test_image_gen.py -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add server/tinytalk/image_gen.py server/tinytalk/config.py server/pyproject.toml server/tests/test_image_gen.py
git commit -m "feat(server): add Stable Diffusion + IP-Adapter image-gen backend"
```

---

## Task 3: `illustrations.py` — the per-page generation pipeline

**Files:**
- Create: `server/tinytalk/illustrations.py`
- Test: `server/tests/test_illustrations.py`

**Interfaces:**
- Consumes: `ImageGenBackend` (Task 2), `LlmEngine` (`engines.py`, existing), `story_store.update_story_illustrations` (Task 1).
- Produces: `async def generate_and_attach(story_id: str, pages: list[dict], *, llm: LlmEngine, image_backend: ImageGenBackend, stories_dir: Path = STORIES_DIR) -> None`.

- [ ] **Step 1: Write the failing tests**

Create `server/tests/test_illustrations.py`:

```python
from typing import AsyncIterator

from PIL import Image

from tinytalk.illustrations import generate_and_attach
from tinytalk.story_store import load_story, save_story, story_id_from_path, update_story_rewrite
from tinytalk.conversation import Conversation


class FakeExtractionLlm:
    """Returns a fixed scene-prompt string for every prompt-extraction
    call, one per page in order."""

    def __init__(self, prompts: list[str] | None = None) -> None:
        self.prompts = prompts
        self.calls: list[list[dict[str, str]]] = []

    async def stream_reply(self, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        self.calls.append(messages)
        if self.prompts is not None:
            index = min(len(self.calls) - 1, len(self.prompts) - 1)
            yield self.prompts[index]
        else:
            yield "a fox in a forest"


class FakeImageBackend:
    """Records every generate() call; returns a tiny real PIL image
    unless that call index is in `flagged_indices`, in which case it
    returns None (simulating a safety-checker drop)."""

    def __init__(self, flagged_indices: set[int] | None = None) -> None:
        self.calls: list[tuple[str, object]] = []
        self.flagged_indices = flagged_indices or set()

    def generate(self, prompt, *, reference_image):
        index = len(self.calls)
        self.calls.append((prompt, reference_image))
        if index in self.flagged_indices:
            return None
        return Image.new("RGB", (8, 8), color=(255, 0, 0))


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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && source .venv/bin/activate && pytest tests/test_illustrations.py -v`
Expected: FAIL with `ModuleNotFoundError: No module named 'tinytalk.illustrations'`.

- [ ] **Step 3: Implement**

Create `server/tinytalk/illustrations.py`:

```python
"""Background illustration pass: generates one Stable Diffusion image per
storybook page, run immediately after storybook.py's text rewrite
succeeds, inside the same REWRITING-gated window. See
docs/superpowers/specs/2026-09-11-storybook-page-art-design.md.
"""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path

from . import story_store
from .engines import EngineError, LlmEngine
from .image_gen import ImageGenBackend
from .story_store import STORIES_DIR

logger = logging.getLogger(__name__)

_PROMPT_EXTRACTION_TEMPLATE = (
    "Describe this storybook page as a short visual scene for an "
    "illustrator: setting, characters, action, and mood, in one "
    "sentence, no more than 25 words. Do not mention that this is from "
    "a story. Reply with ONLY the scene description, no other "
    "text.\n\nPage text: {text}"
)


async def _extract_scene_prompt(llm: LlmEngine, page_text: str) -> str:
    messages = [
        {"role": "user", "content": _PROMPT_EXTRACTION_TEMPLATE.format(text=page_text)}
    ]
    parts: list[str] = []
    async for chunk in llm.stream_reply(messages):
        parts.append(chunk)
    return "".join(parts).strip()


async def generate_and_attach(
    story_id: str,
    pages: list[dict],
    *,
    llm: LlmEngine,
    image_backend: ImageGenBackend,
    stories_dir: Path = STORIES_DIR,
) -> None:
    """Generates one illustration per page, strictly in order (page 0
    first, reference-free; later pages use page 0's own generated image
    as an IP-Adapter reference for character consistency) and patches
    image_path/illustrations_status into the already-saved,
    already-rewritten story -- or marks the whole pass "failed", logged,
    never raised. Called from storybook.py's build_and_attach()
    immediately after a successful text rewrite, still inside the same
    REWRITING-gated window -- see that module for how release of the
    gate is guaranteed regardless of outcome here."""
    try:
        story_store.update_story_illustrations(
            story_id,
            image_filenames=[None] * len(pages),
            illustrations_status="pending",
            stories_dir=stories_dir,
        )
        reference_image = None
        image_filenames: list[str | None] = []
        any_succeeded = False
        for index, page in enumerate(pages):
            scene_prompt = await _extract_scene_prompt(llm, page["text"])
            image = await asyncio.to_thread(
                image_backend.generate, scene_prompt, reference_image=reference_image
            )
            if image is None:
                logger.warning(
                    "illustration for story %s page %d has no image (safety "
                    "check or generation failure)",
                    story_id,
                    index,
                )
                image_filenames.append(None)
                continue
            if reference_image is None:
                reference_image = image
            filename = f"{story_id}-page-{index}.png"
            image.save(stories_dir / filename)
            image_filenames.append(filename)
            any_succeeded = True

        if any_succeeded and all(name is not None for name in image_filenames):
            status = "done"
        elif any_succeeded:
            status = "partial"
        else:
            status = "failed"
        story_store.update_story_illustrations(
            story_id,
            image_filenames=image_filenames,
            illustrations_status=status,
            stories_dir=stories_dir,
        )
        logger.info(
            "illustrations done for story %s: %s (%d/%d pages)",
            story_id,
            status,
            sum(1 for name in image_filenames if name),
            len(pages),
        )
    except asyncio.CancelledError:
        raise
    except EngineError as exc:
        logger.error("illustration pass failed for story %s: %s", story_id, exc)
        story_store.update_story_illustrations(
            story_id,
            image_filenames=[None] * len(pages),
            illustrations_status="failed",
            stories_dir=stories_dir,
        )
    except Exception:  # noqa: BLE001 - a background pass must survive one bad story
        logger.exception("unexpected failure during illustration pass for story %s", story_id)
        story_store.update_story_illustrations(
            story_id,
            image_filenames=[None] * len(pages),
            illustrations_status="failed",
            stories_dir=stories_dir,
        )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && source .venv/bin/activate && pytest tests/test_illustrations.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/illustrations.py server/tests/test_illustrations.py
git commit -m "feat(server): add per-page illustration generation pipeline"
```

---

## Task 4: `storybook.py` — invoke illustrations after a successful rewrite

**Files:**
- Modify: `server/tinytalk/storybook.py`
- Test: `server/tests/test_storybook.py`

**Interfaces:**
- Consumes: `illustrations.generate_and_attach` (Task 3), `ImageGenBackend` (Task 2).
- Produces: `build_and_attach(..., *, image_backend: ImageGenBackend | None = None, ...)` — new optional keyword parameter; `None` means "no illustration pass," preserving every existing call site.

- [ ] **Step 1: Write the failing tests**

`server/tests/test_storybook.py` currently imports `load_story, save_story` from `tinytalk.story_store` (`server/tests/test_storybook.py:6`) but not `story_id_from_path` — extend that import:

```python
from tinytalk.story_store import load_story, save_story, story_id_from_path
```

Then add (reusing that file's existing `FakeRewriteLlm`, `Conversation`, `Turn`):

```python
class FakeImageBackendForStorybook:
    def __init__(self) -> None:
        self.calls = 0

    def generate(self, prompt, *, reference_image):
        from PIL import Image

        self.calls += 1
        return Image.new("RGB", (8, 8), color=(0, 255, 0))


async def test_build_and_attach_runs_illustrations_when_backend_given(tmp_path):
    turns = [Turn(speaker="child", text="a fox story", interrupted=False)]
    conversation = Conversation()
    conversation.add_child("a fox story")
    path = save_story(conversation, stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    llm = FakeRewriteLlm(
        chunks=['{"title": "A Fox", "pages": [{"text": "Once there was a fox."}]}']
    )
    backend = FakeImageBackendForStorybook()

    await build_and_attach(
        story_id, turns, [], llm=llm, page_count=1, stories_dir=tmp_path,
        image_backend=backend,
    )

    assert backend.calls == 1
    story = load_story(story_id, stories_dir=tmp_path)
    assert story["illustrations_status"] in ("done", "partial")


async def test_build_and_attach_skips_illustrations_when_no_backend(tmp_path):
    turns = [Turn(speaker="child", text="a fox story", interrupted=False)]
    conversation = Conversation()
    conversation.add_child("a fox story")
    path = save_story(conversation, stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    llm = FakeRewriteLlm(
        chunks=['{"title": "A Fox", "pages": [{"text": "Once there was a fox."}]}']
    )

    await build_and_attach(story_id, turns, [], llm=llm, page_count=1, stories_dir=tmp_path)

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["illustrations_status"] is None
```

Check the top of `server/tests/test_storybook.py` for its exact existing imports (`load_story`, `story_id_from_path`, `Conversation`, `Turn`, `save_story`, `FakeRewriteLlm`) and reuse them — don't reimport what's already there.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && source .venv/bin/activate && pytest tests/test_storybook.py -k illustrations -v`
Expected: FAIL with `TypeError: build_and_attach() got an unexpected keyword argument 'image_backend'`.

- [ ] **Step 3: Implement**

In `server/tinytalk/storybook.py`, add the import (`server/tinytalk/storybook.py:16`, alongside the existing `from . import config, safety, story_store`):

```python
from . import config, illustrations, safety, story_store
from .image_gen import ImageGenBackend
```

Add `image_backend` to `build_and_attach()`'s signature (`server/tinytalk/storybook.py:139-147`):

```python
async def build_and_attach(
    story_id: str,
    turns: list[Turn],
    shared_facts: list[tuple[str, str]],
    *,
    llm: LlmEngine,
    page_count: int = 5,
    stories_dir: Path = STORIES_DIR,
    image_backend: ImageGenBackend | None = None,
) -> None:
```

Insert the illustration call right after the successful-rewrite branch's `story_store.update_story_rewrite(...)` call and its log line (`server/tinytalk/storybook.py:272-282`), still inside the same `try` block:

```python
        story_store.update_story_rewrite(
            story_id,
            title=title,
            pages=pages,
            epilogue=epilogue,
            rewrite_status="done",
            stories_dir=stories_dir,
        )
        logger.info(
            "storybook rewrite done for story %s: %d pages", story_id, len(pages)
        )
        if image_backend is not None:
            await illustrations.generate_and_attach(
                story_id, pages, llm=llm, image_backend=image_backend, stories_dir=stories_dir,
            )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && source .venv/bin/activate && pytest tests/test_storybook.py -v`
Expected: PASS (all tests in the file, including pre-existing ones — confirms the new optional parameter didn't break any existing call).

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/storybook.py server/tests/test_storybook.py
git commit -m "feat(server): run illustration pass after a successful storybook rewrite"
```

---

## Task 5: `protocol.py` — `GetPageImage` wire message

**Files:**
- Modify: `server/tinytalk/protocol.py`
- Test: `server/tests/test_protocol.py`

**Interfaces:**
- Produces: `GetPageImage(story_id: str, page_index: int)` dataclass; `encode_page_image_done(story_id: str, page_index: int, has_image: bool) -> str`.

- [ ] **Step 1: Write the failing tests**

In `server/tests/test_protocol.py`, add `GetPageImage` and `encode_page_image_done` to the existing import block (`server/tests/test_protocol.py:5-29`), then add a new parametrize case to `test_decodes_each_client_message_type` (`server/tests/test_protocol.py:32-47`), right after the `SynthesizePage` case:

```python
        ('{"type": "get_page_image", "story_id": "abcd1234", "page_index": 1}',
         GetPageImage(story_id="abcd1234", page_index=1)),
```

Then add these new tests:

```python
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && source .venv/bin/activate && pytest tests/test_protocol.py -v`
Expected: FAIL with `ImportError: cannot import name 'GetPageImage'`.

- [ ] **Step 3: Implement**

In `server/tinytalk/protocol.py`, add the dataclass right after `SynthesizePage` (`server/tinytalk/protocol.py:101-110`):

```python
@dataclass(frozen=True)
class GetPageImage:
    """Request the generated illustration for one page of a saved story
    (the Reading screen's page art). Image bytes stream through the same
    binary-frame pathway as SynthesizePage's audio, followed by a
    page_image_done marker whose has_image field tells the client
    whether a binary frame was actually sent -- a page with no
    illustration (not yet generated, or dropped by the safety check)
    sends the marker only, no binary frame."""

    story_id: str
    page_index: int
```

Add it to the `ClientMessage` union (`server/tinytalk/protocol.py:135-146`):

```python
ClientMessage = (
    SpeechStart
    | SpeechEnd
    | Interrupt
    | ObjectSeen
    | NewStory
    | ListStories
    | GetStory
    | SynthesizePage
    | GetPageImage
    | ConcludeStory
    | UpdateSettings
)
```

Add it to `_CLIENT_MESSAGE_TYPES` (`server/tinytalk/protocol.py:148-159`):

```python
    "get_page_image": GetPageImage,
```

Add the decode branch right after `SynthesizePage`'s (`server/tinytalk/protocol.py:193-202`):

```python
    if message_type is GetPageImage:
        story_id = payload.get("story_id")
        page_index = payload.get("page_index")
        if not isinstance(story_id, str) or not story_id.strip():
            raise ProtocolError(
                f"get_page_image requires a non-empty string story_id: {raw!r}"
            )
        if not isinstance(page_index, int):
            raise ProtocolError(f"get_page_image requires an integer page_index: {raw!r}")
        return GetPageImage(story_id=story_id.strip(), page_index=page_index)
```

Add the encoder function right after `encode_page_audio_done` (`server/tinytalk/protocol.py:250-253`):

```python
def encode_page_image_done(story_id: str, page_index: int, has_image: bool) -> str:
    return json.dumps(
        {
            "type": "page_image_done",
            "story_id": story_id,
            "page_index": page_index,
            "has_image": has_image,
        }
    )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && source .venv/bin/activate && pytest tests/test_protocol.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/protocol.py server/tests/test_protocol.py
git commit -m "feat(server): add GetPageImage wire message"
```

---

## Task 6: `session.py` — serve page images and extend `story_detail`

**Files:**
- Modify: `server/tinytalk/session.py`
- Test: `server/tests/test_session.py`

**Interfaces:**
- Consumes: `GetPageImage`, `encode_page_image_done` (Task 5); `story_store.read_page_image` (Task 1); `ImageGenBackend` (Task 2).
- Produces: `SessionRunner.__init__(..., *, image_backend: ImageGenBackend | None = None, ...)`; `handle_get_page_image(self, story_id: str, page_index: int) -> None`. `handle_get_story`'s `story_detail` payload gains per-page `has_image` and top-level `illustrations_status`.

- [ ] **Step 1: Write the failing tests**

`server/tests/test_session.py` currently imports `FailingLlm, FakeLlm, FakeStt, FakeTransport, FakeTts` from `conftest` but not `story_store` or `Conversation` (`server/tests/test_session.py:1-12`) — add both:

```python
from tinytalk import config, story_store
from tinytalk.conversation import Conversation, INTERRUPTED_MARKER
```

(merge with the existing `from tinytalk import config` and `from tinytalk.conversation import INTERRUPTED_MARKER` lines rather than duplicating them). Then add:

```python
async def test_handle_get_page_image_sends_bytes_and_done_marker(tmp_path, monkeypatch):
    monkeypatch.setattr(story_store, "STORIES_DIR", tmp_path)
    transport = FakeTransport()
    session = SessionRunner(transport=transport, stt=FakeStt(), llm=FakeLlm(), tts=FakeTts())
    conversation = Conversation()
    conversation.add_child("hello")
    path = story_store.save_story(conversation, stories_dir=tmp_path)
    story_id = story_store.story_id_from_path(path)
    story_store.update_story_rewrite(
        story_id, title="A Story", pages=[{"text": "Page one."}], epilogue=None,
        rewrite_status="done", stories_dir=tmp_path,
    )
    filename = f"{story_id}-page-0.png"
    (tmp_path / filename).write_bytes(b"fake-png-bytes")
    story_store.update_story_illustrations(
        story_id, image_filenames=[filename], illustrations_status="done", stories_dir=tmp_path,
    )

    await session.handle_get_page_image(story_id, 0)

    assert transport.audio == [b"fake-png-bytes"]
    done = transport.messages_of_type("page_image_done")
    assert done == [{"type": "page_image_done", "story_id": story_id, "page_index": 0, "has_image": True}]


async def test_handle_get_page_image_sends_done_marker_only_when_no_image(tmp_path, monkeypatch):
    monkeypatch.setattr(story_store, "STORIES_DIR", tmp_path)
    transport = FakeTransport()
    session = SessionRunner(transport=transport, stt=FakeStt(), llm=FakeLlm(), tts=FakeTts())
    conversation = Conversation()
    conversation.add_child("hello")
    path = story_store.save_story(conversation, stories_dir=tmp_path)
    story_id = story_store.story_id_from_path(path)
    story_store.update_story_rewrite(
        story_id, title="A Story", pages=[{"text": "Page one."}], epilogue=None,
        rewrite_status="done", stories_dir=tmp_path,
    )

    await session.handle_get_page_image(story_id, 0)

    assert transport.audio == []
    done = transport.messages_of_type("page_image_done")
    assert done == [{"type": "page_image_done", "story_id": story_id, "page_index": 0, "has_image": False}]


async def test_handle_get_page_image_errors_for_unknown_story(tmp_path, monkeypatch):
    monkeypatch.setattr(story_store, "STORIES_DIR", tmp_path)
    transport = FakeTransport()
    session = SessionRunner(transport=transport, stt=FakeStt(), llm=FakeLlm(), tts=FakeTts())

    await session.handle_get_page_image("nope1234", 0)

    errors = transport.messages_of_type("error")
    assert len(errors) == 1


async def test_handle_get_story_includes_has_image_and_illustrations_status(tmp_path, monkeypatch):
    monkeypatch.setattr(story_store, "STORIES_DIR", tmp_path)
    transport = FakeTransport()
    session = SessionRunner(transport=transport, stt=FakeStt(), llm=FakeLlm(), tts=FakeTts())
    conversation = Conversation()
    conversation.add_child("hello")
    path = story_store.save_story(conversation, stories_dir=tmp_path)
    story_id = story_store.story_id_from_path(path)
    story_store.update_story_rewrite(
        story_id, title="A Story", pages=[{"text": "Page one."}, {"text": "Page two."}],
        epilogue=None, rewrite_status="done", stories_dir=tmp_path,
    )
    story_store.update_story_illustrations(
        story_id, image_filenames=[f"{story_id}-page-0.png", None],
        illustrations_status="partial", stories_dir=tmp_path,
    )

    await session.handle_get_story(story_id)

    detail = session._transport.messages_of_type("story_detail")[0]
    assert detail["illustrations_status"] == "partial"
    assert detail["pages"] == [
        {"text": "Page one.", "has_image": True},
        {"text": "Page two.", "has_image": False},
    ]
```

`FakeTransport`'s `messages_of_type` helper (defined in `conftest.py`, shown earlier in this plan) is already available in this file via its existing `from conftest import ... FakeTransport` line.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd server && source .venv/bin/activate && pytest tests/test_session.py -k "page_image or has_image" -v`
Expected: FAIL with `AttributeError: 'SessionRunner' object has no attribute 'handle_get_page_image'`.

- [ ] **Step 3: Implement**

In `server/tinytalk/session.py`, add imports (`server/tinytalk/session.py:26-50`):

```python
from .image_gen import ImageGenBackend
```

and add `GetPageImage`, `encode_page_image_done` to the existing `from .protocol import (...)` block (alphabetically, matching that block's existing sorted style).

Add `image_backend` to `SessionRunner.__init__` (`server/tinytalk/session.py:106-115`):

```python
    def __init__(
        self,
        transport: Transport,
        stt: SttEngine,
        llm: LlmEngine,
        tts: TtsEngine,
        *,
        system_prompt: str = config.SYSTEM_PROMPT,
        conversation: Conversation | None = None,
        image_backend: ImageGenBackend | None = None,
    ) -> None:
```

and store it (`server/tinytalk/session.py:127-129`, alongside `self._tts = tts`):

```python
        self._tts = tts
        self._image_backend = image_backend
```

Dispatch the new message in `handle_text` (`server/tinytalk/session.py:202-207`, alongside the `SynthesizePage` case):

```python
            case GetPageImage(story_id=story_id, page_index=page_index):
                await self.handle_get_page_image(story_id, page_index)
```

Add the handler right after `handle_synthesize_page` (`server/tinytalk/session.py:339-353`):

```python
    async def handle_get_page_image(self, story_id: str, page_index: int) -> None:
        story = story_store.load_story(story_id)
        pages = story.get("pages") if story else None
        if not pages or page_index < 0 or page_index >= len(pages):
            await self._send_text_unbuffered(
                encode_error(
                    f"no page {page_index} for story {story_id!r}", self._current_turn_id
                )
            )
            return
        data = story_store.read_page_image(story_id, page_index)
        async with self._transport_lock:
            if data is not None:
                await self._transport.send_bytes(data)
            await self._transport.send_text(
                encode_page_image_done(story_id, page_index, has_image=data is not None)
            )
```

Extend `handle_get_story`'s payload (`server/tinytalk/session.py:320-337`):

```python
    async def handle_get_story(self, story_id: str) -> None:
        story = story_store.load_story(story_id)
        if story is None:
            await self._send_text_unbuffered(
                encode_error(f"no saved story with id {story_id!r}", self._current_turn_id)
            )
            return
        pages = story.get("pages")
        client_pages = (
            [{"text": p["text"], "has_image": bool(p.get("image_path"))} for p in pages]
            if pages
            else pages
        )
        await self._send_text_unbuffered(
            encode_story_detail(
                {
                    "id": story["id"],
                    "title": story.get("title"),
                    "pages": client_pages,
                    "epilogue": story.get("epilogue"),
                    "rewrite_status": story.get("rewrite_status", "pending"),
                    "illustrations_status": story.get("illustrations_status"),
                }
            )
        )
```

Finally, pass `self._image_backend` through in `_run_rewrite` (`server/tinytalk/session.py:871-878`):

```python
    async def _run_rewrite(
        self, story_id: str, turns: list, shared_facts: list[tuple[str, str]]
    ) -> None:
        try:
            await storybook.build_and_attach(
                story_id, turns, shared_facts, llm=self._llm,
                page_count=self._story_page_count,
                image_backend=self._image_backend,
            )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && source .venv/bin/activate && pytest tests/test_session.py -v`
Expected: PASS (all tests in the file).

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/session.py server/tests/test_session.py
git commit -m "feat(server): serve page images and extend story_detail with illustration info"
```

---

## Task 7: `app.py` — wire the real backend into the running server

**Files:**
- Modify: `server/tinytalk/app.py`
- Test: `server/tests/test_app.py`

**Interfaces:**
- Consumes: `StableDiffusionBackend` (Task 2).
- Produces: `build_session(..., *, image_backend: ImageGenBackend | None = None) -> SessionRunner` — new optional keyword parameter.

- [ ] **Step 1: Write the failing test**

`server/tests/test_app.py` currently imports `WebSocketTransport, build_llm, handle_connection` from `tinytalk.app` (`server/tests/test_app.py:10`) but not `build_session` or `NullTransport` — extend that import:

```python
from tinytalk.app import NullTransport, WebSocketTransport, build_llm, build_session, handle_connection
```

`FakeStt`, `FakeLlm`, `FakeTts` are already imported from `conftest` (`server/tests/test_app.py:7`). Then add:

```python
def test_build_session_forwards_image_backend():
    class FakeBackend:
        def generate(self, prompt, *, reference_image):
            return None

    backend = FakeBackend()
    session = build_session(
        NullTransport(), stt=FakeStt(), llm=FakeLlm(), tts=FakeTts(), image_backend=backend
    )
    assert session._image_backend is backend
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && source .venv/bin/activate && pytest tests/test_app.py -k image_backend -v`
Expected: FAIL with `TypeError: build_session() got an unexpected keyword argument 'image_backend'`.

- [ ] **Step 3: Implement**

In `server/tinytalk/app.py`, add the import (`server/tinytalk/app.py:18-25`):

```python
from .image_gen import ImageGenBackend, StableDiffusionBackend
```

Update `build_session` (`server/tinytalk/app.py:128-131`):

```python
def build_session(
    transport: Transport, *, stt: SttEngine, llm: LlmEngine, tts: TtsEngine,
    image_backend: ImageGenBackend | None = None,
) -> SessionRunner:
    return SessionRunner(transport=transport, stt=stt, llm=llm, tts=tts, image_backend=image_backend)
```

Construct the real backend and pass it through at the real startup call site (`server/tinytalk/app.py:365-374`):

```python
    stt = KyutaiStt()
    llm = build_llm()
    tts = KokoroTts()
    image_backend = StableDiffusionBackend()
    session = build_session(NullTransport(), stt=stt, llm=llm, tts=tts, image_backend=image_backend)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd server && source .venv/bin/activate && pytest tests/test_app.py -v`
Expected: PASS (all tests in the file — confirms the new optional parameter didn't break any existing call).

- [ ] **Step 5: Run the full server test suite**

Run: `cd server && source .venv/bin/activate && pytest -v`
Expected: PASS, every test in the suite. This is the last server-side task — a full green run here confirms nothing upstream (Tasks 1-6) broke anything unrelated.

- [ ] **Step 6: Commit**

```bash
git add server/tinytalk/app.py server/tests/test_app.py
git commit -m "feat(server): construct and wire the real Stable Diffusion backend at startup"
```

---

## Task 8: iOS `Protocol.swift` — wire types for page images

**Files:**
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift`
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/SavedStory.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/ProtocolTests.swift`

**Interfaces:**
- Produces: `ClientMessage.getPageImage(storyId: String, pageIndex: Int)`; `ServerEvent.pageImageDone(storyId: String, pageIndex: Int, hasImage: Bool)`; `StoryPage.hasImage: Bool` (defaults `false`); `IllustrationsStatus` enum; `SavedStoryDetail.illustrationsStatus: IllustrationsStatus?` (defaults `nil`).

- [ ] **Step 1: Write the failing tests**

Add to `ios/TinyTalkCore/Tests/TinyTalkCoreTests/ProtocolTests.swift`, right after `testUpdateSettingsEncodesBothValues` (line 58-63):

```swift
    func testGetPageImageEncodesStoryIdAndPageIndex() {
        XCTAssertEqual(
            ClientMessage.getPageImage(storyId: "abcd1234", pageIndex: 2).encode(),
            #"{"type":"get_page_image","story_id":"abcd1234","page_index":2}"#
        )
    }
```

Right after `testDecodesRewritingDone` (line 114-117):

```swift
    func testDecodesPageImageDoneWithImage() throws {
        let event = try decodeServerEvent(
            #"{"type": "page_image_done", "story_id": "abcd1234", "page_index": 1, "has_image": true}"#
        )
        XCTAssertEqual(event, .pageImageDone(storyId: "abcd1234", pageIndex: 1, hasImage: true))
    }

    func testDecodesPageImageDoneWithoutImage() throws {
        let event = try decodeServerEvent(
            #"{"type": "page_image_done", "story_id": "abcd1234", "page_index": 1, "has_image": false}"#
        )
        XCTAssertEqual(event, .pageImageDone(storyId: "abcd1234", pageIndex: 1, hasImage: false))
    }
```

Right after `testDecodesStoryDetail` (line 141-158):

```swift
    func testDecodesStoryDetailIncludesHasImageAndIllustrationsStatus() throws {
        let event = try decodeServerEvent(
            #"""
            {"type": "story_detail", "id": "pip", "title": "Pip the Fox",
             "pages": [{"text": "Once upon a time.", "has_image": true}, {"text": "The end.", "has_image": false}],
             "epilogue": null, "rewrite_status": "done", "illustrations_status": "partial"}
            """#
        )
        guard case .storyDetail(let detail) = event else {
            return XCTFail("expected storyDetail, got \(event)")
        }
        XCTAssertEqual(detail.pages[0].hasImage, true)
        XCTAssertEqual(detail.pages[1].hasImage, false)
        XCTAssertEqual(detail.illustrationsStatus, .partial)
    }
```

Right after `testDecodesStoryDetailWithNilTitleAndEpilogue` (line 160-174):

```swift
    func testDecodesStoryDetailWithNoIllustrationsStatusDefaultsToNil() throws {
        let event = try decodeServerEvent(
            #"{"type": "story_detail", "id": "brave-turtle", "title": null, "pages": [{"text": "Once upon a time."}], "epilogue": null, "rewrite_status": "pending"}"#
        )
        guard case .storyDetail(let detail) = event else {
            return XCTFail("expected storyDetail, got \(event)")
        }
        XCTAssertNil(detail.illustrationsStatus)
        XCTAssertEqual(detail.pages[0].hasImage, false)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/TinyTalkCore && swift test --filter ProtocolTests 2>&1 | tail -40`
Expected: FAIL to compile (`getPageImage`/`pageImageDone`/`hasImage`/`illustrationsStatus` don't exist yet).

- [ ] **Step 3: Implement**

In `ios/TinyTalkCore/Sources/TinyTalkCore/SavedStory.swift`, update `StoryPage` (lines 9-15):

```swift
public struct StoryPage: Equatable, Sendable {
    public let text: String
    public let hasImage: Bool

    public init(text: String, hasImage: Bool = false) {
        self.text = text
        self.hasImage = hasImage
    }
}
```

Add a new enum after `RewriteStatus` (lines 19-23):

```swift
/// Mirrors story_store.py's `illustrations_status` field exactly
/// (`"pending"`, `"done"`, `"partial"`, `"failed"`). Absent entirely
/// (`nil`) means the text rewrite hasn't finished yet, or finished but
/// no illustration pass has run at all -- distinct from any of the four
/// named states.
public enum IllustrationsStatus: String, Equatable, Sendable {
    case pending
    case done
    case partial
    case failed
}
```

Update `SavedStoryDetail` (lines 50-64):

```swift
public struct SavedStoryDetail: Equatable, Sendable {
    public let id: String
    public let title: String?
    public let pages: [StoryPage]
    public let epilogue: String?
    public let rewriteStatus: RewriteStatus
    public let illustrationsStatus: IllustrationsStatus?

    public init(
        id: String, title: String?, pages: [StoryPage], epilogue: String?,
        rewriteStatus: RewriteStatus, illustrationsStatus: IllustrationsStatus? = nil
    ) {
        self.id = id
        self.title = title
        self.pages = pages
        self.epilogue = epilogue
        self.rewriteStatus = rewriteStatus
        self.illustrationsStatus = illustrationsStatus
    }
}
```

In `ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift`, add the new `ClientMessage` case (after `updateSettings`, lines 45-48):

```swift
    /// Request the generated illustration for one page of a saved story
    /// -- see protocol.py's GetPageImage.
    case getPageImage(storyId: String, pageIndex: Int)
```

Add its `encode()` branch (after `updateSettings`'s, lines 70-71):

```swift
        case .getPageImage(let storyId, let pageIndex):
            return #"{"type":"get_page_image","story_id":"\#(Self.jsonEscaped(storyId))","page_index":\#(pageIndex)}"#
```

Add the new `ServerEvent` case (after `storyDetail`, line 112):

```swift
    /// One page's illustration bytes were just sent as a binary frame
    /// (when hasImage is true) -- see protocol.py's
    /// encode_page_image_done(). hasImage false means that page has no
    /// illustration; no binary frame was sent for this request.
    case pageImageDone(storyId: String, pageIndex: Int, hasImage: Bool)
```

Add its decode case (after `"story_detail"`'s, lines 146-150):

```swift
    case "page_image_done":
        return .pageImageDone(
            storyId: json["story_id"] as? String ?? "",
            pageIndex: json["page_index"] as? Int ?? 0,
            hasImage: json["has_image"] as? Bool ?? false
        )
```

Update `decodeStoryDetail` (lines 175-185) to read the new fields:

```swift
private func decodeStoryDetail(_ json: [String: Any], id: String) -> SavedStoryDetail {
    let rawPages = json["pages"] as? [[String: Any]] ?? []
    let pages = rawPages.map {
        StoryPage(text: $0["text"] as? String ?? "", hasImage: $0["has_image"] as? Bool ?? false)
    }
    let illustrationsStatus = (json["illustrations_status"] as? String)
        .flatMap { IllustrationsStatus(rawValue: $0) }
    return SavedStoryDetail(
        id: id,
        title: json["title"] as? String,
        pages: pages,
        epilogue: json["epilogue"] as? String,
        rewriteStatus: RewriteStatus(rawValue: json["rewrite_status"] as? String ?? "") ?? .pending,
        illustrationsStatus: illustrationsStatus
    )
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/TinyTalkCore && swift test --filter ProtocolTests 2>&1 | tail -40`
Expected: PASS.

Also run the full package test suite to confirm `StoryPage`'s new default parameter and `SavedStoryDetail`'s new default parameter didn't break any existing caller (e.g. `MockStories.swift`):

Run: `cd ios/TinyTalkCore && swift test 2>&1 | tail -60`
Expected: PASS (whole suite).

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift ios/TinyTalkCore/Sources/TinyTalkCore/SavedStory.swift ios/TinyTalkCore/Tests
git commit -m "feat(ios): add GetPageImage wire types"
```

---

## Task 9: iOS `SessionCoordinator.swift` — request and receive page images

**Files:**
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift`
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/SessionCoordinatorTests.swift`

This is the one file where the existing binary-frame handling is turn-scoped (see the code below) and needs a small, deliberate exception for page-image responses, which are not tied to any live turn. Read the surrounding code in `consumeServerEvents()` carefully before editing — this function has several other carefully-reasoned invariants nearby that must not be disturbed.

**Update from Task 8's execution:** adding `ServerEvent.pageImageDone` forced Task 8 to touch this file too (Swift's exhaustive `switch` checking left no choice) — it already added a placeholder `case .message(.pageImageDone): continue` to the story-lifecycle switch below (with a comment marking it a placeholder) and already added `.message(.pageImageDone)` to both `fatalError("unreachable")` case lists (the one in this same function, and a second one inside `runTurn()`'s own event switch ~line 953-961, not otherwise mentioned in this task). Concretely, this changes Task 9's own work:
- **Do not** add a *second* `.message(.pageImageDone)` case to the story-lifecycle switch — Swift would treat it as an unreachable duplicate. Instead, **replace** Task 8's placeholder case body (the bare `continue`) with the real destructuring logic below.
- **Do not** touch either `fatalError("unreachable")` case list — both already list `.message(.pageImageDone)`, added by Task 8.
- The `.audio` handling change, the new `PageImageResult` struct, the new properties, and the new `getPageImage()` method are all still needed exactly as below — Task 8 did not touch any of those.

**Interfaces:**
- Consumes: `ClientMessage.getPageImage`, `ServerEvent.pageImageDone` (Task 8).
- Produces: `SessionCoordinator.getPageImage(storyId: String, pageIndex: Int) async`; `SessionCoordinator.latestPageImage: PageImageResult?` (a new public struct).

- [ ] **Step 1: Write the failing tests**

Add to `ios/TinyTalkCore/Tests/TinyTalkCoreTests/SessionCoordinatorTests.swift`, right after `testListStoriesAndGetStoryUpdatePolledState` (line 314-347), matching that test's exact `FakeConnection`/`FakeAudio`/`FakeVAD` setup and `connection.emit`/`Task.sleep`/`runLoop.cancel()` pattern:

```swift
    func testGetPageImageSendsRequestAndStoresResultOnMatchingDoneMarker() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.getPageImage(storyId: "pip", pageIndex: 1)
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertEqual(connection.sentMessages, [.getPageImage(storyId: "pip", pageIndex: 1)])

        connection.emit(.audio(Data([0x01, 0x02, 0x03])))
        connection.emit(.message(.pageImageDone(storyId: "pip", pageIndex: 1, hasImage: true)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        let result = await coordinator.latestPageImage
        XCTAssertEqual(result?.storyId, "pip")
        XCTAssertEqual(result?.pageIndex, 1)
        XCTAssertEqual(result?.data, Data([0x01, 0x02, 0x03]))

        runLoop.cancel()
    }

    func testPageImageDoneWithoutImageLeavesLatestPageImageNil() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        await coordinator.getPageImage(storyId: "pip", pageIndex: 1)
        try? await Task.sleep(nanoseconds: 5_000_000)
        connection.emit(.message(.pageImageDone(storyId: "pip", pageIndex: 1, hasImage: false)))
        try? await Task.sleep(nanoseconds: 10_000_000)

        let result = await coordinator.latestPageImage
        XCTAssertNil(result)

        runLoop.cancel()
    }

    /// Regression guard for the existing turn-scoped audio path
    /// (testHappyPathReachesIdleAfterTurnEnd's own live-turn .audio
    /// handling, line 5-28 of this file): with no page-image request
    /// pending, live TTS audio arriving mid-turn must still reach
    /// FakeAudio exactly as before this task's change to the .audio
    /// branch in consumeServerEvents().
    func testLiveTurnAudioStillPlaysWithNoPageImageRequestPending() async {
        let connection = FakeConnection()
        let audio = FakeAudio()
        let vad = FakeVAD()
        let coordinator = SessionCoordinator(connection: connection, audio: audio, vad: vad)
        let runLoop = Task { await coordinator.start() }

        vad.fire(.speechStart)
        try? await Task.sleep(nanoseconds: 5_000_000)
        vad.fire(.speechEnd)
        try? await Task.sleep(nanoseconds: 5_000_000)

        connection.emit(.message(.responseText("hi", turnId: 1)))
        connection.emit(.audio(Data([4, 5, 6])))
        connection.emit(.message(.turnEnd(turnId: 1)))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(audio.played, [Data([4, 5, 6])])

        runLoop.cancel()
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ios/TinyTalkCore && swift test --filter SessionCoordinatorTests 2>&1 | tail -60`
Expected: FAIL to compile (`getPageImage`/`latestPageImage`/`PageImageResult` don't exist yet).

- [ ] **Step 3: Implement**

Add a new public struct directly above the `SessionCoordinator` class declaration in `SessionCoordinator.swift` (co-located with its one consumer, the same way this file already defines its own small result types rather than putting everything in `Interfaces.swift`):

```swift
public struct PageImageResult: Equatable, Sendable {
    public let storyId: String
    public let pageIndex: Int
    public let data: Data
}
```

Add new properties alongside `latestStoryDetail` (`ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift:134-135`):

```swift
    public private(set) var latestStoryList: [SavedStorySummary]?
    public private(set) var latestStoryDetail: SavedStoryDetail?
    /// Set when a page_image_done marker arrives with hasImage true,
    /// paired with whatever binary frame immediately preceded it -- see
    /// getPageImage() and consumeServerEvents()'s pendingPageImageRequest
    /// handling below. nil after a request that came back with no image,
    /// or before any request has been made.
    public private(set) var latestPageImage: PageImageResult?
    /// Set by getPageImage() right before sending the request, cleared
    /// once the matching page_image_done marker arrives (whether or not
    /// it carried an image) -- this is what lets consumeServerEvents()
    /// tell "an .audio frame that's actually a requested page image"
    /// apart from a stray/unrelated one, since page images are not
    /// scoped to a turn_id the way live TTS audio is.
    private var pendingPageImageRequest: (storyId: String, pageIndex: Int)?
    private var pendingPageImageBytes: Data?
```

Add the public method near `getStory` (`ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift:841-843`):

```swift
    /// See protocol.py's GetPageImage. Fire-and-forget; the response
    /// updates latestPageImage.
    public func getPageImage(storyId: String, pageIndex: Int) async {
        pendingPageImageRequest = (storyId: storyId, pageIndex: pageIndex)
        pendingPageImageBytes = nil
        try? await connection.send(.getPageImage(storyId: storyId, pageIndex: pageIndex))
    }
```

In `consumeServerEvents()`, change the `.audio` handling (`ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift:595-599`) to check for a pending page-image request first:

```swift
            if case .audio(let data) = event {
                if pendingPageImageRequest != nil {
                    pendingPageImageBytes = data
                    continue
                }
                guard isCurrentTurnAudio else { continue }
                turnContinuation?.yield(event)
                continue
            }
```

Add a `.message(.pageImageDone(...))` case to the story-lifecycle switch (`ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift:609-626`), and add it to the `fatalError("unreachable")` switch's case list too (line 636-639, since it's now handled above that point):

```swift
            switch event {
            case .message(.rewritingStarted):
                isRewriting = true
                sawRewritingStarted = true
                maybeSignalReadyToShowTheEnd()
                continue
            case .message(.rewritingDone):
                isRewriting = false
                continue
            case .message(.storyList(let stories)):
                latestStoryList = stories
                continue
            case .message(.storyDetail(let detail)):
                latestStoryDetail = detail
                continue
            case .message(.pageImageDone(let storyId, let pageIndex, let hasImage)):
                if let request = pendingPageImageRequest,
                   request.storyId == storyId, request.pageIndex == pageIndex {
                    latestPageImage = (hasImage ? pendingPageImageBytes : nil).map {
                        PageImageResult(storyId: storyId, pageIndex: pageIndex, data: $0)
                    }
                    pendingPageImageRequest = nil
                    pendingPageImageBytes = nil
                }
                continue
            default:
                break
            }

            let eventTurnId: Int
            switch event {
            case .message(.transcriptPartial(_, let turnId)),
                 .message(.transcriptFinal(_, let turnId)),
                 .message(.responseText(_, let turnId)),
                 .message(.turnEnd(let turnId)),
                 .message(.error(_, let turnId)):
                eventTurnId = turnId
            case .audio, .closed,
                 .message(.rewritingStarted), .message(.rewritingDone),
                 .message(.storyList), .message(.storyDetail), .message(.pageImageDone):
                fatalError("unreachable: handled above")
            }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ios/TinyTalkCore && swift test --filter SessionCoordinatorTests 2>&1 | tail -60`
Expected: PASS.

Run the full package suite to confirm no regression in the live-turn audio path:

Run: `cd ios/TinyTalkCore && swift test 2>&1 | tail -60`
Expected: PASS (whole suite).

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift ios/TinyTalkCore/Tests
git commit -m "feat(ios): request and receive page images in SessionCoordinator"
```

---

## Task 10: iOS `AppModel.swift` — surface page images to the UI

**Files:**
- Modify: `ios/TinyTalkApp/TinyTalkApp/AppModel.swift`

No dedicated unit test for this task — `AppModel`'s polling loop is not currently unit-tested in isolation (it's a thin observation bridge, per its own comment at line 596-597: "Fine for a bare-bones harness; not a pattern to scale up later"), consistent with the rest of that loop's existing fields (`latestStoryDetail`, `latestStoryList`, etc. have no dedicated `AppModel`-level tests either — they're exercised indirectly via `SessionCoordinatorTests`, covered in Task 9). Verified on-device instead, as part of Task 11's manual test.

**Interfaces:**
- Consumes: `SessionCoordinator.getPageImage`, `SessionCoordinator.latestPageImage` (Task 9).
- Produces: `AppModel.pageImages: [String: Data]` (published, keyed by `"\(storyId)#\(pageIndex)"`); `AppModel.requestPageImage(storyId: String, pageIndex: Int)`.

- [ ] **Step 1: Add the published property**

Add near `selectedStory` (`ios/TinyTalkApp/TinyTalkApp/AppModel.swift:65`):

```swift
    @Published var selectedStory: SavedStoryDetail?
    /// Fetched page images for the currently-open story, keyed by
    /// "storyId#pageIndex" -- see requestPageImage() and
    /// startPollingState()'s pageImage handling below. Never cleared
    /// mid-session; a stale entry for a story the child has moved on
    /// from is harmless (ReadingView only ever reads the key for its
    /// own selectedStory).
    @Published private(set) var pageImages: [String: Data] = [:]
```

- [ ] **Step 2: Add the request method**

Add near other simple coordinator-forwarding methods in this file (search for a short existing method like a `func selectStory` or similar one-liner that forwards to `coordinator` inside a `Task`, and place this alongside it for consistency):

```swift
    func requestPageImage(storyId: String, pageIndex: Int) {
        let key = "\(storyId)#\(pageIndex)"
        guard pageImages[key] == nil else { return }
        Task { [weak self] in
            await self?.coordinator?.getPageImage(storyId: storyId, pageIndex: pageIndex)
        }
    }
```

- [ ] **Step 3: Wire the poll loop**

In `startPollingState()`, add a read alongside the other `coordinator.*` reads (`ios/TinyTalkApp/TinyTalkApp/AppModel.swift:614-615`, right after `let storyDetail = await coordinator.latestStoryDetail`):

```swift
                let pageImage = await coordinator.latestPageImage
```

Inside the `MainActor.run` block, add handling alongside the `storyDetail` handling (`ios/TinyTalkApp/TinyTalkApp/AppModel.swift:708-713`, right after that block):

```swift
                    if let pageImage {
                        let key = "\(pageImage.storyId)#\(pageImage.pageIndex)"
                        if self.pageImages[key] == nil {
                            self.pageImages[key] = pageImage.data
                        }
                    }
```

- [ ] **Step 4: Build to confirm it compiles**

Run: `cd ios/TinyTalkApp && xcodebuild -project TinyTalkApp.xcodeproj -scheme TinyTalkApp -destination 'generic/platform=iOS' build 2>&1 | tail -40`
Expected: `BUILD SUCCEEDED` (or the last lines show no errors — this project doesn't have an iOS simulator/unit-test target for `TinyTalkApp` itself per its existing structure, only for `TinyTalkCore`, so a successful build is this task's own verification step).

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkApp/TinyTalkApp/AppModel.swift
git commit -m "feat(ios): surface fetched page images to the UI layer"
```

---

## Task 11: iOS `ReadingView.swift` — render real page art

**Files:**
- Modify: `ios/TinyTalkApp/TinyTalkApp/ReadingView.swift`

No automated test — this is a SwiftUI view change verified visually on-device (see the plan's closing section). Build-checked here the same way as Task 10.

**Interfaces:**
- Consumes: `AppModel.pageImages`, `AppModel.requestPageImage` (Task 10); `StoryPage.hasImage` (Task 8).

- [ ] **Step 1: Implement**

Replace `pageView` (`ios/TinyTalkApp/TinyTalkApp/ReadingView.swift:52-64`):

```swift
    private func pageView(_ page: StoryPage, index: Int) -> some View {
        VStack(spacing: 0) {
            pageArt(for: page, storyId: model.selectedStory?.id, index: index)
                .frame(height: 260)

            VStack(alignment: .leading, spacing: 10) {
                Text("PAGE \(index + 1)")
                    .font(TTA.Typography.display(14))
                    .tracking(2)
                    .foregroundColor(TTA.Palette.scarf)
                Text(page.text)
                    .font(TTA.Typography.story(22))
                    .foregroundColor(TTA.Palette.ink)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TTA.Palette.paper)
        }
        .background(TTA.Palette.paper)
    }

    @ViewBuilder
    private func pageArt(for page: StoryPage, storyId: String?, index: Int) -> some View {
        if let storyId, page.hasImage,
           let data = model.pageImages["\(storyId)#\(index)"],
           let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipped()
        } else {
            Rectangle()
                .fill(TTA.Palette.paper)
                .overlay(
                    Text("page art")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(TTA.Palette.inkSoft)
                        .padding(8)
                        .background(TTA.Palette.cream.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                )
                .onAppear {
                    if let storyId, page.hasImage {
                        model.requestPageImage(storyId: storyId, pageIndex: index)
                    }
                }
        }
    }
```

Add `import UIKit` at the top of the file (needed for `UIImage`) if it isn't already imported transitively — check the existing import list (`ios/TinyTalkApp/TinyTalkApp/ReadingView.swift:1-3`); `SwiftUI` re-exports `UIKit` on iOS in most contexts, but add it explicitly if the build fails without it.

- [ ] **Step 2: Build to confirm it compiles**

Run: `cd ios/TinyTalkApp && xcodebuild -project TinyTalkApp.xcodeproj -scheme TinyTalkApp -destination 'generic/platform=iOS' build 2>&1 | tail -40`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add ios/TinyTalkApp/TinyTalkApp/ReadingView.swift
git commit -m "feat(ios): render real page illustrations in ReadingView"
```

---

## On-device verification (required before this is considered done)

Per CLAUDE.md's testing conventions, the fakes-based test suite above verifies sequencing, status transitions, and wire-protocol shape — it cannot verify actual image quality, real generation timing on the M1, or whether IP-Adapter genuinely keeps the story's animal recognizable across pages. This requires a real run, in this exact worktree:

1. **Where the code lives:** `.claude/worktrees/storybook-page-art-design/` (server and iOS both, in this same worktree).
2. **Server needs restarting** (new Python code, no auto-reload):
   ```bash
   cd ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/storybook-page-art-design/server
   source .venv/bin/activate
   python -m tinytalk.app
   ```
   The first story concluded after this restart will pay a one-time Stable Diffusion model-download cost (several GB from the Hugging Face Hub) before the first image generates — expect the background rewrite window to take noticeably longer than usual on that first run only.
3. **iOS needs a fresh Build & Run from Xcode** — this worktree is newly created, so `Local.xcconfig` doesn't exist yet:
   ```bash
   cd ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/storybook-page-art-design/ios/TinyTalkApp
   cp Local.xcconfig.example Local.xcconfig
   xcodegen generate
   open TinyTalkApp.xcodeproj
   ```
   Set your Apple Developer Team under Signing & Capabilities (same Team ID as any other worktree), select your iPhone as the run destination, and Run.
4. **What to actually do and look for:**
   - Play a short story through to a natural conclusion (or use "Finish this story").
   - Watch the server's terminal log for `illustrations done for story ...: done (N/N pages)` (or `partial`/`failed`) — this confirms the pipeline ran and tells you which outcome to expect on the phone.
   - On the phone, tap "Read it now" once The End screen's button un-greys. Swipe through the pages: each page that log line reported as illustrated should show a real generated image instead of the "page art" placeholder box.
   - Specifically judge: does the featured animal look recognizably like the *same* animal across pages (the IP-Adapter character-consistency mechanism), or does it look like an unrelated animal was redrawn each time? This is the spec's single biggest open risk (see the design spec's "Feasibility" section) — a real, informed judgment call here is the actual point of this verification step, not just confirming the pipeline runs without crashing.
   - Time how long the "Elsie is still writing this one…" wait actually takes for a full story, now that image generation is added on top of the text rewrite, and compare against the plan's ~1.5-2.5 minute estimate (Section 1 of the design spec) — flag it if it's substantially longer.

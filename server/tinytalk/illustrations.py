"""Background illustration pass: generates one Stable Diffusion image per
storybook page, run immediately after storybook.py's text rewrite
succeeds, inside the same REWRITING-gated window. See
docs/superpowers/specs/2026-09-11-storybook-page-art-design.md.
"""

from __future__ import annotations

import asyncio
import logging
from pathlib import Path

import httpx
from PIL import Image

from . import config, story_store
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


def _generate_and_save(
    image_backend: ImageGenBackend,
    prompt: str,
    reference_image: Image.Image | None,
    path: Path,
) -> Image.Image | None:
    """Runs entirely off the event loop (see its asyncio.to_thread call
    site in generate_and_attach()) -- both the backend's own generation
    call (already the reason to_thread was used here) and the PNG
    encode-and-write that follows a successful one. Encoding synchronously
    on the event loop would stall it for the encode's own duration, same
    concern as the generation call itself."""
    image = image_backend.generate(prompt, reference_image=reference_image)
    if image is not None:
        image.save(path)
    return image


async def _extract_scene_prompt(llm: LlmEngine, page_text: str) -> str:
    messages = [
        {"role": "user", "content": _PROMPT_EXTRACTION_TEMPLATE.format(text=page_text)}
    ]
    parts: list[str] = []
    async for chunk in llm.stream_reply(messages):
        parts.append(chunk)
    return "".join(parts).strip()


async def _release_ollama_memory(*, transport: httpx.BaseTransport | None = None) -> None:
    """Best-effort: tells Ollama to unload its model immediately rather
    than waiting out config.OLLAMA_KEEP_ALIVE (30m default). Called once,
    after all of this pass's prompt-extraction calls finish and before
    the compute-heavy image-generation phase begins.

    Confirmed on real hardware (2026-09-14): without this, interleaving
    one LLM call per page with that page's image generation kept
    Ollama's ~6-7GB resident for the ENTIRE illustration pass (each new
    call refreshes the keep-alive window before it can expire) --
    directly competing with Stable Diffusion for the same 16GB unified
    memory and triggering severe swap thrashing (measured: per-step
    generation time jumped from ~18s to ~217s, a 12x cliff, partway
    through a single image). No-op for a non-Ollama LlmEngine (e.g.
    GroqLlm, a cloud API with no local memory to release). A failure
    here is only a missed optimization, never a correctness problem --
    logged, not raised."""
    if config.LLM_BACKEND != "ollama":
        return
    try:
        async with httpx.AsyncClient(timeout=10.0, transport=transport) as client:
            await client.post(
                f"{config.OLLAMA_HOST}/api/generate",
                json={"model": config.OLLAMA_MODEL, "keep_alive": 0},
            )
    except httpx.HTTPError as exc:
        logger.warning("could not release Ollama's memory before image generation: %s", exc)


def _mark_blank(
    story_id: str, pages: list[dict], status: str, stories_dir: Path
) -> None:
    """Patches an all-None image_filenames list with `status` into the
    story -- used both for the initial "pending" mark and for a
    pass-level "failed" mark, so those two blank-image_path writes
    aren't duplicated at each call site."""
    story_store.update_story_illustrations(
        story_id,
        image_filenames=[None] * len(pages),
        illustrations_status=status,
        stories_dir=stories_dir,
    )


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
        _mark_blank(story_id, pages, "pending", stories_dir)

        # Phase 1: extract every page's scene prompt first, in one quick
        # burst, rather than interleaved with image generation below --
        # see _release_ollama_memory's doc comment for why interleaving
        # them caused severe swap thrashing on real hardware.
        scene_prompts: list[str | None] = []
        for index, page in enumerate(pages):
            try:
                scene_prompt = await _extract_scene_prompt(llm, page["text"])
                logger.info(
                    "story %s page %d scene prompt: %r", story_id, index, scene_prompt
                )
                scene_prompts.append(scene_prompt)
            except asyncio.CancelledError:
                raise
            except EngineError as exc:
                logger.warning(
                    "illustration for story %s page %d failed during prompt "
                    "extraction: %s",
                    story_id,
                    index,
                    exc,
                )
                scene_prompts.append(None)
            except Exception:  # noqa: BLE001 - one page's LLM hiccup must not sink the pass
                logger.exception(
                    "unexpected failure extracting scene prompt for story %s page %d",
                    story_id,
                    index,
                )
                scene_prompts.append(None)

        await _release_ollama_memory()

        # Phase 2: generate images, strictly in page order (page 0's own
        # output becomes the IP-Adapter reference for every later page).
        reference_image = None
        image_filenames: list[str | None] = []
        any_succeeded = False
        for index, scene_prompt in enumerate(scene_prompts):
            if scene_prompt is None:
                # That page's prompt extraction already failed in Phase 1
                # -- no prompt to generate from, same as a None return
                # from image_backend.generate() below: this page just has
                # no illustration, not a reason to skip later pages.
                image_filenames.append(None)
                continue
            filename = f"{story_id}-page-{index}.png"
            try:
                image = await asyncio.to_thread(
                    _generate_and_save,
                    image_backend,
                    scene_prompt,
                    reference_image,
                    stories_dir / filename,
                )
            except asyncio.CancelledError:
                raise
            except EngineError as exc:
                logger.warning(
                    "illustration for story %s page %d failed during image "
                    "generation: %s",
                    story_id,
                    index,
                    exc,
                )
                image_filenames.append(None)
                continue
            except Exception:  # noqa: BLE001 - one page's backend failure must not sink the pass
                logger.exception(
                    "unexpected failure generating image for story %s page %d",
                    story_id,
                    index,
                )
                image_filenames.append(None)
                continue
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
        _mark_blank(story_id, pages, "failed", stories_dir)
    except Exception:  # noqa: BLE001 - a background pass must survive one bad story
        logger.exception("unexpected failure during illustration pass for story %s", story_id)
        _mark_blank(story_id, pages, "failed", stories_dir)

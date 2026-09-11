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

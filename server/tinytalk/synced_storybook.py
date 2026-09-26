"""Validates and stores a finished storybook that the phone uploads alongside
a story synced from away-from-home demo mode, so nothing generated away from
home (title, pages, illustrations) is discarded or redone at the Mac.

Everything in the upload is UNTRUSTED client data (see
story_store.save_synced_story(), which discards the phone's own id and forces
rewrite_status to "pending" for the same reason). The server therefore skips
its own rewrite ONLY when the whole storybook passes every check below;
otherwise store_uploaded_storybook() returns False and the caller falls back
to today's behavior -- leave the story pending and rewrite it from its
transcript. See docs/superpowers/specs/2026-09-19-demo-mode-parity-design.md.
"""

from __future__ import annotations

import base64
import binascii
import io
import logging
from pathlib import Path

from PIL import Image, UnidentifiedImageError

from . import safety, story_store
from .story_store import STORIES_DIR
# The epilogue is always recomputed from shared_facts -- any epilogue text
# the phone sent is ignored -- using the same formula as the live rewrite.
from .storybook import derive_epilogue

logger = logging.getLogger(__name__)

MAX_TITLE_CHARS = 200
MAX_PAGES = 10
MAX_PAGE_TEXT_CHARS = 2000
MAX_IMAGE_BYTES = 1_500_000
# 2048 x 2048. The phone's own images are at most 512 px on the long side,
# so this is generous -- it exists to refuse decompression bombs.
MAX_IMAGE_PIXELS = 2048 * 2048
_ALLOWED_IMAGE_FORMATS = frozenset({"JPEG", "PNG"})


class _Rejected(Exception):
    """A storybook failed validation; the message is the reason logged."""


def _validated_title(storybook: dict) -> str:
    title = storybook.get("title")
    if not isinstance(title, str) or not title.strip():
        raise _Rejected("missing or empty title")
    title = title.strip()
    if len(title) > MAX_TITLE_CHARS:
        raise _Rejected(f"title is longer than {MAX_TITLE_CHARS} characters")
    return title


def _decode_image(index: int, encoded: object) -> Image.Image | None:
    if encoded is None:
        return None
    if not isinstance(encoded, str):
        raise _Rejected(f"page {index} image is not a base64 string")
    try:
        raw = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError):
        raise _Rejected(f"page {index} image is not valid base64") from None
    if not raw or len(raw) > MAX_IMAGE_BYTES:
        raise _Rejected(f"page {index} image is empty or larger than {MAX_IMAGE_BYTES} bytes")
    try:
        image = Image.open(io.BytesIO(raw))
        # Format and size come from the file header, so a decompression
        # bomb is refused BEFORE any pixel data is decoded.
        if image.format not in _ALLOWED_IMAGE_FORMATS:
            raise _Rejected(f"page {index} image is {image.format}, not JPEG or PNG")
        width, height = image.size
        if width * height > MAX_IMAGE_PIXELS:
            raise _Rejected(f"page {index} image is {width}x{height}, over the pixel limit")
        image.load()  # a full decode: catches truncated or corrupt data
    except _Rejected:
        raise
    except (UnidentifiedImageError, OSError, SyntaxError, ValueError, Image.DecompressionBombError) as exc:
        raise _Rejected(f"page {index} image could not be decoded ({exc})") from None
    return image


def _validated_pages(storybook: dict) -> list[tuple[str, Image.Image | None]]:
    pages = storybook.get("pages")
    if not isinstance(pages, list) or not 1 <= len(pages) <= MAX_PAGES:
        raise _Rejected(f"pages must be a list of 1-{MAX_PAGES} entries")
    validated: list[tuple[str, Image.Image | None]] = []
    for index, page in enumerate(pages):
        if not isinstance(page, dict):
            raise _Rejected(f"page {index} is not an object")
        text = page.get("text")
        if not isinstance(text, str) or not text.strip():
            raise _Rejected(f"page {index} has no text")
        text = text.strip()
        if len(text) > MAX_PAGE_TEXT_CHARS:
            raise _Rejected(f"page {index} text is longer than {MAX_PAGE_TEXT_CHARS} characters")
        # Any filename/path the client might have attached is ignored: only
        # "text" and "image" are ever read from a page.
        validated.append((text, _decode_image(index, page.get("image"))))
    return validated


def _write_images(
    story_id: str, images: list[Image.Image | None], stories_dir: Path
) -> list[str | None]:
    """Re-encodes each decoded image to PNG under a SERVER-generated
    filename (`{story_id}-page-{i}.png`, the shape the home pipeline uses,
    so story_store.read_page_image() needs no change). Raw client bytes are
    never written to disk. A page whose image can't be written just has no
    picture; it never sinks the storybook's text."""
    filenames: list[str | None] = []
    for index, image in enumerate(images):
        if image is None:
            filenames.append(None)
            continue
        filename = f"{story_id}-page-{index}.png"
        try:
            image.convert("RGB").save(stories_dir / filename, format="PNG")
            filenames.append(filename)
        except (OSError, ValueError) as exc:
            logger.warning(
                "could not write the synced illustration for story %s page %d: %s",
                story_id, index, exc,
            )
            filenames.append(None)
    return filenames


def store_uploaded_storybook(
    story_id: str,
    storybook: object,
    shared_facts: list[tuple[str, str]],
    *,
    stories_dir: Path = STORIES_DIR,
) -> bool:
    """Validates the uploaded storybook and, if it passes every check,
    stores it on the already-saved synced story `story_id` (status "done").
    Returns True when accepted; False means "rejected or failed -- fall back
    to rewriting from the transcript". Never raises. Logs exactly one line
    per call ("accepted ..." or "rejected ...") so on-device verification can
    tell an accepted upload from a fallback rewrite."""
    try:
        if not isinstance(storybook, dict):
            raise _Rejected("storybook is not an object")
        title = _validated_title(storybook)
        pages = _validated_pages(storybook)
        epilogue = derive_epilogue(shared_facts)

        texts = [title, *(text for text, _ in pages), *([epilogue] if epilogue else [])]
        blocked = sorted({term for text in texts for term in safety.find_blocked(text)})
        if blocked:
            raise _Rejected(f"kid-safety check flagged: {', '.join(blocked)}")

        stored = story_store.update_story_rewrite(
            story_id,
            title=title,
            pages=[{"text": text} for text, _ in pages],
            epilogue=epilogue,
            rewrite_status="done",
            stories_dir=stories_dir,
        )
        if not stored:
            raise _Rejected("could not persist the rewrite")
    except _Rejected as exc:
        logger.warning("synced storybook rejected for story %s: %s", story_id, exc)
        return False
    except Exception:  # noqa: BLE001 - untrusted input must never crash the session
        logger.exception("synced storybook rejected for story %s: unexpected failure", story_id)
        return False

    filenames = _write_images(story_id, [image for _, image in pages], stories_dir)
    if any(filenames):
        story_store.update_story_illustrations(
            story_id,
            image_filenames=filenames,
            illustrations_status="done" if all(filenames) else "partial",
            stories_dir=stories_dir,
        )
    logger.info(
        "synced storybook accepted for story %s: %d page(s), %d image(s)",
        story_id, len(pages), sum(1 for name in filenames if name),
    )
    return True

"""Background rewrite pass: turns a saved story's raw transcript into
storybook pages (title, prose pages, an optional fact-grounded epilogue).

Runs after the story's own final reply has already been sent -- see
state.py's REWRITING state, which gates new-story creation for exactly as
long as this takes, so this call never competes with a live story's own
LLM turns for the same local Ollama process.
"""

from __future__ import annotations

import asyncio
import json
import logging

from . import config, safety, story_store
from .conversation import Turn
from .engines import EngineError, LlmEngine
from .story_store import STORIES_DIR
from pathlib import Path

logger = logging.getLogger(__name__)

_REWRITE_PROMPT_TEMPLATE = (
    "You are turning a story a child and a storyteller made up together "
    "into a picture-book version for the child to read again later.\n\n"
    "Here is the full conversation, in order:\n{transcript}\n\n"
    "{facts_section}"
    "Rewrite this as a children's storybook: continuous third-person "
    "narration that captures the same characters, events, and facts -- "
    "NOT a dialogue transcript, and don't write \"the child said\" or "
    "\"the storyteller said\" anywhere. Split it into exactly {page_count} "
    "pages. Reply with ONLY a JSON object, no other text, in this exact "
    "shape:\n"
    '{{"title": "...", "pages": [{{"text": "..."}}, ...]{epilogue_key}}}'
)

_EPILOGUE_KEY = ', "epilogue": "one true, real fact from the story, in one sentence"'


def _format_transcript(turns: list[Turn]) -> str:
    lines = []
    for turn in turns:
        speaker = "Child" if turn.speaker == "child" else "Storyteller"
        lines.append(f"{speaker}: {turn.text}")
    return "\n".join(lines)


def _build_prompt(
    turns: list[Turn], shared_facts: list[tuple[str, str]], page_count: int
) -> str:
    facts_section = ""
    epilogue_key = ""
    if shared_facts:
        facts_list = "; ".join(f"{animal}: {fact}" for animal, fact in shared_facts)
        facts_section = (
            f"Real facts this story actually used: {facts_list}. If natural, "
            "close with one of these as a one-sentence epilogue, phrased for "
            "a young child.\n\n"
        )
        epilogue_key = _EPILOGUE_KEY
    return _REWRITE_PROMPT_TEMPLATE.format(
        transcript=_format_transcript(turns),
        facts_section=facts_section,
        page_count=page_count,
        epilogue_key=epilogue_key,
    )


def _parse_rewrite(raw: str) -> tuple[str, list[dict], str | None] | None:
    """Extracts {title, pages, epilogue} from the LLM's raw reply text,
    tolerant of leading/trailing prose around the JSON object (a small
    local model doesn't reliably follow "reply with ONLY json"). Returns
    None if nothing usable is found."""
    start = raw.find("{")
    end = raw.rfind("}")
    if start == -1 or end == -1 or end < start:
        return None
    try:
        data = json.loads(raw[start : end + 1])
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict):
        return None
    title = data.get("title")
    pages = data.get("pages")
    epilogue = data.get("epilogue")
    if not isinstance(title, str) or not title.strip():
        return None
    if not isinstance(pages, list) or not pages:
        return None
    normalized_pages = []
    for page in pages:
        if not isinstance(page, dict) or not isinstance(page.get("text"), str):
            return None
        normalized_pages.append({"text": page["text"].strip()})
    if not isinstance(epilogue, str) or not epilogue.strip():
        epilogue = None
    return title.strip(), normalized_pages, epilogue


def _mark_failed(story_id: str, stories_dir: Path) -> None:
    story_store.update_story_rewrite(
        story_id,
        title=None,
        pages=None,
        epilogue=None,
        rewrite_status="failed",
        stories_dir=stories_dir,
    )


async def build_and_attach(
    story_id: str,
    turns: list[Turn],
    shared_facts: list[tuple[str, str]],
    *,
    llm: LlmEngine,
    page_count: int = 5,
    stories_dir: Path = STORIES_DIR,
) -> None:
    """Runs the rewrite and patches the result into the already-saved
    story -- or marks it "failed", logged, never raised. Called as a
    fire-and-forget background task; see session.py's REWRITE_STARTED/
    REWRITE_DONE handling for how its completion (success or failure) is
    guaranteed to release the REWRITING gate.

    Every step below (the LLM call, parsing, persisting) is wrapped in one
    try/except -- like session.py's _run_turn, which this mirrors, a
    background rewrite must survive any single bad turn rather than
    propagate an exception past a fire-and-forget task, where nothing
    would be there to catch it."""
    try:
        prompt = _build_prompt(turns, shared_facts, page_count)
        # Same kid-safety framing every live-turn LLM call gets (session.py
        # prepends config.SYSTEM_PROMPT to every _run_turn call) -- the
        # rewrite model is still a general-purpose local LLM writing content
        # a young child will read and hear, so it needs the same "gentle
        # and wholesome... no violence, no weapons, no death, no
        # frightening peril" framing, not just this module's own
        # storybook-formatting instructions.
        messages = [
            {"role": "system", "content": config.SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ]
        parts: list[str] = []
        async for chunk in llm.stream_reply(messages):
            parts.append(chunk)
        raw = "".join(parts).strip()

        parsed = _parse_rewrite(raw)
        if parsed is None:
            logger.error(
                "storybook rewrite for story %s produced unparseable output: %r",
                story_id,
                raw,
            )
            _mark_failed(story_id, stories_dir)
            return

        title, pages, epilogue = parsed
        # The spec requires the epilogue to "always be a real fact this
        # story actually shared, never something the small model invents
        # fresh". A small local model can't be trusted to hold to that on
        # its own -- even when it's handed the real facts and asked to
        # reuse one verbatim, there is no guarantee it does. So the
        # model's own "epilogue" text (whatever it is) is never used:
        # when real facts exist, the epilogue is always formatted
        # server-side straight from shared_facts, in the same phrasing
        # style the design mock uses; when none exist, it's omitted
        # unconditionally, regardless of what the model volunteered.
        if shared_facts:
            animal, fact = shared_facts[0]
            epilogue = f"And one true thing we learned about the {animal}: {fact}"
        else:
            epilogue = None

        # Kid-safety check -- the same safety.is_safe() gate session.py's
        # live turns already pass through (via safety.filter_reply())
        # before a reply is ever sent or spoken. Unlike a live turn, there
        # is no safe fallback text to substitute here: a rewrite that
        # fails this check is treated exactly like a parse failure -- log
        # it, mark the story "failed", and persist nothing from the
        # rewrite. The raw transcript (already saved, untouched) survives
        # either way.
        texts_to_check = [title, *(page["text"] for page in pages)]
        if epilogue is not None:
            texts_to_check.append(epilogue)
        if not all(safety.is_safe(text) for text in texts_to_check):
            logger.error(
                "storybook rewrite for story %s failed the kid-safety check -- "
                "discarding rather than persisting unsafe content",
                story_id,
            )
            _mark_failed(story_id, stories_dir)
            return

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
    except asyncio.CancelledError:
        raise
    except EngineError as exc:
        logger.error("storybook rewrite failed for story %s: %s", story_id, exc)
        _mark_failed(story_id, stories_dir)
    except Exception:  # noqa: BLE001 - a background rewrite must survive one bad turn
        logger.exception("unexpected failure during storybook rewrite for story %s", story_id)
        _mark_failed(story_id, stories_dir)

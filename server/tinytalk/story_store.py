"""Persists a completed story's transcript to disk.

Deliberately minimal: one JSON file per story, no read/list/browse API.
The future storybook persistence sub-project reads these files directly
-- this module exists so nothing is lost between now and then, in a
shape that sub-project can build on without reworking this one. See
docs/superpowers/specs/2026-08-24-story-generation-engine-design.md.
"""

from __future__ import annotations

import json
import logging
import uuid
from datetime import datetime, timezone
from pathlib import Path

from .conversation import Conversation

logger = logging.getLogger(__name__)

STORIES_DIR = Path(__file__).resolve().parent.parent / "data" / "stories"


def save_story(
    conversation: Conversation, *, stories_dir: Path = STORIES_DIR
) -> Path | None:
    """Writes conversation.full_history to a new JSON file under stories_dir.

    Returns the written path, or None if the write failed -- logged, not
    raised, since losing a saved story must never crash or hang the
    session (same reasoning as _fail_turn's handling of engine failures
    in session.py).
    """
    created_at = datetime.now(timezone.utc)
    story_id = uuid.uuid4().hex[:8]
    filename = f"{created_at.strftime('%Y%m%dT%H%M%S')}-{story_id}.json"
    payload = {
        "id": story_id,
        "created_at": created_at.isoformat(),
        "turns": [
            {
                "speaker": turn.speaker,
                "text": turn.text,
                "interrupted": turn.interrupted,
            }
            for turn in conversation.full_history
        ],
        "title": None,
        "pages": None,
        "epilogue": None,
        "rewrite_status": "pending",
    }
    try:
        stories_dir.mkdir(parents=True, exist_ok=True)
        path = stories_dir / filename
        path.write_text(json.dumps(payload, indent=2))
        return path
    except OSError as exc:
        logger.error("failed to save story: %s", exc)
        return None


def story_id_from_path(path: Path) -> str:
    """The short id save_story() embedded in this filename
    (`<timestamp>-<id>.json`) -- the one piece of the filename format
    callers outside this module are allowed to depend on."""
    return path.stem.rsplit("-", 1)[-1]


def _find_story_path(story_id: str, *, stories_dir: Path) -> Path | None:
    if not stories_dir.exists():
        return None
    matches = list(stories_dir.glob(f"*-{story_id}.json"))
    return matches[0] if matches else None


def list_stories(*, stories_dir: Path = STORIES_DIR) -> list[dict]:
    """Summaries for the Library screen, newest first. A corrupt or
    unreadable file is skipped and logged, not raised -- one bad story
    must never break browsing the rest."""
    if not stories_dir.exists():
        return []
    summaries = []
    for path in stories_dir.glob("*.json"):
        try:
            payload = json.loads(path.read_text())
            story_id = payload.get("id")
            created_at = payload.get("created_at")
            # Skip files that don't have the required fields (corrupt schema)
            if story_id is None or created_at is None:
                logger.error("skipping story %s: missing required fields", path)
                continue
            pages = payload.get("pages")
            summaries.append(
                {
                    "id": story_id,
                    "title": payload.get("title"),
                    "created_at": created_at,
                    "page_count": len(pages) if pages else 0,
                    "rewrite_status": payload.get("rewrite_status", "pending"),
                }
            )
        except (OSError, json.JSONDecodeError, UnicodeDecodeError, KeyError) as exc:
            logger.error("failed to read story %s: %s", path, exc)
            continue
    summaries.sort(key=lambda summary: summary["created_at"], reverse=True)
    return summaries


def load_story(story_id: str, *, stories_dir: Path = STORIES_DIR) -> dict | None:
    """Full contents of one saved story, or None if it doesn't exist or
    can't be read."""
    path = _find_story_path(story_id, stories_dir=stories_dir)
    if path is None:
        return None
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError, UnicodeDecodeError, KeyError) as exc:
        logger.error("failed to read story %s: %s", story_id, exc)
        return None


def update_story_rewrite(
    story_id: str,
    *,
    title: str | None,
    pages: list[dict] | None,
    epilogue: str | None,
    rewrite_status: str,
    stories_dir: Path = STORIES_DIR,
) -> bool:
    """Patches storybook.py's rewrite result (or a "failed" status) into
    an already-saved story file. Logged, not raised, on any failure --
    same reasoning as save_story(): a rewrite that can't be persisted
    must never crash or hang the session that kicked it off."""
    path = _find_story_path(story_id, stories_dir=stories_dir)
    if path is None:
        logger.error("cannot update rewrite -- no saved story with id %r", story_id)
        return False
    try:
        payload = json.loads(path.read_text())
        payload["title"] = title
        payload["pages"] = pages
        payload["epilogue"] = epilogue
        payload["rewrite_status"] = rewrite_status
        path.write_text(json.dumps(payload, indent=2))
        return True
    except (OSError, json.JSONDecodeError, UnicodeDecodeError, KeyError) as exc:
        logger.error("failed to update rewrite for story %s: %s", story_id, exc)
        return False

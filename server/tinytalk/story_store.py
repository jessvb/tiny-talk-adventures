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
    }
    try:
        stories_dir.mkdir(parents=True, exist_ok=True)
        path = stories_dir / filename
        path.write_text(json.dumps(payload, indent=2))
        return path
    except OSError as exc:
        logger.error("failed to save story: %s", exc)
        return None

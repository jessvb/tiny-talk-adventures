"""Running conversation history, in the shape the LLM expects.

The interrupt marker matters: when the child barges in, the agent's half-spoken
line is recorded as interrupted so the next reply can react to being cut off
rather than pretending it finished the sentence.
"""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from typing import Literal

Speaker = Literal["child", "agent"]

INTERRUPTED_MARKER = "[interrupted by the child]"

_ROLES: dict[str, str] = {"child": "user", "agent": "assistant"}


@dataclass(frozen=True)
class Turn:
    speaker: Speaker
    text: str
    interrupted: bool = False


class Conversation:
    def __init__(self, max_turns: int = 20) -> None:
        self._turns: deque[Turn] = deque(maxlen=max_turns)

    @property
    def turns(self) -> tuple[Turn, ...]:
        return tuple(self._turns)

    def add_child(self, text: str) -> None:
        self._add(Turn(speaker="child", text=text.strip()))

    def add_agent(self, text: str, *, interrupted: bool = False) -> None:
        self._add(Turn(speaker="agent", text=text.strip(), interrupted=interrupted))

    def _add(self, turn: Turn) -> None:
        # An interrupt can land before the agent has said anything at all;
        # an empty turn would only confuse the model.
        if not turn.text:
            return
        self._turns.append(turn)

    def to_messages(self, system_prompt: str) -> list[dict[str, str]]:
        messages = [{"role": "system", "content": system_prompt}]
        for turn in self._turns:
            content = turn.text
            if turn.interrupted:
                content = f"{content} {INTERRUPTED_MARKER}"
            messages.append({"role": _ROLES[turn.speaker], "content": content})
        return messages

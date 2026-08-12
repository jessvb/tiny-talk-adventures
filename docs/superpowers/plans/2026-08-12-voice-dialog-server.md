# Voice/Dialog Pipeline — Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Mac-side server for the interruptible voice/dialog pipeline — WebSocket transport, streaming STT, a kid-safe LLM turn loop, streaming TTS, and mid-turn interrupt abort — plus a CLI test client that can hold a full interruptible voice conversation without any phone.

**Architecture:** A Python 3.12 asyncio WebSocket server. Each connection gets a `SessionRunner` that owns a turn-taking state machine (IDLE → LISTENING → THINKING → SPEAKING) and a running conversation. Incoming binary frames are mic audio fed to STT; incoming JSON frames are control events (`speech_start`, `speech_end`, `interrupt`). A turn runs as a cancellable asyncio task: on `interrupt`, the task is cancelled, whatever the agent had already said is recorded in conversation history marked as interrupted, and the session returns to LISTENING. The three models sit behind narrow `Protocol` interfaces (`SttEngine`, `LlmEngine`, `TtsEngine`) so all orchestration logic is unit-testable with fakes and no model downloads.

**Tech Stack:** Python 3.12, asyncio, `websockets`, `httpx`, `numpy`, `pytest` + `pytest-asyncio`. Models: Kyutai STT (`moshi_mlx`), Qwen 3.5 9B via Ollama HTTP API, Kokoro-82M TTS.

**Scope:** This plan covers the Mac server only. The iOS client (AVAudioEngine capture, Silero VAD, AEC, playback) is a separate plan written after this one lands. Everything here is verifiable from the laptop alone via the CLI test client in Task 10.

## Global Constraints

- Python 3.12 specifically — required by `moshi_mlx`.
- Free/local models only. No paid cloud AI APIs, no network calls to third-party inference services.
- All model inference runs on the local M1 MacBook Pro (16GB unified memory).
- Ollama uses its **Metal** backend on this machine, not MLX (Ollama's MLX backend requires 32GB unified memory). Do not add MLX-backend configuration for Ollama.
- LLM model id: `qwen3.5:9b`. Fallback if it misbehaves: `llama3.3:8b`.
- STT: Kyutai STT MLX build, HF repo `kyutai/stt-2.6b-en-mlx`, via the `moshi_mlx` package.
- TTS: Kokoro-82M via the `kokoro` package, 24000 Hz output.
- Wire audio format for mic input: 16 kHz, mono, signed 16-bit little-endian PCM.
- No auth, no TLS, no reconnect logic — single-household LAN pet project.
- The safety filter in this plan is an explicit **stub** (keyword denylist). Do not build out real content-safety scaffolding here; that is a later sub-project.
- Commit after every task. Small, focused commits.

---

### Task 1: Project scaffolding and wire protocol

**Files:**
- Create: `server/pyproject.toml`
- Create: `server/storyadventure/__init__.py`
- Create: `server/storyadventure/protocol.py`
- Create: `server/tests/test_protocol.py`

**Note:** `tests/` deliberately has no `__init__.py`. That keeps pytest putting the test directory itself on `sys.path`, which is what lets later tasks do `from conftest import FakeLlm` for shared fakes.

**Interfaces:**
- Consumes: nothing (first task)
- Produces: `ProtocolError`; client message classes `SpeechStart`, `SpeechEnd`, `Interrupt` and union alias `ClientMessage`; `decode_client_message(raw: str) -> ClientMessage`; encoders `encode_transcript_partial(text: str) -> str`, `encode_transcript_final(text: str) -> str`, `encode_response_text(text: str) -> str`, `encode_turn_end() -> str`, `encode_error(message: str) -> str`

- [ ] **Step 1: Create the Python environment and project metadata**

```bash
cd server 2>/dev/null || mkdir -p server && cd server
python3.12 -m venv .venv
source .venv/bin/activate
python --version   # must print Python 3.12.x
```

Create `server/pyproject.toml`:

```toml
[project]
name = "storyadventure-server"
version = "0.1.0"
description = "Voice/dialog pipeline server for the Story Adventure kids' storytelling app"
requires-python = ">=3.12,<3.13"
dependencies = [
    "websockets>=13.0",
    "httpx>=0.27",
    "numpy>=1.26",
]

[project.optional-dependencies]
dev = ["pytest>=8.0", "pytest-asyncio>=0.24"]

[build-system]
requires = ["setuptools>=68"]
build-backend = "setuptools.build_meta"

# Explicit, because `tools/` and `tests/` sit alongside the package and would
# otherwise confuse setuptools' flat-layout auto-discovery.
[tool.setuptools]
packages = ["storyadventure"]

[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]
```

Then install:

```bash
pip install -e ".[dev]"
```

- [ ] **Step 2: Write the failing test**

Create `server/tests/test_protocol.py`:

```python
import json

import pytest

from storyadventure.protocol import (
    Interrupt,
    ProtocolError,
    SpeechEnd,
    SpeechStart,
    decode_client_message,
    encode_error,
    encode_response_text,
    encode_transcript_final,
    encode_transcript_partial,
    encode_turn_end,
)


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ('{"type": "speech_start"}', SpeechStart()),
        ('{"type": "speech_end"}', SpeechEnd()),
        ('{"type": "interrupt"}', Interrupt()),
    ],
)
def test_decodes_each_client_message_type(raw, expected):
    assert decode_client_message(raw) == expected


def test_decode_rejects_invalid_json():
    with pytest.raises(ProtocolError):
        decode_client_message("not json at all")


def test_decode_rejects_non_object_json():
    with pytest.raises(ProtocolError):
        decode_client_message('["speech_start"]')


def test_decode_rejects_unknown_type():
    with pytest.raises(ProtocolError):
        decode_client_message('{"type": "launch_rocket"}')


def test_encoders_produce_expected_payloads():
    assert json.loads(encode_transcript_partial("a fox")) == {
        "type": "transcript_partial",
        "text": "a fox",
    }
    assert json.loads(encode_transcript_final("a fox ran")) == {
        "type": "transcript_final",
        "text": "a fox ran",
    }
    assert json.loads(encode_response_text("Once upon a time")) == {
        "type": "response_text",
        "text": "Once upon a time",
    }
    assert json.loads(encode_turn_end()) == {"type": "turn_end"}
    assert json.loads(encode_error("ollama is not running")) == {
        "type": "error",
        "message": "ollama is not running",
    }
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd server && source .venv/bin/activate && pytest tests/test_protocol.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'storyadventure.protocol'`

- [ ] **Step 4: Write the implementation**

Create `server/storyadventure/__init__.py` as an empty file, and `server/storyadventure/protocol.py`:

```python
"""Wire protocol between the phone client and this server.

Control messages are JSON text frames. Audio travels as binary frames and is
not represented here: mic audio in (16 kHz mono PCM16 LE) and TTS audio out
(24 kHz mono PCM16 LE).
"""

from __future__ import annotations

import json
from dataclasses import dataclass


class ProtocolError(ValueError):
    """Raised when an incoming control message is malformed or unknown."""


@dataclass(frozen=True)
class SpeechStart:
    """The client's VAD detected speech onset; audio frames follow."""


@dataclass(frozen=True)
class SpeechEnd:
    """The client's VAD detected speech offset; finalize the transcript."""


@dataclass(frozen=True)
class Interrupt:
    """The child barged in. Abort the in-flight turn and start listening."""


ClientMessage = SpeechStart | SpeechEnd | Interrupt

_CLIENT_MESSAGE_TYPES: dict[str, type] = {
    "speech_start": SpeechStart,
    "speech_end": SpeechEnd,
    "interrupt": Interrupt,
}


def decode_client_message(raw: str) -> ClientMessage:
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ProtocolError(f"control frame is not valid JSON: {raw!r}") from exc

    if not isinstance(payload, dict):
        raise ProtocolError(
            f"control frame must be a JSON object, got {type(payload).__name__}"
        )

    kind = payload.get("type")
    message_type = _CLIENT_MESSAGE_TYPES.get(kind)
    if message_type is None:
        raise ProtocolError(f"unknown client message type: {kind!r}")
    return message_type()


def encode_transcript_partial(text: str) -> str:
    return json.dumps({"type": "transcript_partial", "text": text})


def encode_transcript_final(text: str) -> str:
    return json.dumps({"type": "transcript_final", "text": text})


def encode_response_text(text: str) -> str:
    return json.dumps({"type": "response_text", "text": text})


def encode_turn_end() -> str:
    return json.dumps({"type": "turn_end"})


def encode_error(message: str) -> str:
    return json.dumps({"type": "error", "message": message})
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd server && source .venv/bin/activate && pytest tests/test_protocol.py -v`
Expected: PASS — 8 passed

- [ ] **Step 6: Commit**

```bash
cd /Users/jess/Development/claude-tests/story-adventure
printf '.venv/\n__pycache__/\n*.pyc\n.pytest_cache/\n*.egg-info/\n' >> .gitignore
git add .gitignore server/pyproject.toml server/storyadventure/__init__.py server/storyadventure/protocol.py server/tests/test_protocol.py
git commit -m "feat(server): add project scaffolding and wire protocol"
```

---

### Task 2: Turn-taking state machine

**Files:**
- Create: `server/storyadventure/state.py`
- Create: `server/tests/test_state.py`

**Interfaces:**
- Consumes: nothing
- Produces: `State` enum (`IDLE`, `LISTENING`, `THINKING`, `SPEAKING`); `Event` enum (`SPEECH_START`, `SPEECH_END`, `RESPONSE_READY`, `TTS_DONE`, `INTERRUPT`); `InvalidTransition`; `TurnStateMachine` with read-only property `state: State` and method `handle(event: Event) -> State`

- [ ] **Step 1: Write the failing test**

Create `server/tests/test_state.py`:

```python
import pytest

from storyadventure.state import Event, InvalidTransition, State, TurnStateMachine


def test_starts_idle():
    assert TurnStateMachine().state is State.IDLE


def test_happy_path_cycles_back_to_idle():
    machine = TurnStateMachine()
    assert machine.handle(Event.SPEECH_START) is State.LISTENING
    assert machine.handle(Event.SPEECH_END) is State.THINKING
    assert machine.handle(Event.RESPONSE_READY) is State.SPEAKING
    assert machine.handle(Event.TTS_DONE) is State.IDLE


@pytest.mark.parametrize(
    "state_setup",
    [
        [],
        [Event.SPEECH_START],
        [Event.SPEECH_START, Event.SPEECH_END],
        [Event.SPEECH_START, Event.SPEECH_END, Event.RESPONSE_READY],
    ],
    ids=["idle", "listening", "thinking", "speaking"],
)
def test_interrupt_from_any_state_lands_in_listening(state_setup):
    machine = TurnStateMachine()
    for event in state_setup:
        machine.handle(event)
    assert machine.handle(Event.INTERRUPT) is State.LISTENING


def test_barge_in_during_speaking_then_completes_a_new_turn():
    machine = TurnStateMachine()
    machine.handle(Event.SPEECH_START)
    machine.handle(Event.SPEECH_END)
    machine.handle(Event.RESPONSE_READY)
    machine.handle(Event.INTERRUPT)
    assert machine.handle(Event.SPEECH_END) is State.THINKING
    assert machine.handle(Event.RESPONSE_READY) is State.SPEAKING
    assert machine.handle(Event.TTS_DONE) is State.IDLE


def test_rejects_nonsense_transition():
    machine = TurnStateMachine()
    with pytest.raises(InvalidTransition):
        machine.handle(Event.TTS_DONE)


def test_rejected_transition_leaves_state_unchanged():
    machine = TurnStateMachine()
    with pytest.raises(InvalidTransition):
        machine.handle(Event.RESPONSE_READY)
    assert machine.state is State.IDLE
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && source .venv/bin/activate && pytest tests/test_state.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'storyadventure.state'`

- [ ] **Step 3: Write the implementation**

Create `server/storyadventure/state.py`:

```python
"""The turn-taking state machine.

Pure logic, no I/O — this is the piece that decides what a session is allowed
to do next, and it is where interrupt handling is defined. Side effects
(cancelling work, resetting STT) live in the session orchestrator.
"""

from __future__ import annotations

from enum import Enum, auto


class State(Enum):
    IDLE = auto()
    LISTENING = auto()
    THINKING = auto()
    SPEAKING = auto()


class Event(Enum):
    SPEECH_START = auto()
    SPEECH_END = auto()
    RESPONSE_READY = auto()
    TTS_DONE = auto()
    INTERRUPT = auto()


class InvalidTransition(RuntimeError):
    """Raised when an event arrives that the current state cannot handle."""


# An interrupt is legal from every state and always lands in LISTENING: the
# child has started talking, so whatever we were doing no longer matters.
_TRANSITIONS: dict[tuple[State, Event], State] = {
    (State.IDLE, Event.SPEECH_START): State.LISTENING,
    (State.LISTENING, Event.SPEECH_END): State.THINKING,
    (State.THINKING, Event.RESPONSE_READY): State.SPEAKING,
    (State.SPEAKING, Event.TTS_DONE): State.IDLE,
    (State.IDLE, Event.INTERRUPT): State.LISTENING,
    (State.LISTENING, Event.INTERRUPT): State.LISTENING,
    (State.THINKING, Event.INTERRUPT): State.LISTENING,
    (State.SPEAKING, Event.INTERRUPT): State.LISTENING,
}


class TurnStateMachine:
    def __init__(self) -> None:
        self._state = State.IDLE

    @property
    def state(self) -> State:
        return self._state

    def handle(self, event: Event) -> State:
        next_state = _TRANSITIONS.get((self._state, event))
        if next_state is None:
            raise InvalidTransition(
                f"cannot handle {event.name} while in {self._state.name}"
            )
        self._state = next_state
        return self._state
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && source .venv/bin/activate && pytest tests/test_state.py -v`
Expected: PASS — 10 passed

- [ ] **Step 5: Commit**

```bash
cd /Users/jess/Development/claude-tests/story-adventure
git add server/storyadventure/state.py server/tests/test_state.py
git commit -m "feat(server): add turn-taking state machine with interrupt transitions"
```

---

### Task 3: Conversation history with interrupt markers

**Files:**
- Create: `server/storyadventure/conversation.py`
- Create: `server/tests/test_conversation.py`

**Interfaces:**
- Consumes: nothing
- Produces: `Turn` dataclass with fields `speaker: str` (`"child"` or `"agent"`), `text: str`, `interrupted: bool`; `Conversation(max_turns: int = 20)` with methods `add_child(text: str) -> None`, `add_agent(text: str, *, interrupted: bool = False) -> None`, `to_messages(system_prompt: str) -> list[dict[str, str]]`, and property `turns: tuple[Turn, ...]`

- [ ] **Step 1: Write the failing test**

Create `server/tests/test_conversation.py`:

```python
from storyadventure.conversation import Conversation, Turn

SYSTEM = "You tell stories to children."


def test_starts_empty():
    assert Conversation().turns == ()


def test_records_child_and_agent_turns_in_order():
    conversation = Conversation()
    conversation.add_child("tell me about a fox")
    conversation.add_agent("Once upon a time there was a fox.")
    assert conversation.turns == (
        Turn(speaker="child", text="tell me about a fox", interrupted=False),
        Turn(
            speaker="agent",
            text="Once upon a time there was a fox.",
            interrupted=False,
        ),
    )


def test_to_messages_starts_with_system_prompt():
    conversation = Conversation()
    conversation.add_child("hello")
    messages = conversation.to_messages(SYSTEM)
    assert messages[0] == {"role": "system", "content": SYSTEM}
    assert messages[1] == {"role": "user", "content": "hello"}


def test_agent_turns_map_to_assistant_role():
    conversation = Conversation()
    conversation.add_agent("Once upon a time.")
    assert conversation.to_messages(SYSTEM)[1] == {
        "role": "assistant",
        "content": "Once upon a time.",
    }


def test_interrupted_agent_turn_is_marked_for_the_llm():
    conversation = Conversation()
    conversation.add_agent("The fox crept through the forest and", interrupted=True)
    conversation.add_child("wait, make it a dragon!")
    messages = conversation.to_messages(SYSTEM)
    assert messages[1] == {
        "role": "assistant",
        "content": "The fox crept through the forest and [interrupted by the child]",
    }
    assert messages[2] == {"role": "user", "content": "wait, make it a dragon!"}


def test_empty_interrupted_agent_turn_is_not_recorded():
    conversation = Conversation()
    conversation.add_agent("   ", interrupted=True)
    assert conversation.turns == ()


def test_history_is_capped_at_max_turns():
    conversation = Conversation(max_turns=4)
    for index in range(10):
        conversation.add_child(f"line {index}")
    assert len(conversation.turns) == 4
    assert conversation.turns[0].text == "line 6"
    assert conversation.turns[-1].text == "line 9"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && source .venv/bin/activate && pytest tests/test_conversation.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'storyadventure.conversation'`

- [ ] **Step 3: Write the implementation**

Create `server/storyadventure/conversation.py`:

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && source .venv/bin/activate && pytest tests/test_conversation.py -v`
Expected: PASS — 7 passed

- [ ] **Step 5: Commit**

```bash
cd /Users/jess/Development/claude-tests/story-adventure
git add server/storyadventure/conversation.py server/tests/test_conversation.py
git commit -m "feat(server): add conversation history with interrupt markers"
```

---

### Task 4: Stub safety filter

**Files:**
- Create: `server/storyadventure/safety.py`
- Create: `server/tests/test_safety.py`

**Interfaces:**
- Consumes: nothing
- Produces: `SAFE_FALLBACK: str`; `is_safe(text: str) -> bool`; `filter_reply(text: str) -> str`

**Note:** This is deliberately a stub, per the spec's non-goals. Real safety scaffolding is a later sub-project. Keep the denylist short and obviously provisional — do not expand it into a pretend content-moderation system.

- [ ] **Step 1: Write the failing test**

Create `server/tests/test_safety.py`:

```python
import pytest

from storyadventure.safety import SAFE_FALLBACK, filter_reply, is_safe


@pytest.mark.parametrize(
    "text",
    [
        "The fox ran through the sunny meadow.",
        "The dragon sneezed and made a rainbow!",
        "",
    ],
)
def test_wholesome_text_is_safe(text):
    assert is_safe(text) is True


@pytest.mark.parametrize(
    "text",
    [
        "He picked up the knife.",
        "There was blood everywhere.",
        "The hunter had a GUN.",
    ],
)
def test_blocked_words_are_unsafe(text):
    assert is_safe(text) is False


@pytest.mark.parametrize(
    "text",
    [
        "The race had begun at last.",
        "She was a knifemaker's daughter.",
    ],
)
def test_substring_matches_inside_other_words_do_not_trigger(text):
    assert is_safe(text) is True


def test_filter_passes_safe_text_through_unchanged():
    text = "The fox curled up under a warm blanket."
    assert filter_reply(text) == text


def test_filter_replaces_unsafe_text_with_fallback():
    assert filter_reply("He picked up the knife.") == SAFE_FALLBACK
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && source .venv/bin/activate && pytest tests/test_safety.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'storyadventure.safety'`

- [ ] **Step 3: Write the implementation**

Create `server/storyadventure/safety.py`:

```python
"""Placeholder safety filter for LLM output.

STUB. This is a keyword denylist standing in for real safety scaffolding,
which is a separate sub-project. It exists so the pipeline has the right
shape — a checkpoint between the LLM and the child's ears — not because a
denylist is adequate protection. Do not mistake this for the real thing.
"""

from __future__ import annotations

import re

SAFE_FALLBACK = "Hmm, let's take the story somewhere else! What should happen next?"

_BLOCKED_WORDS = (
    "blood",
    "gun",
    "guns",
    "knife",
    "knives",
    "kill",
    "kills",
    "killed",
    "dead",
    "die",
    "dies",
    "died",
)

# Word boundaries keep "begun" and "knifemaker" from tripping the filter.
_BLOCKED_PATTERN = re.compile(
    r"\b(?:" + "|".join(re.escape(word) for word in _BLOCKED_WORDS) + r")\b",
    re.IGNORECASE,
)


def is_safe(text: str) -> bool:
    return _BLOCKED_PATTERN.search(text) is None


def filter_reply(text: str) -> str:
    return text if is_safe(text) else SAFE_FALLBACK
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && source .venv/bin/activate && pytest tests/test_safety.py -v`
Expected: PASS — 11 passed

- [ ] **Step 5: Commit**

```bash
cd /Users/jess/Development/claude-tests/story-adventure
git add server/storyadventure/safety.py server/tests/test_safety.py
git commit -m "feat(server): add stub keyword safety filter for LLM output"
```

---

### Task 5: Audio helpers and sentence splitting

**Files:**
- Create: `server/storyadventure/audio.py`
- Create: `server/tests/test_audio.py`

**Interfaces:**
- Consumes: nothing
- Produces: `MIC_SAMPLE_RATE: int` (16000); `TTS_SAMPLE_RATE: int` (24000); `float32_to_pcm16(samples: numpy.ndarray) -> bytes`; `pcm16_to_float32(data: bytes) -> numpy.ndarray`; `split_sentences(text: str) -> list[str]`

Sentence splitting exists so TTS can synthesize and stream one sentence at a time instead of waiting for the whole reply — that is what gets first audio to the child quickly, and it gives interrupts a natural place to take effect.

- [ ] **Step 1: Write the failing test**

Create `server/tests/test_audio.py`:

```python
import numpy as np
import pytest

from storyadventure.audio import (
    MIC_SAMPLE_RATE,
    TTS_SAMPLE_RATE,
    float32_to_pcm16,
    pcm16_to_float32,
    split_sentences,
)


def test_sample_rates_match_the_wire_format():
    assert MIC_SAMPLE_RATE == 16000
    assert TTS_SAMPLE_RATE == 24000


def test_float32_to_pcm16_encodes_little_endian_int16():
    encoded = float32_to_pcm16(np.array([0.0, 1.0, -1.0], dtype=np.float32))
    assert encoded == b"\x00\x00\xff\x7f\x01\x80"


def test_float32_to_pcm16_clips_out_of_range_samples():
    encoded = float32_to_pcm16(np.array([2.5, -2.5], dtype=np.float32))
    assert encoded == b"\xff\x7f\x01\x80"


def test_pcm16_round_trips_back_to_float():
    original = np.array([0.0, 0.5, -0.5], dtype=np.float32)
    restored = pcm16_to_float32(float32_to_pcm16(original))
    np.testing.assert_allclose(restored, original, atol=1e-4)


def test_pcm16_to_float32_handles_empty_input():
    assert len(pcm16_to_float32(b"")) == 0


def test_split_sentences_splits_on_terminal_punctuation():
    assert split_sentences("The fox ran. It was fast! Was it? Yes.") == [
        "The fox ran.",
        "It was fast!",
        "Was it?",
        "Yes.",
    ]


def test_split_sentences_keeps_unterminated_trailing_text():
    assert split_sentences("The fox ran. Then he") == ["The fox ran.", "Then he"]


@pytest.mark.parametrize("text", ["", "   ", "\n\n"])
def test_split_sentences_returns_empty_for_blank_input(text):
    assert split_sentences(text) == []
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && source .venv/bin/activate && pytest tests/test_audio.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'storyadventure.audio'`

- [ ] **Step 3: Write the implementation**

Create `server/storyadventure/audio.py`:

```python
"""Audio format conversion and text chunking for streaming TTS."""

from __future__ import annotations

import re

import numpy as np

MIC_SAMPLE_RATE = 16000
TTS_SAMPLE_RATE = 24000

_SENTENCE_BOUNDARY = re.compile(r"(?<=[.!?])\s+")


def float32_to_pcm16(samples: np.ndarray) -> bytes:
    """Convert model float audio in [-1.0, 1.0] to wire-format PCM16 LE."""
    clipped = np.clip(samples, -1.0, 1.0)
    return (clipped * 32767.0).astype("<i2").tobytes()


def pcm16_to_float32(data: bytes) -> np.ndarray:
    """Convert wire-format PCM16 LE to float audio in [-1.0, 1.0]."""
    return np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0


def split_sentences(text: str) -> list[str]:
    """Split a reply into sentences so TTS can stream one at a time."""
    stripped = text.strip()
    if not stripped:
        return []
    return [part.strip() for part in _SENTENCE_BOUNDARY.split(stripped) if part.strip()]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && source .venv/bin/activate && pytest tests/test_audio.py -v`
Expected: PASS — 11 passed

- [ ] **Step 5: Commit**

```bash
cd /Users/jess/Development/claude-tests/story-adventure
git add server/storyadventure/audio.py server/tests/test_audio.py
git commit -m "feat(server): add PCM conversion helpers and sentence splitting"
```

---

### Task 6: Engine interfaces and the Ollama LLM client

**Files:**
- Create: `server/storyadventure/engines.py`
- Create: `server/storyadventure/config.py`
- Create: `server/storyadventure/llm_ollama.py`
- Create: `server/tests/test_llm_ollama.py`

**Interfaces:**
- Consumes: nothing
- Produces:
  - From `engines.py`: `SttEngine` Protocol with `feed(pcm: bytes) -> str | None`, `finish() -> str`, `reset() -> None`; `LlmEngine` Protocol with `stream_reply(messages: list[dict[str, str]]) -> AsyncIterator[str]`; `TtsEngine` Protocol with `synthesize(text: str) -> AsyncIterator[bytes]`; `EngineError`
  - From `config.py`: `OLLAMA_HOST`, `OLLAMA_MODEL`, `SYSTEM_PROMPT`, `SERVER_HOST`, `SERVER_PORT`
  - From `llm_ollama.py`: `parse_chat_line(line: str) -> str | None`; `OllamaLlm(model: str = ..., host: str = ...)` implementing `LlmEngine`

The three model wrappers sit behind Protocols so every orchestration test in Task 9 runs with fakes — no model downloads, no GPU, fast tests.

- [ ] **Step 1: Write the failing test**

Create `server/tests/test_llm_ollama.py`:

```python
import json

import httpx
import pytest

from storyadventure.engines import EngineError
from storyadventure.llm_ollama import OllamaLlm, parse_chat_line


def chat_line(content: str, done: bool = False) -> str:
    return json.dumps(
        {"model": "qwen3.5:9b", "message": {"role": "assistant", "content": content}, "done": done}
    )


def test_parse_chat_line_extracts_content():
    assert parse_chat_line(chat_line("Once ")) == "Once "


def test_parse_chat_line_returns_none_for_done_marker():
    assert parse_chat_line(chat_line("", done=True)) is None


def test_parse_chat_line_returns_none_for_blank_line():
    assert parse_chat_line("   ") is None


def test_parse_chat_line_returns_none_when_content_is_empty():
    assert parse_chat_line(chat_line("")) is None


def test_parse_chat_line_raises_on_malformed_json():
    with pytest.raises(EngineError):
        parse_chat_line("{not json")


async def test_stream_reply_yields_content_chunks_in_order():
    lines = [chat_line("Once "), chat_line("upon "), chat_line("a time."), chat_line("", done=True)]

    def handler(request: httpx.Request) -> httpx.Response:
        payload = json.loads(request.content)
        assert payload["model"] == "qwen3.5:9b"
        assert payload["stream"] is True
        assert payload["messages"][0]["role"] == "system"
        return httpx.Response(200, text="\n".join(lines))

    llm = OllamaLlm(transport=httpx.MockTransport(handler))
    messages = [{"role": "system", "content": "be kind"}, {"role": "user", "content": "hi"}]

    chunks = [chunk async for chunk in llm.stream_reply(messages)]
    assert chunks == ["Once ", "upon ", "a time."]


async def test_stream_reply_raises_engine_error_when_ollama_is_down():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    llm = OllamaLlm(transport=httpx.MockTransport(handler))
    with pytest.raises(EngineError, match="Ollama"):
        [chunk async for chunk in llm.stream_reply([{"role": "user", "content": "hi"}])]


async def test_stream_reply_raises_engine_error_on_http_error_status():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(404, text='{"error":"model not found"}')

    llm = OllamaLlm(transport=httpx.MockTransport(handler))
    with pytest.raises(EngineError, match="model not found|404"):
        [chunk async for chunk in llm.stream_reply([{"role": "user", "content": "hi"}])]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && source .venv/bin/activate && pytest tests/test_llm_ollama.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'storyadventure.engines'`

- [ ] **Step 3: Write the engine interfaces**

Create `server/storyadventure/engines.py`:

```python
"""Narrow interfaces for the three models.

Orchestration depends on these Protocols rather than on the concrete model
wrappers, so session logic can be tested with fakes — no model weights, no
Metal, no network.
"""

from __future__ import annotations

from typing import AsyncIterator, Protocol


class EngineError(RuntimeError):
    """A model backend failed. Surfaced to the client as an error message."""


class SttEngine(Protocol):
    def feed(self, pcm: bytes) -> str | None:
        """Feed PCM16 LE mic audio. Returns updated partial text, or None."""
        ...

    def finish(self) -> str:
        """Finalize the utterance and return the full transcript."""
        ...

    def reset(self) -> None:
        """Discard any in-progress utterance state."""
        ...


class LlmEngine(Protocol):
    def stream_reply(self, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        """Stream the reply as text chunks."""
        ...


class TtsEngine(Protocol):
    def synthesize(self, text: str) -> AsyncIterator[bytes]:
        """Stream synthesized speech as PCM16 LE audio chunks."""
        ...
```

- [ ] **Step 4: Write the configuration module**

Create `server/storyadventure/config.py`:

```python
"""Server configuration.

Single-household LAN pet project: plain module constants, overridable by
environment variable where it is convenient during development.
"""

from __future__ import annotations

import os

SERVER_HOST = os.environ.get("STORYADVENTURE_HOST", "0.0.0.0")
SERVER_PORT = int(os.environ.get("STORYADVENTURE_PORT", "8765"))

OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
OLLAMA_MODEL = os.environ.get("STORYADVENTURE_MODEL", "qwen3.5:9b")

STT_HF_REPO = os.environ.get("STORYADVENTURE_STT_REPO", "kyutai/stt-2.6b-en-mlx")

KOKORO_LANG_CODE = os.environ.get("STORYADVENTURE_TTS_LANG", "a")
KOKORO_VOICE = os.environ.get("STORYADVENTURE_TTS_VOICE", "af_heart")

SYSTEM_PROMPT = (
    "You are a warm, playful storyteller telling a story out loud with a young "
    "child, aged about three to six. You and the child are making the story up "
    "together.\n"
    "\n"
    "Rules you always follow:\n"
    "- Reply with one to three short sentences. Never more. The child is "
    "listening, not reading.\n"
    "- Use simple words a young child knows.\n"
    "- Keep everything gentle and wholesome. No violence, no weapons, no death, "
    "no frightening peril.\n"
    "- End most replies by asking the child what should happen next.\n"
    "- If the child interrupts you, follow their idea happily. Never scold them "
    "for interrupting and never insist on finishing your previous sentence.\n"
    "- Write plain spoken words only: no emoji, no asterisks, no stage "
    "directions, no narration about yourself."
)
```

- [ ] **Step 5: Write the Ollama client**

Create `server/storyadventure/llm_ollama.py`:

```python
"""LLM backend: Qwen 3.5 9B served locally by Ollama.

Ollama's /api/chat streams newline-delimited JSON, one object per token-ish
chunk, with a final object carrying done=true.
"""

from __future__ import annotations

import json
from typing import AsyncIterator

import httpx

from . import config
from .engines import EngineError


def parse_chat_line(line: str) -> str | None:
    """Extract the text chunk from one NDJSON line, or None if there is none."""
    stripped = line.strip()
    if not stripped:
        return None
    try:
        payload = json.loads(stripped)
    except json.JSONDecodeError as exc:
        raise EngineError(f"Ollama sent a malformed response line: {stripped!r}") from exc
    if payload.get("done"):
        return None
    return payload.get("message", {}).get("content") or None


class OllamaLlm:
    """LlmEngine backed by a local Ollama server."""

    def __init__(
        self,
        model: str = config.OLLAMA_MODEL,
        host: str = config.OLLAMA_HOST,
        *,
        transport: httpx.BaseTransport | None = None,
        timeout: float = 120.0,
    ) -> None:
        self._model = model
        self._host = host.rstrip("/")
        self._transport = transport
        self._timeout = timeout

    async def stream_reply(self, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        body = {"model": self._model, "messages": messages, "stream": True}
        try:
            async with httpx.AsyncClient(
                timeout=self._timeout, transport=self._transport
            ) as client:
                async with client.stream(
                    "POST", f"{self._host}/api/chat", json=body
                ) as response:
                    if response.status_code != 200:
                        detail = (await response.aread()).decode("utf-8", "replace")
                        raise EngineError(
                            f"Ollama returned {response.status_code}: {detail.strip()}"
                        )
                    async for line in response.aiter_lines():
                        chunk = parse_chat_line(line)
                        if chunk:
                            yield chunk
        except httpx.HTTPError as exc:
            raise EngineError(
                f"could not reach Ollama at {self._host} — is `ollama serve` running? ({exc})"
            ) from exc
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd server && source .venv/bin/activate && pytest tests/test_llm_ollama.py -v`
Expected: PASS — 8 passed

- [ ] **Step 7: Verify against the real Ollama server**

```bash
ollama serve   # in a separate terminal, if not already running
ollama pull qwen3.5:9b
cd server && source .venv/bin/activate
python -c "
import asyncio
from storyadventure.llm_ollama import OllamaLlm
from storyadventure import config

async def main():
    llm = OllamaLlm()
    messages = [
        {'role': 'system', 'content': config.SYSTEM_PROMPT},
        {'role': 'user', 'content': 'I want a story about a fox.'},
    ]
    async for chunk in llm.stream_reply(messages):
        print(chunk, end='', flush=True)
    print()

asyncio.run(main())
"
```

Expected: a short, wholesome two-or-three sentence story opening that ends with a question, streamed token by token. If the reply is long or full of asterisks, tighten `SYSTEM_PROMPT` in `config.py` before moving on — this prompt is what keeps replies short enough to feel conversational.

- [ ] **Step 8: Commit**

```bash
cd /Users/jess/Development/claude-tests/story-adventure
git add server/storyadventure/engines.py server/storyadventure/config.py server/storyadventure/llm_ollama.py server/tests/test_llm_ollama.py
git commit -m "feat(server): add engine interfaces, config, and Ollama LLM client"
```

---

### Task 7: Kokoro TTS adapter

**Files:**
- Create: `server/storyadventure/tts_kokoro.py`
- Create: `server/tests/test_tts_kokoro.py`

**Interfaces:**
- Consumes: `TtsEngine`, `EngineError` from `storyadventure.engines`; `float32_to_pcm16`, `TTS_SAMPLE_RATE` from `storyadventure.audio`; `KOKORO_LANG_CODE`, `KOKORO_VOICE` from `storyadventure.config`
- Produces: `KokoroTts(lang_code: str = ..., voice: str = ..., pipeline_factory: Callable[[str], object] | None = None)` implementing `TtsEngine`

Kokoro's `KPipeline` is a blocking generator, so synthesis runs in a worker thread via `asyncio.to_thread` — otherwise it would block the event loop and interrupts would not be processed promptly, which is exactly what this project is trying to get right.

- [ ] **Step 1: Write the failing test**

Create `server/tests/test_tts_kokoro.py`:

```python
import numpy as np
import pytest

from storyadventure.audio import float32_to_pcm16
from storyadventure.engines import EngineError
from storyadventure.tts_kokoro import KokoroTts


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


async def test_model_failure_is_reported_as_engine_error():
    tts = KokoroTts(pipeline_factory=ExplodingPipeline)
    with pytest.raises(EngineError, match="Kokoro"):
        [chunk async for chunk in tts.synthesize("The fox ran.")]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && source .venv/bin/activate && pytest tests/test_tts_kokoro.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'storyadventure.tts_kokoro'`

- [ ] **Step 3: Write the implementation**

Create `server/storyadventure/tts_kokoro.py`:

```python
"""TTS backend: Kokoro-82M.

KPipeline is a blocking generator, so each synthesis runs on a worker thread.
Keeping the event loop free is what lets an interrupt be handled while the
agent is mid-sentence.
"""

from __future__ import annotations

import asyncio
from typing import AsyncIterator, Callable

from . import config
from .audio import float32_to_pcm16
from .engines import EngineError


def _default_pipeline_factory(lang_code: str):
    try:
        from kokoro import KPipeline
    except ImportError as exc:  # pragma: no cover - depends on the environment
        raise EngineError(
            "Kokoro is not installed — run `pip install kokoro soundfile` "
            "and `brew install espeak-ng`"
        ) from exc
    return KPipeline(lang_code=lang_code)


class KokoroTts:
    """TtsEngine backed by Kokoro-82M."""

    def __init__(
        self,
        lang_code: str = config.KOKORO_LANG_CODE,
        voice: str = config.KOKORO_VOICE,
        *,
        pipeline_factory: Callable[[str], object] | None = None,
    ) -> None:
        self._lang_code = lang_code
        self._voice = voice
        self._pipeline_factory = pipeline_factory or _default_pipeline_factory
        self._pipeline = None

    def _get_pipeline(self):
        # Built lazily and cached: loading weights takes seconds, and doing it
        # at import time would slow every test run and CLI invocation.
        if self._pipeline is None:
            self._pipeline = self._pipeline_factory(self._lang_code)
        return self._pipeline

    async def synthesize(self, text: str) -> AsyncIterator[bytes]:
        if not text.strip():
            return
        try:
            pipeline = await asyncio.to_thread(self._get_pipeline)
            segments = await asyncio.to_thread(
                lambda: list(pipeline(text, voice=self._voice))
            )
        except EngineError:
            raise
        except Exception as exc:
            raise EngineError(f"Kokoro synthesis failed: {exc}") from exc

        for _graphemes, _phonemes, samples in segments:
            yield float32_to_pcm16(samples)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && source .venv/bin/activate && pytest tests/test_tts_kokoro.py -v`
Expected: PASS — 4 passed

- [ ] **Step 5: Install Kokoro and verify against the real model**

```bash
brew install espeak-ng
cd server && source .venv/bin/activate
pip install kokoro soundfile
python -c "
import asyncio, wave
from storyadventure.tts_kokoro import KokoroTts
from storyadventure.audio import TTS_SAMPLE_RATE

async def main():
    tts = KokoroTts()
    pcm = b''.join([chunk async for chunk in tts.synthesize('Once upon a time, a little fox found a shiny stone.')])
    with wave.open('/tmp/kokoro_check.wav', 'wb') as out:
        out.setnchannels(1); out.setsampwidth(2); out.setframerate(TTS_SAMPLE_RATE)
        out.writeframes(pcm)
    print(f'wrote {len(pcm)} bytes')

asyncio.run(main())
"
afplay /tmp/kokoro_check.wav
```

Expected: you hear a natural-sounding sentence. If the voice is wrong or missing, try another voice id via `STORYADVENTURE_TTS_VOICE`. If it errors on espeak, confirm `brew list espeak-ng` succeeded.

- [ ] **Step 6: Add Kokoro to project dependencies and commit**

Add to the `dependencies` list in `server/pyproject.toml`:

```toml
    "kokoro>=0.9.2",
    "soundfile>=0.12",
```

```bash
cd /Users/jess/Development/claude-tests/story-adventure
git add server/pyproject.toml server/storyadventure/tts_kokoro.py server/tests/test_tts_kokoro.py
git commit -m "feat(server): add streaming Kokoro TTS adapter"
```

---

### Task 8: Kyutai STT adapter

**Files:**
- Create: `server/storyadventure/stt_kyutai.py`
- Create: `server/tests/test_stt_kyutai.py`
- Modify: `docs/superpowers/specs/2026-08-12-voice-dialog-pipeline-design.md` (record what the API exploration found, resolving the spec's first open question)

**Interfaces:**
- Consumes: `SttEngine`, `EngineError` from `storyadventure.engines`; `pcm16_to_float32`, `MIC_SAMPLE_RATE` from `storyadventure.audio`; `STT_HF_REPO` from `storyadventure.config`
- Produces: `KyutaiStt(hf_repo: str = ..., recognizer_factory: Callable[[str], object] | None = None)` implementing `SttEngine`

**This task is verification-first.** The spec flags an open question: whether the `moshi_mlx` Python/MLX path exposes a streaming API and a semantic VAD signal. Explore the installed package before writing the adapter rather than guessing at its surface.

- [ ] **Step 1: Install and explore the real package API**

```bash
cd server && source .venv/bin/activate
pip install moshi_mlx
python -c "
import moshi_mlx, pkgutil, inspect
print('version:', getattr(moshi_mlx, '__version__', 'unknown'))
print('submodules:', [m.name for m in pkgutil.iter_modules(moshi_mlx.__path__)])
print('top-level names:', [n for n in dir(moshi_mlx) if not n.startswith('_')])
"
python -c "
import moshi_mlx.models as models, inspect
print([n for n in dir(models) if not n.startswith('_')])
"
```

Also confirm the documented file-inference entry point runs at all:

```bash
say "the fox ran through the forest" -o /tmp/stt_check.aiff
python -m moshi_mlx.run_inference --hf-repo kyutai/stt-2.6b-en-mlx /tmp/stt_check.aiff --temp 0
```

Expected: a transcript close to "the fox ran through the forest". Record in your notes which of these is true:
- **(a)** a streaming/incremental API exists (a model object you can feed chunks to and read partial text from), or
- **(b)** only whole-file/whole-buffer inference is available from Python.

Both are workable. In case (b), `feed()` buffers audio and returns `None`, and `finish()` transcribes the whole buffered utterance at once — the phone's Silero VAD already tells us when the utterance ended, so partial transcripts are a nicety, not a requirement. Do not fake a streaming API that the package does not have.

- [ ] **Step 2: Write the failing test**

Create `server/tests/test_stt_kyutai.py`. These tests pin the `SttEngine` contract — buffering, finalize, and reset — independent of which underlying API shape you found:

```python
import numpy as np
import pytest

from storyadventure.audio import float32_to_pcm16
from storyadventure.engines import EngineError
from storyadventure.stt_kyutai import KyutaiStt


class FakeRecognizer:
    """Stands in for the moshi_mlx recognizer: float samples in, text out."""

    def __init__(self, hf_repo: str) -> None:
        self.hf_repo = hf_repo
        self.transcribe_calls: list[int] = []

    def transcribe(self, samples: np.ndarray) -> str:
        self.transcribe_calls.append(len(samples))
        return "the fox ran"


class ExplodingRecognizer:
    def __init__(self, hf_repo: str) -> None:
        pass

    def transcribe(self, samples: np.ndarray) -> str:
        raise RuntimeError("mlx backend unavailable")


def pcm(*values: float) -> bytes:
    return float32_to_pcm16(np.array(values, dtype=np.float32))


def test_finish_returns_transcript_of_all_fed_audio():
    recognizer = FakeRecognizer("repo")
    stt = KyutaiStt(recognizer_factory=lambda repo: recognizer)

    stt.feed(pcm(0.1, 0.2))
    stt.feed(pcm(0.3, 0.4))

    assert stt.finish() == "the fox ran"
    assert recognizer.transcribe_calls == [4]


def test_finish_with_no_audio_returns_empty_string_without_calling_model():
    recognizer = FakeRecognizer("repo")
    stt = KyutaiStt(recognizer_factory=lambda repo: recognizer)

    assert stt.finish() == ""
    assert recognizer.transcribe_calls == []


def test_finish_clears_the_buffer_for_the_next_utterance():
    recognizer = FakeRecognizer("repo")
    stt = KyutaiStt(recognizer_factory=lambda repo: recognizer)

    stt.feed(pcm(0.1, 0.2))
    stt.finish()
    stt.feed(pcm(0.5))
    stt.finish()

    assert recognizer.transcribe_calls == [2, 1]


def test_reset_discards_buffered_audio():
    recognizer = FakeRecognizer("repo")
    stt = KyutaiStt(recognizer_factory=lambda repo: recognizer)

    stt.feed(pcm(0.1, 0.2))
    stt.reset()

    assert stt.finish() == ""
    assert recognizer.transcribe_calls == []


def test_model_failure_is_reported_as_engine_error():
    stt = KyutaiStt(recognizer_factory=ExplodingRecognizer)
    stt.feed(pcm(0.1))
    with pytest.raises(EngineError, match="Kyutai"):
        stt.finish()
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd server && source .venv/bin/activate && pytest tests/test_stt_kyutai.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'storyadventure.stt_kyutai'`

- [ ] **Step 4: Write the implementation**

Create `server/storyadventure/stt_kyutai.py`. Fill in `_default_recognizer_factory` using the API you confirmed in Step 1 — the class below is the seam that keeps the rest of the server independent of that detail:

```python
"""STT backend: Kyutai STT (MLX build).

The phone's Silero VAD decides when an utterance starts and ends, so this
adapter only needs to accumulate one utterance's audio and transcribe it on
finish(). If the installed moshi_mlx exposes a true streaming API, feed() can
be upgraded to return live partial text without changing any caller.
"""

from __future__ import annotations

from typing import Callable

import numpy as np

from . import config
from .audio import pcm16_to_float32
from .engines import EngineError


class _Recognizer:
    """Thin wrapper over moshi_mlx, built lazily so imports stay cheap.

    Replace the body of transcribe() with the call confirmed in Task 8 Step 1.
    """

    def __init__(self, hf_repo: str) -> None:
        try:
            import moshi_mlx  # noqa: F401
        except ImportError as exc:  # pragma: no cover - depends on environment
            raise EngineError(
                "moshi_mlx is not installed — run `pip install moshi_mlx` "
                "under Python 3.12"
            ) from exc
        self._hf_repo = hf_repo
        self._model = self._load()

    def _load(self):
        raise NotImplementedError(
            "Wire this to the moshi_mlx entry point confirmed in Task 8 Step 1."
        )

    def transcribe(self, samples: np.ndarray) -> str:
        raise NotImplementedError(
            "Wire this to the moshi_mlx entry point confirmed in Task 8 Step 1."
        )


def _default_recognizer_factory(hf_repo: str) -> _Recognizer:
    return _Recognizer(hf_repo)


class KyutaiStt:
    """SttEngine backed by Kyutai STT."""

    def __init__(
        self,
        hf_repo: str = config.STT_HF_REPO,
        *,
        recognizer_factory: Callable[[str], object] | None = None,
    ) -> None:
        self._hf_repo = hf_repo
        self._recognizer_factory = recognizer_factory or _default_recognizer_factory
        self._recognizer = None
        self._buffer: list[np.ndarray] = []

    def _get_recognizer(self):
        if self._recognizer is None:
            self._recognizer = self._recognizer_factory(self._hf_repo)
        return self._recognizer

    def feed(self, pcm: bytes) -> str | None:
        samples = pcm16_to_float32(pcm)
        if len(samples):
            self._buffer.append(samples)
        return None

    def finish(self) -> str:
        if not self._buffer:
            return ""
        samples = np.concatenate(self._buffer)
        self._buffer.clear()
        try:
            return self._get_recognizer().transcribe(samples)
        except EngineError:
            raise
        except Exception as exc:
            raise EngineError(f"Kyutai STT failed to transcribe: {exc}") from exc

    def reset(self) -> None:
        self._buffer.clear()
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd server && source .venv/bin/activate && pytest tests/test_stt_kyutai.py -v`
Expected: PASS — 5 passed

- [ ] **Step 6: Implement the real recognizer and verify end to end**

Replace the two `NotImplementedError` bodies with the confirmed `moshi_mlx` calls, then:

```bash
cd server && source .venv/bin/activate
say "the fox ran through the forest" -o /tmp/stt_check.wav --data-format=LEI16@16000
python -c "
import wave
from storyadventure.stt_kyutai import KyutaiStt

with wave.open('/tmp/stt_check.wav', 'rb') as source:
    assert source.getframerate() == 16000, source.getframerate()
    pcm = source.readframes(source.getnframes())

stt = KyutaiStt()
stt.feed(pcm)
print(repr(stt.finish()))
"
```

Expected: a transcript close to "the fox ran through the forest".

- [ ] **Step 7: Record the finding in the spec**

In `docs/superpowers/specs/2026-08-12-voice-dialog-pipeline-design.md`, replace the first bullet under "Open questions / risks" with what you actually found — whether the Python/MLX path exposes streaming and semantic VAD, and which mode the adapter uses. The open question is now answered; the spec should say so.

- [ ] **Step 8: Add the dependency and commit**

Add to the `dependencies` list in `server/pyproject.toml`:

```toml
    "moshi_mlx>=0.2",
```

```bash
cd /Users/jess/Development/claude-tests/story-adventure
git add server/pyproject.toml server/storyadventure/stt_kyutai.py server/tests/test_stt_kyutai.py docs/superpowers/specs/2026-08-12-voice-dialog-pipeline-design.md
git commit -m "feat(server): add Kyutai STT adapter and resolve streaming-API open question"
```

---

### Task 9: Session orchestration and interrupt abort

**Files:**
- Create: `server/storyadventure/session.py`
- Create: `server/tests/conftest.py`
- Create: `server/tests/test_session.py`

**Interfaces:**
- Consumes: everything built so far — `protocol`, `state`, `conversation`, `safety`, `audio`, `engines`, `config`
- Produces: `Transport` Protocol with `send_text(payload: str) -> None` and `send_bytes(payload: bytes) -> None`; `SessionRunner(transport, stt, llm, tts, *, system_prompt=..., conversation=None)` with methods `handle_text(raw: str) -> None`, `handle_audio(pcm: bytes) -> None`, `aclose() -> None`, and read-only properties `state: State`, `conversation: Conversation`

This is the heart of the plan: the turn runs as a cancellable task, and an interrupt cancels it, records whatever was already spoken as an interrupted turn, and returns to LISTENING.

- [ ] **Step 1: Write the shared test fakes**

Create `server/tests/conftest.py`:

```python
import asyncio
import json
from typing import AsyncIterator

import pytest


class FakeTransport:
    """Records everything the session sends back to the client."""

    def __init__(self) -> None:
        self.text: list[str] = []
        self.audio: list[bytes] = []

    async def send_text(self, payload: str) -> None:
        self.text.append(payload)

    async def send_bytes(self, payload: bytes) -> None:
        self.audio.append(payload)

    def messages_of_type(self, kind: str) -> list[dict]:
        decoded = [json.loads(item) for item in self.text]
        return [item for item in decoded if item["type"] == kind]

    def types(self) -> list[str]:
        return [json.loads(item)["type"] for item in self.text]


class FakeStt:
    def __init__(self, transcript: str = "tell me about a fox") -> None:
        self.transcript = transcript
        self.fed: list[bytes] = []
        self.resets = 0

    def feed(self, pcm: bytes) -> str | None:
        self.fed.append(pcm)
        return None

    def finish(self) -> str:
        return self.transcript

    def reset(self) -> None:
        self.resets += 1
        self.fed.clear()


class FakeLlm:
    """Yields fixed chunks, optionally pausing so a test can interrupt mid-stream."""

    def __init__(self, chunks: list[str] | None = None, delay: float = 0.0) -> None:
        self.chunks = chunks if chunks is not None else ["Once upon a time. ", "A fox ran."]
        self.delay = delay
        self.calls: list[list[dict[str, str]]] = []
        self.cancelled = False

    async def stream_reply(self, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        self.calls.append(messages)
        try:
            for chunk in self.chunks:
                if self.delay:
                    await asyncio.sleep(self.delay)
                yield chunk
        except asyncio.CancelledError:
            self.cancelled = True
            raise


class FakeTts:
    """Emits one audio chunk per sentence, optionally slowly."""

    def __init__(self, delay: float = 0.0) -> None:
        self.delay = delay
        self.spoken: list[str] = []
        self.cancelled = False

    async def synthesize(self, text: str) -> AsyncIterator[bytes]:
        try:
            if self.delay:
                await asyncio.sleep(self.delay)
            self.spoken.append(text)
            yield f"<audio:{text}>".encode()
        except asyncio.CancelledError:
            self.cancelled = True
            raise


class FailingLlm:
    def __init__(self, error: Exception) -> None:
        self.error = error

    async def stream_reply(self, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        raise self.error
        yield ""  # pragma: no cover - unreachable, marks this a generator


@pytest.fixture
def transport() -> FakeTransport:
    return FakeTransport()
```

- [ ] **Step 2: Write the failing test**

Create `server/tests/test_session.py`:

```python
import asyncio

from conftest import FailingLlm, FakeLlm, FakeStt, FakeTts
from storyadventure.conversation import INTERRUPTED_MARKER
from storyadventure.engines import EngineError
from storyadventure.safety import SAFE_FALLBACK
from storyadventure.session import SessionRunner
from storyadventure.state import State

SPEECH_START = '{"type": "speech_start"}'
SPEECH_END = '{"type": "speech_end"}'
INTERRUPT = '{"type": "interrupt"}'


def make_session(transport, *, stt=None, llm=None, tts=None) -> SessionRunner:
    return SessionRunner(
        transport=transport,
        stt=stt or FakeStt(),
        llm=llm or FakeLlm(),
        tts=tts or FakeTts(),
        system_prompt="be a kind storyteller",
    )


async def run_full_turn(session) -> None:
    await session.handle_text(SPEECH_START)
    await session.handle_audio(b"\x01\x02")
    await session.handle_text(SPEECH_END)
    await session.wait_for_turn()


async def test_full_turn_emits_transcript_response_audio_and_turn_end(transport):
    tts = FakeTts()
    session = make_session(transport, tts=tts)

    await run_full_turn(session)

    assert transport.types() == [
        "transcript_final",
        "response_text",
        "turn_end",
    ]
    assert transport.messages_of_type("transcript_final")[0]["text"] == "tell me about a fox"
    assert transport.messages_of_type("response_text")[0]["text"] == "Once upon a time. A fox ran."
    assert tts.spoken == ["Once upon a time.", "A fox ran."]
    assert transport.audio == [b"<audio:Once upon a time.>", b"<audio:A fox ran.>"]
    assert session.state is State.IDLE


async def test_audio_is_forwarded_to_stt_while_listening(transport):
    stt = FakeStt()
    session = make_session(transport, stt=stt)

    await session.handle_text(SPEECH_START)
    await session.handle_audio(b"\x01\x02")

    assert stt.fed == [b"\x01\x02"]


async def test_audio_is_ignored_when_not_listening(transport):
    stt = FakeStt()
    session = make_session(transport, stt=stt)

    await session.handle_audio(b"\x01\x02")

    assert stt.fed == []


async def test_turn_records_both_sides_in_conversation(transport):
    session = make_session(transport)

    await run_full_turn(session)

    turns = session.conversation.turns
    assert [(turn.speaker, turn.text) for turn in turns] == [
        ("child", "tell me about a fox"),
        ("agent", "Once upon a time. A fox ran."),
    ]


async def test_llm_receives_system_prompt_and_history(transport):
    llm = FakeLlm()
    session = make_session(transport, llm=llm)

    await run_full_turn(session)

    assert llm.calls[0] == [
        {"role": "system", "content": "be a kind storyteller"},
        {"role": "user", "content": "tell me about a fox"},
    ]


async def test_unsafe_reply_is_replaced_with_the_fallback(transport):
    llm = FakeLlm(chunks=["He picked up the knife."])
    session = make_session(transport, llm=llm)

    await run_full_turn(session)

    assert transport.messages_of_type("response_text")[0]["text"] == SAFE_FALLBACK


async def test_interrupt_during_speaking_stops_the_turn(transport):
    tts = FakeTts(delay=0.05)
    session = make_session(transport, tts=tts)

    await session.handle_text(SPEECH_START)
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.01)
    await session.handle_text(INTERRUPT)

    assert session.state is State.LISTENING
    assert tts.cancelled is True
    assert "turn_end" not in transport.types()


async def test_interrupt_during_llm_generation_cancels_it(transport):
    llm = FakeLlm(chunks=["Once ", "upon ", "a time."], delay=0.05)
    session = make_session(transport, llm=llm)

    await session.handle_text(SPEECH_START)
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.01)
    await session.handle_text(INTERRUPT)

    assert session.state is State.LISTENING
    assert llm.cancelled is True
    assert transport.messages_of_type("response_text") == []


async def test_interrupt_records_spoken_text_as_an_interrupted_turn(transport):
    tts = FakeTts(delay=0.03)
    llm = FakeLlm(chunks=["Once upon a time. ", "A fox ran."])
    session = make_session(transport, llm=llm, tts=tts)

    await session.handle_text(SPEECH_START)
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.045)  # first sentence spoken, second still synthesizing
    await session.handle_text(INTERRUPT)

    agent_turns = [turn for turn in session.conversation.turns if turn.speaker == "agent"]
    assert len(agent_turns) == 1
    assert agent_turns[0].text == "Once upon a time."
    assert agent_turns[0].interrupted is True


async def test_interrupted_turn_is_visible_to_the_next_llm_call(transport):
    tts = FakeTts(delay=0.03)
    llm = FakeLlm(chunks=["Once upon a time. ", "A fox ran."])
    session = make_session(transport, llm=llm, tts=tts)

    await session.handle_text(SPEECH_START)
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.045)
    await session.handle_text(INTERRUPT)

    llm.chunks = ["A dragon then!"]
    await session.handle_audio(b"\x03")
    await session.handle_text(SPEECH_END)
    await session.wait_for_turn()

    second_call = llm.calls[1]
    assert second_call[2]["role"] == "assistant"
    assert second_call[2]["content"].endswith(INTERRUPTED_MARKER)


async def test_interrupt_resets_stt_so_old_audio_is_discarded(transport):
    stt = FakeStt()
    tts = FakeTts(delay=0.05)
    session = make_session(transport, stt=stt, tts=tts)

    await session.handle_text(SPEECH_START)
    await session.handle_audio(b"\x01")
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.01)
    await session.handle_text(INTERRUPT)

    assert stt.resets == 1
    assert stt.fed == []


async def test_interrupt_while_idle_just_starts_listening(transport):
    session = make_session(transport)

    await session.handle_text(INTERRUPT)

    assert session.state is State.LISTENING
    assert transport.messages_of_type("error") == []


async def test_engine_failure_is_reported_as_an_error_message(transport):
    session = make_session(transport, llm=FailingLlm(EngineError("Ollama is not running")))

    await run_full_turn(session)

    errors = transport.messages_of_type("error")
    assert len(errors) == 1
    assert "Ollama is not running" in errors[0]["message"]
    assert session.state is State.IDLE


async def test_malformed_control_frame_is_reported_without_killing_the_session(transport):
    session = make_session(transport)

    await session.handle_text("{not json")

    assert transport.messages_of_type("error")
    assert session.state is State.IDLE


async def test_empty_transcript_ends_the_turn_without_calling_the_llm(transport):
    llm = FakeLlm()
    session = make_session(transport, stt=FakeStt(transcript="   "), llm=llm)

    await run_full_turn(session)

    assert llm.calls == []
    assert session.state is State.IDLE
    assert "turn_end" in transport.types()


async def test_aclose_cancels_an_in_flight_turn(transport):
    tts = FakeTts(delay=0.05)
    session = make_session(transport, tts=tts)

    await session.handle_text(SPEECH_START)
    await session.handle_text(SPEECH_END)
    await asyncio.sleep(0.01)
    await session.aclose()

    assert tts.cancelled is True
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd server && source .venv/bin/activate && pytest tests/test_session.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'storyadventure.session'`

- [ ] **Step 4: Write the implementation**

Create `server/storyadventure/session.py`:

```python
"""Per-connection orchestration.

One SessionRunner per WebSocket connection. The turn (LLM generation plus TTS
playback) runs as its own asyncio task so that an interrupt can cancel it
mid-flight — that cancellation, and recording what the agent had already said,
is the core of the barge-in behaviour.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
from typing import Protocol

from . import config, safety
from .audio import split_sentences
from .conversation import Conversation
from .engines import EngineError, LlmEngine, SttEngine, TtsEngine
from .protocol import (
    Interrupt,
    ProtocolError,
    SpeechEnd,
    SpeechStart,
    decode_client_message,
    encode_error,
    encode_response_text,
    encode_transcript_final,
    encode_transcript_partial,
    encode_turn_end,
)
from .state import Event, InvalidTransition, State, TurnStateMachine

logger = logging.getLogger(__name__)


class Transport(Protocol):
    async def send_text(self, payload: str) -> None: ...
    async def send_bytes(self, payload: bytes) -> None: ...


class SessionRunner:
    def __init__(
        self,
        transport: Transport,
        stt: SttEngine,
        llm: LlmEngine,
        tts: TtsEngine,
        *,
        system_prompt: str = config.SYSTEM_PROMPT,
        conversation: Conversation | None = None,
    ) -> None:
        self._transport = transport
        self._stt = stt
        self._llm = llm
        self._tts = tts
        self._system_prompt = system_prompt
        self._conversation = conversation or Conversation()
        self._machine = TurnStateMachine()
        self._turn_task: asyncio.Task | None = None
        self._spoken: list[str] = []

    @property
    def state(self) -> State:
        return self._machine.state

    @property
    def conversation(self) -> Conversation:
        return self._conversation

    async def handle_text(self, raw: str) -> None:
        try:
            message = decode_client_message(raw)
        except ProtocolError as exc:
            logger.warning("bad control frame: %s", exc)
            await self._transport.send_text(encode_error(str(exc)))
            return

        match message:
            case SpeechStart():
                await self._start_listening()
            case SpeechEnd():
                await self._finish_listening()
            case Interrupt():
                await self._interrupt()

    async def handle_audio(self, pcm: bytes) -> None:
        # Audio arriving outside LISTENING is stale — a frame in flight when
        # the utterance ended. Dropping it is correct, not an error.
        if self._machine.state is not State.LISTENING:
            return
        partial = self._stt.feed(pcm)
        if partial:
            await self._transport.send_text(encode_transcript_partial(partial))

    async def wait_for_turn(self) -> None:
        """Await the in-flight turn. Used by tests and on disconnect."""
        if self._turn_task is not None:
            await asyncio.gather(self._turn_task, return_exceptions=True)

    async def aclose(self) -> None:
        await self._cancel_turn(record_spoken=False)

    async def _start_listening(self) -> None:
        await self._cancel_turn(record_spoken=True)
        self._transition(Event.SPEECH_START)

    async def _finish_listening(self) -> None:
        if self._machine.state is not State.LISTENING:
            return
        self._transition(Event.SPEECH_END)
        transcript = self._stt.finish()
        await self._transport.send_text(encode_transcript_final(transcript))
        if not transcript.strip():
            self._transition(Event.RESPONSE_READY)
            self._transition(Event.TTS_DONE)
            await self._transport.send_text(encode_turn_end())
            return
        self._spoken = []
        self._turn_task = asyncio.create_task(self._run_turn(transcript))

    async def _interrupt(self) -> None:
        interrupt_received = time.monotonic()
        await self._cancel_turn(record_spoken=True)
        self._stt.reset()
        self._transition(Event.INTERRUPT)
        logger.info(
            "interrupt handled in %.1f ms",
            (time.monotonic() - interrupt_received) * 1000,
        )

    async def _cancel_turn(self, *, record_spoken: bool) -> None:
        task, self._turn_task = self._turn_task, None
        if task is None or task.done():
            return
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task
        if record_spoken and self._spoken:
            self._conversation.add_agent(" ".join(self._spoken), interrupted=True)
        self._spoken = []

    async def _run_turn(self, transcript: str) -> None:
        try:
            self._conversation.add_child(transcript)
            messages = self._conversation.to_messages(self._system_prompt)

            parts: list[str] = []
            async for chunk in self._llm.stream_reply(messages):
                parts.append(chunk)
            reply = safety.filter_reply("".join(parts).strip())

            await self._transport.send_text(encode_response_text(reply))
            self._transition(Event.RESPONSE_READY)

            for sentence in split_sentences(reply):
                async for pcm in self._tts.synthesize(sentence):
                    await self._transport.send_bytes(pcm)
                # Recorded only once fully sent, so an interrupt attributes to
                # the agent exactly what the child actually heard.
                self._spoken.append(sentence)

            self._conversation.add_agent(reply)
            self._spoken = []
            self._transition(Event.TTS_DONE)
            await self._transport.send_text(encode_turn_end())
        except asyncio.CancelledError:
            raise
        except EngineError as exc:
            logger.error("engine failure during turn: %s", exc)
            await self._fail_turn(str(exc))
        except Exception as exc:  # noqa: BLE001 - a session must survive one bad turn
            logger.exception("unexpected failure during turn")
            await self._fail_turn(f"internal error: {exc}")

    async def _fail_turn(self, message: str) -> None:
        await self._transport.send_text(encode_error(message))
        self._spoken = []
        if self._machine.state is State.THINKING:
            self._transition(Event.RESPONSE_READY)
        if self._machine.state is State.SPEAKING:
            self._transition(Event.TTS_DONE)

    def _transition(self, event: Event) -> None:
        try:
            self._machine.handle(event)
        except InvalidTransition as exc:
            # Races are expected here (an interrupt landing as a turn ends);
            # log and keep the session alive rather than tearing it down.
            logger.debug("ignoring invalid transition: %s", exc)
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd server && source .venv/bin/activate && pytest tests/test_session.py -v`
Expected: PASS — 16 passed

- [ ] **Step 6: Run the whole suite**

Run: `cd server && source .venv/bin/activate && pytest -v`
Expected: PASS — all tests from Tasks 1-9 green

- [ ] **Step 7: Commit**

```bash
cd /Users/jess/Development/claude-tests/story-adventure
git add server/storyadventure/session.py server/tests/conftest.py server/tests/test_session.py
git commit -m "feat(server): add session orchestration with mid-turn interrupt abort"
```

---

### Task 10: WebSocket app, CLI test client, and end-to-end verification

**Files:**
- Create: `server/storyadventure/app.py`
- Create: `server/tools/test_client.py`
- Create: `server/tests/test_app.py`
- Modify: `README.md` (add a "Running the server" section)

**Interfaces:**
- Consumes: `SessionRunner`, `Transport` from `storyadventure.session`; `KyutaiStt`, `OllamaLlm`, `KokoroTts`; `config`
- Produces: `WebSocketTransport(websocket)` implementing `Transport`; `handle_connection(websocket) -> None`; `build_session(transport) -> SessionRunner`; `main() -> None`

- [ ] **Step 1: Write the failing test**

Create `server/tests/test_app.py`:

```python
from conftest import FakeLlm, FakeStt, FakeTts
from storyadventure.app import WebSocketTransport, handle_connection
from storyadventure.session import SessionRunner


class FakeWebSocket:
    """Minimal stand-in for a websockets connection."""

    def __init__(self, incoming: list[str | bytes]) -> None:
        self._incoming = incoming
        self.sent: list[str | bytes] = []

    def __aiter__(self):
        async def generate():
            for item in self._incoming:
                yield item

        return generate()

    async def send(self, payload: str | bytes) -> None:
        self.sent.append(payload)


async def test_transport_sends_text_and_binary_over_the_socket():
    websocket = FakeWebSocket([])
    transport = WebSocketTransport(websocket)

    await transport.send_text('{"type": "turn_end"}')
    await transport.send_bytes(b"\x01\x02")

    assert websocket.sent == ['{"type": "turn_end"}', b"\x01\x02"]


async def test_handle_connection_drives_a_full_turn():
    websocket = FakeWebSocket(
        ['{"type": "speech_start"}', b"\x01\x02", '{"type": "speech_end"}']
    )

    def session_factory(transport):
        return SessionRunner(
            transport=transport,
            stt=FakeStt(),
            llm=FakeLlm(),
            tts=FakeTts(),
            system_prompt="be kind",
        )

    await handle_connection(websocket, session_factory=session_factory)

    text_frames = [item for item in websocket.sent if isinstance(item, str)]
    assert any("transcript_final" in frame for frame in text_frames)
    assert any("turn_end" in frame for frame in text_frames)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd server && source .venv/bin/activate && pytest tests/test_app.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'storyadventure.app'`

- [ ] **Step 3: Write the implementation**

Create `server/storyadventure/app.py`:

```python
"""WebSocket entry point.

Binary frames are mic audio; text frames are JSON control messages.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Callable

import websockets

from . import config
from .llm_ollama import OllamaLlm
from .session import SessionRunner, Transport
from .stt_kyutai import KyutaiStt
from .tts_kokoro import KokoroTts

logger = logging.getLogger(__name__)


class WebSocketTransport:
    def __init__(self, websocket) -> None:
        self._websocket = websocket

    async def send_text(self, payload: str) -> None:
        await self._websocket.send(payload)

    async def send_bytes(self, payload: bytes) -> None:
        await self._websocket.send(payload)


def build_session(transport: Transport) -> SessionRunner:
    # Engines are per-connection so one session's STT buffer can never bleed
    # into another's. Single-household use, so the memory cost is fine.
    return SessionRunner(
        transport=transport,
        stt=KyutaiStt(),
        llm=OllamaLlm(),
        tts=KokoroTts(),
    )


async def handle_connection(
    websocket,
    *,
    session_factory: Callable[[Transport], SessionRunner] = build_session,
) -> None:
    transport = WebSocketTransport(websocket)
    session = session_factory(transport)
    logger.info("client connected")
    try:
        async for message in websocket:
            if isinstance(message, bytes):
                await session.handle_audio(message)
            else:
                await session.handle_text(message)
        await session.wait_for_turn()
    finally:
        await session.aclose()
        logger.info("client disconnected")


async def serve() -> None:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )
    logger.info(
        "listening on ws://%s:%s (model=%s)",
        config.SERVER_HOST,
        config.SERVER_PORT,
        config.OLLAMA_MODEL,
    )
    async with websockets.serve(
        handle_connection, config.SERVER_HOST, config.SERVER_PORT, max_size=None
    ):
        await asyncio.Future()


def main() -> None:
    try:
        asyncio.run(serve())
    except KeyboardInterrupt:
        logger.info("shutting down")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd server && source .venv/bin/activate && pytest tests/test_app.py -v`
Expected: PASS — 2 passed

- [ ] **Step 5: Write the CLI test client**

Create `server/tools/test_client.py`. This is what makes the server verifiable without the phone — it stands in for the iOS client, including the interrupt:

```python
"""CLI stand-in for the phone client.

Sends a WAV file as if it were mic audio, optionally fires an interrupt part
way through the reply, and writes the received TTS audio to a WAV file.

Usage:
    python tools/test_client.py utterance.wav
    python tools/test_client.py utterance.wav --interrupt-after 0.8
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
import wave

import websockets

from storyadventure.audio import MIC_SAMPLE_RATE, TTS_SAMPLE_RATE

CHUNK_FRAMES = 1600  # 100 ms at 16 kHz


def read_wav(path: str) -> bytes:
    with wave.open(path, "rb") as source:
        if source.getframerate() != MIC_SAMPLE_RATE or source.getnchannels() != 1:
            sys.exit(
                f"{path} must be mono {MIC_SAMPLE_RATE} Hz PCM16; got "
                f"{source.getnchannels()}ch @ {source.getframerate()} Hz.\n"
                f"Convert it with: ffmpeg -i {path} -ac 1 -ar {MIC_SAMPLE_RATE} -sample_fmt s16 fixed.wav"
            )
        return source.readframes(source.getnframes())


def write_wav(path: str, pcm: bytes) -> None:
    with wave.open(path, "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(TTS_SAMPLE_RATE)
        out.writeframes(pcm)


async def receive(websocket, audio: list[bytes], interrupt_at: float | None, started: float):
    async for message in websocket:
        if isinstance(message, bytes):
            audio.append(message)
            continue
        payload = json.loads(message)
        kind = payload["type"]
        if kind == "transcript_final":
            print(f"  heard: {payload['text']!r}")
        elif kind == "response_text":
            print(f"  agent: {payload['text']!r}")
        elif kind == "error":
            print(f"  ERROR: {payload['message']}")
        elif kind == "turn_end":
            print(f"  turn complete in {time.monotonic() - started:.2f}s")
            if interrupt_at is None:
                return


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wav", help="mono 16 kHz PCM16 WAV file to send as mic audio")
    parser.add_argument("--url", default="ws://localhost:8765")
    parser.add_argument(
        "--interrupt-after",
        type=float,
        default=None,
        metavar="SECONDS",
        help="fire an interrupt this long after speech_end",
    )
    parser.add_argument("--out", default="/tmp/reply.wav")
    args = parser.parse_args()

    pcm = read_wav(args.wav)
    audio: list[bytes] = []

    async with websockets.connect(args.url, max_size=None) as websocket:
        started = time.monotonic()
        await websocket.send(json.dumps({"type": "speech_start"}))
        for offset in range(0, len(pcm), CHUNK_FRAMES * 2):
            await websocket.send(pcm[offset : offset + CHUNK_FRAMES * 2])
            await asyncio.sleep(0.01)  # loosely pace it like a live mic
        await websocket.send(json.dumps({"type": "speech_end"}))
        print("sent utterance, waiting for reply...")

        receiver = asyncio.create_task(
            receive(websocket, audio, args.interrupt_after, started)
        )

        if args.interrupt_after is not None:
            await asyncio.sleep(args.interrupt_after)
            fired = time.monotonic()
            await websocket.send(json.dumps({"type": "interrupt"}))
            print(f"  sent interrupt at {fired - started:.2f}s")
            await asyncio.sleep(0.5)
            receiver.cancel()

        try:
            await receiver
        except asyncio.CancelledError:
            pass

    if audio:
        write_wav(args.out, b"".join(audio))
        print(f"wrote {len(b''.join(audio))} bytes of reply audio to {args.out}")
    else:
        print("no audio received")


if __name__ == "__main__":
    asyncio.run(main())
```

- [ ] **Step 6: Verify the happy path end to end with real models**

```bash
ollama serve   # separate terminal
cd server && source .venv/bin/activate
python -m storyadventure.app   # separate terminal; leave running

# in a third terminal:
cd server && source .venv/bin/activate
say "tell me a story about a brave little fox" -o /tmp/utterance.wav --data-format=LEI16@16000
python tools/test_client.py /tmp/utterance.wav
afplay /tmp/reply.wav
```

Expected: the server logs a connection, the client prints the transcript and a short wholesome reply, and `/tmp/reply.wav` plays that reply in Kokoro's voice. Note the reported turn time — on an M1 with all three models loaded, several seconds is normal for the first turn (cold weights) and faster after.

- [ ] **Step 7: Verify the interrupt path end to end**

```bash
cd server && source .venv/bin/activate
python tools/test_client.py /tmp/utterance.wav --interrupt-after 0.8
```

Expected: the client prints `sent interrupt`, and the server log shows `interrupt handled in N ms` with no `turn_end` for that turn. Confirm in the server log that the turn was cancelled rather than running to completion. Try a couple of values for `--interrupt-after` — one landing during LLM generation (early, before `agent:` prints) and one during TTS playback (after it prints) — since those exercise the two different cancellation paths.

- [ ] **Step 8: Check memory headroom with all three models loaded**

This is the spec's second open risk — three models on one 16GB Mac.

```bash
# with the server running and after at least one full turn:
ps -o rss=,command= -p $(pgrep -f "storyadventure.app") | awk '{printf "server RSS: %.1f GB\n", $1/1048576}'
ollama ps
vm_stat | head -5
```

Expected: server RSS plus the Ollama model (~6.6 GB) leaves usable headroom on 16 GB. If the machine is swapping hard, note it in the spec's risk section and consider the `llama3.3:8b` fallback or a smaller quantization.

- [ ] **Step 9: Document how to run it**

Add a "Running the server" section to `README.md`, after the existing Setup section:

```markdown
### Running the server

Three terminals:

```bash
# 1. Ollama
ollama serve

# 2. The voice/dialog server
cd server && source .venv/bin/activate && python -m storyadventure.app

# 3. The CLI test client (stands in for the phone)
cd server && source .venv/bin/activate
say "tell me a story about a brave little fox" -o /tmp/utterance.wav --data-format=LEI16@16000
python tools/test_client.py /tmp/utterance.wav          # full turn
python tools/test_client.py /tmp/utterance.wav --interrupt-after 0.8   # barge-in
afplay /tmp/reply.wav
```

Run the tests with `cd server && source .venv/bin/activate && pytest`.
```

- [ ] **Step 10: Run the full suite and commit**

```bash
cd server && source .venv/bin/activate && pytest -v
cd /Users/jess/Development/claude-tests/story-adventure
git add server/storyadventure/app.py server/tools/test_client.py server/tests/test_app.py README.md
git commit -m "feat(server): add websocket entry point and CLI test client"
```

---

## Done criteria

- `pytest` passes in `server/`.
- A full turn works end to end from the CLI client with all three real models.
- An interrupt fired during LLM generation cancels it; an interrupt fired during TTS playback cancels it and records the spoken portion as an interrupted turn.
- Memory headroom on the 16GB M1 is confirmed and recorded.
- The spec's STT open question is resolved and written back into the spec.

## Follow-up plan

The iOS client — AVAudioEngine capture, Silero VAD, `AVAudioSession` voice-processing AEC, WebSocket client, streaming playback with immediate local stop, and the client-side latency instrumentation the spec asks for (VAD-fire → interrupt-sent → playback-stopped) — is written as a separate plan once this server lands.

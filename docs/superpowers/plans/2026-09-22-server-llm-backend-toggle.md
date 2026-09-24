# Server-Mode LLM Backend Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a parent choose, from the phone, whether the home server uses local Ollama or Groq for the next story (issue #25).

**Architecture:** The phone adds an optional `llm_backend` field to the existing `update_settings` message. The server holds an Ollama engine plus an optional Groq engine (present only if `GROQ_API_KEY` is set), resolves the preference into a per-story engine inside `_begin_story()`, and replies with a new `llm_backend` status event. The concluded story's engine and page count are captured before the next-story reset so the storybook rewrite uses the right ones.

**Tech Stack:** Python 3.12 server (asyncio, pytest), Swift/SwiftUI iOS app with SwiftPM core package `TinyTalkCore` (XCTest).

**Spec:** `docs/superpowers/specs/2026-09-22-server-llm-backend-toggle-design.md`

## Global Constraints

- Allowed `llm_backend` values on the wire: exactly `"ollama"` and `"groq"`.
- Default everywhere is Ollama: phone UserDefaults default `"ollama"`; server startup preference `config.LLM_BACKEND` (`TINYTALK_LLM_BACKEND`, default `"ollama"`).
- The Groq API key is never sent over the wire. Server reads `GROQ_API_KEY` at startup only.
- The backend choice applies to the **next** story only, never mid-story.
- No automatic Groq→Ollama fallback on a mid-story Groq error.
- Kid-safety code (`safety.py`) is not modified.
- Never `pip install` anything. Run server tests from the worktree's `server/` dir with main's venv: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest` (the `-m` form puts cwd first on the path so it tests the worktree's code; don't use the bare `pytest` script).
- `swift test` prints ~1M log lines: always redirect to `/Users/jess/.claude/jobs/b6b5c819/tmp/swift.txt` and grep the summary (commands in each task).
- The worktree guard rejects compound command lines containing git or `python -m pytest` with shell variables: run each command plainly, with literal paths.
- Commit after every task, message ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Baselines on main: server pytest ~423 passed; `swift test` 256 tests / 0 failures. Known flake: `testPageAudioDittyStopsOnStopPageAudio`.

## File map

| File | Change |
|---|---|
| `server/tinytalk/protocol.py` | `UpdateSettings.llm_backend`, decode validation, `encode_llm_backend()` |
| `server/tinytalk/session.py` | `groq_llm`/`llm_backend` ctor args, `_resolve_llm()`, `_story_llm`, settings handler + event, rewrite arg fix, synced rewrite engine |
| `server/tinytalk/app.py` | `build_llms()` replaces `build_llm()`, `build_session()` passes both engines, startup banner |
| `server/tinytalk/llm_groq.py` | module docstring only |
| `server/tests/test_protocol.py`, `test_session.py`, `test_app.py` | new/updated tests |
| `README.md` | "Running the server": how to enable Groq for home mode |
| `ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift` | `.updateSettings(..., llmBackend:)`, `LlmBackendStatus`, `.llmBackend` event |
| `ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift` | `latestLlmBackendStatus`, `updateSettings(..., llmBackend:)` |
| `ios/TinyTalkCore/Sources/TinyTalkCore/DemoConnection.swift` | ignore the new field |
| `ios/TinyTalkCore/Tests/TinyTalkCoreTests/*` | Protocol/Coordinator/parity tests |
| `ios/TinyTalkApp/TinyTalkApp/AppModel.swift` | `llmBackend` persisted, `setLlmBackend`, `serverLlmStatus` |
| `ios/TinyTalkApp/TinyTalkApp/SettingsView.swift` | card renamed "Elsie's Brain", picker + status |

---

### Task 1: Server wire protocol — `llm_backend` field and status event

**Files:**
- Modify: `server/tinytalk/protocol.py` (`UpdateSettings` ~line 148; decode ~line 246; append encoder at end)
- Test: `server/tests/test_protocol.py`

**Interfaces:**
- Produces: `UpdateSettings(target_turns: int, page_count: int, llm_backend: str | None = None)`; `LLM_BACKENDS: tuple[str, ...] = ("ollama", "groq")`; `encode_llm_backend(requested: str, active: str, groq_available: bool) -> str`.

- [ ] **Step 1: Write the failing tests** — append to `server/tests/test_protocol.py` and add `encode_llm_backend` to its `from tinytalk.protocol import (...)` list:

```python
def test_decode_update_settings_with_llm_backend():
    assert decode_client_message(
        '{"type": "update_settings", "target_turns": 7, "page_count": 5, "llm_backend": "groq"}'
    ) == UpdateSettings(target_turns=7, page_count=5, llm_backend="groq")


def test_decode_update_settings_without_llm_backend_leaves_it_none():
    message = decode_client_message(
        '{"type": "update_settings", "target_turns": 7, "page_count": 5}'
    )
    assert message == UpdateSettings(target_turns=7, page_count=5)
    assert message.llm_backend is None


def test_decode_rejects_update_settings_unknown_llm_backend():
    with pytest.raises(ProtocolError, match="llm_backend"):
        decode_client_message(
            '{"type": "update_settings", "target_turns": 7, "page_count": 5, "llm_backend": "gpt"}'
        )


def test_decode_rejects_update_settings_non_string_llm_backend():
    with pytest.raises(ProtocolError, match="llm_backend"):
        decode_client_message(
            '{"type": "update_settings", "target_turns": 7, "page_count": 5, "llm_backend": 1}'
        )


def test_encode_llm_backend():
    assert json.loads(encode_llm_backend("groq", "ollama", False)) == {
        "type": "llm_backend",
        "requested": "groq",
        "active": "ollama",
        "groq_available": False,
    }
```

- [ ] **Step 2: Run to verify they fail**

From `/Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/llm-backend-toggle/server`:
Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest tests/test_protocol.py -q`
Expected: collection ImportError for `encode_llm_backend`.

- [ ] **Step 3: Implement** in `server/tinytalk/protocol.py`.

Replace the `UpdateSettings` dataclass with:

```python
LLM_BACKENDS = ("ollama", "groq")


@dataclass(frozen=True)
class UpdateSettings:
    """Parent-adjustable settings from the Settings screen -- persisted
    client-side, sent once after connecting and again whenever changed
    while connected. Applied to the next story construction, not
    retroactively to one already in progress -- see SessionRunner's
    handle_update_settings().

    llm_backend is optional (docs/superpowers/specs/
    2026-09-22-server-llm-backend-toggle-design.md): absent means "keep
    whatever the server is already using", so an older phone build or
    demo mode's own messages change nothing."""

    target_turns: int
    page_count: int
    llm_backend: str | None = None
```

In `decode_client_message`, replace the final `return UpdateSettings(target_turns=target_turns, page_count=page_count)` with:

```python
        llm_backend = payload.get("llm_backend")
        if llm_backend is not None and llm_backend not in LLM_BACKENDS:
            raise ProtocolError(
                f"update_settings llm_backend must be one of {LLM_BACKENDS}: {raw!r}"
            )
        return UpdateSettings(
            target_turns=target_turns, page_count=page_count, llm_backend=llm_backend
        )
```

(`1 not in ("ollama", "groq")` is True, so the non-string case is covered by the same check.)

Append at end of file:

```python
def encode_llm_backend(requested: str, active: str, groq_available: bool) -> str:
    """Reply to an update_settings carrying llm_backend -- `active` is what
    the NEXT story will actually use (ollama if groq was requested but this
    server has no GROQ_API_KEY). No turn_id: not part of live turn-taking,
    same as story_list."""
    return json.dumps(
        {
            "type": "llm_backend",
            "requested": requested,
            "active": active,
            "groq_available": groq_available,
        }
    )
```

- [ ] **Step 4: Run to verify they pass**

Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest tests/test_protocol.py -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/protocol.py server/tests/test_protocol.py
```
```bash
git commit -m "feat(server): optional llm_backend on update_settings + llm_backend event (#25)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Session — per-story engine resolution and the settings reply

**Files:**
- Modify: `server/tinytalk/session.py` (`__init__` ~line 110-141; dispatch ~line 218; `_begin_story` ~line 288; `handle_update_settings` ~line 301; `_stream_llm_reply` ~line 784; imports)
- Test: `server/tests/test_session.py`

**Interfaces:**
- Consumes: `UpdateSettings.llm_backend`, `encode_llm_backend(requested, active, groq_available)` from Task 1.
- Produces: `SessionRunner(..., groq_llm: LlmEngine | None = None, llm_backend: str = "ollama")` keyword args; attributes `_llm_backend: str`, `_groq_llm: LlmEngine | None`, `_story_llm: LlmEngine`, `_story_llm_name: str`; method `_resolve_llm() -> tuple[LlmEngine, str]`; `handle_update_settings(target_turns: int, page_count: int, llm_backend: str | None = None)`.

- [ ] **Step 1: Write the failing tests** — append to `server/tests/test_session.py`:

```python
def make_two_engine_session(transport, *, ollama=None, groq=None, llm_backend="ollama"):
    return SessionRunner(
        transport=transport,
        stt=FakeStt(),
        llm=ollama or FakeLlm(),
        tts=FakeTts(),
        system_prompt="be a kind storyteller",
        groq_llm=groq,
        llm_backend=llm_backend,
    )


async def test_default_session_uses_the_local_engine(transport):
    ollama = FakeLlm()
    session = make_two_engine_session(transport, ollama=ollama, groq=FakeLlm())
    assert session._story_llm is ollama
    assert session._story_llm_name == "ollama"


async def test_startup_preference_groq_is_used_when_available(transport):
    groq = FakeLlm()
    session = make_two_engine_session(transport, groq=groq, llm_backend="groq")
    await run_full_turn(session)
    assert session._story_llm is groq
    assert len(groq.calls) == 1


async def test_update_settings_between_stories_switches_the_next_storys_engine(transport):
    ollama, groq = FakeLlm(), FakeLlm()
    session = make_two_engine_session(transport, ollama=ollama, groq=groq)
    await session.handle_text(
        '{"type": "update_settings", "target_turns": 7, "page_count": 5, "llm_backend": "groq"}'
    )
    await run_full_turn(session)
    assert len(groq.calls) == 1
    assert ollama.calls == []


async def test_update_settings_mid_story_keeps_the_current_storys_engine(transport):
    ollama, groq = FakeLlm(), FakeLlm()
    session = make_two_engine_session(transport, ollama=ollama, groq=groq)
    await run_full_turn(session)  # story has started on ollama
    await session.handle_text(
        '{"type": "update_settings", "target_turns": 7, "page_count": 5, "llm_backend": "groq"}'
    )
    await run_full_turn(session)
    assert len(ollama.calls) == 2
    assert groq.calls == []
    assert session._llm_backend == "groq"


async def test_update_settings_new_story_after_mid_story_switch_uses_the_new_engine(transport):
    ollama, groq = FakeLlm(), FakeLlm()
    session = make_two_engine_session(transport, ollama=ollama, groq=groq)
    await run_full_turn(session)
    await session.handle_update_settings(7, 5, llm_backend="groq")
    await session.handle_new_story()
    assert session._story_llm is groq


async def test_groq_requested_without_a_groq_engine_falls_back_to_ollama(transport):
    ollama = FakeLlm()
    session = make_two_engine_session(transport, ollama=ollama, groq=None)
    await session.handle_text(
        '{"type": "update_settings", "target_turns": 7, "page_count": 5, "llm_backend": "groq"}'
    )
    assert session._story_llm is ollama
    assert transport.messages_of_type("llm_backend")[-1] == {
        "type": "llm_backend",
        "requested": "groq",
        "active": "ollama",
        "groq_available": False,
    }


async def test_update_settings_with_llm_backend_replies_with_status(transport):
    session = make_two_engine_session(transport, groq=FakeLlm())
    await session.handle_text(
        '{"type": "update_settings", "target_turns": 7, "page_count": 5, "llm_backend": "groq"}'
    )
    assert transport.messages_of_type("llm_backend")[-1] == {
        "type": "llm_backend",
        "requested": "groq",
        "active": "groq",
        "groq_available": True,
    }


async def test_update_settings_without_llm_backend_sends_no_status_and_keeps_preference(transport):
    session = make_two_engine_session(transport, groq=FakeLlm(), llm_backend="groq")
    await session.handle_text(
        '{"type": "update_settings", "target_turns": 7, "page_count": 5}'
    )
    assert transport.messages_of_type("llm_backend") == []
    assert session._llm_backend == "groq"


async def test_groq_story_replies_still_pass_the_safety_filter(transport):
    groq = FakeLlm(chunks=["He picked up the knife."])
    session = make_two_engine_session(transport, groq=groq, llm_backend="groq")
    await run_full_turn(session)
    assert transport.messages_of_type("response_text")[0]["text"] == SAFE_FALLBACK
```

- [ ] **Step 2: Run to verify they fail**

Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest tests/test_session.py -q -k "engine or groq or llm_backend or local"`
Expected: FAIL — `TypeError: SessionRunner.__init__() got an unexpected keyword argument 'groq_llm'`.

- [ ] **Step 3: Implement** in `server/tinytalk/session.py`.

3a. Add `encode_llm_backend` to the existing `from .protocol import (...)` block.

3b. `__init__` signature — add after `image_backend`:

```python
        image_backend: ImageGenBackend | None = None,
        groq_llm: LlmEngine | None = None,
        llm_backend: str = "ollama",
    ) -> None:
```

and directly after `self._llm = llm`:

```python
        self._llm = llm
        # Server-mode backend toggle (issue #25, docs/superpowers/specs/
        # 2026-09-22-server-llm-backend-toggle-design.md). self._llm stays
        # the local (Ollama) engine; _groq_llm exists only when
        # GROQ_API_KEY was set at startup. _llm_backend is the parent's
        # preference, resolved into _story_llm once per story by
        # _begin_story() -- never mid-story.
        self._groq_llm = groq_llm
        self._llm_backend = llm_backend
```

(These must be set before `__init__`'s own `self._begin_story()` call further down, which reads them.)

3c. Add a method just above `_begin_story`:

```python
    def _resolve_llm(self) -> tuple[LlmEngine, str]:
        """The engine the parent's current preference maps to: Groq only
        if it was asked for AND this server has one (GROQ_API_KEY set at
        startup), otherwise the local engine."""
        if self._llm_backend == "groq" and self._groq_llm is not None:
            return self._groq_llm, "groq"
        return self._llm, "ollama"
```

3d. At the end of `_begin_story`'s body (after `self._story_page_count = self._page_count`):

```python
        self._story_llm, self._story_llm_name = self._resolve_llm()
        if self._llm_backend == "groq" and self._story_llm_name != "groq":
            logger.warning(
                "groq requested but GROQ_API_KEY is not set on this server -- "
                "the next story will use ollama"
            )
        logger.info("story llm: %s", self._story_llm_name)
```

3e. Replace `handle_update_settings`'s signature and body tail. Signature:

```python
    async def handle_update_settings(
        self, target_turns: int, page_count: int, llm_backend: str | None = None
    ) -> None:
```

Keep the docstring and clamping. Right after the two clamping lines add:

```python
        if llm_backend is not None:
            self._llm_backend = llm_backend
```

Replace the existing trailing `logger.info("update_settings: ...")` with:

```python
        _, active = self._resolve_llm()
        logger.info(
            "update_settings: target_turns=%d, page_count=%d, llm_backend=%s "
            "(active=%s) (will apply to the next story)",
            self._target_turns,
            self._page_count,
            self._llm_backend,
            active,
        )
        if llm_backend is not None:
            await self._send_text_unbuffered(
                encode_llm_backend(self._llm_backend, active, self._groq_llm is not None)
            )
```

3f. Dispatch (~line 218):

```python
            case UpdateSettings(
                target_turns=target_turns, page_count=page_count, llm_backend=llm_backend
            ):
                await self.handle_update_settings(target_turns, page_count, llm_backend)
```

3g. In `_stream_llm_reply`, change `async for chunk in self._llm.stream_reply(messages):` to `async for chunk in self._story_llm.stream_reply(messages):`.

- [ ] **Step 4: Run the new tests, then the whole server suite**

Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest tests/test_session.py -q -k "engine or groq or llm_backend or local"`
Expected: PASS.
Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest -q`
Expected: all pass (baseline ~423 + new).

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/session.py server/tests/test_session.py
```
```bash
git commit -m "feat(server): resolve the story's LLM per story from the parent's preference (#25)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Session — rewrite uses the concluded story's engine and page count

**Files:**
- Modify: `server/tinytalk/session.py` (conclusion block in `_run_turn` ~line 940-955; `_run_rewrite` ~line 969; `_run_synced_rewrite` ~line 984)
- Test: `server/tests/test_session.py`

**Interfaces:**
- Consumes: `_story_llm`, `_story_page_count`, `_resolve_llm()` from Task 2.
- Produces: `_run_rewrite(self, story_id, turns, shared_facts, *, llm: LlmEngine, page_count: int)`.

- [ ] **Step 1: Write the failing tests** — append to `server/tests/test_session.py`:

```python
async def test_rewrite_uses_the_concluded_storys_engine_and_page_count(transport, monkeypatch):
    """_run_turn's conclusion block calls _begin_story() (next story's
    settings) BEFORE the rewrite starts -- the rewrite must still get the
    settings of the story that just ended, even if the parent changed
    them mid-story."""
    monkeypatch.setattr("tinytalk.session.story_store.save_story", _fake_save_story)
    captured = {}

    async def capturing_build_and_attach(story_id, turns, shared_facts, **kwargs):
        captured.update(kwargs)

    monkeypatch.setattr(
        "tinytalk.session.storybook.build_and_attach", capturing_build_and_attach
    )
    assert config.STORYBOOK_PAGE_COUNT != 3  # otherwise this test proves nothing
    ollama = FakeLlm(chunks_by_call=[["A fox found a shiny key. "], ["The end."]])
    groq = FakeLlm()
    session = make_two_engine_session(transport, ollama=ollama, groq=groq)

    await run_full_turn(session)  # story starts on ollama
    await session.handle_update_settings(7, 3, llm_backend="groq")
    await run_full_turn(session)  # "The end." concludes the story
    await session.wait_for_rewrite()

    assert captured["llm"] is ollama
    assert captured["page_count"] == config.STORYBOOK_PAGE_COUNT
    assert session._story_llm is groq  # the NEXT story gets the new choice
    assert session._story_page_count == 3


async def test_synced_demo_story_rewrite_uses_the_current_preference(monkeypatch, tmp_path):
    monkeypatch.setattr(
        story_store, "save_synced_story",
        lambda payload, **kw: tmp_path / f"20260909T120000-{payload['id']}.json",
    )
    captured = {}

    async def capturing_build_and_attach(story_id, turns, shared_facts, **kwargs):
        captured.update(kwargs)

    monkeypatch.setattr(
        "tinytalk.session.storybook.build_and_attach", capturing_build_and_attach
    )
    groq = FakeLlm()
    transport = FakeTransport()
    session = make_two_engine_session(transport, groq=groq, llm_backend="groq")
    story = {
        "id": "abc12345",
        "created_at": "2026-09-09T12:00:00+00:00",
        "turns": [{"speaker": "child", "text": "a fox", "interrupted": False}],
        "shared_facts": [],
    }
    await session.handle_text(json.dumps({"type": "sync_demo_stories", "stories": [story]}))
    await asyncio.sleep(0.01)  # let the fire-and-forget rewrite task run

    assert captured["llm"] is groq
```

(Same monkeypatch shape as the existing `test_handle_sync_demo_stories_saves_and_schedules_rewrite`; `story_store` is already imported at the top of `test_session.py`.)

- [ ] **Step 2: Run to verify they fail**

Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest tests/test_session.py -q -k "concluded_storys or synced_demo_story_rewrite_uses"`
Expected: FAIL — first test: `captured["llm"]` is the session-wide `_llm` path/`page_count == 3`; second: `captured["llm"]` is the Ollama fake.

- [ ] **Step 3: Implement** in `server/tinytalk/session.py`.

In `_run_turn`'s `if concluding:` block, replace:

```python
                self._conversation = Conversation()
                self._begin_story()
```

with:

```python
                # Captured BEFORE _begin_story() swaps in the next story's
                # settings: the rewrite belongs to the story that just
                # ended, so it must use that story's engine and page count
                # even if the parent changed either mid-story.
                story_llm = self._story_llm
                story_page_count = self._story_page_count
                self._conversation = Conversation()
                self._begin_story()
```

and the task creation:

```python
                    self._rewrite_task = asyncio.create_task(
                        self._run_rewrite(
                            story_id, turns, shared_facts,
                            llm=story_llm, page_count=story_page_count,
                        )
                    )
```

Replace `_run_rewrite`'s signature and its `build_and_attach` call:

```python
    async def _run_rewrite(
        self,
        story_id: str,
        turns: list,
        shared_facts: list[tuple[str, str]],
        *,
        llm: LlmEngine,
        page_count: int,
    ) -> None:
        try:
            await storybook.build_and_attach(
                story_id, turns, shared_facts, llm=llm,
                page_count=page_count,
                image_backend=self._image_backend,
            )
```

In `_run_synced_rewrite`, change `llm=self._llm,` to:

```python
                story_id, turns, shared_facts, llm=self._resolve_llm()[0],
```

- [ ] **Step 4: Run the new tests, then the whole server suite**

Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest tests/test_session.py -q -k "concluded_storys or synced_demo_story_rewrite_uses"`
Expected: PASS.
Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/session.py server/tests/test_session.py
```
```bash
git commit -m "fix(server): storybook rewrite uses the concluded story's engine and page count

Previously _begin_story() ran before the rewrite started, so a page-count
change made mid-story leaked into the story that was ending (#25).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: App wiring, startup banner, docs

**Files:**
- Modify: `server/tinytalk/app.py` (`build_session` ~line 129; `build_llm` ~line 136; `serve()` banner ~line 339 and engine construction ~line 368-377)
- Modify: `server/tinytalk/llm_groq.py` (module docstring's "Not intended for real use…" paragraph)
- Modify: `README.md` ("Running the server", after the Terminal 2 block ~line 234)
- Test: `server/tests/test_app.py` (lines 11, 71-79)

**Interfaces:**
- Consumes: `SessionRunner(..., groq_llm=, llm_backend=)` from Task 2.
- Produces: `build_llms() -> tuple[LlmEngine, LlmEngine | None]`; `build_session(transport, *, stt, llm, tts, image_backend=None, groq_llm=None, llm_backend="ollama")`.

- [ ] **Step 1: Update the tests** — in `server/tests/test_app.py` change the import `build_llm` → `build_llms` and replace the two `test_build_llm_*` tests with:

```python
def test_build_llms_without_a_groq_key_has_only_ollama(monkeypatch):
    monkeypatch.setattr(config, "GROQ_API_KEY", "")
    local, groq = build_llms()
    assert isinstance(local, OllamaLlm)
    assert groq is None


def test_build_llms_with_a_groq_key_builds_both(monkeypatch):
    monkeypatch.setattr(config, "GROQ_API_KEY", "test-key")
    local, groq = build_llms()
    assert isinstance(local, OllamaLlm)
    assert isinstance(groq, GroqLlm)


def test_build_session_passes_both_engines_and_the_startup_preference():
    groq = FakeLlm()
    session = build_session(
        NullTransport(), stt=FakeStt(), llm=FakeLlm(), tts=FakeTts(),
        groq_llm=groq, llm_backend="groq",
    )
    assert session._story_llm is groq
```

(`FakeLlm, FakeStt, FakeTts` are already imported from `conftest` at the top of `test_app.py`. No existing test asserts the banner or the `update_settings:` log text, so rewording both is safe.)

- [ ] **Step 2: Run to verify they fail**

Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest tests/test_app.py -q`
Expected: ImportError `build_llms`.

- [ ] **Step 3: Implement** in `server/tinytalk/app.py`.

Replace `build_session` and `build_llm`:

```python
def build_session(
    transport: Transport, *, stt: SttEngine, llm: LlmEngine, tts: TtsEngine,
    image_backend: ImageGenBackend | None = None,
    groq_llm: LlmEngine | None = None,
    llm_backend: str = "ollama",
) -> SessionRunner:
    return SessionRunner(
        transport=transport, stt=stt, llm=llm, tts=tts, image_backend=image_backend,
        groq_llm=groq_llm, llm_backend=llm_backend,
    )


def build_llms() -> tuple[LlmEngine, LlmEngine | None]:
    """The local engine always; Groq only if GROQ_API_KEY is set. Which
    one a story uses is the parent's choice from the phone (issue #25),
    defaulting to config.LLM_BACKEND -- see SessionRunner._resolve_llm()."""
    groq = GroqLlm() if config.GROQ_API_KEY else None
    return OllamaLlm(), groq
```

In `serve()`, replace the banner `logger.info(...)` call with:

```python
    logger.info(
        "listening on ws://%s:%s (default llm_backend=%s, ollama model=%s, "
        "think=%s, groq=%s)",
        config.SERVER_HOST,
        config.SERVER_PORT,
        config.LLM_BACKEND,
        config.OLLAMA_MODEL,
        # Only meaningful for the Ollama backend. Confirming this at a
        # glance (rather than only via request-body inspection) is exactly
        # what would have saved a round of real debugging on 2026-08-25.
        config.OLLAMA_THINK,
        f"available ({config.GROQ_MODEL})" if config.GROQ_API_KEY else "unavailable (no GROQ_API_KEY)",
    )
```

Replace `llm = build_llm()` with `llm, groq_llm = build_llms()`, and the `session = build_session(...)` line with:

```python
    session = build_session(
        NullTransport(), stt=stt, llm=llm, tts=tts, image_backend=image_backend,
        groq_llm=groq_llm, llm_backend=config.LLM_BACKEND,
    )
```

In `server/tinytalk/llm_groq.py`, replace the first two docstring paragraphs (from "For A/B-testing…" through "…by the household's own explicit choice.") with:

```
Originally added for A/B-testing whether LLM generation speed is the
actual bottleneck in reply latency. Now also a parent-chosen option for
real stories (issue #25): built only when GROQ_API_KEY is set, and used
for a story only when the parent picks it on the phone (default stays
local Ollama). Groq's inference hardware (LPUs, not GPUs) is routinely far
faster than local Metal/GPU inference for models in this class.

Privacy trade-off, chosen explicitly by the household: with Groq selected,
story conversation text (transcribed child speech and Elsie's replies)
goes to Groq's servers. Audio never leaves the Mac -- STT and TTS stay
local regardless.
```

In `README.md`, directly after the Terminal 2 code block, add:

````markdown
To let a parent switch stories to Groq's cloud LLM from the phone (hidden
"Elsie's Brain" card in Settings — long-press "UNDER THE HOOD"), start the
server with a free Groq key from https://console.groq.com/keys instead:

```bash
cd server && source .venv/bin/activate && GROQ_API_KEY=gsk_your_key_here python -m tinytalk.app
```

Without `GROQ_API_KEY` everything stays local and the phone's card says so.
With Groq picked, story text (not audio) goes to Groq's servers.
````

- [ ] **Step 4: Run the whole server suite**

Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add server/tinytalk/app.py server/tinytalk/llm_groq.py server/tests/test_app.py README.md
```
```bash
git commit -m "feat(server): build both LLM engines at startup; document Groq for home mode (#25)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: TinyTalkCore — protocol and coordinator

**Files:**
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/Protocol.swift` (`ClientMessage.updateSettings` ~line 55 + encode ~line 124; `ServerEvent` ~line 151; `decodeServerEvent` ~line 227)
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/SessionCoordinator.swift` (properties ~line 147; `updateSettings` ~line 462; event switch ~line 946; two `fatalError` lists ~lines 1017-1020 and 1462-1464)
- Modify: `ios/TinyTalkCore/Sources/TinyTalkCore/DemoConnection.swift` (~line 178)
- Test: `ios/TinyTalkCore/Tests/TinyTalkCoreTests/ProtocolTests.swift`, `SessionCoordinatorTests.swift`, `DemoProtocolParityTests.swift`

**Interfaces:**
- Consumes: wire shapes from Task 1.
- Produces: `ClientMessage.updateSettings(targetTurns: Int, pageCount: Int, llmBackend: String? = nil)`; `public struct LlmBackendStatus: Sendable, Equatable { requested: String; active: String; groqAvailable: Bool }`; `ServerEvent.llmBackend(LlmBackendStatus)`; `SessionCoordinator.latestLlmBackendStatus: LlmBackendStatus?`; `SessionCoordinator.updateSettings(targetTurns: Int, pageCount: Int, llmBackend: String? = nil) async`.

- [ ] **Step 1: Write the failing tests.**

Append inside the test class in `ProtocolTests.swift`:

```swift
    func testUpdateSettingsEncodesLlmBackendWhenPresent() {
        XCTAssertEqual(
            ClientMessage.updateSettings(targetTurns: 7, pageCount: 5, llmBackend: "groq").encode(),
            #"{"type":"update_settings","target_turns":7,"page_count":5,"llm_backend":"groq"}"#
        )
    }

    func testDecodesLlmBackendStatus() throws {
        let event = try decodeServerEvent(
            #"{"type": "llm_backend", "requested": "groq", "active": "ollama", "groq_available": false}"#
        )
        XCTAssertEqual(
            event,
            .llmBackend(LlmBackendStatus(requested: "groq", active: "ollama", groqAvailable: false))
        )
    }
```

(The existing `testUpdateSettingsEncodesBothValues` stays unchanged and must still pass — it proves the field is omitted when nil.)

Append inside the test class in `SessionCoordinatorTests.swift`, next to `testUpdateSettingsSendsTheControlFrame`:

```swift
    func testUpdateSettingsSendsTheLlmBackend() async {
        let connection = FakeConnection()
        let coordinator = SessionCoordinator(connection: connection, audio: FakeAudio(), vad: FakeVAD())
        let runLoop = Task { await coordinator.start() }

        await coordinator.updateSettings(targetTurns: 9, pageCount: 4, llmBackend: "groq")
        try? await Task.sleep(nanoseconds: 5_000_000)

        XCTAssertEqual(
            connection.sentMessages,
            [.updateSettings(targetTurns: 9, pageCount: 4, llmBackend: "groq")]
        )
        runLoop.cancel()
    }

    func testLlmBackendEventIsStoredAsLatestStatus() async {
        let connection = FakeConnection()
        let coordinator = SessionCoordinator(connection: connection, audio: FakeAudio(), vad: FakeVAD())
        let runLoop = Task { await coordinator.start() }

        connection.emit(.message(.llmBackend(
            LlmBackendStatus(requested: "groq", active: "groq", groqAvailable: true)
        )))
        try? await Task.sleep(nanoseconds: 10_000_000)

        let status = await coordinator.latestLlmBackendStatus
        XCTAssertEqual(status, LlmBackendStatus(requested: "groq", active: "groq", groqAvailable: true))
        runLoop.cancel()
    }
```

- [ ] **Step 2: Run to verify they fail (compile errors)**

From `/Users/jess/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/llm-backend-toggle/ios/TinyTalkCore`:
Run: `swift build --build-tests > /Users/jess/.claude/jobs/b6b5c819/tmp/swift-build.txt 2>&1`
Then: `grep -E "error:" /Users/jess/.claude/jobs/b6b5c819/tmp/swift-build.txt | head`
Expected: errors about `llmBackend` / `LlmBackendStatus` not existing.

- [ ] **Step 3: Implement.**

`Protocol.swift` — change the case declaration and its doc comment:

```swift
    /// Parent-adjustable settings from the Settings screen -- see
    /// protocol.py's UpdateSettings. Sent once after connecting and
    /// again whenever changed while connected. llmBackend ("ollama" /
    /// "groq", issue #25) is omitted from the JSON when nil, so the
    /// server keeps its current choice.
    case updateSettings(targetTurns: Int, pageCount: Int, llmBackend: String? = nil)
```

and its encode branch:

```swift
        case .updateSettings(let targetTurns, let pageCount, let llmBackend):
            if let llmBackend {
                return #"{"type":"update_settings","target_turns":\#(targetTurns),"page_count":\#(pageCount),"llm_backend":"\#(Self.jsonEscaped(llmBackend))"}"#
            }
            return #"{"type":"update_settings","target_turns":\#(targetTurns),"page_count":\#(pageCount)}"#
```

Just above `public enum ServerEvent`, add:

```swift
/// The server's reply to an updateSettings carrying llmBackend -- see
/// protocol.py's encode_llm_backend(). `active` is what the NEXT story
/// will use: "ollama" when "groq" was requested but the Mac has no
/// GROQ_API_KEY (then groqAvailable is false).
public struct LlmBackendStatus: Sendable, Equatable {
    public let requested: String
    public let active: String
    public let groqAvailable: Bool

    public init(requested: String, active: String, groqAvailable: Bool) {
        self.requested = requested
        self.active = active
        self.groqAvailable = groqAvailable
    }
}
```

Add as the last case of `ServerEvent`:

```swift
    /// See LlmBackendStatus. No turn_id, like storyList.
    case llmBackend(LlmBackendStatus)
```

In `decodeServerEvent`, before `default:`:

```swift
    case "llm_backend":
        return .llmBackend(LlmBackendStatus(
            requested: json["requested"] as? String ?? "ollama",
            active: json["active"] as? String ?? "ollama",
            groqAvailable: json["groq_available"] as? Bool ?? false
        ))
```

`SessionCoordinator.swift` — after `latestStoryDetail`'s declaration:

```swift
    /// The server's most recent llm_backend reply (issue #25), or nil if it
    /// never sent one (an older server, or not yet connected).
    public private(set) var latestLlmBackendStatus: LlmBackendStatus?
```

Replace `updateSettings`:

```swift
    public func updateSettings(targetTurns: Int, pageCount: Int, llmBackend: String? = nil) async {
        try? await connection.send(.updateSettings(targetTurns: targetTurns, pageCount: pageCount, llmBackend: llmBackend))
    }
```

In the event switch, after the `.message(.storyDetail(let detail))` case:

```swift
            case .message(.llmBackend(let status)):
                latestLlmBackendStatus = status
                continue
```

In BOTH `fatalError` case lists, change `.message(.pageImageDone), .message(.pageAudioDone):` to `.message(.pageImageDone), .message(.pageAudioDone), .message(.llmBackend):`.

`DemoConnection.swift` — change `case .updateSettings(let turns, let pages):` to:

```swift
        case .updateSettings(let turns, let pages, _):
            // llmBackend is ignored: away-from-home mode is always Groq,
            // and it never replies with an llm_backend event.
```

(keep the existing comment and body below it).

`DemoProtocolParityTests.swift` — change the `.updateSettings` reason string to:

```swift
            return .silentByDesign("takes effect on the next story; demo mode ignores llmBackend (always Groq), so unlike the real server it sends no llm_backend reply")
```

- [ ] **Step 4: Run the full package tests**

Run: `swift test > /Users/jess/.claude/jobs/b6b5c819/tmp/swift.txt 2>&1`
Then: `grep -E "Executed [0-9]+ tests|error:|failed" /Users/jess/.claude/jobs/b6b5c819/tmp/swift.txt | grep -v "ditty loop" | grep -v "send failed" | tail`
Expected: last `Executed N tests` line shows 260 tests (256 + 4 new), 0 failures (re-run once if only `testPageAudioDittyStopsOnStopPageAudio` fails — known flake).

- [ ] **Step 5: Commit**

```bash
git add ios/TinyTalkCore
```
```bash
git commit -m "feat(ios-core): llmBackend on updateSettings + llm_backend status event (#25)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: App — persisted choice and the "Elsie's Brain" card

**Files:**
- Modify: `ios/TinyTalkApp/TinyTalkApp/AppModel.swift` (properties ~line 37; `init` ~line 243; `updateSettings` call sites at ~480, ~615, ~961; poll loop reads ~1155 and assignments ~1218)
- Modify: `ios/TinyTalkApp/TinyTalkApp/SettingsView.swift` (`awayFromHomeCard` ~line 257; body reference ~line 59)

**Interfaces:**
- Consumes: `SessionCoordinator.updateSettings(targetTurns:pageCount:llmBackend:)`, `latestLlmBackendStatus`, `LlmBackendStatus` from Task 5.
- Produces: `AppModel.llmBackend: String` (`@Published`), `AppModel.serverLlmStatus: LlmBackendStatus?` (`@Published`), `AppModel.setLlmBackend(_ backend: String)`.

No unit-test target exists for the app (see Global Constraints); verification is a compile check here plus the on-device script.

- [ ] **Step 1: AppModel properties.** After `@Published var storybookPageCount: Int`:

```swift
    /// Which LLM the HOME SERVER uses for the next story -- "ollama" (local,
    /// default) or "groq" (issue #25, docs/superpowers/specs/
    /// 2026-09-22-server-llm-backend-toggle-design.md). Persisted like the
    /// story-length settings and sent alongside them on every
    /// updateSettings. Ignored by away-from-home mode (always Groq).
    @Published var llmBackend: String
    /// The server's latest reply about which backend it will actually use
    /// -- nil until it sends one. Mirrored from the coordinator by the poll
    /// loop, same as isRewriting.
    @Published var serverLlmStatus: LlmBackendStatus?
```

In `init()`, after the `storybookPageCount = ...` line:

```swift
        llmBackend = UserDefaults.standard.string(forKey: "llmBackend") ?? "ollama"
```

- [ ] **Step 2: Send it everywhere settings are sent.** Change all three existing calls:
- ~line 480 (`connect()`) and ~line 615 (`connectAwayFromHome()`): `coordinator.updateSettings(targetTurns: storyTurnCount, pageCount: storybookPageCount)` → `coordinator.updateSettings(targetTurns: storyTurnCount, pageCount: storybookPageCount, llmBackend: llmBackend)`
- ~line 961 (`updateStorySettings`): `coordinator.updateSettings(targetTurns: turnCount, pageCount: pageCount)` → `coordinator.updateSettings(targetTurns: turnCount, pageCount: pageCount, llmBackend: llmBackend)`

(Demo mode receives it too and ignores it — that keeps one code path.)

Add after `updateStorySettings`:

```swift
    /// What the "Elsie's Brain" picker calls. Same shape as
    /// updateStorySettings(): persists immediately, sends immediately only
    /// if connected (otherwise connect() sends it). Applies to the next
    /// story only -- the server locks each story's engine when it starts.
    func setLlmBackend(_ backend: String) {
        llmBackend = backend
        UserDefaults.standard.set(backend, forKey: "llmBackend")
        guard isConnected, let coordinator else { return }
        Task {
            await coordinator.updateSettings(
                targetTurns: storyTurnCount, pageCount: storybookPageCount, llmBackend: backend
            )
        }
    }
```

- [ ] **Step 3: Poll loop.** Next to `let storyDetail = await coordinator.latestStoryDetail` add:

```swift
                let llmStatus = await coordinator.latestLlmBackendStatus
```

and next to `self.isRewriting = rewriting` add:

```swift
                    self.serverLlmStatus = llmStatus
```

- [ ] **Step 4: SettingsView card.** In `awayFromHomeCard`, replace the header `Text("AWAY FROM HOME")` block with:

```swift
                Text("ELSIE'S BRAIN")
                    .font(TTA.Typography.display(12))
                    .tracking(1.5)
                    .foregroundColor(TTA.Palette.inkSoft)

                Text("At home, Elsie thinks with:")
                    .font(TTA.Typography.body(12.5, weight: .medium))
                    .foregroundColor(TTA.Palette.inkSoft)

                Picker(
                    "At home, Elsie thinks with",
                    selection: Binding(
                        get: { model.llmBackend },
                        set: { model.setLlmBackend($0) }
                    )
                ) {
                    Text("Mac (local)").tag("ollama")
                    Text("Groq cloud").tag("groq")
                }
                .pickerStyle(.segmented)

                Text("Applies from the next story. With Groq, story text goes to Groq's cloud; listening and voices stay on your Mac. Needs GROQ_API_KEY set on the Mac.")
                    .font(TTA.Typography.body(12.5))
                    .foregroundColor(TTA.Palette.inkSoft)

                if model.isConnected, !model.awayFromHomeEnabled, let status = model.serverLlmStatus {
                    Text(llmStatusText(status))
                        .font(TTA.Typography.body(11.5))
                        .foregroundColor(
                            status.requested != status.active ? TTA.Palette.alert : TTA.Palette.inkSoft
                        )
                }

                Divider().padding(.vertical, 4)

                Text("Away from home")
                    .font(TTA.Typography.body(12.5, weight: .medium))
                    .foregroundColor(TTA.Palette.inkSoft)
```

(The existing "For demos only, away from the home WiFi…" text and every control after it stay exactly as they are.)

Add a helper inside `SettingsView`, after `awayFromHomeCard`:

```swift
    private func llmStatusText(_ status: LlmBackendStatus) -> String {
        let active = status.active == "groq" ? "Groq cloud" : "Mac (local)"
        if status.requested == "groq" && !status.groqAvailable {
            return "Mac will use: \(active) -- no Groq key set on the Mac"
        }
        return "Mac will use: \(active)"
    }
```

If `TTA.Typography.body(_:weight:)` doesn't accept `.medium` in that position, match the existing call in `StoryView.swift` (`TTA.Typography.body(10, weight: .medium)`) — it does there.

- [ ] **Step 5: Compile check**

From the worktree root, if `ios/TinyTalkApp/Local.xcconfig` doesn't exist: `cp ios/TinyTalkApp/Local.xcconfig.example ios/TinyTalkApp/Local.xcconfig`
Run: `xcodebuild -project ios/TinyTalkApp/TinyTalkApp.xcodeproj -scheme TinyTalkApp -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build > /Users/jess/.claude/jobs/b6b5c819/tmp/xcode.txt 2>&1`
Then: `grep -E "error:|BUILD (SUCCEEDED|FAILED)" /Users/jess/.claude/jobs/b6b5c819/tmp/xcode.txt | tail`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add ios/TinyTalkApp/TinyTalkApp/AppModel.swift ios/TinyTalkApp/TinyTalkApp/SettingsView.swift
```
```bash
git commit -m "feat(ios): Elsie's Brain card -- pick the home server's LLM for the next story (#25)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## After all tasks: on-device verification (household)

Not agent-executable — goes into the PR description with full paths per CLAUDE.md. Includes the spec's `reasoning_effort` check:

1. Start Ollama, then the server from `~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/llm-backend-toggle/server` with `GROQ_API_KEY` set. Banner shows `groq=available (openai/gpt-oss-20b)`.
2. Rebuild the app from `~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/llm-backend-toggle/ios/TinyTalkApp/TinyTalkApp.xcodeproj`. Settings → long-press "UNDER THE HOOD" → Elsie's Brain → Groq cloud. Server log: `update_settings: … llm_backend=groq (active=groq)`; card: "Mac will use: Groq cloud".
3. New story. Log: `story llm: groq`; noticeably faster first reply.
4. Finish the story. Check the log's `story … page N scene prompt: '…'` lines. **If any are `''`**, the Phase 2 `reasoning_effort` gotcha applies server-side too → follow-up: add an optional `reasoning_effort` param to `GroqLlm` and pass `"low"` from `_extract_scene_prompt` (spec, "Groq `reasoning_effort`").
5. Mid-story, switch back to Mac (local): no new `story llm:` line until the next story; that story's storybook completes.
6. Restart without `GROQ_API_KEY`, pick Groq: card shows "no Groq key set on the Mac" in the alert color; story runs on Ollama.

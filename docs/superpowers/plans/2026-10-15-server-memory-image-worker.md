# Server Memory: Short-Lived Image Worker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stable Diffusion runs in a short-lived child process for each picture pass, so its GPU/MPS memory returns to macOS when the pass ends and an SD crash can't take down the live server (issue #75).

**Architecture:** A new `image_worker.py` holds an `ImageWorker` that spawns a child process (`multiprocessing` "spawn"), talks to it over a `Pipe` using only prompts and file paths, and kills it on close. `illustrations.generate_and_attach` runs its per-page image loop against a worker built by an injected `image_worker_factory`, which replaces `image_backend` at every hop (`app.py` → `session.py` → `storybook.py` → `illustrations.py`). `image_gen.py`'s `StableDiffusionBackend` is unchanged and now only ever runs inside the child.

**Tech Stack:** Python 3.12, `multiprocessing` (spawn), pytest + pytest-asyncio (`asyncio_mode = "auto"`), Pillow.

**Spec:** `docs/superpowers/specs/2026-09-25-server-memory-image-worker-design.md`. Read it first; the plan implements it section by section.

## Global Constraints

- **Worktree:** `~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/server-memory-image-worker` (branch `worktree-server-memory-image-worker`). Run every command from its `server/` directory. Worktrees have no `.venv`; use main's interpreter, which is editable-installed from main but tests *this* worktree's code because `-m` puts the cwd first on `sys.path`:
  `PY=/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python`
  (steps below write the full path out). Never `pip install` anything; this plan adds no dependencies.
- **Baseline:** `$PY -m pytest -q -p no:cacheprovider` → **501 passed** on this branch before any change (after merging `origin/main` 2026-10-15). Run it from `server/`, not the worktree root; from the root the tests mis-resolve and ~209 fail.
- **Kid-safety pipeline is unchanged:** do not edit `server/tinytalk/image_gen.py` (model, LoRA, IP-Adapter, negative prompt, built-in safety checker). The child must call the existing `StableDiffusionBackend` exactly as today.
- **Start method is `spawn`, never `fork`** (forking a process that already holds MLX, Metal and threads is unsafe on macOS).
- **Only prompts and file paths cross the pipe.** The child writes each PNG itself; no image bytes go over the pipe.
- **Config name and default:** `TINYTALK_IMAGE_WORKER_PAGE_TIMEOUT`, read into `config.IMAGE_WORKER_PAGE_TIMEOUT`, default `300.0` seconds per page request.
- **Log lines (exact text, the on-device check greps for them):** `image worker: started (pid N)`, `image worker: first page took X s (includes model load)`, `image worker: exited (code C) after X s`, `image worker died (...)`.
- **Pet-project scope:** no worker restarts mid-pass, no retries, no worker pool. A dead worker means the current and remaining pages get no picture.
- **Ordering is preserved:** scene-prompt extraction and `_release_ollama_memory()` still run before the worker starts.
- **Commits:** small and frequent. End every commit message with these two lines:
  `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01UN6MTdnWqmagVqFqmwTDxr`

## Review Focus

Failure modes the spec implies that no happy-path test would exercise, most likely first. Each one is pinned by a test in the task named on its line.

1. **Two stories back to back:** the second pass must get a fresh worker and the first must be fully gone (not alive, different pid). → Task 1 `test_back_to_back_workers_are_separate_processes`.
2. **Missing reference file:** if page 0's PNG is gone when page 1 asks for it, that page degrades to "error" with no crash and no hang. → Task 1 `test_missing_reference_file_degrades_that_page`.
3. **Non-ASCII prompt:** a prompt like `a fox 🦊 in a café` arrives intact through the pipe. → Task 1 `test_unicode_prompt_arrives_intact`.
4. **Orphaned child:** a worker whose parent vanished (pipe closed) exits by itself instead of lingering with GBs of memory. → Task 1 `test_worker_main_exits_when_the_pipe_closes`.
5. **Misuse of the lifecycle:** `close()` twice, `close()` before `start()`, and `generate_to_file` after `close()` must return `worker_dead`/no-op, never hang or raise. → Task 1 `test_close_is_idempotent_and_generate_after_close_is_worker_dead`.

---

### Task 1: `ImageWorker` (the worker process) and its config

**Files:**
- Modify: `server/tinytalk/config.py` (add `IMAGE_WORKER_PAGE_TIMEOUT` right after `IMAGE_GEN_NUM_INFERENCE_STEPS`)
- Create: `server/tinytalk/image_worker.py`
- Create: `server/tests/image_worker_fakes.py` (fake backends the spawned child imports, plus the in-process adapter later tasks reuse)
- Create: `server/tests/test_image_worker.py`
- Modify: `server/tests/test_config.py` (append one test)

**Interfaces:**
- Produces (Task 2 and 3 rely on these exact names):
  - `tinytalk.image_worker.PageResult(kind: str, detail: str = "")`, a frozen dataclass.
  - Constants `OK = "ok"`, `FLAGGED = "flagged"`, `ERROR = "error"`, `WORKER_DEAD = "worker_dead"`.
  - `PageImageWorker` Protocol: `start() -> None`, `generate_to_file(prompt: str, reference_path: Path | None, out_path: Path) -> PageResult`, `close() -> None`.
  - `ImageWorkerFactory = Callable[[], PageImageWorker]`.
  - `ImageWorker(backend_factory: str, *, page_timeout: float | None = None)` implementing the Protocol, also usable as a context manager.
  - `build_image_worker() -> ImageWorker`: the production factory (backend `"tinytalk.image_worker:build_stable_diffusion_backend"`).
  - `tests/image_worker_fakes.py`: `InProcessImageWorker(backend)` (implements `PageImageWorker` by calling `backend.generate(prompt, reference_image=...)` in-process) and the spawn-target factories `make_ok_backend`, `make_flagged_backend`, `make_raising_backend`, `make_crashing_backend`, `make_hanging_backend`, `make_prompt_width_backend`.

- [ ] **Step 1: Write the config test (fails: attribute missing)**

Append to `server/tests/test_config.py`:

```python
def test_image_worker_page_timeout_defaults_to_five_minutes():
    # Issue #75: the per-page allowance for the short-lived Stable
    # Diffusion worker. The first page's allowance includes the model
    # load, so it must be generous.
    assert config.IMAGE_WORKER_PAGE_TIMEOUT == 300.0
```

- [ ] **Step 2: Run it to verify it fails**

Run (from `server/`): `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_config.py::test_image_worker_page_timeout_defaults_to_five_minutes`
Expected: FAIL with `AttributeError: module 'tinytalk.config' has no attribute 'IMAGE_WORKER_PAGE_TIMEOUT'`.

- [ ] **Step 3: Add the config value**

In `server/tinytalk/config.py`, immediately after the `IMAGE_GEN_NUM_INFERENCE_STEPS = int(...)` statement, add:

```python
# Issue #75: Stable Diffusion runs in a short-lived worker process per
# picture pass (image_worker.py). This is how long the parent waits for
# ONE page's reply before killing the worker and treating the rest of the
# pass as failed. Generous on purpose: the first page's wait includes the
# multi-second torch import and model load, on a Mac that may be swapping.
IMAGE_WORKER_PAGE_TIMEOUT = float(os.environ.get("TINYTALK_IMAGE_WORKER_PAGE_TIMEOUT", "300"))
```

- [ ] **Step 4: Run the config test to verify it passes**

Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_config.py::test_image_worker_page_timeout_defaults_to_five_minutes`
Expected: PASS.

- [ ] **Step 5: Write the fake backends and in-process adapter**

Create `server/tests/image_worker_fakes.py`. It has no torch dependency, and because `tests/` has no `__init__.py`, pytest puts this directory on `sys.path`, which a spawned child inherits, so `"image_worker_fakes:make_ok_backend"` is importable in the child.

```python
"""Fakes for the short-lived Stable Diffusion worker (issue #75).

Two kinds live here:
- spawn-target backend factories (`make_*_backend`): a spawned child
  process imports these by name ("image_worker_fakes:make_ok_backend"), so
  they must stay importable at module top level and need no torch.
- InProcessImageWorker: lets test_illustrations.py / test_storybook.py keep
  their simple in-process fake backends while exercising the new
  PageImageWorker interface, with no process spawn.
"""

from __future__ import annotations

import os
import signal
import time
from pathlib import Path

from PIL import Image

from tinytalk.image_worker import ERROR, FLAGGED, OK, PageResult


class _OkBackend:
    """Red 8x8 image when there is no reference, blue when there is one --
    so a test can tell from the saved PNG whether the reference arrived."""

    def generate(self, prompt, *, reference_image):
        color = (255, 0, 0) if reference_image is None else (0, 0, 255)
        return Image.new("RGB", (8, 8), color=color)


class _FlaggedBackend:
    def generate(self, prompt, *, reference_image):
        return None


class _RaisingBackend:
    def generate(self, prompt, *, reference_image):
        raise RuntimeError("simulated MPS allocation failure")


class _CrashingBackend:
    def generate(self, prompt, *, reference_image):
        os.kill(os.getpid(), signal.SIGSEGV)


class _HangingBackend:
    def generate(self, prompt, *, reference_image):
        time.sleep(60)


class _PromptWidthBackend:
    """Image width == len(prompt), so a test can prove the prompt arrived
    intact (including non-ASCII) through the pipe."""

    def generate(self, prompt, *, reference_image):
        return Image.new("RGB", (len(prompt), 1), color=(0, 255, 0))


def make_ok_backend():
    return _OkBackend()


def make_flagged_backend():
    return _FlaggedBackend()


def make_raising_backend():
    return _RaisingBackend()


def make_crashing_backend():
    return _CrashingBackend()


def make_hanging_backend():
    return _HangingBackend()


def make_prompt_width_backend():
    return _PromptWidthBackend()


class InProcessImageWorker:
    """Implements PageImageWorker by calling an in-process fake backend
    (anything with generate(prompt, *, reference_image)). Records
    started/closed so tests can assert the lifecycle."""

    def __init__(self, backend) -> None:
        self.backend = backend
        self.started = False
        self.closed = False

    def start(self) -> None:
        self.started = True

    def close(self) -> None:
        self.closed = True

    def generate_to_file(self, prompt: str, reference_path: Path | None, out_path: Path) -> PageResult:
        reference = None
        if reference_path is not None:
            with Image.open(reference_path) as opened:
                reference = opened.copy()
        try:
            image = self.backend.generate(prompt, reference_image=reference)
        except Exception as exc:  # noqa: BLE001 - mirrors the real worker's "error" reply
            return PageResult(ERROR, repr(exc))
        if image is None:
            return PageResult(FLAGGED)
        image.save(out_path)
        return PageResult(OK)
```

- [ ] **Step 6: Write the failing worker tests**

Create `server/tests/test_image_worker.py`:

```python
import multiprocessing
import threading
from pathlib import Path

from PIL import Image

from tinytalk.image_worker import (
    ERROR,
    FLAGGED,
    OK,
    WORKER_DEAD,
    ImageWorker,
    PageResult,
    _worker_main,
)

OK_BACKEND = "image_worker_fakes:make_ok_backend"


def _pixel(path: Path):
    with Image.open(path) as image:
        return image.getpixel((0, 0))


def test_ok_page_writes_the_png_and_reports_ok(tmp_path):
    out = tmp_path / "page-0.png"
    with ImageWorker(OK_BACKEND, page_timeout=60) as worker:
        result = worker.generate_to_file("a fox", None, out)
    assert result == PageResult(OK, "")
    assert _pixel(out) == (255, 0, 0)  # red: no reference given


def test_reference_path_reaches_the_backend(tmp_path):
    first = tmp_path / "page-0.png"
    second = tmp_path / "page-1.png"
    with ImageWorker(OK_BACKEND, page_timeout=60) as worker:
        worker.generate_to_file("a fox", None, first)
        result = worker.generate_to_file("a fox again", first, second)
    assert result.kind == OK
    assert _pixel(second) == (0, 0, 255)  # blue: a reference image arrived


def test_flagged_page_reports_flagged_and_writes_nothing(tmp_path):
    out = tmp_path / "page-0.png"
    with ImageWorker("image_worker_fakes:make_flagged_backend", page_timeout=60) as worker:
        result = worker.generate_to_file("a fox", None, out)
    assert result.kind == FLAGGED
    assert not out.exists()


def test_backend_exception_is_an_error_reply_and_the_worker_survives(tmp_path):
    with ImageWorker("image_worker_fakes:make_raising_backend", page_timeout=60) as worker:
        first = worker.generate_to_file("a fox", None, tmp_path / "a.png")
        second = worker.generate_to_file("a fox", None, tmp_path / "b.png")
    assert first.kind == ERROR and "simulated MPS allocation failure" in first.detail
    assert second.kind == ERROR  # still answering: one bad page doesn't kill the worker


def test_crash_is_reported_as_worker_dead_with_the_signal(tmp_path):
    with ImageWorker("image_worker_fakes:make_crashing_backend", page_timeout=60) as worker:
        result = worker.generate_to_file("a fox", None, tmp_path / "a.png")
        later = worker.generate_to_file("a fox", None, tmp_path / "b.png")
    assert result.kind == WORKER_DEAD
    assert "SIGSEGV" in result.detail
    assert later.kind == WORKER_DEAD  # the rest of the pass fails fast, no new spawn
    # Reaching this line at all is the point: the parent (this test process)
    # survived the child's segfault.


def test_hang_past_the_timeout_kills_the_worker(tmp_path):
    worker = ImageWorker("image_worker_fakes:make_hanging_backend", page_timeout=1.5)
    worker.start()
    process = worker._process
    try:
        result = worker.generate_to_file("a fox", None, tmp_path / "a.png")
    finally:
        worker.close()
    assert result.kind == WORKER_DEAD
    assert "no reply" in result.detail
    assert not process.is_alive()


def test_close_stops_the_child_process(tmp_path):
    worker = ImageWorker(OK_BACKEND, page_timeout=60)
    worker.start()
    process = worker._process
    assert process.is_alive()
    worker.close()
    assert not process.is_alive()


# --- Review Focus (see the plan header) ---------------------------------


def test_back_to_back_workers_are_separate_processes(tmp_path):
    first = ImageWorker(OK_BACKEND, page_timeout=60)
    first.start()
    first_process = first._process
    first.generate_to_file("a fox", None, tmp_path / "a.png")
    first.close()

    second = ImageWorker(OK_BACKEND, page_timeout=60)
    second.start()
    second_process = second._process
    try:
        result = second.generate_to_file("a fox", None, tmp_path / "b.png")
    finally:
        second.close()

    assert result.kind == OK
    assert first_process.pid != second_process.pid
    assert not first_process.is_alive()
    assert not second_process.is_alive()


def test_missing_reference_file_degrades_that_page(tmp_path):
    with ImageWorker(OK_BACKEND, page_timeout=60) as worker:
        result = worker.generate_to_file(
            "a fox", tmp_path / "does-not-exist.png", tmp_path / "b.png"
        )
        after = worker.generate_to_file("a fox", None, tmp_path / "c.png")
    assert result.kind == ERROR
    assert after.kind == OK  # and the worker keeps going


def test_unicode_prompt_arrives_intact(tmp_path):
    prompt = "a fox 🦊 in a café"
    with ImageWorker("image_worker_fakes:make_prompt_width_backend", page_timeout=60) as worker:
        result = worker.generate_to_file(prompt, None, tmp_path / "a.png")
    assert result.kind == OK
    with Image.open(tmp_path / "a.png") as image:
        assert image.width == len(prompt)


def test_worker_main_exits_when_the_pipe_closes():
    # An orphaned worker (parent killed) sees EOF on its pipe and must exit
    # by itself rather than linger holding gigabytes. Run the child's loop
    # in a thread here, with real Pipe ends, and close the parent's end.
    parent_conn, child_conn = multiprocessing.Pipe()
    finished = threading.Event()

    def run():
        _worker_main(child_conn, OK_BACKEND)
        finished.set()

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    parent_conn.close()
    assert finished.wait(timeout=10), "worker loop did not exit on EOF"


def test_close_is_idempotent_and_generate_after_close_is_worker_dead(tmp_path):
    never_started = ImageWorker(OK_BACKEND, page_timeout=60)
    never_started.close()  # before start(): a no-op, not an error
    assert never_started.generate_to_file("a fox", None, tmp_path / "a.png").kind == WORKER_DEAD

    worker = ImageWorker(OK_BACKEND, page_timeout=60)
    worker.start()
    worker.close()
    worker.close()  # twice: still fine
    assert worker.generate_to_file("a fox", None, tmp_path / "b.png").kind == WORKER_DEAD
```

- [ ] **Step 7: Run the worker tests to verify they fail**

Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_image_worker.py`
Expected: collection ERROR, `ModuleNotFoundError: No module named 'tinytalk.image_worker'`.

- [ ] **Step 8: Write the worker module**

Create `server/tinytalk/image_worker.py`:

```python
"""A short-lived worker process for Stable Diffusion (issue #75).

Why a separate process: PyTorch's MPS backend does not reliably hand GPU
memory back to the OS, so loading Stable Diffusion in the server's own
process kept gigabytes resident for the server's whole lifetime and left
the 16GB Mac swapping, which slowed live turns. Run in a child process
for one picture pass, ALL of that memory (GPU heaps and the MPS cache
included) returns to macOS when the child exits. An SD crash also kills
only the child. See docs/superpowers/specs/2026-09-25-server-memory-image-worker-design.md.

Protocol (over one multiprocessing.Pipe): the parent sends
(prompt, reference_path_or_None, out_path) tuples as strings, or None to
quit; the child replies (kind, detail). Only text crosses the pipe: the
child writes each PNG itself.
"""

from __future__ import annotations

import importlib
import logging
import multiprocessing
import signal
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from . import config

logger = logging.getLogger(__name__)

OK = "ok"
FLAGGED = "flagged"
ERROR = "error"
WORKER_DEAD = "worker_dead"

# How often the parent wakes up while waiting for a reply, to notice a
# dead child or a close() from another thread. Not a latency cost: poll()
# returns the instant a reply arrives.
_POLL_SLICE_SECONDS = 0.25
_QUIT_JOIN_SECONDS = 5.0
_KILL_JOIN_SECONDS = 2.0


@dataclass(frozen=True)
class PageResult:
    kind: str
    detail: str = ""


class PageImageWorker(Protocol):
    def start(self) -> None: ...

    def generate_to_file(
        self, prompt: str, reference_path: Path | None, out_path: Path
    ) -> PageResult: ...

    def close(self) -> None: ...


ImageWorkerFactory = Callable[[], PageImageWorker]


def build_stable_diffusion_backend():
    """The production backend factory, run INSIDE the child. Imported
    lazily so the parent never pays the torch import."""
    from .image_gen import StableDiffusionBackend

    return StableDiffusionBackend()


def _worker_main(conn, backend_factory: str) -> None:
    """The child's whole life. `backend_factory` is "module:function"."""
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )
    child_logger = logging.getLogger("tinytalk.image_worker.child")
    module_name, _, function_name = backend_factory.partition(":")
    backend = getattr(importlib.import_module(module_name), function_name)()
    first_request = True
    while True:
        try:
            request = conn.recv()
        except (EOFError, OSError):
            return  # the parent is gone: exit instead of lingering
        if request is None:
            return
        prompt, reference_path, out_path = request
        started = time.monotonic()
        try:
            reference = None
            if reference_path is not None:
                from PIL import Image

                with Image.open(reference_path) as opened:
                    reference = opened.copy()
            image = backend.generate(prompt, reference_image=reference)
            if image is None:
                reply = (FLAGGED, "")
            else:
                image.save(out_path)
                reply = (OK, "")
        except Exception as exc:  # noqa: BLE001 - one bad page must not kill the worker
            child_logger.exception("page generation failed")
            reply = (ERROR, repr(exc))
        if first_request:
            first_request = False
            child_logger.info(
                "image worker: first page took %.1f s (includes model load)",
                time.monotonic() - started,
            )
        try:
            conn.send(reply)
        except (BrokenPipeError, OSError):
            return


class ImageWorker:
    """Parent-side handle to one worker process. start() / close() are
    blocking (call them via asyncio.to_thread from async code), and so is
    generate_to_file()."""

    def __init__(self, backend_factory: str, *, page_timeout: float | None = None) -> None:
        self._backend_factory = backend_factory
        self._page_timeout = (
            config.IMAGE_WORKER_PAGE_TIMEOUT if page_timeout is None else page_timeout
        )
        self._process = None
        self._conn = None
        self._started_at = 0.0
        self._closed = False
        self._dead_reason: str | None = None

    def __enter__(self) -> ImageWorker:
        self.start()
        return self

    def __exit__(self, *exc_info) -> None:
        self.close()

    def start(self) -> None:
        # spawn, never fork: forking a process that already holds MLX,
        # Metal and threads is unsafe on macOS.
        context = multiprocessing.get_context("spawn")
        parent_conn, child_conn = context.Pipe()
        process = context.Process(
            target=_worker_main,
            args=(child_conn, self._backend_factory),
            daemon=True,
            name="image-worker",
        )
        process.start()
        child_conn.close()  # the parent only needs its own end
        self._process = process
        self._conn = parent_conn
        self._started_at = time.monotonic()
        logger.info("image worker: started (pid %s)", process.pid)

    def generate_to_file(
        self, prompt: str, reference_path: Path | None, out_path: Path
    ) -> PageResult:
        if self._dead_reason is not None:
            return PageResult(WORKER_DEAD, self._dead_reason)
        if self._process is None or self._closed:
            return PageResult(WORKER_DEAD, "worker is not running")
        try:
            self._conn.send(
                (prompt, None if reference_path is None else str(reference_path), str(out_path))
            )
        except (BrokenPipeError, OSError) as exc:
            return self._mark_dead(f"could not send the request: {exc}")
        deadline = time.monotonic() + self._page_timeout
        while True:
            if self._closed:
                return self._mark_dead("worker was closed mid-request")
            try:
                if self._conn.poll(_POLL_SLICE_SECONDS):
                    kind, detail = self._conn.recv()
                    return PageResult(kind, detail)
                if not self._process.is_alive():
                    # It may have replied just before exiting: look once more.
                    if self._conn.poll(0):
                        kind, detail = self._conn.recv()
                        return PageResult(kind, detail)
                    return self._mark_dead(self._describe_exit())
            except (EOFError, OSError):
                return self._mark_dead(self._describe_exit())
            if time.monotonic() > deadline:
                return self._mark_dead(
                    f"no reply within {self._page_timeout:g} s -- killed the worker"
                )

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        process = self._process
        if process is None:
            return
        try:
            self._conn.send(None)  # ask it to quit
        except (BrokenPipeError, OSError):
            pass
        process.join(_QUIT_JOIN_SECONDS)
        if process.is_alive():
            process.terminate()
            process.join(_KILL_JOIN_SECONDS)
        if process.is_alive():
            process.kill()
            process.join(_KILL_JOIN_SECONDS)
        logger.info(
            "image worker: exited (code %s) after %.1f s",
            process.exitcode,
            time.monotonic() - self._started_at,
        )

    def _describe_exit(self) -> str:
        process = self._process
        process.join(0.5)
        code = process.exitcode
        if code is None:
            return "worker stopped answering"
        if code < 0:
            try:
                return f"exit code {code} ({signal.Signals(-code).name})"
            except ValueError:
                return f"exit code {code}"
        return f"exit code {code}"

    def _mark_dead(self, reason: str) -> PageResult:
        self._dead_reason = reason
        logger.error("image worker died (%s)", reason)
        process = self._process
        if process is not None and process.is_alive():
            process.kill()
            process.join(_KILL_JOIN_SECONDS)
        return PageResult(WORKER_DEAD, reason)


def build_image_worker() -> ImageWorker:
    """The production image_worker_factory (passed down from app.py)."""
    return ImageWorker("tinytalk.image_worker:build_stable_diffusion_backend")
```

- [ ] **Step 9: Run the worker tests to verify they pass**

Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_image_worker.py`
Expected: 12 passed, in roughly 10–30 s (each spawn imports Pillow and the fakes). If `ModuleNotFoundError: image_worker_fakes` appears in the child's stderr, the child did not inherit `tests/` on `sys.path`; fix by running from `server/` and confirming `tests/conftest.py` exists (pytest's rootdir-based path insertion is what makes it importable).

- [ ] **Step 10: Run the full suite**

Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest -q -p no:cacheprovider`
Expected: 501 + 13 new = **514 passed** (12 worker tests + 1 config test).

- [ ] **Step 11: Commit**

```bash
git add server/tinytalk/config.py server/tinytalk/image_worker.py server/tests/image_worker_fakes.py server/tests/test_image_worker.py server/tests/test_config.py
git commit -m "feat(server): short-lived image worker process (#75)

ImageWorker spawns a child that runs the existing StableDiffusionBackend,
talks to it over a Pipe using only prompts and file paths, and kills it on
close, so Stable Diffusion's GPU memory returns to macOS after each
picture pass. Not wired in yet.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UN6MTdnWqmagVqFqmwTDxr"
```

---

### Task 2: Run the illustration pass against a worker

**Files:**
- Modify: `server/tinytalk/illustrations.py` (imports; delete `_generate_and_save`; replace the image loop; rename the parameter)
- Modify: `server/tests/test_illustrations.py`

**Interfaces:**
- Consumes (from Task 1): `PageResult`, `OK`, `FLAGGED`, `ERROR`, `WORKER_DEAD`, `ImageWorkerFactory`, and `tests/image_worker_fakes.InProcessImageWorker`.
- Produces: `illustrations.generate_and_attach(story_id: str, pages: list[dict], *, llm: LlmEngine, image_worker_factory: ImageWorkerFactory, stories_dir: Path = STORIES_DIR) -> None` (the `image_backend` parameter is gone).

- [ ] **Step 1: Convert the existing tests to the new parameter (they will fail)**

In `server/tests/test_illustrations.py`:

1. Add to the imports at the top: `import asyncio`, `import threading`, `import pytest`, `from image_worker_fakes import InProcessImageWorker`, and `from tinytalk.image_worker import ERROR, WORKER_DEAD, PageResult`.
2. In every `generate_and_attach(...)` call, replace the argument `image_backend=X` with `image_worker_factory=lambda: InProcessImageWorker(X)`, where `X` is the same expression. Concretely (the variable is evaluated once per call, which is fine because each pass builds one worker):
   - `image_backend=backend` → `image_worker_factory=lambda: InProcessImageWorker(backend)` (tests: one-image-per-page, reference, flagged, every-page-flagged, llm-failure, backend-failure, ordering)
   - `image_backend=FakeImageBackend()` → `image_worker_factory=lambda: InProcessImageWorker(FakeImageBackend())` (test: prompt-extraction uses each page's text)
   - `image_backend=RecordingBackend()` → `image_worker_factory=lambda: InProcessImageWorker(RecordingBackend())` (test: pending status)
3. No assertion changes are needed: `backend.calls[i][1]` is `None` for page 0 and a loaded PIL image (not `None`) for later pages, exactly what the reference tests assert.
4. Update the stale comment in `test_llm_failure_on_one_page_degrades_only_that_page` that says "image_backend.generate() returning None" to say "the worker returning a flagged result".

- [ ] **Step 2: Add the new tests (they fail with the old signature)**

Append to `server/tests/test_illustrations.py`:

```python
class DyingWorker(InProcessImageWorker):
    """Behaves normally for the first `alive_for` pages, then reports
    worker_dead for every later request (a crashed child)."""

    def __init__(self, backend, alive_for: int) -> None:
        super().__init__(backend)
        self.alive_for = alive_for
        self.requests = 0

    def generate_to_file(self, prompt, reference_path, out_path):
        self.requests += 1
        if self.requests > self.alive_for:
            return PageResult(WORKER_DEAD, "exit code -11 (SIGSEGV)")
        return super().generate_to_file(prompt, reference_path, out_path)


async def test_worker_dying_mid_pass_leaves_earlier_pages_and_blanks_the_rest(tmp_path):
    pages = [{"text": f"Page {n}."} for n in range(1, 5)]
    story_id = _saved_story_with_pages(tmp_path, pages)
    worker = DyingWorker(FakeImageBackend(), alive_for=2)

    await generate_and_attach(
        story_id, pages, llm=FakeExtractionLlm(), image_worker_factory=lambda: worker,
        stories_dir=tmp_path,
    )

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["illustrations_status"] == "partial"
    assert story["pages"][0]["image_path"] is not None
    assert story["pages"][1]["image_path"] is not None
    assert story["pages"][2]["image_path"] is None
    assert story["pages"][3]["image_path"] is None
    # Once dead, the pass stops asking: page 4 is never requested.
    assert worker.requests == 3
    assert worker.closed


async def test_worker_dying_on_the_first_page_marks_the_story_failed(tmp_path):
    pages = [{"text": "Page one."}, {"text": "Page two."}]
    story_id = _saved_story_with_pages(tmp_path, pages)
    worker = DyingWorker(FakeImageBackend(), alive_for=0)

    await generate_and_attach(
        story_id, pages, llm=FakeExtractionLlm(), image_worker_factory=lambda: worker,
        stories_dir=tmp_path,
    )

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["illustrations_status"] == "failed"
    assert worker.closed


async def test_worker_is_started_and_closed_on_a_normal_pass(tmp_path):
    pages = [{"text": "Page one."}]
    story_id = _saved_story_with_pages(tmp_path, pages)
    worker = InProcessImageWorker(FakeImageBackend())

    await generate_and_attach(
        story_id, pages, llm=FakeExtractionLlm(), image_worker_factory=lambda: worker,
        stories_dir=tmp_path,
    )

    assert worker.started and worker.closed


async def test_worker_that_fails_to_start_marks_the_story_failed_and_still_closes(tmp_path):
    pages = [{"text": "Page one."}]
    story_id = _saved_story_with_pages(tmp_path, pages)

    class UnstartableWorker(InProcessImageWorker):
        def start(self) -> None:
            raise OSError("cannot spawn")

    worker = UnstartableWorker(FakeImageBackend())

    await generate_and_attach(
        story_id, pages, llm=FakeExtractionLlm(), image_worker_factory=lambda: worker,
        stories_dir=tmp_path,
    )

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["illustrations_status"] == "failed"
    assert worker.closed


async def test_cancellation_closes_the_worker(tmp_path):
    pages = [{"text": "Page one."}]
    story_id = _saved_story_with_pages(tmp_path, pages)
    entered = threading.Event()
    release = threading.Event()

    class BlockingWorker(InProcessImageWorker):
        def generate_to_file(self, prompt, reference_path, out_path):
            entered.set()
            release.wait(10)
            return PageResult(ERROR, "released")

    worker = BlockingWorker(FakeImageBackend())
    task = asyncio.create_task(
        generate_and_attach(
            story_id, pages, llm=FakeExtractionLlm(), image_worker_factory=lambda: worker,
            stories_dir=tmp_path,
        )
    )
    assert await asyncio.to_thread(entered.wait, 10)

    task.cancel()
    release.set()
    with pytest.raises(asyncio.CancelledError):
        await task

    assert worker.closed
```

- [ ] **Step 3: Run the illustration tests to verify they fail**

Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_illustrations.py`
Expected: FAIL, `TypeError: generate_and_attach() got an unexpected keyword argument 'image_worker_factory'` (and missing-argument errors for `image_backend`).

- [ ] **Step 4: Rewrite the image loop in `illustrations.py`**

In `server/tinytalk/illustrations.py`:

1. Imports: delete `from PIL import Image` and `from .image_gen import ImageGenBackend` (check with `grep -n "Image\b" server/tinytalk/illustrations.py` that nothing else uses `Image`), and add:

```python
from .image_worker import FLAGGED, OK, WORKER_DEAD, ImageWorkerFactory
```

2. Delete the whole `_generate_and_save` function.

3. In the `generate_and_attach` signature, replace `image_backend: ImageGenBackend,` with `image_worker_factory: ImageWorkerFactory,`. In its docstring, change "(page 0 first, reference-free; later pages use page 0's own generated image as an IP-Adapter reference ...)" to mention the pictures are drawn by a short-lived worker process (issue #75) and the reference is page 0's saved file.

4. Replace the block that starts at the line `reference_image = None` (immediately after `await _release_ollama_memory()`) and ends at the line `any_succeeded = True` (the last line of the `for index, scene_prompt in enumerate(scene_prompts):` loop) with:

```python
        image_filenames: list[str | None] = []
        any_succeeded = False
        # Page 0's saved PNG, passed to every later page as the IP-Adapter
        # reference. A path, not an in-memory image: the worker is a
        # separate process and only text crosses to it.
        reference_path: Path | None = None
        worker_dead = False
        worker = image_worker_factory()
        try:
            await asyncio.to_thread(worker.start)
            for index, scene_prompt in enumerate(scene_prompts):
                if scene_prompt is None or worker_dead:
                    image_filenames.append(None)
                    continue
                filename = f"{story_id}-page-{index}.png"
                path = stories_dir / filename
                result = await asyncio.to_thread(
                    worker.generate_to_file, scene_prompt, reference_path, path
                )
                if result.kind == OK:
                    if reference_path is None:
                        reference_path = path
                    image_filenames.append(filename)
                    any_succeeded = True
                    continue
                if result.kind == FLAGGED:
                    logger.warning(
                        "illustration for story %s page %d has no image (safety "
                        "check or generation failure)",
                        story_id,
                        index,
                    )
                elif result.kind == WORKER_DEAD:
                    logger.error(
                        "illustration for story %s page %d: the image worker died "
                        "(%s) -- this page and any remaining pages get no picture",
                        story_id,
                        index,
                        result.detail,
                    )
                    worker_dead = True
                else:
                    logger.warning(
                        "illustration for story %s page %d failed during image "
                        "generation: %s",
                        story_id,
                        index,
                        result.detail,
                    )
                image_filenames.append(None)
        finally:
            # Always: the child's exit is what hands Stable Diffusion's
            # memory back to macOS. Awaited in a thread so a slow join never
            # blocks the event loop; it also runs on cancellation.
            await asyncio.to_thread(worker.close)
```

Leave everything after the loop (the `done`/`partial`/`failed` status calculation, `update_story_illustrations`, the final log and the `except` clauses) exactly as it is.

- [ ] **Step 5: Run the illustration tests to verify they pass**

Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_illustrations.py`
Expected: all pass (the 12 existing tests plus 5 new = 17; `grep -c "^async def test_\|^def test_" server/tests/test_illustrations.py` should equal the passed count).

- [ ] **Step 6: Commit**

```bash
git add server/tinytalk/illustrations.py server/tests/test_illustrations.py
git commit -m "feat(server): draw story pictures in a short-lived worker (#75)

generate_and_attach now takes image_worker_factory and runs the per-page
loop against a worker it starts and always closes (also on cancel). The
reference image is page 0's saved path. A dead worker blanks the current
and remaining pages and the live server keeps running. Prompt extraction
and the Ollama release still run before the worker starts.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UN6MTdnWqmagVqFqmwTDxr"
```

(The full suite is red at this commit because `storybook.py` still passes `image_backend`; Task 3 fixes the wiring. Do not run the full suite until then.)

---

### Task 3: Wire the factory through storybook, session and app

**Files:**
- Modify: `server/tinytalk/storybook.py` (import, `build_and_attach` parameter, the `generate_and_attach` call)
- Modify: `server/tinytalk/session.py` (import, `SessionRunner.__init__` parameter and attribute, the `_run_rewrite` call)
- Modify: `server/tinytalk/app.py` (imports, `build_session` parameter, startup wiring)
- Modify: `server/tests/test_storybook.py`, `server/tests/test_app.py`

**Interfaces:**
- Consumes: `ImageWorkerFactory` and `build_image_worker` (Task 1); `generate_and_attach(..., image_worker_factory=...)` (Task 2).
- Produces: `storybook.build_and_attach(..., image_worker_factory: ImageWorkerFactory | None = None)`; `SessionRunner(..., image_worker_factory=...)` storing `self._image_worker_factory`; `build_session(..., image_worker_factory=...)`. `None` still means "no illustrations".

- [ ] **Step 1: Update the tests first (they fail)**

In `server/tests/test_storybook.py`:
- Add `from image_worker_fakes import InProcessImageWorker` to the imports.
- In `test_build_and_attach_runs_illustrations_when_backend_given`, change `image_backend=backend,` to `image_worker_factory=lambda: InProcessImageWorker(backend),` (keep `assert backend.calls == 1`; rename the test to `test_build_and_attach_runs_illustrations_when_worker_factory_given`).
- In `test_build_and_attach_survives_illustrations_pass_raising`, change `image_backend=FakeImageBackendForStorybook(),` to `image_worker_factory=lambda: InProcessImageWorker(FakeImageBackendForStorybook()),`.

In `server/tests/test_app.py`, replace `test_build_session_forwards_image_backend` with:

```python
def test_build_session_forwards_image_worker_factory():
    def factory():
        raise AssertionError("not called by this test")

    session = build_session(
        NullTransport(), stt=FakeStt(), llm=FakeLlm(), tts=FakeTts(),
        image_worker_factory=factory,
    )
    assert session._image_worker_factory is factory
```

- [ ] **Step 2: Run them to verify they fail**

Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_storybook.py tests/test_app.py`
Expected: FAIL (`unexpected keyword argument 'image_worker_factory'`).

- [ ] **Step 3: Rewire the three modules**

`server/tinytalk/storybook.py`:
- Replace `from .image_gen import ImageGenBackend` with `from .image_worker import ImageWorkerFactory`.
- In `build_and_attach`'s signature replace `image_backend: ImageGenBackend | None = None,` with `image_worker_factory: ImageWorkerFactory | None = None,`.
- Replace `if image_backend is not None:` with `if image_worker_factory is not None:`, and in the call change `llm=llm, image_backend=image_backend, stories_dir=stories_dir,` to `llm=llm, image_worker_factory=image_worker_factory, stories_dir=stories_dir,`.

`server/tinytalk/session.py`:
- Replace `from .image_gen import ImageGenBackend` with `from .image_worker import ImageWorkerFactory`.
- In `SessionRunner.__init__` replace the parameter `image_backend: ImageGenBackend | None = None,` with `image_worker_factory: ImageWorkerFactory | None = None,` and the line `self._image_backend = image_backend` with `self._image_worker_factory = image_worker_factory`.
- In `_run_rewrite`, change `image_backend=self._image_backend,` to `image_worker_factory=self._image_worker_factory,`.

`server/tinytalk/app.py`:
- Replace `from .image_gen import ImageGenBackend, StableDiffusionBackend` with `from .image_worker import ImageWorkerFactory, build_image_worker`.
- In `build_session`, replace `image_backend: ImageGenBackend | None = None,` with `image_worker_factory: ImageWorkerFactory | None = None,` and pass `image_worker_factory=image_worker_factory` to `SessionRunner(...)` in place of `image_backend=image_backend`.
- At startup, delete the line `image_backend = StableDiffusionBackend()`, and in the `build_session(` call replace `image_backend=image_backend,` with `image_worker_factory=build_image_worker,`.
- In the long comment above `stt = KyutaiStt()` that says "...each of these lazily loads a multi-GB model... Built once and shared across every connection", add one sentence: "Stable Diffusion is deliberately NOT built here: it runs in a short-lived worker process per picture pass (image_worker.py, issue #75) so its memory returns to macOS afterwards."

Then run `grep -rn "image_backend\|ImageGenBackend\|StableDiffusionBackend" server/tinytalk server/tests`. The only hits left must be `server/tinytalk/image_gen.py`, `server/tinytalk/image_worker.py` (its docstring/factory), `server/tests/test_image_gen.py`, and the fake backends inside `test_illustrations.py`/`test_storybook.py`/`image_worker_fakes.py` (names like `FakeImageBackend`). Anything else is a missed hop.

- [ ] **Step 4: Run the full suite**

Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest -q -p no:cacheprovider`
Expected: **519 passed** (501 baseline + 13 from Task 1 + 5 from Task 2; Tasks 3 renames a test, adding none). Zero failures. If the number differs, compare with `grep -c` of test functions rather than guessing.

- [ ] **Step 5: Verify the server still imports and builds without loading torch**

Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -c "import sys, tinytalk.app; print('torch' in sys.modules, 'diffusers' in sys.modules)"`
Expected: prints `False False`: importing the server must not pull torch or diffusers into the live process through the new module. If `torch` prints `True`, find which module imports it with `python -X importtime -c "import tinytalk.app" 2>&1 | grep -i torch | head`; the new code is only at fault if `tinytalk/image_worker.py` has a top-level `torch` or `diffusers` import (it must not; `build_stable_diffusion_backend` imports `image_gen` lazily, inside the function).

- [ ] **Step 6: Commit**

```bash
git add server/tinytalk/storybook.py server/tinytalk/session.py server/tinytalk/app.py server/tests/test_storybook.py server/tests/test_app.py
git commit -m "feat(server): wire the image worker factory through app, session and storybook (#75)

image_worker_factory replaces image_backend at every hop. The server no
longer builds a long-lived StableDiffusionBackend, so only STT and TTS
stay resident during live turns.

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UN6MTdnWqmagVqFqmwTDxr"
```

---

### Task 4: Docs, and the memory measurement

**Files:**
- Modify: `README.md` (one note, one config line)
- Modify: nothing else. CLAUDE.md is not edited (the user owns it; list it as stale-doc candidate in the PR instead).

**Interfaces:** none.

- [ ] **Step 1: Add the README note**

In `README.md`, directly after the numbered setup item `6. **Kokoro TTS** ...` (ends with the sentence about `pip install -e ".[dev]"` in step 3 of "Running the server" below), add an unnumbered paragraph:

```markdown
   **Picture drawing and memory.** Stable Diffusion does not stay loaded in
   the server. After a story ends, the server starts a short-lived worker
   process to draw that story's pictures and stops it afterwards, so the
   gigabytes it needs go back to macOS and live conversation (STT + TTS)
   keeps the memory. The cost is a few seconds of start-up before the first
   picture, all after The End. If a page takes longer than
   `TINYTALK_IMAGE_WORKER_PAGE_TIMEOUT` seconds (default `300`; the first
   page includes loading the model), the worker is stopped and the story
   keeps whatever pictures it already has. Log lines to look for:
   `image worker: started`, `image worker: exited`, `image worker died`.
```

- [ ] **Step 2: Run the full suite once more**

Run: `/Users/jess/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/python -m pytest -q -p no:cacheprovider`
Expected: 519 passed (docs only; unchanged).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: README note on the short-lived image worker (#75)

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01UN6MTdnWqmagVqFqmwTDxr"
```

- [ ] **Step 4: Measure memory, before and after (the acceptance test; done with the household)**

Memory must be read with `footprint`, **not** `ps` RSS (RSS read ~6 MB against a real 4.3 GB on 2026-09-24 because the process was compressed/swapped). Both servers listen on port 8765, so run one at a time.

Before (old code, the main checkout), in one terminal:

```bash
cd ~/Development/claude-tests/tiny-talk-adventures/server
```
```bash
source .venv/bin/activate
```
```bash
python -m tinytalk.app
```

Then take a live turn from the phone (so STT and TTS load), and read point 1 from another terminal:

```bash
footprint -p "$(lsof -ti tcp:8765 -sTCP:LISTEN)" | sed -n 2p
```

Finish an illustrated story, wait for the pictures, and read point 2 with the same command. Write both numbers down. Stop the server (Ctrl+C), then repeat from the worktree:

```bash
cd ~/Development/claude-tests/tiny-talk-adventures/.claude/worktrees/server-memory-image-worker/server
```
```bash
source ~/Development/claude-tests/tiny-talk-adventures/server/.venv/bin/activate
```
```bash
python -m tinytalk.app
```

(This uses main's venv, editable-installed from main; running with `-m` from the worktree's `server/` loads the worktree's code. Check the first log lines or run `python -c "import tinytalk; print(tinytalk.__file__)"` once to confirm the path is inside the worktree.) Note the worktree's `server/data/stories` starts empty, which is expected.

**Pass:** with the new code, point 2 is within ~0.5 GB of point 1, and the log shows `image worker: started (pid N)`, `image worker: first page took X s (includes model load)`, and `image worker: exited (code 0) after X s`. On the old code, point 2 keeps the Stable Diffusion gigabytes.

- [ ] **Step 5: Report the numbers and the on-device script**

Follow CLAUDE.md's "Testing changes on-device" rules in the final message: worktree path, **server restart required** (Python code changed; no auto-reload), **no iOS rebuild** (no `ios/` changes; the installed build is fine), and the test script: finish a server-mode story → pictures appear as before in Library/Reading → the three `image worker:` log lines appear → `footprint` before/after as above → the next story's turns feel at least as fast. Also list stale docs for the PR body: CLAUDE.md's "Current focus" does not yet mention this change, and `project_server_memory_footprint` memory note's "no code fix yet" becomes stale after merge.

---

## Self-Review (done against the spec)

- **Spec coverage:** `image_worker.py` with spawn, pipe, quit/terminate/kill, log lines → Task 1. Parent/child protocol, paths only, child writes PNGs → Task 1. `illustrations.py` runs inside the worker, reference as a path, Ollama release and prompt extraction before the worker, dead worker blanks the rest, `asyncio.to_thread` waits → Task 2. Factory replaces `image_backend` through `build_session`/`SessionRunner`/`build_and_attach`/`generate_and_attach`, `app.py` no longer builds SD → Task 3. `IMAGE_WORKER_PAGE_TIMEOUT` → Task 1. Failure table: crash, hang, shutdown/cancel, flagged, fails-to-start → Tasks 1–2 tests. README + config docs → Task 4. Measurement and acceptance → Task 4 Step 4. `image_gen.py` untouched → Global Constraints.
- **One deliberate deviation from the spec text:** the spec says the child logs `model loaded in X s`; the SD model loads lazily inside the first `generate()`, so the child logs the first page's duration instead (`first page took X s (includes model load)`), which is what the on-device check looks for. The backend's own `loading Stable Diffusion pipeline` / `pipeline loaded` lines still appear in the child's output.
- **Placeholder scan:** none. Every code step carries code. The two edits that say "replace the block from X to Y" in `illustrations.py` name unique anchor lines and give the full replacement.
- **Type consistency:** `PageResult`/`OK`/`FLAGGED`/`ERROR`/`WORKER_DEAD`, `PageImageWorker`, `ImageWorkerFactory`, `build_image_worker`, `image_worker_factory`, `_image_worker_factory` are spelled identically in every task.
- **Test count arithmetic:** 501 + 13 (12 worker tests + 1 config test) = 514 after Task 1; + 5 new illustration tests = 519 after Task 2; Task 3 renames two tests and replaces one (net 0) → 519 final. Task 2's intermediate suite is intentionally red until Task 3.
- **Known risk to watch during execution:** the spawn-based tests depend on the child inheriting `tests/` on `sys.path` (Task 1 Step 9 says what to do if not). The first spawn on a swapping Mac can be slow; the tests use a 60 s timeout for that reason, except the deliberate-hang test (1.5 s).

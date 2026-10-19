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

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

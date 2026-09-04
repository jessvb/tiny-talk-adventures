"""Answers one question: can STT keep up with a child talking?

The whole voice pipeline assumes it can. Audio arrives from the phone at
exactly realtime and there is no way to slow the child down, so if
decoding a second of speech takes longer than a second, every utterance
puts the server further behind, without bound. That is not a latency
nuisance -- it is the root cause behind both faces of the "app randomly
disconnects" bug:

  - Before reading was decoupled from processing, the backlog paused the
    TCP socket, which stopped the keepalive PONG being read, and the
    server hung up on a healthy client 40s later (ping_interval +
    ping_timeout). Short utterances drained in time and survived, which is
    why it looked random.
  - After decoupling, nothing dies -- the backlog just grows and the turn
    never starts, so the app waits in the ditty loop indefinitely.

Both disappear if, and only if, STT runs faster than realtime.

    server/.venv/bin/python tools/stt_realtime_probe.py

Exits 0 if STT keeps up, 1 if it does not. Honours TINYTALK_STT_REPO, so
a candidate model can be checked before committing to it:

    TINYTALK_STT_REPO=kyutai/stt-1b-en_fr-mlx .venv/bin/python tools/stt_realtime_probe.py

Measured on the household M1 (16GB) on 2026-09-03, for comparison:
kyutai/stt-2.6b-en-mlx managed 2.33x slower than realtime with the machine
otherwise idle, and 3.5x slower with qwen3.5:9b resident in Ollama at the
same time. Memory pressure makes it worse but is not what makes it slow --
the numbers below print both so the two can be told apart.
"""

from __future__ import annotations

import os
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tinytalk import config  # noqa: E402
from tinytalk.audio import MIC_SAMPLE_RATE  # noqa: E402
from tinytalk.stt_kyutai import KyutaiStt  # noqa: E402

FRAME_MS = 80  # one client audio frame; also moshi_mlx's own decode step
SPEECH_SECONDS = 10  # a long-ish sentence from a child
RUNS = 2  # the first pays one-off warmup costs; the second is the real number


def _swap_summary() -> str:
    usage = subprocess.run(
        ["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True
    ).stdout.strip()
    summary = subprocess.run(
        ["vmmap", "--summary", str(os.getpid())], capture_output=True, text=True
    ).stdout
    swapped = next(
        (line.strip() for line in summary.splitlines() if line.startswith("Writable regions")),
        "(vmmap unavailable)",
    )
    return f"  system swap: {usage}\n  this process: {swapped}"


def main() -> int:
    print(f"model: {config.STT_HF_REPO}")
    load_started = time.perf_counter()
    stt = KyutaiStt()
    stt._get_recognizer()  # loading is lazy; do it before timing anything
    print(f"loaded in {time.perf_counter() - load_started:.1f}s")

    frame_bytes = int(MIC_SAMPLE_RATE * FRAME_MS / 1000) * 2
    # Noise rather than silence: silent audio can take a shortcut through
    # the audio tokenizer, which would flatter the result.
    rng = np.random.default_rng(0)
    frame = rng.normal(0, 3000, frame_bytes // 2).astype(np.int16).tobytes()

    factor = float("inf")
    for run in range(1, RUNS + 1):
        per_frame: list[float] = []
        feed_started = time.perf_counter()
        for _ in range(int(SPEECH_SECONDS * 1000 / FRAME_MS)):
            frame_started = time.perf_counter()
            stt.feed(frame)
            per_frame.append(time.perf_counter() - frame_started)
        feed_seconds = time.perf_counter() - feed_started
        finish_started = time.perf_counter()
        stt.finish()
        finish_seconds = time.perf_counter() - finish_started
        factor = feed_seconds / SPEECH_SECONDS
        print(
            f"run {run}: {SPEECH_SECONDS}s of speech decoded in {feed_seconds:.1f}s "
            f"({factor:.2f}x realtime), per frame median "
            f"{sorted(per_frame)[len(per_frame) // 2] * 1000:.0f}ms / max "
            f"{max(per_frame) * 1000:.0f}ms (a frame is {FRAME_MS}ms of audio), "
            f"then finish() {finish_seconds:.1f}s"
        )

    print(_swap_summary())
    if factor >= 1.0:
        lag = (factor - 1.0) * SPEECH_SECONDS
        print(
            f"\nFAIL -- STT cannot keep up. Every {SPEECH_SECONDS}s the child talks puts "
            f"the server {lag:.0f}s further behind, and the turn cannot start until that "
            f"drains. Try a smaller model (TINYTALK_STT_REPO) and free memory: a swapped-out "
            f"model decodes far slower (see the numbers above)."
        )
        return 1
    headroom = (1.0 - factor) * 100
    print(f"\nPASS -- STT keeps up with {headroom:.0f}% headroom. No backlog can build.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

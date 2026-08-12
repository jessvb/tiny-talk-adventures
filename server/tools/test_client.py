"""CLI stand-in for the phone client.

Sends a WAV file as if it were mic audio, optionally fires an interrupt part
way through the reply, and writes the received TTS audio to a WAV file.

Usage:
    python tools/test_client.py utterance.wav
    python tools/test_client.py utterance.wav --interrupt-after 0.8
    python tools/test_client.py utterance.wav --interrupt-after 0.8 --then second.wav
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


async def send_utterance(websocket, pcm: bytes) -> None:
    """Send one utterance's worth of control frames and mic audio."""
    await websocket.send(json.dumps({"type": "speech_start"}))
    for offset in range(0, len(pcm), CHUNK_FRAMES * 2):
        await websocket.send(pcm[offset : offset + CHUNK_FRAMES * 2])
        await asyncio.sleep(0.01)  # loosely pace it like a live mic
    await websocket.send(json.dumps({"type": "speech_end"}))


async def receive(websocket, audio: list[bytes], remaining_turn_ends: int, started: float):
    # `remaining_turn_ends` counts how many turn_end frames still complete
    # the run: 1 for a plain send-and-wait, 1 for "interrupt then a
    # follow-up utterance" (only the follow-up's turn actually finishes —
    # the interrupted one never emits turn_end), or 0 for "interrupt with no
    # follow-up", where the caller cancels this task externally instead.
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
            sys.exit(1)
        elif kind == "turn_end":
            print(f"  turn complete in {time.monotonic() - started:.2f}s")
            remaining_turn_ends -= 1
            if remaining_turn_ends <= 0:
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
    parser.add_argument(
        "--then",
        metavar="WAV",
        help=(
            "after the interrupt fires, send this WAV as a follow-up utterance "
            "and wait for its reply -- exercises the actual payoff of barge-in: "
            "that the reply reacts to the interruption. Requires --interrupt-after."
        ),
    )
    parser.add_argument("--out", default="/tmp/reply.wav")
    args = parser.parse_args()

    if args.then is not None and args.interrupt_after is None:
        parser.error("--then requires --interrupt-after")

    pcm = read_wav(args.wav)
    audio: list[bytes] = []

    async with websockets.connect(args.url, max_size=None) as websocket:
        started = time.monotonic()
        await send_utterance(websocket, pcm)
        print("sent utterance, waiting for reply...")

        expect_turn_end = args.interrupt_after is None or args.then is not None
        receiver = asyncio.create_task(
            receive(websocket, audio, 1 if expect_turn_end else 0, started)
        )

        if args.interrupt_after is not None:
            await asyncio.sleep(args.interrupt_after)
            fired = time.monotonic()
            await websocket.send(json.dumps({"type": "interrupt"}))
            print(f"  sent interrupt at {fired - started:.2f}s")

            if args.then is not None:
                await asyncio.sleep(0.3)  # brief pause before the follow-up
                print(f"  sending follow-up utterance {args.then!r}...")
                await send_utterance(websocket, read_wav(args.then))
            else:
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

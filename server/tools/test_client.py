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
            sys.exit(1)
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

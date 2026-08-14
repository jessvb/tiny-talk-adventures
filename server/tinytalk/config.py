"""Server configuration.

Single-household LAN pet project: plain module constants, overridable by
environment variable where it is convenient during development.
"""

from __future__ import annotations

import os

SERVER_HOST = os.environ.get("TINYTALK_HOST", "0.0.0.0")
SERVER_PORT = int(os.environ.get("TINYTALK_PORT", "8765"))

OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
OLLAMA_MODEL = os.environ.get("TINYTALK_MODEL", "qwen3.5:9b")

STT_HF_REPO = os.environ.get("TINYTALK_STT_REPO", "kyutai/stt-2.6b-en-mlx")

KOKORO_LANG_CODE = os.environ.get("TINYTALK_TTS_LANG", "a")
KOKORO_VOICE = os.environ.get("TINYTALK_TTS_VOICE", "af_heart")

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

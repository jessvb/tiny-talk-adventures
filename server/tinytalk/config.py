"""Server configuration.

Single-household LAN pet project: plain module constants, overridable by
environment variable where it is convenient during development.
"""

from __future__ import annotations

import os

SERVER_HOST = os.environ.get("TINYTALK_HOST", "0.0.0.0")
SERVER_PORT = int(os.environ.get("TINYTALK_PORT", "8765"))

OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
# Back to qwen3.5:9b (2026-08-25) now that OLLAMA_THINK=False is the real
# fix for the memory-pressure/latency saga -- see that setting's own
# comment. 9b's replies were confirmed better-reasoned than 4b's on real
# on-device testing, "good enough for now" per the household's own
# judgment, and now that thinking is off, 9b's peak memory-pressure
# window is short (one quick reply, not minutes of reasoning tokens) --
# the earlier severe swap thrashing was mostly a symptom of thinking-mode
# generation duration, not model size alone. Deliberately NOT a "-mlx"
# tagged variant: confirmed (2026-08) Ollama's MLX backend still
# hard-requires 32GB unified memory regardless of model size, so this
# stays on the same Metal/llama.cpp backend already in use.
OLLAMA_MODEL = os.environ.get("TINYTALK_MODEL", "qwen3.5:9b")
# Ollama's own default is 5 minutes, after which it unloads the model and
# the NEXT request has to reload it from disk (multiple GB) before it can
# generate a single token -- under real memory pressure from STT+TTS
# competing for the same machine's RAM, Ollama can evict it far more
# aggressively than that. A sudden multi-minute reply, distinct from
# normal (even if slow) token-generation speed, is the signature of this
# happening. "30m" keeps the model warm across a realistic gap between a
# child's turns without pinning the memory forever if the app sits idle.
OLLAMA_KEEP_ALIVE = os.environ.get("TINYTALK_OLLAMA_KEEP_ALIVE", "30m")
# qwen3.5 defaults to "thinking" mode -- a long internal chain-of-thought
# (confirmed 2026-08-25 via `ollama run qwen3.5:4b` directly, bypassing
# this app entirely: 100+ lines of thinking output, ~3m19s wall clock,
# for a single short prompt) before it ever produces the actual reply.
# This was the real root cause of the multi-minute/empty-reply latency,
# not (only) memory pressure -- turning it off is a request-level flag,
# not a different model. This app only ever needs 1-3 plain spoken
# sentences per turn (see SYSTEM_PROMPT); the story doesn't benefit from
# deep reasoning, so thinking is off by default.
OLLAMA_THINK = os.environ.get("TINYTALK_OLLAMA_THINK", "false").strip().lower() == "true"

# "ollama" (default, local/private) or "groq" (hosted, for A/B-testing
# whether LLM speed is the actual latency bottleneck -- see llm_groq.py's
# module docstring). Swappable with no other code changes.
LLM_BACKEND = os.environ.get("TINYTALK_LLM_BACKEND", "ollama")
GROQ_API_KEY = os.environ.get("GROQ_API_KEY", "")
GROQ_HOST = os.environ.get("GROQ_HOST", "https://api.groq.com")
# Groq's free-tier model lineup changes over time -- check
# https://console.groq.com for what's currently available before relying on
# this default.
GROQ_MODEL = os.environ.get("TINYTALK_GROQ_MODEL", "llama-3.1-8b-instant")

# Free sign-up at https://api-ninjas.com (100 requests/hour free tier) --
# used only on the first-ever mention of a given animal; every later
# mention, in any story, is an instant local cache lookup with no network
# call. See animal_facts.py.
ANIMAL_FACTS_API_KEY = os.environ.get("ANIMAL_FACTS_API_KEY", "")

STT_HF_REPO = os.environ.get("TINYTALK_STT_REPO", "kyutai/stt-2.6b-en-mlx")

KOKORO_LANG_CODE = os.environ.get("TINYTALK_TTS_LANG", "a")
KOKORO_VOICE = os.environ.get("TINYTALK_TTS_VOICE", "af_heart")
# Kokoro's own device auto-detection (kokoro/pipeline.py) only checks
# torch.cuda.is_available() -- never MPS -- so on Apple Silicon it silently
# falls back to CPU even though the GPU is available. Benchmarked on this
# Mac with the real production code path: MPS ran ~1.8x faster than CPU for
# a representative reply-length synthesis (1.11s vs 2.01s for 9.4s of
# audio). Overridable in case a future non-Apple-Silicon host needs "cpu"
# or "cuda" instead.
KOKORO_DEVICE = os.environ.get("TINYTALK_TTS_DEVICE", "mps")

# One turn = one child utterance + one agent reply. Roughly matched to a
# young child's attention span -- see story_arc.py's module docstring for
# how this drives narrative staging. Lowered from 12 to 7 after real
# on-device testing: even 12 felt too long, and a 15-turn real session
# never reached the old grace ceiling of 15 (forcing only kicks in at
# target+4), so the story just never concluded.
STORY_TARGET_TURNS = int(os.environ.get("TINYTALK_STORY_TARGET_TURNS", "7"))

SYSTEM_PROMPT = (
    "You are a warm, interesting storyteller telling a story out loud with a young, "
    "intelligent child, aged about three to six. You and the child are making the "
    "story up together. You like to subtly add educational facts to the story to make it "
    "more interesting.\n"
    "\n"
    "Rules you always follow:\n"
    "- Reply with one to three short sentences. Never more. The child is "
    "listening, not reading.\n"
    "- Keep everything gentle and wholesome. No violence, no weapons, no death, "
    "no frightening peril.\n"
    "- End most replies by asking the child what should happen next.\n"
    "- If the child interrupts you, follow their idea happily. Never scold them "
    "for interrupting and never insist on finishing your previous sentence.\n"
    "- Keep the story grounded in the real world: no magic, no talking "
    "plants or objects, no impossible physics. Animal characters can "
    "talk and think like people, but everything else about the world "
    "should be realistic.\n"
    "- Write plain spoken words only: no emoji, no asterisks, no stage "
    "directions, no narration about yourself."
)

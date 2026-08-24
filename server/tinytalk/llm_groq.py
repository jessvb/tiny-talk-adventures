"""LLM backend: Groq's hosted, OpenAI-compatible chat completions API.

For A/B-testing whether LLM generation speed is the actual bottleneck in
reply latency -- swappable with OllamaLlm via TINYTALK_LLM_BACKEND=groq,
same LlmEngine interface, no other code changes needed. Groq's inference
hardware (LPUs, not GPUs) is routinely far faster than local Metal/GPU
inference for models in this class, and its free tier is generous enough
for interactive testing.

Not intended for real use with a child: this sends conversation text to a
third party, which conflicts with CLAUDE.md's privacy-first constraint.
Testing-only, by the household's own explicit choice.

Groq streams Server-Sent Events in the same shape as OpenAI's Chat
Completions streaming API: lines prefixed "data: ", one JSON object per
chunk, with a terminal "data: [DONE]" line (not itself JSON) -- structurally
different from Ollama's bare NDJSON (llm_ollama.py's parse_chat_line), so
this needs its own line parser rather than reusing that one.
"""

from __future__ import annotations

import json
from typing import AsyncIterator

import httpx

from . import config
from .engines import EngineError


def parse_sse_line(line: str) -> str | None:
    """Extract the text chunk from one SSE line, or None if there is none."""
    stripped = line.strip()
    if not stripped or not stripped.startswith("data:"):
        return None
    payload = stripped[len("data:"):].strip()
    if payload == "[DONE]":
        return None
    try:
        parsed = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise EngineError(f"Groq sent a malformed response line: {stripped!r}") from exc
    if "error" in parsed:
        message = parsed["error"]
        if isinstance(message, dict):
            message = message.get("message", message)
        raise EngineError(f"Groq reported an error: {message}")
    choices = parsed.get("choices") or []
    if not choices:
        return None
    return choices[0].get("delta", {}).get("content") or None


class GroqLlm:
    """LlmEngine backed by Groq's hosted, OpenAI-compatible chat API."""

    def __init__(
        self,
        model: str | None = None,
        host: str | None = None,
        api_key: str | None = None,
        *,
        transport: httpx.BaseTransport | None = None,
        timeout: float = 30.0,
    ) -> None:
        # Resolved from config at call time, not bound as a parameter
        # default -- a default value would be frozen at first import
        # (config.GROQ_API_KEY read once, before any real key is set),
        # rather than picking up the actual key when this is constructed.
        model = model if model is not None else config.GROQ_MODEL
        host = host if host is not None else config.GROQ_HOST
        api_key = api_key if api_key is not None else config.GROQ_API_KEY
        if not api_key:
            raise EngineError(
                "GROQ_API_KEY is not set -- get a free key at "
                "https://console.groq.com/keys"
            )
        self._model = model
        self._host = host.rstrip("/")
        self._api_key = api_key
        self._transport = transport
        self._timeout = timeout

    async def stream_reply(self, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        body = {"model": self._model, "messages": messages, "stream": True}
        headers = {"Authorization": f"Bearer {self._api_key}"}
        try:
            async with httpx.AsyncClient(
                timeout=self._timeout, transport=self._transport
            ) as client:
                async with client.stream(
                    "POST",
                    f"{self._host}/openai/v1/chat/completions",
                    json=body,
                    headers=headers,
                ) as response:
                    if response.status_code != 200:
                        detail = (await response.aread()).decode("utf-8", "replace")
                        raise EngineError(
                            f"Groq returned {response.status_code}: {detail.strip()}"
                        )
                    async for line in response.aiter_lines():
                        chunk = parse_sse_line(line)
                        if chunk:
                            yield chunk
        except httpx.HTTPError as exc:
            raise EngineError(f"could not reach Groq at {self._host} ({exc})") from exc

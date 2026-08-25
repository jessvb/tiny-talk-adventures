"""LLM backend: Qwen 3.5 9B served locally by Ollama.

Ollama's /api/chat streams newline-delimited JSON, one object per token-ish
chunk, with a final object carrying done=true.
"""

from __future__ import annotations

import json
from typing import AsyncIterator

import httpx

from . import config
from .engines import EngineError


def parse_chat_line(line: str) -> str | None:
    """Extract the text chunk from one NDJSON line, or None if there is none."""
    stripped = line.strip()
    if not stripped:
        return None
    try:
        payload = json.loads(stripped)
    except json.JSONDecodeError as exc:
        raise EngineError(f"Ollama sent a malformed response line: {stripped!r}") from exc
    if "error" in payload:
        raise EngineError(f"Ollama reported an error: {payload['error']}")
    if payload.get("done"):
        return None
    return payload.get("message", {}).get("content") or None


class OllamaLlm:
    """LlmEngine backed by a local Ollama server."""

    def __init__(
        self,
        model: str = config.OLLAMA_MODEL,
        host: str = config.OLLAMA_HOST,
        *,
        keep_alive: str | None = None,
        think: bool | None = None,
        transport: httpx.BaseTransport | None = None,
        timeout: float = 120.0,
    ) -> None:
        # keep_alive/think resolved here, not bound as `=
        # config.OLLAMA_KEEP_ALIVE`/`= config.OLLAMA_THINK` in the
        # signature -- a signature default would freeze them at first
        # import instead of picking up a test's monkeypatched config
        # value, the same class-definition-time-binding bug GroqLlm's
        # constructor was deliberately written to avoid for its own
        # parameters.
        self._model = model
        self._host = host.rstrip("/")
        self._keep_alive = keep_alive if keep_alive is not None else config.OLLAMA_KEEP_ALIVE
        self._think = think if think is not None else config.OLLAMA_THINK
        self._transport = transport
        self._timeout = timeout

    async def stream_reply(self, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        body = {
            "model": self._model,
            "messages": messages,
            "stream": True,
            "keep_alive": self._keep_alive,
            "think": self._think,
        }
        try:
            async with httpx.AsyncClient(
                timeout=self._timeout, transport=self._transport
            ) as client:
                async with client.stream(
                    "POST", f"{self._host}/api/chat", json=body
                ) as response:
                    if response.status_code != 200:
                        detail = (await response.aread()).decode("utf-8", "replace")
                        raise EngineError(
                            f"Ollama returned {response.status_code}: {detail.strip()}"
                        )
                    async for line in response.aiter_lines():
                        chunk = parse_chat_line(line)
                        if chunk:
                            yield chunk
        except httpx.HTTPError as exc:
            raise EngineError(
                f"could not reach Ollama at {self._host} — is `ollama serve` running? ({exc})"
            ) from exc

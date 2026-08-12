import json

import httpx
import pytest

from storyadventure.engines import EngineError
from storyadventure.llm_ollama import OllamaLlm, parse_chat_line


def chat_line(content: str, done: bool = False) -> str:
    return json.dumps(
        {"model": "qwen3.5:9b", "message": {"role": "assistant", "content": content}, "done": done}
    )


def test_parse_chat_line_extracts_content():
    assert parse_chat_line(chat_line("Once ")) == "Once "


def test_parse_chat_line_returns_none_for_done_marker():
    assert parse_chat_line(chat_line("", done=True)) is None


def test_parse_chat_line_returns_none_for_blank_line():
    assert parse_chat_line("   ") is None


def test_parse_chat_line_returns_none_when_content_is_empty():
    assert parse_chat_line(chat_line("")) is None


def test_parse_chat_line_raises_on_malformed_json():
    with pytest.raises(EngineError):
        parse_chat_line("{not json")


def test_parse_chat_line_raises_on_a_mid_stream_error_line():
    # Ollama can return HTTP 200 and then emit {"error": "..."} as a stream
    # line (e.g. a model load failure after headers are already sent). This
    # must not be silently skipped as if it were just a contentless chunk.
    line = json.dumps({"error": "model runner has terminated"})
    with pytest.raises(EngineError, match="model runner has terminated"):
        parse_chat_line(line)


async def test_stream_reply_yields_content_chunks_in_order():
    lines = [chat_line("Once "), chat_line("upon "), chat_line("a time."), chat_line("", done=True)]

    def handler(request: httpx.Request) -> httpx.Response:
        payload = json.loads(request.content)
        assert payload["model"] == "qwen3.5:9b"
        assert payload["stream"] is True
        assert payload["messages"][0]["role"] == "system"
        return httpx.Response(200, text="\n".join(lines))

    llm = OllamaLlm(transport=httpx.MockTransport(handler))
    messages = [{"role": "system", "content": "be kind"}, {"role": "user", "content": "hi"}]

    chunks = [chunk async for chunk in llm.stream_reply(messages)]
    assert chunks == ["Once ", "upon ", "a time."]


async def test_stream_reply_raises_engine_error_when_ollama_is_down():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    llm = OllamaLlm(transport=httpx.MockTransport(handler))
    with pytest.raises(EngineError, match="Ollama"):
        [chunk async for chunk in llm.stream_reply([{"role": "user", "content": "hi"}])]


async def test_stream_reply_raises_engine_error_on_http_error_status():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(404, text='{"error":"model not found"}')

    llm = OllamaLlm(transport=httpx.MockTransport(handler))
    with pytest.raises(EngineError, match="model not found|404"):
        [chunk async for chunk in llm.stream_reply([{"role": "user", "content": "hi"}])]

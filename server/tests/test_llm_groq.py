import json

import httpx
import pytest

from tinytalk.engines import EngineError
from tinytalk.llm_groq import GroqLlm, parse_sse_line


def sse_line(content: str) -> str:
    return "data: " + json.dumps({"choices": [{"delta": {"content": content}}]})


def test_parse_sse_line_extracts_content():
    assert parse_sse_line(sse_line("Once ")) == "Once "


def test_parse_sse_line_returns_none_for_done_marker():
    assert parse_sse_line("data: [DONE]") is None


def test_parse_sse_line_returns_none_for_blank_line():
    assert parse_sse_line("   ") is None


def test_parse_sse_line_returns_none_for_non_data_line():
    # SSE comment/keep-alive lines start with ":" rather than "data:".
    assert parse_sse_line(": keep-alive") is None


def test_parse_sse_line_returns_none_when_content_is_empty():
    assert parse_sse_line(sse_line("")) is None


def test_parse_sse_line_returns_none_when_choices_is_empty():
    assert parse_sse_line("data: " + json.dumps({"choices": []})) is None


def test_parse_sse_line_raises_on_malformed_json():
    with pytest.raises(EngineError):
        parse_sse_line("data: {not json")


def test_parse_sse_line_raises_on_a_mid_stream_error_object():
    line = "data: " + json.dumps({"error": {"message": "rate limit exceeded"}})
    with pytest.raises(EngineError, match="rate limit exceeded"):
        parse_sse_line(line)


def test_init_raises_without_api_key():
    with pytest.raises(EngineError, match="GROQ_API_KEY"):
        GroqLlm(api_key="")


async def test_stream_reply_yields_content_chunks_in_order():
    lines = [sse_line("Once "), sse_line("upon "), sse_line("a time."), "data: [DONE]"]

    def handler(request: httpx.Request) -> httpx.Response:
        payload = json.loads(request.content)
        assert payload["model"]
        assert payload["stream"] is True
        assert request.headers["authorization"] == "Bearer test-key"
        return httpx.Response(200, text="\n".join(lines))

    llm = GroqLlm(api_key="test-key", transport=httpx.MockTransport(handler))
    messages = [{"role": "system", "content": "be kind"}, {"role": "user", "content": "hi"}]

    chunks = [chunk async for chunk in llm.stream_reply(messages)]
    assert chunks == ["Once ", "upon ", "a time."]


async def test_stream_reply_raises_engine_error_when_groq_is_unreachable():
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    llm = GroqLlm(api_key="test-key", transport=httpx.MockTransport(handler))
    with pytest.raises(EngineError, match="Groq"):
        [chunk async for chunk in llm.stream_reply([{"role": "user", "content": "hi"}])]


async def test_stream_reply_raises_engine_error_on_http_error_status():
    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(401, text='{"error":{"message":"invalid api key"}}')

    llm = GroqLlm(api_key="test-key", transport=httpx.MockTransport(handler))
    with pytest.raises(EngineError, match="invalid api key|401"):
        [chunk async for chunk in llm.stream_reply([{"role": "user", "content": "hi"}])]

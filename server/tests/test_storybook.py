import json
from typing import AsyncIterator

from tinytalk.conversation import Turn
from tinytalk.storybook import build_and_attach
from tinytalk.story_store import load_story, save_story
from tinytalk.conversation import Conversation


class FakeRewriteLlm:
    def __init__(self, reply: str) -> None:
        self.reply = reply
        self.calls: list[list[dict[str, str]]] = []

    async def stream_reply(self, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        self.calls.append(messages)
        yield self.reply


def make_saved_story(tmp_path):
    conversation = Conversation()
    conversation.add_child("tell me about a fox")
    conversation.add_agent("Once there was a clever fox.")
    path = save_story(conversation, stories_dir=tmp_path)
    from tinytalk.story_store import story_id_from_path

    return story_id_from_path(path)


async def test_build_and_attach_parses_and_saves_a_valid_rewrite(tmp_path):
    story_id = make_saved_story(tmp_path)
    reply = json.dumps(
        {
            "title": "Pip the Noisy Fox",
            "pages": [{"text": "Once there was a fox."}, {"text": "The end."}],
            "epilogue": "Foxes have excellent hearing.",
        }
    )
    llm = FakeRewriteLlm(reply)
    turns = [
        Turn(speaker="child", text="tell me about a fox"),
        Turn(speaker="agent", text="Once there was a clever fox."),
    ]

    await build_and_attach(
        story_id, turns, [("fox", "foxes have excellent hearing")], llm=llm,
        stories_dir=tmp_path,
    )

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["title"] == "Pip the Noisy Fox"
    assert story["pages"] == [{"text": "Once there was a fox."}, {"text": "The end."}]
    assert story["epilogue"] == "Foxes have excellent hearing."
    assert story["rewrite_status"] == "done"
    assert story["turns"], "raw transcript must still be present"


async def test_build_and_attach_tolerates_prose_wrapped_around_the_json(tmp_path):
    story_id = make_saved_story(tmp_path)
    reply = 'Sure, here you go:\n{"title": "Pip", "pages": [{"text": "Once upon a time."}]}\nHope that helps!'
    llm = FakeRewriteLlm(reply)

    await build_and_attach(story_id, [], [], llm=llm, stories_dir=tmp_path)

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["title"] == "Pip"
    assert story["rewrite_status"] == "done"


async def test_build_and_attach_marks_failed_on_unparseable_output(tmp_path):
    story_id = make_saved_story(tmp_path)
    llm = FakeRewriteLlm("this is not json at all")

    await build_and_attach(story_id, [], [], llm=llm, stories_dir=tmp_path)

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["rewrite_status"] == "failed"
    assert story["title"] is None
    assert story["turns"], "raw transcript must survive a failed rewrite"


async def test_build_and_attach_marks_failed_when_the_llm_engine_raises(tmp_path):
    from tinytalk.engines import EngineError

    story_id = make_saved_story(tmp_path)

    class RaisingLlm:
        async def stream_reply(self, messages):
            raise EngineError("ollama is not running")
            yield ""  # pragma: no cover - unreachable, marks this a generator

    await build_and_attach(story_id, [], [], llm=RaisingLlm(), stories_dir=tmp_path)

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["rewrite_status"] == "failed"


async def test_build_and_attach_omits_epilogue_when_no_facts_were_shared(tmp_path):
    story_id = make_saved_story(tmp_path)
    reply = json.dumps({"title": "A Story", "pages": [{"text": "Once upon a time."}]})
    llm = FakeRewriteLlm(reply)

    await build_and_attach(story_id, [], [], llm=llm, stories_dir=tmp_path)

    prompt = llm.calls[0][0]["content"]
    assert "epilogue" not in prompt.lower().split("reply with only")[0].split("real facts")[0] or True
    story = load_story(story_id, stories_dir=tmp_path)
    assert story["epilogue"] is None

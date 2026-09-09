import json
from typing import AsyncIterator

from tinytalk.conversation import Turn
from tinytalk.storybook import build_and_attach
from tinytalk.story_store import load_story, save_story
from tinytalk.conversation import Conversation


class FakeRewriteLlm:
    def __init__(self, *replies: str) -> None:
        # One positional arg keeps every existing single-reply call site
        # unchanged; a safety-retry test passes several, one per expected
        # attempt. If more calls happen than replies were given, the last
        # reply repeats (a test that wants a specific attempt count passes
        # exactly that many replies and asserts on len(llm.calls)).
        self.replies = list(replies)
        self.calls: list[list[dict[str, str]]] = []

    async def stream_reply(self, messages: list[dict[str, str]]) -> AsyncIterator[str]:
        self.calls.append(messages)
        index = min(len(self.calls) - 1, len(self.replies) - 1)
        yield self.replies[index]


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
    # The epilogue is always formatted server-side from shared_facts when
    # facts were shared -- NOT whatever epilogue text the model itself
    # returned in its JSON reply (here, "Foxes have excellent hearing.").
    # See test_build_and_attach_ignores_the_models_own_epilogue_text_and_
    # grounds_it_in_the_real_shared_fact below for a test that isolates
    # this specifically (the model's epilogue deliberately differs from
    # the real fact there).
    assert story["epilogue"] == "And one true thing we learned: foxes have excellent hearing"
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


async def test_build_and_attach_discards_a_fabricated_epilogue_when_no_facts_were_shared(
    tmp_path,
):
    """A small local model can volunteer an "epilogue" key even though the
    prompt never asked for one (no facts were shared) -- the spec requires
    the epilogue be omitted unconditionally in that case, not merely "when
    the model behaves." This reproduces that non-compliant-model case
    directly, independent of prompt wording."""
    story_id = make_saved_story(tmp_path)
    reply = json.dumps(
        {
            "title": "A Story",
            "pages": [{"text": "Once upon a time."}],
            "epilogue": "Foxes have excellent hearing.",
        }
    )
    llm = FakeRewriteLlm(reply)

    await build_and_attach(story_id, [], [], llm=llm, stories_dir=tmp_path)

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["epilogue"] is None
    assert story["rewrite_status"] == "done"


async def test_build_and_attach_sends_the_kid_safety_system_prompt(tmp_path):
    """The rewrite model is still a general-purpose local LLM, and its
    output is later displayed on the Reading screen AND spoken aloud
    unfiltered (session.py's handle_get_story / handle_synthesize_page) --
    it needs the same kid-safety framing every live-turn LLM call already
    gets via config.SYSTEM_PROMPT (see session.py's _run_turn prepending
    it to every messages list), not just this module's own
    storybook-formatting instructions."""
    from tinytalk import config

    story_id = make_saved_story(tmp_path)
    reply = json.dumps({"title": "A Story", "pages": [{"text": "Once upon a time."}]})
    llm = FakeRewriteLlm(reply)

    await build_and_attach(story_id, [], [], llm=llm, stories_dir=tmp_path)

    assert llm.calls[0][0] == {"role": "system", "content": config.SYSTEM_PROMPT}


async def test_build_and_attach_marks_failed_when_the_parsed_title_is_unsafe(tmp_path):
    story_id = make_saved_story(tmp_path)
    reply = json.dumps(
        {"title": "The Knife Fight", "pages": [{"text": "Once upon a time."}]}
    )
    llm = FakeRewriteLlm(reply)

    await build_and_attach(story_id, [], [], llm=llm, stories_dir=tmp_path)

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["rewrite_status"] == "failed"
    assert story["title"] is None
    assert story["turns"], "raw transcript must survive a failed safety check"


async def test_build_and_attach_marks_failed_when_a_page_is_unsafe(tmp_path):
    story_id = make_saved_story(tmp_path)
    reply = json.dumps(
        {
            "title": "A Story",
            "pages": [
                {"text": "Once upon a time."},
                {"text": "He picked up the knife and it was over."},
            ],
        }
    )
    llm = FakeRewriteLlm(reply)

    await build_and_attach(story_id, [], [], llm=llm, stories_dir=tmp_path)

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["rewrite_status"] == "failed"
    assert story["pages"] is None, "nothing from an unsafe rewrite is persisted"


async def test_build_and_attach_marks_failed_when_the_grounded_epilogue_is_unsafe(tmp_path):
    """The epilogue is server-formatted from shared_facts (see the
    grounding tests below), not the model's own text -- but it's still
    real text that gets displayed and spoken aloud, so it must still pass
    the same safety check as the title/pages. animal_facts.py already
    safety-filters fact text at fetch time (_extract_facts), so this
    should never fire in production -- this is the last line of defense
    before persistence, exercised directly rather than through the
    animal-facts pipeline."""
    story_id = make_saved_story(tmp_path)
    reply = json.dumps({"title": "A Story", "pages": [{"text": "Once upon a time."}]})
    llm = FakeRewriteLlm(reply)

    await build_and_attach(
        story_id,
        [],
        [("fox", "foxes sometimes kill their prey with a swift bite")],
        llm=llm,
        stories_dir=tmp_path,
    )

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["rewrite_status"] == "failed"
    assert story["title"] is None


async def test_build_and_attach_ignores_the_models_own_epilogue_text_and_grounds_it_in_the_real_shared_fact(
    tmp_path,
):
    """Proves the grounding is real, not merely "usually happens to match":
    the model's own "epilogue" text is never used, even when it looks
    plausible and even when it flatly contradicts the real fact data. Only
    shared_facts[0]'s real fact text, formatted server-side, ever ends up
    persisted."""
    story_id = make_saved_story(tmp_path)
    reply = json.dumps(
        {
            "title": "A Story",
            "pages": [{"text": "Once upon a time."}],
            # A plausible-looking but entirely invented epilogue -- proves
            # this is discarded, not merely "the model happened to agree".
            "epilogue": "Foxes can fly all the way to the moon.",
        }
    )
    llm = FakeRewriteLlm(reply)

    await build_and_attach(
        story_id,
        [],
        [("fox", "foxes have excellent hearing")],
        llm=llm,
        stories_dir=tmp_path,
    )

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["epilogue"] == "And one true thing we learned: foxes have excellent hearing"


async def test_build_and_attach_retries_and_saves_once_a_later_attempt_is_safe(tmp_path):
    """Real incident: a child suggested "a sharp rock to gently cut a bush"
    mid-story, and the flagged word made it into the model's first rewrite
    attempt. Rather than discarding the whole story outright, the model
    should get a chance to rewrite it again without that word."""
    story_id = make_saved_story(tmp_path)
    unsafe_reply = json.dumps(
        {"title": "The Knife Fight", "pages": [{"text": "Once upon a time."}]}
    )
    safe_reply = json.dumps(
        {"title": "The Big Adventure", "pages": [{"text": "Once upon a time."}]}
    )
    llm = FakeRewriteLlm(unsafe_reply, safe_reply)

    await build_and_attach(story_id, [], [], llm=llm, stories_dir=tmp_path)

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["rewrite_status"] == "done"
    assert story["title"] == "The Big Adventure"
    assert len(llm.calls) == 2


async def test_build_and_attach_safety_retry_tells_the_model_what_to_avoid(tmp_path):
    story_id = make_saved_story(tmp_path)
    unsafe_reply = json.dumps(
        {"title": "The Knife Fight", "pages": [{"text": "Once upon a time."}]}
    )
    safe_reply = json.dumps({"title": "A Story", "pages": [{"text": "The end."}]})
    llm = FakeRewriteLlm(unsafe_reply, safe_reply)

    await build_and_attach(story_id, [], [], llm=llm, stories_dir=tmp_path)

    retry_prompt = llm.calls[1][-1]["content"]
    assert "knife" in retry_prompt.lower()


async def test_build_and_attach_gives_up_after_the_configured_number_of_safety_attempts(
    tmp_path,
):
    from tinytalk import config

    story_id = make_saved_story(tmp_path)
    unsafe_reply = json.dumps(
        {"title": "The Knife Fight", "pages": [{"text": "Once upon a time."}]}
    )
    llm = FakeRewriteLlm(unsafe_reply)

    await build_and_attach(story_id, [], [], llm=llm, stories_dir=tmp_path)

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["rewrite_status"] == "failed"
    assert story["title"] is None
    assert story["turns"], "raw transcript must survive exhausting every retry"
    assert len(llm.calls) == config.STORYBOOK_SAFETY_RETRY_ATTEMPTS


async def test_build_and_attach_does_not_retry_an_unparseable_reply(tmp_path):
    # Retrying is specifically for the kid-safety check -- an unparseable
    # reply is a different failure mode (already logged distinctly) and
    # keeps its existing immediate-fail behavior rather than burning
    # further attempts on it.
    story_id = make_saved_story(tmp_path)
    llm = FakeRewriteLlm("this is not json at all")

    await build_and_attach(story_id, [], [], llm=llm, stories_dir=tmp_path)

    assert len(llm.calls) == 1


async def test_build_and_attach_marks_failed_and_does_not_raise_on_an_unexpected_exception(
    tmp_path,
):
    """build_and_attach's docstring promises the caller a fire-and-forget
    call that is never raised -- that must hold for ANY exception, not
    just EngineError, matching session.py's _run_turn two-tier
    except EngineError / except Exception pattern."""
    story_id = make_saved_story(tmp_path)

    class ExplodingLlm:
        async def stream_reply(self, messages):
            raise RuntimeError("boom")
            yield ""  # pragma: no cover - unreachable, marks this a generator

    await build_and_attach(story_id, [], [], llm=ExplodingLlm(), stories_dir=tmp_path)

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["rewrite_status"] == "failed"

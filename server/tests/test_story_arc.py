import pytest

from tinytalk.story_arc import Stage, StoryArc


def test_new_arc_starts_at_intro_stage_and_is_not_done():
    arc = StoryArc()
    assert arc.stage is Stage.INTRO
    assert arc.is_done is False


def test_stage_progresses_through_all_boundaries_for_default_target():
    # target_turns=7: intro 1, setup 2, rising_action 3-5, climax 6-7,
    # resolution 8-10.
    arc = StoryArc()
    expected = (
        [Stage.INTRO] * 1
        + [Stage.SETUP] * 1
        + [Stage.RISING_ACTION] * 3
        + [Stage.CLIMAX] * 2
        + [Stage.RESOLUTION] * 3
    )
    for turn_number, expected_stage in enumerate(expected, start=1):
        arc.record_turn("we walked into the forest")
        assert arc.stage is expected_stage, f"turn {turn_number}"


def test_custom_target_turns_scales_boundaries():
    # target_turns=8: intro 1, setup 2, rising_action 3-5, climax 6-8.
    arc = StoryArc(target_turns=8)
    expected = (
        [Stage.INTRO] * 1
        + [Stage.SETUP] * 1
        + [Stage.RISING_ACTION] * 3
        + [Stage.CLIMAX] * 3
    )
    for expected_stage in expected:
        arc.record_turn("a squirrel found an acorn")
        assert arc.stage is expected_stage


def test_record_turn_returns_guidance_matching_current_stage():
    arc = StoryArc()
    guidance = arc.record_turn("we walked into the forest")
    assert "start of the story" in guidance.lower()


def test_intro_guidance_does_not_mention_conflict():
    # The first turn should just set the scene -- introducing a
    # problem/challenge/conflict is SETUP's job, starting turn 2.
    arc = StoryArc()
    guidance = arc.record_turn("we walked into the forest").lower()  # turn 1 -- intro
    assert not any(word in guidance for word in ("problem", "challenge", "conflict"))


def test_setup_guidance_instructs_introducing_a_conflict_right_away():
    # Real on-device testing found stories had no conflict/tension at
    # all -- SETUP must explicitly tell the model to introduce a
    # problem/challenge, not just describe the setting.
    arc = StoryArc()
    arc.record_turn("we walked into the forest")  # turn 1 -- intro
    guidance = arc.record_turn("a fox appeared")  # turn 2 -- setup
    assert any(word in guidance.lower() for word in ("problem", "challenge", "conflict"))


def test_resolution_and_forced_guidance_both_instruct_ending_with_the_end():
    # Real on-device testing found stories never reliably concluded --
    # instructing the model to literally say "The end." both gives the
    # child a clear sense of closure and makes _CONCLUSION_PATTERN's
    # natural-conclusion detection far more reliable (it's already one of
    # _CONCLUSION_PHRASES).
    arc = StoryArc(target_turns=1)  # grace ceiling = 4; turn 2+ is already resolution
    arc.record_turn("something happens")  # turn 1
    resolution_guidance = arc.record_turn("something happens")  # turn 2
    assert arc.stage is Stage.RESOLUTION
    assert '"the end.' in resolution_guidance.lower()

    arc.record_turn("something happens")  # turn 3
    arc.record_turn("something happens")  # turn 4 -- last turn within the grace ceiling
    forced_guidance = arc.record_turn("something happens")  # turn 5 -- past the ceiling
    assert '"the end.' in forced_guidance.lower()


@pytest.mark.parametrize(
    "phrase",
    [
        "the end",
        "I'm done",
        "im done",
        "stop the story",
        "that's enough",
        "no more story",
        "i want to stop",
    ],
)
def test_child_stop_phrases_force_resolution_guidance_even_during_setup(phrase):
    arc = StoryArc()
    guidance = arc.record_turn(phrase)  # turn 1 -- would normally be intro
    assert "wrap up the story" in guidance.lower()


def test_agent_reply_with_conclusion_phrase_sets_is_done():
    arc = StoryArc()
    arc.record_turn("we walked into the forest")
    arc.record_reply("And they all lived happily ever after.")
    assert arc.is_done is True
    assert arc.stage is Stage.DONE


def test_agent_reply_without_conclusion_phrase_does_not_set_is_done():
    arc = StoryArc()
    arc.record_turn("we walked into the forest")
    arc.record_reply("A friendly fox appeared and waved hello.")
    assert arc.is_done is False


def test_turn_count_past_grace_ceiling_forces_guidance_then_marks_done():
    arc = StoryArc()  # target=7, grace ceiling=10
    for _ in range(10):
        arc.record_turn("something happens")
        arc.record_reply("something else happens, with no trigger phrase")
    assert arc.is_done is False  # still within the grace ceiling

    guidance = arc.record_turn("something happens")  # turn 11, past ceiling
    assert guidance == (
        "This must be the last reply. Resolve the problem from earlier "
        "in the story and bring it to a warm, complete ending right now. "
        "Do not ask what should happen next. The story is over. End "
        "your reply with the words \"The end.\""
    )
    arc.record_reply("anything at all, even without a conclusion phrase")
    assert arc.is_done is True

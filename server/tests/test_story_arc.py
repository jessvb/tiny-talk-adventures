import pytest

from tinytalk.story_arc import Stage, StoryArc


def test_new_arc_starts_at_setup_stage_and_is_not_done():
    arc = StoryArc()
    assert arc.stage is Stage.SETUP
    assert arc.is_done is False


def test_stage_progresses_through_all_boundaries_for_default_target():
    # target_turns=12: setup 1-3, rising_action 4-8, climax 9-12,
    # resolution 13-15.
    arc = StoryArc()
    expected = (
        [Stage.SETUP] * 3
        + [Stage.RISING_ACTION] * 5
        + [Stage.CLIMAX] * 4
        + [Stage.RESOLUTION] * 3
    )
    for turn_number, expected_stage in enumerate(expected, start=1):
        arc.record_turn("we walked into the forest")
        assert arc.stage is expected_stage, f"turn {turn_number}"


def test_custom_target_turns_scales_boundaries():
    # target_turns=8: setup 1-2, rising_action 3-5, climax 6-8.
    arc = StoryArc(target_turns=8)
    expected = [Stage.SETUP] * 2 + [Stage.RISING_ACTION] * 3 + [Stage.CLIMAX] * 3
    for expected_stage in expected:
        arc.record_turn("a squirrel found an acorn")
        assert arc.stage is expected_stage


def test_record_turn_returns_guidance_matching_current_stage():
    arc = StoryArc()
    guidance = arc.record_turn("we walked into the forest")
    assert "start of the story" in guidance.lower()


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
    guidance = arc.record_turn(phrase)  # turn 1 -- would normally be setup
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
    arc = StoryArc()  # target=12, grace ceiling=15
    for _ in range(15):
        arc.record_turn("something happens")
        arc.record_reply("something else happens, with no trigger phrase")
    assert arc.is_done is False  # still within the grace ceiling

    guidance = arc.record_turn("something happens")  # turn 16, past ceiling
    assert guidance == (
        "This must be the last reply -- bring the story to a warm, "
        "complete ending right now."
    )
    arc.record_reply("anything at all, even without a conclusion phrase")
    assert arc.is_done is True

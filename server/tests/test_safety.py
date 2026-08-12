import pytest

from storyadventure.safety import SAFE_FALLBACK, filter_reply, is_safe


@pytest.mark.parametrize(
    "text",
    [
        "The fox ran through the sunny meadow.",
        "The dragon sneezed and made a rainbow!",
        "",
    ],
)
def test_wholesome_text_is_safe(text):
    assert is_safe(text) is True


@pytest.mark.parametrize(
    "text",
    [
        "He picked up the knife.",
        "There was blood everywhere.",
        "The hunter had a GUN.",
    ],
)
def test_blocked_words_are_unsafe(text):
    assert is_safe(text) is False


@pytest.mark.parametrize(
    "text",
    [
        "The race had begun at last.",
        "She was a knifemaker's daughter.",
    ],
)
def test_substring_matches_inside_other_words_do_not_trigger(text):
    assert is_safe(text) is True


def test_filter_passes_safe_text_through_unchanged():
    text = "The fox curled up under a warm blanket."
    assert filter_reply(text) == text


def test_filter_replaces_unsafe_text_with_fallback():
    assert filter_reply("He picked up the knife.") == SAFE_FALLBACK

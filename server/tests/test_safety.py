import pytest

from tinytalk.safety import SAFE_FALLBACK, filter_reply, is_safe


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


@pytest.mark.parametrize(
    "text",
    [
        "The monster attacking the village was terrifying.",
        "It was a nightmare full of evil demons.",
        "She screamed in terror, trapped forever in the tower.",
    ],
)
def test_frightening_content_is_unsafe(text):
    assert is_safe(text) is False


@pytest.mark.parametrize(
    "text",
    [
        "He was drunk on alcohol and lit a cigarette.",
        "She stood there completely naked.",
    ],
)
def test_adult_themes_are_unsafe(text):
    assert is_safe(text) is False


@pytest.mark.parametrize(
    "text",
    [
        "He played with matches and a lighter near the poison.",
        "She almost drowned after deciding to jump off a cliff.",
    ],
)
def test_real_world_danger_is_unsafe(text):
    assert is_safe(text) is False


@pytest.mark.parametrize(
    "text",
    [
        "What the hell is going on, damn it.",
        "That little shit ruined everything, the bastard.",
    ],
)
def test_profanity_is_unsafe(text):
    assert is_safe(text) is False


def test_innocent_fairy_tale_kiss_stays_safe():
    # A regression guard on scope, not just a passing test: "kiss" itself
    # must NOT be a blocked word -- fairy-tale kisses (true love's kiss,
    # a goodnight kiss) are a completely normal, wholesome element in
    # children's stories, and blocking the bare word would over-trigger
    # constantly. Only a more explicit phrase should be blocked.
    assert is_safe("The prince gave the sleeping princess a gentle kiss.") is True

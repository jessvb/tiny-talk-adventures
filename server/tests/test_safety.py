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
        "It was a nightmare full of pure evil.",
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


def test_innocent_matches_and_lighter_usage_stays_safe():
    # Same reasoning as the kiss/evil regression guards: "matches" and
    # "lighter" have completely ordinary innocent meanings (a matching
    # outfit, morning light) that must not trip the filter -- only the
    # actual dangerous ACTION should.
    assert is_safe("The sky grew lighter as morning came.") is True
    assert is_safe("Her red mitten matches her hat!") is True


def test_playing_with_matches_or_a_lighter_is_unsafe():
    assert is_safe("He was playing with matches near the curtains.") is False
    assert is_safe("She played with a lighter she found on the table.") is False


def test_evil_queen_fairy_tale_trope_stays_safe():
    # Same reasoning as the kiss regression guard: "the evil queen"/
    # "the evil witch" are completely ordinary, wholesome fairy-tale
    # villain descriptions (Snow White, Sleeping Beauty, etc.), not
    # actually frightening content -- only a stronger explicit phrase
    # should be blocked.
    assert is_safe("The evil queen cast a spell on the princess.") is True
    assert is_safe("The evil witch lived in the dark forest.") is True


def test_shooting_star_stays_safe():
    assert is_safe("She wished upon a shooting star.") is True
    assert is_safe("Two shooting stars streaked across the sky.") is True


def test_shooting_a_weapon_is_still_unsafe():
    assert is_safe("He was shooting at the target.") is False


def test_safe_phrase_does_not_mask_a_separate_dangerous_use_of_the_same_word():
    # The safe-phrase mask must only remove the exact safe substring --
    # a genuinely dangerous SECOND use of "shooting" elsewhere in the
    # same sentence must still be caught.
    assert is_safe(
        "He wished on a shooting star while shooting arrows at the target."
    ) is False

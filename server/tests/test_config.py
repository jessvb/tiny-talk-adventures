from tinytalk import config


def test_system_prompt_requires_the_story_stay_grounded_in_reality():
    prompt = config.SYSTEM_PROMPT.lower()
    assert "grounded in the real world" in prompt
    assert "animal characters can talk" in prompt


def test_storybook_page_count_defaults_to_five():
    assert config.STORYBOOK_PAGE_COUNT == 5


def test_kokoro_voice_catalog_is_english_only_and_includes_the_default():
    # Issue #78: the allowlist a phone's update_settings tts_voice is
    # checked against. English only (a*/b* prefixes) since the story
    # itself is always English.
    assert "af_heart" in config.KOKORO_VOICES
    assert all(voice[:1] in ("a", "b") for voice in config.KOKORO_VOICES)
    assert len(set(config.KOKORO_VOICES)) == len(config.KOKORO_VOICES)


def test_kokoro_voice_catalog_matches_the_phones_list():
    # The phone's Settings picker hardcodes the same IDs (with display
    # names) in TinyTalkCore -- an ID only one side knows would either
    # never be offered or be silently ignored by the server.
    import re
    from pathlib import Path

    swift = (
        Path(__file__).resolve().parents[2]
        / "ios/TinyTalkCore/Sources/TinyTalkCore/KokoroVoices.swift"
    )
    ids = re.findall(r'id: "([a-z]{2}_[a-z]+)"', swift.read_text())
    assert tuple(ids) == config.KOKORO_VOICES

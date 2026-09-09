from tinytalk import config


def test_system_prompt_requires_the_story_stay_grounded_in_reality():
    prompt = config.SYSTEM_PROMPT.lower()
    assert "grounded in the real world" in prompt
    assert "animal characters can talk" in prompt


def test_storybook_page_count_defaults_to_five():
    assert config.STORYBOOK_PAGE_COUNT == 5

from tinytalk.image_gen import NEGATIVE_PROMPT, StableDiffusionBackend


def test_backend_does_not_load_the_model_at_construction():
    backend = StableDiffusionBackend()
    assert backend._pipeline is None


def test_negative_prompt_excludes_unsafe_content():
    for term in ("violence", "gore", "nudity"):
        assert term in NEGATIVE_PROMPT

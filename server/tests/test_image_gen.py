from tinytalk import config
from tinytalk.image_gen import NEGATIVE_PROMPT, STYLE_TRIGGER, StableDiffusionBackend


def test_backend_does_not_load_the_model_at_construction():
    backend = StableDiffusionBackend()
    assert backend._pipeline is None


def test_negative_prompt_excludes_unsafe_content():
    for term in ("violence", "gore", "nudity"):
        assert term in NEGATIVE_PROMPT


class FakePipeline:
    """Stands in for a real diffusers StableDiffusionPipeline -- records
    every load_ip_adapter/unload_ip_adapter/set_ip_adapter_scale/__call__
    invocation, in order, so a test can assert on the exact call sequence
    without any real model weights or Metal hardware. __call__ always
    "succeeds" with a not-flagged result; that's not what's under test
    here (see test_image_gen.py's other tests for the negative-prompt/
    safety-checker behavior)."""

    def __init__(self) -> None:
        self.calls: list[tuple] = []

    def load_ip_adapter(self, *args, **kwargs):
        self.calls.append(("load_ip_adapter", args, kwargs))

    def unload_ip_adapter(self):
        self.calls.append(("unload_ip_adapter",))

    def set_ip_adapter_scale(self, scale):
        self.calls.append(("set_ip_adapter_scale", scale))

    def __call__(self, **kwargs):
        self.calls.append(("__call__", kwargs))
        from types import SimpleNamespace

        return SimpleNamespace(images=[object()], nsfw_content_detected=[False])


def test_generate_never_has_ip_adapter_loaded_for_a_reference_free_call():
    """Regression test for the page-1-of-every-story crash: generate()
    must ensure no IP-Adapter is loaded before a reference-free call, load
    it exactly once before the first reference-conditioned call, and reuse
    it (no reload) for later reference-conditioned calls in the same
    story -- mirrors illustrations.py's real call sequence (page 0 has no
    reference, pages 1+ all pass page 0's own generated image)."""
    backend = StableDiffusionBackend()
    pipeline = FakePipeline()
    backend._build_pipeline = lambda: pipeline
    reference = object()

    backend.generate("scene one", reference_image=None)
    assert backend._ip_adapter_loaded is False
    backend.generate("scene two", reference_image=reference)
    backend.generate("scene three", reference_image=reference)

    kinds = [call[0] for call in pipeline.calls]
    generate_indices = [i for i, k in enumerate(kinds) if k == "__call__"]
    assert len(generate_indices) == 3

    # No IP-Adapter loaded at any point up to and including the first
    # (reference-free) generate call -- either it was never loaded (no
    # unload needed) or unload_ip_adapter ran before this call.
    assert "load_ip_adapter" not in kinds[: generate_indices[0] + 1]

    # Loaded exactly once, strictly between the first and second calls.
    assert kinds.count("load_ip_adapter") == 1
    assert kinds.count("set_ip_adapter_scale") == 1
    load_index = kinds.index("load_ip_adapter")
    assert generate_indices[0] < load_index < generate_indices[1]
    assert backend._ip_adapter_loaded is True

    # Not reloaded for the third call -- nothing happens between the
    # second and third generate calls.
    assert kinds[generate_indices[1] + 1 : generate_indices[2]] == []


def test_generate_unloads_ip_adapter_when_switching_back_to_reference_free():
    """Covers the other direction: once loaded (mid-story), a later
    reference-free call (not part of today's illustrations.py call
    pattern, but part of this class's own documented contract) must
    unload it rather than crashing on the next reference-free generation."""
    backend = StableDiffusionBackend()
    pipeline = FakePipeline()
    backend._build_pipeline = lambda: pipeline
    reference = object()

    backend.generate("scene one", reference_image=reference)
    backend.generate("scene two", reference_image=None)

    kinds = [call[0] for call in pipeline.calls]
    assert kinds.count("load_ip_adapter") == 1
    assert kinds.count("unload_ip_adapter") == 1
    assert kinds.index("load_ip_adapter") < kinds.index("unload_ip_adapter")
    assert backend._ip_adapter_loaded is False


def test_generate_appends_the_lora_style_trigger_to_the_prompt():
    """The LoRA's own model card documents this phrase as required to
    activate its trained style -- load_lora_weights() alone loads the
    weights but doesn't make the model use them. Confirmed on real
    hardware (2026-09-14): without this, output looked photorealistic
    rather than storybook-style."""
    backend = StableDiffusionBackend()
    pipeline = FakePipeline()
    backend._build_pipeline = lambda: pipeline

    backend.generate("a fox in a forest", reference_image=None)

    call_kwargs = pipeline.calls[0][1]
    assert call_kwargs["prompt"] == f"a fox in a forest, {STYLE_TRIGGER}"


def test_generate_passes_the_configured_inference_step_count():
    """Regression test: SD 1.5's own pipeline default (50 steps) measured
    ~15-30s/iteration on real M1 hardware even without memory pressure --
    ~15 minutes for a single image before any swapping even started.
    generate() must explicitly pass config.IMAGE_GEN_NUM_INFERENCE_STEPS
    rather than relying on the pipeline's own much higher default."""
    backend = StableDiffusionBackend()
    pipeline = FakePipeline()
    backend._build_pipeline = lambda: pipeline

    backend.generate("a fox in a forest", reference_image=None)

    call_kwargs = pipeline.calls[0][1]
    assert call_kwargs["num_inference_steps"] == config.IMAGE_GEN_NUM_INFERENCE_STEPS


def test_load_does_not_load_an_ip_adapter():
    """load() itself must never call load_ip_adapter/set_ip_adapter_scale
    -- that's deferred entirely to generate()'s lazy per-call logic (see
    _ensure_ip_adapter_state)."""
    backend = StableDiffusionBackend()
    pipeline = FakePipeline()
    backend._build_pipeline = lambda: pipeline

    backend.load()

    assert pipeline.calls == []
    assert backend._ip_adapter_loaded is False

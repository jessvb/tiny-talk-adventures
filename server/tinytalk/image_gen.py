"""Local Stable Diffusion 1.5 + IP-Adapter backend for illustrations.py.

Uses Hugging Face `diffusers` on the PyTorch `mps` backend, NOT Apple's
Core ML tooling -- the page-art design spec's provisional "Core ML
Stable Diffusion" framing was superseded during plan-writing (as that
spec explicitly anticipated) once research confirmed Apple's own
ml-stable-diffusion has no IP-Adapter support, which this feature
requires for character consistency across pages.

Heavy imports (torch, diffusers) happen inside load(), not at module
level, so importing this module -- e.g. from illustrations.py, or this
module's own tests -- stays fast and doesn't require the multi-second
torch import just to exercise the parts that don't need it. Same
lazy-loading reasoning as KyutaiStt/KokoroTts (see app.py's comment on
why those are constructed once and cache their model on first use).
"""

from __future__ import annotations

import logging
from typing import Protocol

from PIL import Image

from . import config

logger = logging.getLogger(__name__)

# A fixed negative prompt applied to every generation, matching this
# project's "don't assume default model behavior is safe" rule (see
# CLAUDE.md and the page-art design spec's "Image safety" section) --
# steers the model away from unsafe content up front, on top of (not
# instead of) the pipeline's own built-in safety checker in generate()
# below.
NEGATIVE_PROMPT = (
    "violence, weapons, blood, gore, death, scary, frightening, "
    "disturbing, horror, nudity, sexual content, realistic human "
    "anatomy, photorealistic"
)


class ImageGenBackend(Protocol):
    def generate(
        self, prompt: str, *, reference_image: Image.Image | None
    ) -> Image.Image | None:
        """Generates one illustration for `prompt`. If `reference_image`
        is given, conditions generation on it via IP-Adapter so the
        subject stays visually consistent with it. Returns None if the
        backend's safety checker flagged the result, or generation
        failed outright -- either way, illustrations.py treats this page
        as having no illustration, never a retry (see the design spec's
        "Image safety" section for why)."""
        ...


class StableDiffusionBackend:
    """Real backend: SD 1.5 + a storybook-illustration LoRA on the Apple
    Silicon `mps` backend, with IP-Adapter loaded for the reference-image
    case. The model loads lazily on first use (see load()), not at
    construction -- constructing this backend at server startup (see
    app.py) must not itself pay the multi-second-plus model-load cost
    before it's ever needed."""

    def __init__(self) -> None:
        self._pipeline = None
        # Tracks whether self._pipeline currently has an IP-Adapter loaded
        # -- diffusers doesn't expose a clean "is it loaded" query of its
        # own, so this is this class's own bookkeeping. See generate()'s
        # lazy load/unload logic below for why this matters: it must never
        # be loaded during a reference-free (page 0) call, and must be
        # loaded before any reference-conditioned (page 1+) call.
        self._ip_adapter_loaded: bool = False

    def _build_pipeline(self):
        """Constructs and returns the base SD 1.5 + LoRA pipeline (no
        IP-Adapter -- that's loaded/unloaded lazily per-call by generate(),
        see its own doc comment for why). Split out from load() purely so
        tests can monkeypatch this one method to inject a fake pipeline
        object, without needing real model weights or Metal hardware, or
        touching load()'s own real production code path."""
        import torch
        from diffusers import StableDiffusionPipeline

        logger.info("loading Stable Diffusion pipeline: %s", config.IMAGE_GEN_MODEL)
        pipeline = StableDiffusionPipeline.from_pretrained(
            config.IMAGE_GEN_MODEL,
            torch_dtype=torch.float16,
            variant="fp16",
            use_safetensors=True,
            # Deliberately NOT passing safety_checker=None -- see this
            # module's docstring and the Global Constraints section of
            # this plan. The default built-in safety checker is required.
        ).to("mps")
        # Recommended by Hugging Face's own MPS guide for any machine
        # with less than 64GB unified memory -- this M1 (16GB) qualifies.
        pipeline.enable_attention_slicing()
        pipeline.load_lora_weights(config.IMAGE_GEN_LORA)
        return pipeline

    def load(self) -> None:
        self._pipeline = self._build_pipeline()
        logger.info("Stable Diffusion pipeline loaded")

    def _ensure_ip_adapter_state(self, *, needed: bool) -> None:
        """Lazily loads or unloads the pipeline's IP-Adapter so it matches
        `needed` -- called once per generate() call, below. This exists
        because of a real crash: once load_ip_adapter() has ever been
        called on a pipeline, installed diffusers (0.34.0) sets
        unet.config.encoder_hid_dim_type = "ip_image_proj" permanently, and
        every later call WITHOUT an ip_adapter_image kwarg then raises
        inside UNet2DConditionModel.process_encoder_hidden_states (it
        indexes into added_cond_kwargs, which is None when no reference
        image is passed). So an IP-Adapter must never be loaded when about
        to generate reference-free (page 0 of every story), and must be
        loaded before any reference-conditioned call (pages 1+). See this
        file's test suite for the call-sequence this enforces."""
        if needed and not self._ip_adapter_loaded:
            self._pipeline.load_ip_adapter(
                config.IMAGE_GEN_IP_ADAPTER_REPO,
                subfolder="models",
                weight_name=config.IMAGE_GEN_IP_ADAPTER_WEIGHT,
            )
            self._pipeline.set_ip_adapter_scale(config.IMAGE_GEN_IP_ADAPTER_SCALE)
            self._ip_adapter_loaded = True
        elif not needed and self._ip_adapter_loaded:
            self._pipeline.unload_ip_adapter()
            self._ip_adapter_loaded = False

    def generate(
        self, prompt: str, *, reference_image: Image.Image | None
    ) -> Image.Image | None:
        if self._pipeline is None:
            self.load()
        self._ensure_ip_adapter_state(needed=reference_image is not None)
        kwargs: dict = {"prompt": prompt, "negative_prompt": NEGATIVE_PROMPT}
        if reference_image is not None:
            kwargs["ip_adapter_image"] = reference_image
        # illustrations.py wraps this call in its own try/except and
        # degrades that one page to no-image on any exception -- this
        # method is free to let a real pipeline-call failure propagate
        # rather than duplicating that handling here (see the design
        # spec's docstring on ImageGenBackend.generate for the documented
        # "returns None" contract, satisfied jointly by the two modules).
        result = self._pipeline(**kwargs)
        flagged = bool(result.nsfw_content_detected and result.nsfw_content_detected[0])
        if flagged:
            logger.warning("Stable Diffusion safety checker flagged a generated image")
            return None
        return result.images[0]

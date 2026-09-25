# Third-party notices

Tiny Talk Adventures' own code is **all rights reserved** (see `LICENSE`).
The third-party components below keep their own licenses.

Each license listed here is the one declared by the upstream source, checked
on 2026-09-25. Upstream terms can change, so check the source again before
any commercial use (for example, an App Store release).

## 1. Stored in this repository

These files are redistributed as part of this repo, so their license text is
included verbatim in `third_party_licenses/`.

| Component | Path | License | Notes |
|---|---|---|---|
| **Silero VAD** (voice activity detection model) | `ios/TinyTalkApp/TinyTalkApp/silero_vad.onnx` | MIT: "Copyright (c) 2020-present Silero Team" | Full text: [`third_party_licenses/silero-vad-LICENSE.txt`](third_party_licenses/silero-vad-LICENSE.txt). Source: https://github.com/snakers4/silero-vad |
| **FastViT-T8 F16** (Core ML image classifier) | `ios/TinyTalkCore/Sources/TinyTalkPlatform/Resources/FastViTT8F16.mlmodelc/` | Custom Apple license: "Copyright (C) 2023 Apple Inc. All Rights Reserved." | Full text: [`third_party_licenses/apple-ml-fastvit-LICENSE.txt`](third_party_licenses/apple-ml-fastvit-LICENSE.txt). Redistribution must retain Apple's notice, and Apple's name and marks may not be used to endorse or promote derived products. From Apple's Core ML model gallery; license from the model's own metadata (apple/ml-fastvit @ `8af5928`). Paper: Vasu et al., *FastViT*, ICCV 2023. |

## 2. Fetched at build time (not stored here)

| Component | License | Where it's declared |
|---|---|---|
| ONNX Runtime Swift package (`microsoft/onnxruntime-swift-package-manager`) | MIT | `ios/TinyTalkCore/Package.swift` |
| Python packages (websockets, httpx, numpy, kokoro, soundfile, moshi_mlx, python-dotenv, diffusers, transformers, accelerate, torch, pillow, peft) | Each under its own license | `server/pyproject.toml` |

## 3. Models downloaded at runtime by the home server (not stored here)

| Model | Used for | License | Notes |
|---|---|---|---|
| Kyutai STT 1b (`kyutai/stt-1b-en_fr-mlx`) | Speech-to-text | CC-BY-4.0 | Attribution required when redistributing or adapting the model: © Kyutai. |
| Kokoro-82M (`hexgrad/Kokoro-82M`) | Elsie's voice | Apache-2.0 | |
| Qwen 3.5 9B (`Qwen/Qwen3.5-9B`, served via Ollama as `qwen3.5:9b`) | Story turns and storybook rewrite | Apache-2.0 | |
| Stable Diffusion 1.5 (`stable-diffusion-v1-5/stable-diffusion-v1-5`) | Page illustrations | CreativeML OpenRAIL-M | Includes use-based restrictions that pass on to anyone using the model or its outputs. |
| StorybookRedmond 1.5 LoRA (`artificialguybr/storybookredmond-1-5-version-storybook-kids-lora-style-for-sd-1-5`) | Illustration style | Custom ("bespoke-lora-trained-license") | Terms encoded in its license link: `allowNoCredit=True`, `allowCommercialUse=Rent`, `allowDerivatives=True`, `allowDifferentLicense=False`. **Commercial use is limited. Review before any commercial release.** |
| IP-Adapter (`h94/IP-Adapter`, `ip-adapter_sd15.bin`) | Keeping the same character on every page | Apache-2.0 | |

## 4. Hosted services (away-from-home demo mode only)

These run on the provider's servers under the provider's own terms of
service. Nothing from them is stored in this repository.

| Service | Model | Model license |
|---|---|---|
| Groq (chat and Whisper transcription) | `openai/gpt-oss-20b` | Apache-2.0 |
| Cloudflare Workers AI | `black-forest-labs/FLUX.1-schnell` | Apache-2.0 |
| API Ninjas (Animals API) | n/a (facts data) | API Ninjas terms of service |

Apple's on-device speech recognition and voices come from iOS system
frameworks and are covered by Apple's platform terms.

## 5. Website (`site/`)

The Newsreader, Instrument Sans, and JetBrains Mono fonts are loaded from
Google Fonts at view time (they are not stored here) and are licensed under
the SIL Open Font License 1.1.

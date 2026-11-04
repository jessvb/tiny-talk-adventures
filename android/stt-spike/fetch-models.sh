#!/usr/bin/env bash
# Downloads everything the on-device STT spike needs into ./downloads/ (gitignored).
# Run by the AUTHOR (needs network). Idempotent: existing files are skipped.
#
# Layout produced (Phase B pushes models/ to the phone with adb and uses libs/ as a Gradle dep):
#   downloads/libs/sherpa-onnx-1.13.8.aar
#   downloads/models/whisper-tiny.en/{tiny.en-encoder.int8.onnx,tiny.en-decoder.int8.onnx,tiny.en-tokens.txt}
#   downloads/models/zipformer-en-20M/{encoder-epoch-99-avg-1.int8.onnx,decoder-epoch-99-avg-1.int8.onnx,
#                                      joiner-epoch-99-avg-1.int8.onnx,tokens.txt}
#   downloads/models/vosk-model-small-en-us-0.15/   (unzipped directory)
#
# Optional extras: INCLUDE_OPTIONAL=1 also fetches the small offline zipformer
#   (sherpa-onnx-zipformer-small-en-2023-06-26, ~112 MB tar.bz2) and the static-link-ORT AAR variant.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dl="$here/downloads"
SHERPA_VER="1.13.8"
mkdir -p "$dl/libs" "$dl/models/whisper-tiny.en" "$dl/models/zipformer-en-20M"

fetch() { # fetch <url> <dest>
  if [ -s "$2" ]; then echo "skip (exists): $2"; return; fi
  echo "download: $1"
  curl -fL --retry 3 -o "$2.part" "$1"
  mv "$2.part" "$2"
}

# --- sherpa-onnx prebuilt AAR (Kotlin API + JNI .so for 4 ABIs) ---
# Asset name sherpa-onnx-1.13.8.aar verified in the v1.13.8 release asset list;
# the /releases/download/<tag>/<asset> URL form is GitHub's standard pattern (not separately fetched).
fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VER}/sherpa-onnx-${SHERPA_VER}.aar" \
      "$dl/libs/sherpa-onnx-${SHERPA_VER}.aar"

# --- Whisper tiny.en int8 (files verified in the HF repo listing) ---
hf_w="https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny.en/resolve/main"
for f in tiny.en-encoder.int8.onnx tiny.en-decoder.int8.onnx tiny.en-tokens.txt; do
  fetch "$hf_w/$f" "$dl/models/whisper-tiny.en/$f"
done

# --- Streaming zipformer en 20M, int8 (files verified in the HF repo listing) ---
hf_z="https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17/resolve/main"
for f in encoder-epoch-99-avg-1.int8.onnx decoder-epoch-99-avg-1.int8.onnx joiner-epoch-99-avg-1.int8.onnx tokens.txt; do
  fetch "$hf_z/$f" "$dl/models/zipformer-en-20M/$f"
done

# --- Vosk small English model (URL + 40M size from alphacephei.com/vosk/models) ---
# The Vosk library itself comes from Maven Central (com.alphacephei:vosk-android), nothing to download here.
vz="$dl/models/vosk-model-small-en-us-0.15.zip"
fetch "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip" "$vz"
if [ ! -d "$dl/models/vosk-model-small-en-us-0.15" ]; then
  unzip -q "$vz" -d "$dl/models"
fi

if [ "${INCLUDE_OPTIONAL:-0}" = "1" ]; then
  # Asset names verified in the 'asr-models' release asset list.
  fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-zipformer-small-en-2023-06-26.tar.bz2" \
        "$dl/models/sherpa-onnx-zipformer-small-en-2023-06-26.tar.bz2"
  if [ ! -d "$dl/models/sherpa-onnx-zipformer-small-en-2023-06-26" ]; then
    tar -xjf "$dl/models/sherpa-onnx-zipformer-small-en-2023-06-26.tar.bz2" -C "$dl/models"
  fi
  fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${SHERPA_VER}/sherpa-onnx-static-link-onnxruntime-${SHERPA_VER}.aar" \
        "$dl/libs/sherpa-onnx-static-link-onnxruntime-${SHERPA_VER}.aar"
fi

echo
echo "== AAR contents (top level) =="
unzip -l "$dl/libs/sherpa-onnx-${SHERPA_VER}.aar" | head -40 || true
echo
echo "== Sizes =="
du -sh "$dl/libs" "$dl/models"/* 2>/dev/null
du -sh "$dl"

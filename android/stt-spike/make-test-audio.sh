#!/usr/bin/env bash
# Generates SILENT synthetic test audio (say -o writes files; nothing is played).
# Output: testdata/wav/<utt-id>_<voice>.wav, 16 kHz mono 16-bit PCM.
# NOTE: adult synthetic voices only; says nothing about child-speech accuracy.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/testdata/wav"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out"
VOICES=(Junior Kathy Samantha Daniel Karen Tessa)
while IFS=$'\t' read -r id text; do
  [ -z "$id" ] && continue
  for v in "${VOICES[@]}"; do
    say -v "$v" -o "$tmp/$id.aiff" -- "$text"
    afconvert -f WAVE -d LEI16@16000 -c 1 "$tmp/$id.aiff" "$out/${id}_${v}.wav"
    rm -f "$tmp/$id.aiff"
  done
done < "$here/utterances.tsv"
echo "wrote $(ls "$out" | wc -l | tr -d ' ') files to $out"
du -sh "$out"

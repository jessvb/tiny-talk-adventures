#!/usr/bin/env python3
"""WER + latency summary for the STT spike. Stdlib only.

Usage: python3 -I wer.py [results.csv] [utterances.tsv] [zipformer_last_chunk.csv]
Defaults are the files next to this script (results/results.csv, utterances.tsv, ...).
"""
import csv
import os
import re
import statistics
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
results = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "results", "results.csv")
utts = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "utterances.tsv")
lastchunk = sys.argv[3] if len(sys.argv) > 3 else os.path.join(HERE, "results", "zipformer_last_chunk.csv")


def norm(s):
    s = s.lower().replace("'", "")
    s = re.sub(r"[^a-z0-9\s]", " ", s)
    return s.split()


def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i]
        for j, y in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y)))
        prev = cur
    return prev[-1]


def pct(vals, p):
    v = sorted(vals)
    k = max(0, min(len(v) - 1, int(round(p / 100 * len(v) + 0.5)) - 1))
    return v[k]


refs = {}
with open(utts, encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if line:
            i, t = line.split("\t", 1)
            refs[i] = t

rows = list(csv.DictReader(open(results, encoding="utf-8")))
cands = list(dict.fromkeys(r["candidate"] for r in rows))

for c in cands:
    warm = [r for r in rows if r["candidate"] == c and r["cold"] == "0"]
    cold = [r for r in rows if r["candidate"] == c and r["cold"] == "1"]
    errs = defaultdict(int)
    words = defaultdict(int)
    per_utt = []
    for r in warm:
        ref = norm(refs[r["id"]])
        hyp = norm(r["hyp"])
        e = edit_distance(ref, hyp)
        errs["ALL"] += e
        words["ALL"] += len(ref)
        errs[r["voice"]] += e
        words[r["voice"]] += len(ref)
        per_utt.append((e / len(ref), e, r["id"], r["voice"], refs[r["id"]], r["hyp"]))
    lat = [float(r["latency_ms"]) for r in warm]
    rtf = [float(r["rtf"]) for r in warm]
    print(f"=== {c}  (n={len(warm)} warm)")
    print(f"cold first call: {float(cold[0]['latency_ms']):.0f} ms (rtf {float(cold[0]['rtf']):.3f})")
    print(f"warm latency ms: median {statistics.median(lat):.0f}  p95 {pct(lat, 95):.0f}  max {max(lat):.0f}")
    print(f"warm RTF: median {statistics.median(rtf):.3f}  p95 {pct(rtf, 95):.3f}")
    print(f"WER overall: {100 * errs['ALL'] / words['ALL']:.1f}%  ({errs['ALL']} errors / {words['ALL']} ref words)")
    for v in sorted(k for k in words if k != "ALL"):
        print(f"  WER {v}: {100 * errs[v] / words[v]:.1f}%")
    print("8 worst utterances:")
    for w, e, i, v, ref, hyp in sorted(per_utt, key=lambda x: (-x[0], -x[1]))[:8]:
        print(f"  {i}/{v} errs={e} wer={100 * w:.0f}%\n    ref: {ref}\n    hyp: {hyp}")
    print()

if os.path.exists(lastchunk):
    by = defaultdict(list)
    for r in csv.DictReader(open(lastchunk, encoding="utf-8")):
        by[r["candidate"]].append(float(r["after_last_chunk_ms"]))
    for c, v in by.items():
        v = v[2:]  # drop the cold call and the untimed warm-up row
        print(f"=== {c} latency after last chunk (+0.5 s silence), n={len(v)}: "
              f"median {statistics.median(v):.0f} ms  p95 {pct(v, 95):.0f} ms  max {max(v):.0f} ms")

# Storybook Page Art — Design Notes

Status: Approved, not yet implemented (brainstormed 2026-09-11)

## Context

`2026-09-08-storybook-persistence-design.md` explicitly deferred
illustration: "Real AI-generated per-page art is its own sub-project given
the free/local-only, M1/16GB constraint." That sub-project is this one.
`ReadingView.swift` (merged in PR #12) already has a literal placeholder —
a `Rectangle` overlaid with the text "page art" — sized and positioned for
where real art belongs; nothing else in the client needs new layout.

The README has also long listed "illustration sourcing with attribution"
as a planned future step, written before this project had confirmed how
its own animal-facts grounding or local-model constraints would shape it.
Brainstorming this sub-project surfaced a real fork between that original
framing (real photos, sourced from the web) and locally generated
illustration art, with a feasibility question neither this spec nor that
README entry had actually verified: can an M1 MacBook Pro with 16GB
unified memory generate images at all, given it's already running Kyutai
STT, `qwen3.5:9b` via Ollama, and Kokoro TTS for the live dialogue
pipeline?

## Scope decisions made during brainstorming

**Locally generated illustrations, not web-sourced photos.** Confirmed
against CLAUDE.md's privacy-first rule (a web image search would send
story/animal data off household devices) and kid-safe-content rule (no
practical way to safety-filter arbitrary web photos the way the text
pipeline filters LLM replies). This also sidesteps attribution/licensing
bookkeeping entirely. A hybrid (real animal photo + generated scene art)
was considered and declined as unnecessary scope for a first version.

**Feasibility, researched before committing to this path:** Core ML
Stable Diffusion (SD 1.5-based, runs on the Neural Engine) is the right
tool for *this* hardware specifically — not FLUX, which needs ~7GB even
quantized and would require unloading the resident Ollama model first. SD
1.5 quantizes to 2-4GB, comfortably coexisting with the ~5-6GB
`qwen3.5:9b` already resident during the background rewrite window this
pipeline runs inside. Apple's own Core ML SD benchmark reports ~11s for a
512×512 image on M1 via the Neural Engine — tens of seconds per page is a
non-issue in an async background job. Well-regarded "storybook
illustration" style LoRAs exist for SD 1.5, so the *style* question is
solved; the one real open problem is **character consistency**: plain SD
regenerates the story's animal differently on every call, with nothing
tying page 3's fox to page 1's fox.

**Character consistency is designed in from day one, not deferred.**
IP-Adapter conditions generation on a reference image so a character's
visual traits persist across calls. Reference source: **page 1 generates
first, prompt-only, and its output becomes the IP-Adapter reference for
every later page** — not a pre-bundled set of real animal photos. This
works for any animal the child picks (not just a curated list matching
`animal_facts.py`'s supported set) and adds no attribution bookkeeping,
at the cost of pages having to generate strictly in order.

**Per-page prompts are LLM-condensed, not raw prose.** A page's full
narrative paragraph is not what SD expects as input; a short scene
description (setting/characters/action/mood) produces markedly better
results. This reuses the same local `qwen3.5:9b` Ollama call already
resident for the text rewrite — no new model.

**Image safety scaffolding, matching this project's "don't assume default
model behavior is safe" rule:** a fixed negative prompt (excluding
scary/violent/realistic-gore/adult terms) applied to every generation,
plus Stable Diffusion's standard built-in safety checker left enabled as a
backstop. No retry loop (unlike the text pipeline's flagged-word retry) —
image regeneration is far more expensive per attempt (~15-30s vs.
near-instant), so a flagged image is simply dropped for that page rather
than retried.

**iOS scope is deliberately narrow.** This sub-project wires images into
the one real-data path that already exists today: The End → "Read it
now" → the real `SavedStoryDetail` PR #17 already fetches for a
just-finished story. It does **not** wire Library's story list to real
data — that's already flagged in CLAUDE.md as its own future
`superpowers:brainstorming` session, and pulling it in here would roughly
double this sub-project's surface for a concern this spec doesn't need to
solve. Any story reached through Library still shows mock data,
unaffected by this work.

## Pipeline architecture

A new module, `server/tinytalk/illustrations.py`, kept separate from
`storybook.py` the same way `storybook.py` is kept separate from
`story_store.py` — one clear responsibility each. It runs as a **second
phase inside the existing background job**, invoked from
`build_and_attach()` immediately after the text rewrite completes, inside
the same `REWRITING`-gated window (see
`2026-09-08-storybook-persistence-design.md`'s state-machine section) —
not a separate gate, since both phases call the same Ollama process and
must never run concurrently with a live turn or with each other.
Concretely, `build_and_attach()` calls into `illustrations.py` before it
returns, so the existing `REWRITE_DONE` event (fired in a `finally` once
`build_and_attach()` completes, per the persistence spec) now covers both
phases together — the session doesn't leave `REWRITING`, and the client's
`rewriting_done` message doesn't fire, until illustration generation has
also finished (successfully or not). No new session state or event is
introduced; a slower combined background phase is the accepted tradeoff
for keeping "no new story while a rewrite is in flight" airtight without
adding a second gate to reason about.

For each page, strictly in order:

1. **Prompt extraction**: one `qwen3.5:9b` call condenses that page's
   prose into a short visual scene description, with the negative-prompt
   safety list folded into the request.
2. **Image generation**: Core ML Stable Diffusion (SD 1.5 + a
   storybook-illustration LoRA). Page 1 generates prompt-only. Pages 2
   through N pass page 1's generated image through IP-Adapter as a
   reference. This ordering dependency means illustration generation
   cannot be parallelized across pages within a story — acceptable, since
   this is an async background job with no one waiting in real time.
3. **Safety check**: Stable Diffusion's built-in safety checker runs on
   each output. A flagged image means that page simply has no
   illustration — logged, not retried, not raised.

Expected latency: ~15-30s per page (LLM condense + ~11-25s generation),
so roughly 1.5-2.5 minutes total for a 5-page story, layered on top of the
existing text-rewrite time, entirely inside the async window the client
already shows a "still writing this one…" state for.

## Data model: extending `story_store.py` / `storybook.py`'s output

Each page dict gains an `image_path` field (relative path under that
story's own directory on disk; `null` if generation hasn't run yet or was
dropped by the safety check):

```json
{
  "pages": [{"text": "...", "image_path": "page_0.png" | null}, ...],
  "illustrations_status": "pending" | "done" | "partial" | "failed"
}
```

`illustrations_status` is a second, independent status field alongside
the existing `rewrite_status` — the two phases can succeed or fail
independently (a story can have perfect prose and zero illustrations, if
every page happens to trip the safety checker). `"partial"` covers the
common case where some pages got art and others didn't; `"failed"` is
reserved for the pipeline not running at all (e.g. the Core ML model
failed to load), not for individual dropped pages. Images are written as
PNG files directly under that story's own directory, sibling to its JSON
— never embedded as base64 inside the JSON itself.

## Wire protocol additions

One new state-independent read (same category as `GetStory`/
`ListStories` — works regardless of session state):

- `GetPageImage(story_id, page_index)` → binary image data over the
  existing binary-frame pathway already used for TTS audio, or a
  `no_image` completion marker if that page has none. Fetched **on
  demand**, one call per page as `ReadingView` displays it — the same
  lazy pattern already planned for `SynthesizePage`'s audio, not pushed
  eagerly alongside `story_detail`.

`story_detail`'s existing payload gains the per-page `image_path`
presence (as a boolean, not the path itself — the client doesn't need the
server's filesystem layout, just whether to bother fetching) and the new
top-level `illustrations_status`, so `ReadingView` knows upfront which
pages to even attempt fetching.

## iOS integration

`ReadingView.swift`'s placeholder (`Rectangle` + "page art" text,
currently lines 52-64) is replaced with a real `Image` view backed by a
`GetPageImage` fetch, triggered when that page becomes visible. Scope
stays exactly to the path confirmed above: `model.selectedStory`'s
existing real-data route from The End's "Read it now" (PR #17). If a
page's `image_path` is absent, or `illustrations_status` isn't `done` /
`partial`-with-that-page-present, the existing placeholder box remains
for that page — matching `LibraryView`'s established pattern of an
honest pending/degraded state rather than a fabricated one.

## Error handling

- Any failure in `illustrations.py` — a prompt-extraction call failing,
  the Core ML pipeline failing to load or erroring on a specific page —
  is caught, logged, and reflected in `illustrations_status`
  (`"partial"` or `"failed"`), never raised into the live session and
  never blocks `REWRITE_DONE`/leaving the `REWRITING` state. Illustration
  failure must never brick a story the same way a stuck `REWRITING` state
  would, and must never block the text rewrite's own success from being
  saved.
- A safety-checker-flagged image is treated identically to a
  generation failure for that page: no image, not a retry, not a
  placeholder image — see Scope decisions above for why no retry loop
  exists here.

## Testing

- `illustrations.py`: tests against a fake/injectable image-generation
  backend (mirrors `storybook.py`'s fake-LLM pattern) covering: prompt
  extraction happening per page, page 1 generating reference-free, pages
  2+ receiving page 1's output as an IP-Adapter reference, a
  safety-checker-flagged page resulting in `image_path: null` for that
  page only (not aborting the rest), and `illustrations_status`
  transitioning correctly across the pending/done/partial/failed cases.
- `story_store.py`: round-trip tests for the new `image_path`/
  `illustrations_status` fields, defaulting appropriately when absent
  (older saved stories predate this field entirely).
- `protocol.py`: encode/decode round-trip tests for `GetPageImage` and
  its response, plus the extended `story_detail` payload.
- iOS: `ReadingView`'s image-fetch-per-visible-page behavior, and its
  fallback to the placeholder when a page has no image.
- **On-device verification is required before this is considered done**,
  the same way the text-rewrite pipeline needed a real run against
  `qwen3.5:9b` before it was trusted — the fakes-based suite can verify
  sequencing and status logic, but actual image quality, generation
  timing on real hardware, and whether the IP-Adapter reference genuinely
  keeps the animal recognizable across pages can only be judged by
  running it for real on the M1.

## Open questions / risks

- **Exact Core ML / IP-Adapter integration path is implementation detail
  for the plan phase, not fixed here.** Which specific packaging (Apple's
  `ml-stable-diffusion`, a wrapped CLI, or a Python binding) gets used,
  and exactly how IP-Adapter reference-conditioning is invoked against
  it, needs verifying against current tooling when the implementation
  plan is written — this space moves fast enough that anything more
  specific risks being stale by the time it's built.
- **Total background-window latency stacks with the text rewrite's own
  time.** A 5-page story could spend several minutes in `REWRITING`
  between the two phases combined. Worth watching on real hardware; if it
  proves too long in practice, phases could run for fewer than all pages
  (e.g. illustrate only the first N pages) as a future mitigation — not
  designed in now, since it's speculative until measured.
- **No retry for a safety-checker-flagged page** — a story that happens
  to trip the checker on most pages ends up mostly art-free, visibly, via
  `illustrations_status: "partial"`. Worth revisiting if it proves to
  matter in practice, same posture as the persistence spec took toward
  rewrite-failure retries before real usage showed the safety-retry gap
  that became PR #18.
- **Library's story list and Reading's non-"just finished" path stay
  fully mock**, per the scope decision above — a story browsed from
  Library still shows no real art (or any other real data) until that
  separate, not-yet-brainstormed sub-project happens.
- **Away-from-home demo mode has no local image source at all — flagged
  as future work, not built here.** That sub-project
  ([[project_away_from_home_demo_mode]] in memory;
  `2026-09-09-away-from-home-demo-mode-design.md`) lets the phone bypass
  the home Mac server entirely via cloud APIs (Groq) when off the home
  WiFi. This spec's illustration pipeline is Core ML on the Mac's own
  Neural Engine — there's no equivalent running on the phone, and no
  local Mac reachable to fall back to while genuinely away from home.
  This is the same general class of gap that project's own memory
  already tracks as issue #24 ("features built the same way silently
  no-op in demo mode unless `DemoConnection` is deliberately extended")
  — GetPageImage would be one more such feature. The likely future fix,
  raised by the user during this brainstorm and intentionally deferred
  rather than designed now: a free-tier cloud image-generation API (an
  API-key-gated fallback), mirroring how away-from-home mode already
  substitutes Groq for the local LLM rather than leaving that path with
  no story dialogue at all. Filed as its own GitHub issue rather than
  designed here — issue #26. **Development note for this sub-project's
  own implementation:** keep `illustrations.py`'s image-generation
  backend swapped in behind the same fake/injectable interface already
  planned for testing (see Testing, above) — that seam is what would let
  a future cloud backend slot in for away-from-home mode without
  redesigning this pipeline, so no extra work is needed now beyond not
  hard-coding the Core ML call path directly into the per-page loop.

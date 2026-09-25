# Server Memory: Short-Lived Image Worker — Design Notes

Status: Approved in brainstorming 2026-09-25 (all three sections), awaiting written-spec review.
Tracks issue #75.

## Context

The home server (`python -m tinytalk.app`) runs on a 16 GB M1 MacBook Pro.
It holds a lot of memory for its whole lifetime:

- **2026-09-22** (Activity Monitor): `python3.12` = **12.03 GB**.
- **2026-09-24** (`footprint -p`, 4h23m-old process): **4.3 GB**, of which
  3.1 GB was GPU memory (`IOAccelerator`). `ps` RSS read ~6 MB because nearly
  all of it had been compressed or swapped out, so RSS is not a usable
  measure here.
- Swap was 3.99 of 5.12 GB in use. Testing has seen 10–14 s TTS-to-first-audio
  (against ~0.9 s warm) and `STT is running behind realtime` warnings.

The cause, from the code:

- `app.py` builds one `KyutaiStt` (MLX), one `KokoroTts` (torch/MPS) and one
  `StableDiffusionBackend` (torch/MPS) for the server's whole lifetime.
- `StableDiffusionBackend` loads its pipeline lazily on the first
  illustration and never frees it. The pipeline is SD 1.5 fp16, a storybook
  LoRA, an IP-Adapter and the safety checker.
- PyTorch's MPS caching allocator keeps freed blocks instead of returning
  them to the OS. `tts_kokoro.py`'s `_release_mps_cache()` covers only
  Kokoro's own calls, not SD.
- Ollama is a separate process. It is already released before each picture
  pass by `illustrations._release_ollama_memory()` (PR #27), so it is out of
  scope here.

The only path that draws pictures is `session.py` →
`storybook.build_and_attach` → `illustrations.generate_and_attach`. It runs
after The End, inside the story's `REWRITING` window, so two passes never
overlap and no pass ever runs during a live turn.

## Goals

- **Faster live turns** (the household's stated priority, 2026-09-25). While
  the child is talking to Elsie, the server holds only what a turn needs:
  STT and TTS.
- After a picture pass, the server's footprint returns to roughly where it
  was before the pass (within ~0.5 GB).
- An SD crash can no longer take down the live server.

## Non-goals

- **Unloading STT or TTS.** Every turn needs them, so unloading would slow
  turns down.
- **Speed of the picture pass.** It may take ~10–20 s longer to start, all of
  it after The End. The household accepted this trade explicitly.
- **Changing the image model, LoRA, IP-Adapter, safety checker or negative
  prompt.** The kid-safety pipeline stays byte-for-byte the same.
- **Away-from-home (demo) illustrations.** Those run through Cloudflare on
  the phone and don't touch this server.
- Worker restarts mid-pass, retries, worker pools, or any retry of pages
  that failed. Retrying is #68 cause 3's design question.

## Approaches considered

- **A. A short-lived worker process for each picture pass (chosen).** macOS
  reclaims everything, including GPU heaps and the MPS cache, when the child
  exits. It also isolates SD crashes, and it removes the uncovered risk noted
  after #34: SD sharing the process-wide MPS graph cache with Kokoro, outside
  Kokoro's lock.
- **B. Unload in place** (`del` the pipeline, `gc.collect()`,
  `torch.mps.empty_cache()`). This is the smallest diff, but PyTorch-on-Metal
  doesn't reliably hand GPU heaps back to the OS, so it may only partly work.
  SD would also still share the live server's process.
- **C. Keep SD loaded, but shrink it** (offload parts of it to the CPU, or a
  smaller model). This reclaims the least, and it touches the safety pipeline.

## Design

### Components

1. **`server/tinytalk/image_worker.py` (new)**
   - **Parent side: `ImageWorker`**, a context manager.
     - **Construction:** it takes a backend factory as an importable
       `"module:function"` string. Production passes
       `"tinytalk.image_worker:build_stable_diffusion_backend"`. Tests pass a
       fake that needs no torch.
     - **`__enter__`:** starts a child with
       `multiprocessing.get_context("spawn")`. It must not fork: forking a
       process that already holds MLX, Metal and threads is unsafe on macOS.
       The child is `daemon=True`, and the parent logs
       `image worker: started (pid N)`.
     - **`generate_to_file(prompt, reference_path, out_path)`:** sends one
       request over a `multiprocessing.Pipe`, waits for the reply using
       `poll(timeout)`, and returns a `PageResult`. The four results are
       `ok`, `flagged`, `error(text)` and `worker_dead(reason)`.
     - **`__exit__`:** runs on success, error and cancellation. It sends
       `quit`, joins for a few seconds, then `terminate()`s and, if needed,
       `kill()`s. It logs
       `image worker: exited (code C) after X s`.
   - **Child side: `_worker_main(conn, backend_factory)`.**
     - Configures logging with an `image-worker` prefix.
     - Imports and calls the factory, which builds the **existing, unchanged**
       `StableDiffusionBackend` (loaded lazily on the first request, as today).
     - Loops over requests. For each one it loads the reference PNG if a path
       was given, calls `backend.generate(...)`, and saves the PNG itself.
       No image ever crosses the pipe.
     - Replies `ok`, `flagged` or `error`.
     - Exits on `quit`, or when the pipe closes (EOF), for example after the
       parent was killed.
     - Logs `image worker: model loaded in X s` on its first request.

2. **`server/tinytalk/illustrations.py` (changed)**
   - Scene-prompt extraction and `_release_ollama_memory()` stay exactly where
     they are. Both still run **before** the worker starts, so Ollama and SD
     never overlap.
   - The per-page image loop runs inside `with image_worker_factory() as
     worker:`.
   - The reference image becomes a **path**: page 0's saved PNG, not an
     in-memory `Image`. Pages 1+ receive that path.
   - `worker_dead` marks the current page and every later page as having no
     picture, and the pass carries on to the normal status calculation.
   - Page order, the `done`/`partial`/`failed` rules, `_mark_blank` and the
     existing log lines all stay the same.
   - Each wait on the worker runs in `asyncio.to_thread`, as `generate()`
     does today, so the event loop never blocks.

3. **`server/tinytalk/app.py`, `session.py`, `storybook.py` (changed)**
   - `app.py` no longer builds a long-lived `StableDiffusionBackend`. It
     passes `image_worker_factory` (a zero-argument callable that returns an
     `ImageWorker`) down the same parameter chain that `image_backend` uses
     today, replacing `image_backend` at every hop: `build_session`,
     `SessionRunner`, `storybook.build_and_attach` and
     `illustrations.generate_and_attach`. `None` still means "no
     illustrations".
   - `image_gen.py`'s `StableDiffusionBackend` is unchanged. It now runs only
     inside the child.

4. **`server/tinytalk/config.py`:** adds `IMAGE_WORKER_PAGE_TIMEOUT`, read
   from `TINYTALK_IMAGE_WORKER_PAGE_TIMEOUT`. It defaults to 300 seconds per
   page request, and the first request's allowance includes loading the model.

### Failure handling

| Failure | Behaviour |
|---|---|
| Child crashes (SIGBUS/SIGSEGV, or killed by macOS) | Pipe EOF, or `poll` sees a dead process. Log `image worker died (exit code -N)`. The current and remaining pages get no picture, and the story ends `partial`/`failed`. **The live server keeps running.** |
| Child hangs | The page request hits its timeout. The child is killed, and the rest is handled as a crash. The `REWRITING` gate cannot hang (the same class of problem as #32). |
| Server shuts down or the pass is cancelled | `CancelledError` reaches `__exit__`, which kills the child. The parent's blocked `poll` returns at once because of the pipe EOF. An orphaned child exits by itself on EOF. |
| Safety checker flags a page | Reply `flagged`. That page gets no picture and there is no retry, the same as today. The existing warning is logged. |
| Worker fails to start | `__enter__` raises. The pass's existing broad `except` marks the story `failed`, and it is logged. |

The `REWRITING` gate is still released by `storybook.py`'s existing
`finally`, whatever the outcome.

## Testing

**pytest, no GPU:**

- `tests/test_image_worker.py` spawns a **real** child with a fake backend
  factory (a module inside `tests/`, no torch), about 1 s per test. It covers:
  - `ok` writes the PNG
  - `flagged` writes nothing
  - the reference path reaches the backend
  - crash via `os.kill(os.getpid(), signal.SIGSEGV)`: `worker_dead`
    reporting the signal, and the test process survives
  - hang past a 1 s timeout: the child is killed
  - after `__exit__`, `is_alive()` is False
- `tests/test_illustrations.py`:
  - The existing fake becomes a fake worker.
  - Existing ordering, reference and status tests keep passing.
  - New: a worker that dies on page 2 gives a `partial` story with pages 0–1.
  - New: cancellation closes the worker.
- The full suite stays green: the 486 baseline plus the new tests.

**Measurement: plan step 1 (old code) and again at the end (new code).**
Use `footprint -p <server pid>` at two points:

1. A fresh server at idle, after one live turn (STT and TTS loaded).
2. Straight after one illustrated server-mode story.

**Acceptance:**

- The new code's footprint at point 2 is within ~0.5 GB of point 1. On the
  old code, point 2 still holds the SD pipeline.
- The pass's extra start-up time is logged (expected ~10–20 s).
- Pictures look the same as before: same model, LoRA and safety checker.

**On-device (household):**

- Restart the server from the worktree and finish a server-mode story.
- Pictures appear as before.
- The three `image worker:` lines are logged.
- `footprint` before and after the pass.
- The next story's turns feel at least as fast as before.

## Docs

README's Setup/config section gets two additions:

- `TINYTALK_IMAGE_WORKER_PAGE_TIMEOUT`
- one line saying picture drawing runs in a short-lived worker process, so
  the server gives that memory back after each story.

## Open questions / risks

- **Spawn start-up cost.** Importing torch and diffusers in a fresh
  interpreter takes a few seconds, on top of loading the model. Measured in
  step 1 and logged. Accepted by the household.
- **Disk cache.** The model reloads from the Hugging Face disk cache on every
  pass. Under heavy swap the first load may be slow, but it's within the
  300 s allowance.
- **The 12 GB vs 4.3 GB gap.** Step 1's measurement will attribute it to
  specific models. If Kyutai STT (MLX) turns out to be the largest
  resident share, that's a separate follow-up issue, not part of this spec.

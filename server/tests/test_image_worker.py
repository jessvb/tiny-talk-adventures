import multiprocessing
import threading
from pathlib import Path

from PIL import Image

from tinytalk.image_worker import (
    ERROR,
    FLAGGED,
    OK,
    WORKER_DEAD,
    ImageWorker,
    PageResult,
    _worker_main,
)

OK_BACKEND = "image_worker_fakes:make_ok_backend"


def _pixel(path: Path):
    with Image.open(path) as image:
        return image.getpixel((0, 0))


def test_ok_page_writes_the_png_and_reports_ok(tmp_path):
    out = tmp_path / "page-0.png"
    with ImageWorker(OK_BACKEND, page_timeout=60) as worker:
        result = worker.generate_to_file("a fox", None, out)
    assert result == PageResult(OK, "")
    assert _pixel(out) == (255, 0, 0)  # red: no reference given


def test_reference_path_reaches_the_backend(tmp_path):
    first = tmp_path / "page-0.png"
    second = tmp_path / "page-1.png"
    with ImageWorker(OK_BACKEND, page_timeout=60) as worker:
        worker.generate_to_file("a fox", None, first)
        result = worker.generate_to_file("a fox again", first, second)
    assert result.kind == OK
    assert _pixel(second) == (0, 0, 255)  # blue: a reference image arrived


def test_flagged_page_reports_flagged_and_writes_nothing(tmp_path):
    out = tmp_path / "page-0.png"
    with ImageWorker("image_worker_fakes:make_flagged_backend", page_timeout=60) as worker:
        result = worker.generate_to_file("a fox", None, out)
    assert result.kind == FLAGGED
    assert not out.exists()


def test_backend_exception_is_an_error_reply_and_the_worker_survives(tmp_path):
    with ImageWorker("image_worker_fakes:make_raising_backend", page_timeout=60) as worker:
        first = worker.generate_to_file("a fox", None, tmp_path / "a.png")
        second = worker.generate_to_file("a fox", None, tmp_path / "b.png")
    assert first.kind == ERROR and "simulated MPS allocation failure" in first.detail
    assert second.kind == ERROR  # still answering: one bad page doesn't kill the worker


def test_crash_is_reported_as_worker_dead_with_the_signal(tmp_path):
    with ImageWorker("image_worker_fakes:make_crashing_backend", page_timeout=60) as worker:
        result = worker.generate_to_file("a fox", None, tmp_path / "a.png")
        later = worker.generate_to_file("a fox", None, tmp_path / "b.png")
    assert result.kind == WORKER_DEAD
    assert "SIGSEGV" in result.detail
    assert later.kind == WORKER_DEAD  # the rest of the pass fails fast, no new spawn
    # Reaching this line at all is the point: the parent (this test process)
    # survived the child's segfault.


def test_hang_past_the_timeout_kills_the_worker(tmp_path):
    worker = ImageWorker("image_worker_fakes:make_hanging_backend", page_timeout=1.5)
    worker.start()
    process = worker._process
    try:
        result = worker.generate_to_file("a fox", None, tmp_path / "a.png")
    finally:
        worker.close()
    assert result.kind == WORKER_DEAD
    assert "no reply" in result.detail
    assert not process.is_alive()


def test_close_stops_the_child_process(tmp_path):
    worker = ImageWorker(OK_BACKEND, page_timeout=60)
    worker.start()
    process = worker._process
    assert process.is_alive()
    worker.close()
    assert not process.is_alive()


# --- Review Focus (see the plan header) ---------------------------------


def test_back_to_back_workers_are_separate_processes(tmp_path):
    first = ImageWorker(OK_BACKEND, page_timeout=60)
    first.start()
    first_process = first._process
    first.generate_to_file("a fox", None, tmp_path / "a.png")
    first.close()

    second = ImageWorker(OK_BACKEND, page_timeout=60)
    second.start()
    second_process = second._process
    try:
        result = second.generate_to_file("a fox", None, tmp_path / "b.png")
    finally:
        second.close()

    assert result.kind == OK
    assert first_process.pid != second_process.pid
    assert not first_process.is_alive()
    assert not second_process.is_alive()


def test_missing_reference_file_degrades_that_page(tmp_path):
    with ImageWorker(OK_BACKEND, page_timeout=60) as worker:
        result = worker.generate_to_file(
            "a fox", tmp_path / "does-not-exist.png", tmp_path / "b.png"
        )
        after = worker.generate_to_file("a fox", None, tmp_path / "c.png")
    assert result.kind == ERROR
    assert after.kind == OK  # and the worker keeps going


def test_unicode_prompt_arrives_intact(tmp_path):
    prompt = "a fox 🦊 in a café"
    with ImageWorker("image_worker_fakes:make_prompt_width_backend", page_timeout=60) as worker:
        result = worker.generate_to_file(prompt, None, tmp_path / "a.png")
    assert result.kind == OK
    with Image.open(tmp_path / "a.png") as image:
        assert image.width == len(prompt)


def test_worker_main_exits_when_the_pipe_closes():
    # An orphaned worker (parent killed) sees EOF on its pipe and must exit
    # by itself rather than linger holding gigabytes. Run the child's loop
    # in a thread here, with real Pipe ends, and close the parent's end.
    parent_conn, child_conn = multiprocessing.Pipe()
    finished = threading.Event()

    def run():
        _worker_main(child_conn, OK_BACKEND)
        finished.set()

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    parent_conn.close()
    assert finished.wait(timeout=10), "worker loop did not exit on EOF"


def test_close_is_idempotent_and_generate_after_close_is_worker_dead(tmp_path):
    never_started = ImageWorker(OK_BACKEND, page_timeout=60)
    never_started.close()  # before start(): a no-op, not an error
    assert never_started.generate_to_file("a fox", None, tmp_path / "a.png").kind == WORKER_DEAD

    worker = ImageWorker(OK_BACKEND, page_timeout=60)
    worker.start()
    worker.close()
    worker.close()  # twice: still fine
    assert worker.generate_to_file("a fox", None, tmp_path / "b.png").kind == WORKER_DEAD

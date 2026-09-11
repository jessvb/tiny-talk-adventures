import json

from tinytalk.conversation import Conversation
from tinytalk.story_store import (
    save_story,
    story_id_from_path,
    list_stories,
    load_story,
    update_story_rewrite,
    update_story_illustrations,
    read_page_image,
)


def make_conversation() -> Conversation:
    conversation = Conversation()
    conversation.add_child("tell me about a fox")
    conversation.add_agent("Once there was a clever fox.")
    return conversation


def test_save_story_writes_a_json_file_with_expected_shape(tmp_path):
    conversation = make_conversation()

    path = save_story(conversation, stories_dir=tmp_path)

    assert path is not None
    assert path.exists()
    assert path.parent == tmp_path
    payload = json.loads(path.read_text())
    assert payload["turns"] == [
        {"speaker": "child", "text": "tell me about a fox", "interrupted": False},
        {"speaker": "agent", "text": "Once there was a clever fox.", "interrupted": False},
    ]
    assert "id" in payload
    assert "created_at" in payload


def test_save_story_creates_the_directory_if_missing(tmp_path):
    stories_dir = tmp_path / "nested" / "stories"
    assert not stories_dir.exists()

    path = save_story(make_conversation(), stories_dir=stories_dir)

    assert path is not None
    assert stories_dir.exists()


def test_repeated_saves_produce_unique_filenames(tmp_path):
    first = save_story(make_conversation(), stories_dir=tmp_path)
    second = save_story(make_conversation(), stories_dir=tmp_path)

    assert first != second
    assert len(list(tmp_path.glob("*.json"))) == 2


def test_save_failure_is_logged_and_returns_none_instead_of_raising(tmp_path):
    # A regular FILE sitting where the stories directory needs to go makes
    # mkdir() genuinely fail with a real OSError (FileExistsError), no
    # monkeypatching needed.
    blocked_path = tmp_path / "blocked"
    blocked_path.write_text("not a directory")

    result = save_story(make_conversation(), stories_dir=blocked_path)

    assert result is None


def test_save_story_includes_turns_beyond_the_llm_context_window(tmp_path):
    conversation = Conversation()  # default max_turns=20
    for i in range(15):
        conversation.add_child(f"turn {i}")
        conversation.add_agent(f"reply {i}")
    # 30 entries added, exceeding the default window of 20
    path = save_story(conversation, stories_dir=tmp_path)
    payload = json.loads(path.read_text())
    assert len(payload["turns"]) == 30
    assert payload["turns"][0]["text"] == "turn 0"  # the beginning was NOT dropped


def test_save_story_includes_the_new_nullable_fields(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    payload = json.loads(path.read_text())
    assert payload["title"] is None
    assert payload["pages"] is None
    assert payload["epilogue"] is None
    assert payload["rewrite_status"] == "pending"


def test_story_id_from_path_extracts_the_id(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    payload = json.loads(path.read_text())
    assert story_id_from_path(path) == payload["id"]


def test_list_stories_returns_summaries_newest_first(tmp_path):
    import time

    first = save_story(make_conversation(), stories_dir=tmp_path)
    time.sleep(1.1)  # created_at has 1-second resolution
    second = save_story(make_conversation(), stories_dir=tmp_path)

    summaries = list_stories(stories_dir=tmp_path)

    assert [s["id"] for s in summaries] == [
        story_id_from_path(second),
        story_id_from_path(first),
    ]
    assert summaries[0]["page_count"] == 0
    assert summaries[0]["rewrite_status"] == "pending"
    assert summaries[0]["title"] is None


def test_list_stories_returns_empty_list_when_directory_does_not_exist(tmp_path):
    assert list_stories(stories_dir=tmp_path / "missing") == []


def test_load_story_returns_full_payload(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)

    story = load_story(story_id, stories_dir=tmp_path)

    assert story is not None
    assert story["id"] == story_id
    assert story["turns"] == json.loads(path.read_text())["turns"]


def test_load_story_returns_none_for_unknown_id(tmp_path):
    save_story(make_conversation(), stories_dir=tmp_path)
    assert load_story("does-not-exist", stories_dir=tmp_path) is None


def test_update_story_rewrite_patches_in_the_result(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    # Captured BEFORE update_story_rewrite() runs, so the assertion below is
    # a genuine before/after comparison -- not `payload["turns"] ==
    # json.loads(path.read_text())["turns"]` re-reading the same
    # already-updated file on both sides of the `==`, which can never fail
    # regardless of what update_story_rewrite() actually does to `turns`.
    turns_before = json.loads(path.read_text())["turns"]

    ok = update_story_rewrite(
        story_id,
        title="Pip the Noisy Fox",
        pages=[{"text": "Once upon a time..."}],
        epilogue="Foxes have excellent hearing.",
        rewrite_status="done",
        stories_dir=tmp_path,
    )

    assert ok is True
    payload = json.loads(path.read_text())
    assert payload["title"] == "Pip the Noisy Fox"
    assert payload["pages"] == [{"text": "Once upon a time..."}]
    assert payload["epilogue"] == "Foxes have excellent hearing."
    assert payload["rewrite_status"] == "done"
    # the raw transcript must survive untouched
    assert payload["turns"] == turns_before


def test_update_story_rewrite_records_a_failed_status(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)

    ok = update_story_rewrite(
        story_id,
        title=None,
        pages=None,
        epilogue=None,
        rewrite_status="failed",
        stories_dir=tmp_path,
    )

    assert ok is True
    payload = json.loads(path.read_text())
    assert payload["rewrite_status"] == "failed"
    assert payload["title"] is None


def test_update_story_rewrite_returns_false_for_unknown_id(tmp_path):
    ok = update_story_rewrite(
        "does-not-exist",
        title="x",
        pages=[],
        epilogue=None,
        rewrite_status="done",
        stories_dir=tmp_path,
    )
    assert ok is False


def test_list_stories_skips_corrupt_files_with_missing_required_fields(tmp_path):
    """Corrupt/truncated files missing required fields should be skipped,
    not crash the entire listing. One bad file must never break browsing."""
    # Write a valid story
    valid = save_story(make_conversation(), stories_dir=tmp_path)
    valid_id = story_id_from_path(valid)

    # Write a corrupt file (missing both id and created_at)
    corrupt_path = tmp_path / "20260908T000000-corrupt.json"
    corrupt_path.write_text(json.dumps({"turns": []}))

    # list_stories should skip the corrupt file and return only the valid one
    summaries = list_stories(stories_dir=tmp_path)

    assert len(summaries) == 1
    assert summaries[0]["id"] == valid_id


def test_list_stories_skips_files_with_corrupt_encoding(tmp_path):
    """Non-UTF8 files should be skipped, not crash the listing."""
    # Write a valid story
    valid = save_story(make_conversation(), stories_dir=tmp_path)
    valid_id = story_id_from_path(valid)

    # Write a file with invalid UTF-8
    corrupt_path = tmp_path / "20260908T000000-badutf8.json"
    corrupt_path.write_bytes(b"\x80\x81\x82\x83")

    # list_stories should skip the corrupt file and return only the valid one
    summaries = list_stories(stories_dir=tmp_path)

    assert len(summaries) == 1
    assert summaries[0]["id"] == valid_id


def test_save_story_defaults_illustrations_status_to_none(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    payload = json.loads(path.read_text())
    assert payload["illustrations_status"] is None


def test_update_story_illustrations_patches_pages_and_status(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    update_story_rewrite(
        story_id,
        title="A Story",
        pages=[{"text": "Page one."}, {"text": "Page two."}],
        epilogue=None,
        rewrite_status="done",
        stories_dir=tmp_path,
    )

    ok = update_story_illustrations(
        story_id,
        image_filenames=[f"{story_id}-page-0.png", None],
        illustrations_status="partial",
        stories_dir=tmp_path,
    )

    assert ok is True
    story = load_story(story_id, stories_dir=tmp_path)
    assert story["pages"][0]["image_path"] == f"{story_id}-page-0.png"
    assert story["pages"][1]["image_path"] is None
    assert story["illustrations_status"] == "partial"


def test_update_story_illustrations_returns_false_for_unknown_story(tmp_path):
    ok = update_story_illustrations(
        "nope1234", image_filenames=[], illustrations_status="failed", stories_dir=tmp_path
    )
    assert ok is False


def test_read_page_image_returns_bytes_when_present(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    update_story_rewrite(
        story_id, title="A Story", pages=[{"text": "Page one."}], epilogue=None,
        rewrite_status="done", stories_dir=tmp_path,
    )
    filename = f"{story_id}-page-0.png"
    (tmp_path / filename).write_bytes(b"fake-png-bytes")
    update_story_illustrations(
        story_id, image_filenames=[filename], illustrations_status="done", stories_dir=tmp_path
    )

    data = read_page_image(story_id, 0, stories_dir=tmp_path)

    assert data == b"fake-png-bytes"


def test_read_page_image_returns_none_when_no_image(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    update_story_rewrite(
        story_id, title="A Story", pages=[{"text": "Page one."}], epilogue=None,
        rewrite_status="done", stories_dir=tmp_path,
    )

    assert read_page_image(story_id, 0, stories_dir=tmp_path) is None


def test_read_page_image_returns_none_for_out_of_range_page(tmp_path):
    path = save_story(make_conversation(), stories_dir=tmp_path)
    story_id = story_id_from_path(path)
    update_story_rewrite(
        story_id, title="A Story", pages=[{"text": "Page one."}], epilogue=None,
        rewrite_status="done", stories_dir=tmp_path,
    )

    assert read_page_image(story_id, 5, stories_dir=tmp_path) is None

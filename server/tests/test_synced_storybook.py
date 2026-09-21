import base64
import io
import logging

import pytest
from PIL import Image

from tinytalk import synced_storybook
from tinytalk.story_store import (
    load_story,
    read_page_image,
    save_synced_story,
    story_id_from_path,
)
from tinytalk.synced_storybook import (
    MAX_IMAGE_BYTES,
    MAX_PAGE_TEXT_CHARS,
    MAX_PAGES,
    MAX_TITLE_CHARS,
    derive_epilogue,
    store_uploaded_storybook,
)


def make_synced_story(tmp_path) -> str:
    path = save_synced_story(
        {"created_at": "2026-09-19T12:00:00+00:00", "turns": []}, stories_dir=tmp_path
    )
    return story_id_from_path(path)


def image_b64(fmt: str = "JPEG", size: tuple[int, int] = (8, 8)) -> str:
    buffer = io.BytesIO()
    Image.new("RGB", size, color=(200, 30, 30)).save(buffer, format=fmt)
    return base64.b64encode(buffer.getvalue()).decode()


def storybook(**overrides) -> dict:
    base = {
        "title": "Pip the Fox",
        "pages": [{"text": "Page one."}, {"text": "Page two."}],
    }
    base.update(overrides)
    return base


def assert_left_pending(story_id, tmp_path):
    story = load_story(story_id, stories_dir=tmp_path)
    assert story["rewrite_status"] == "pending"
    assert story["title"] is None
    assert story["pages"] is None
    assert list(tmp_path.glob("*.png")) == [], "a rejected storybook must not leave image files behind"


# ---------- acceptance ----------


def test_a_valid_text_only_storybook_is_stored_as_done(tmp_path):
    story_id = make_synced_story(tmp_path)

    accepted = store_uploaded_storybook(story_id, storybook(), [], stories_dir=tmp_path)

    assert accepted is True
    story = load_story(story_id, stories_dir=tmp_path)
    assert story["title"] == "Pip the Fox"
    assert story["pages"] == [{"text": "Page one."}, {"text": "Page two."}]
    assert story["epilogue"] is None
    assert story["rewrite_status"] == "done"
    assert story.get("illustrations_status") is None
    assert story["turns"] == [], "the transcript must be untouched"


def test_the_epilogue_is_recomputed_from_shared_facts_and_the_uploaded_one_is_ignored(tmp_path):
    story_id = make_synced_story(tmp_path)

    store_uploaded_storybook(
        story_id,
        storybook(epilogue="Foxes can fly to the moon."),
        [("fox", "foxes have excellent hearing")],
        stories_dir=tmp_path,
    )

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["epilogue"] == "And one true thing we learned about the fox: foxes have excellent hearing"


def test_a_fabricated_epilogue_is_dropped_when_no_facts_were_shared(tmp_path):
    story_id = make_synced_story(tmp_path)
    store_uploaded_storybook(
        story_id, storybook(epilogue="Foxes can fly to the moon."), [], stories_dir=tmp_path
    )
    assert load_story(story_id, stories_dir=tmp_path)["epilogue"] is None


def test_derive_epilogue_matches_the_live_rewrite_formula():
    # test_storybook.py asserts this exact literal for build_and_attach();
    # pinning both to it means neither can drift without a test failing.
    assert (
        derive_epilogue([("fox", "foxes have excellent hearing")])
        == "And one true thing we learned about the fox: foxes have excellent hearing"
    )
    assert derive_epilogue([]) is None


def test_images_are_stored_as_server_named_pngs_and_marked_done(tmp_path):
    story_id = make_synced_story(tmp_path)
    book = storybook(pages=[
        {"text": "Page one.", "image": image_b64("JPEG")},
        {"text": "Page two.", "image": image_b64("PNG")},
    ])

    accepted = store_uploaded_storybook(story_id, book, [], stories_dir=tmp_path)

    assert accepted is True
    story = load_story(story_id, stories_dir=tmp_path)
    assert story["illustrations_status"] == "done"
    assert [page["image_path"] for page in story["pages"]] == [
        f"{story_id}-page-0.png",
        f"{story_id}-page-1.png",
    ]
    for index in range(2):
        data = read_page_image(story_id, index, stories_dir=tmp_path)
        assert Image.open(io.BytesIO(data)).format == "PNG"


def test_some_images_marks_the_illustrations_partial(tmp_path):
    story_id = make_synced_story(tmp_path)
    book = storybook(pages=[{"text": "Page one.", "image": image_b64()}, {"text": "Page two."}])

    store_uploaded_storybook(story_id, book, [], stories_dir=tmp_path)

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["illustrations_status"] == "partial"
    assert story["pages"][0]["image_path"] == f"{story_id}-page-0.png"
    assert story["pages"][1].get("image_path") is None


def test_raw_client_bytes_are_never_written_to_disk(tmp_path):
    # The stored file must be the SERVER's own PNG re-encode, not the
    # uploaded JPEG bytes.
    story_id = make_synced_story(tmp_path)
    uploaded = image_b64("JPEG")
    store_uploaded_storybook(
        story_id, storybook(pages=[{"text": "One.", "image": uploaded}]), [], stories_dir=tmp_path
    )
    stored = (tmp_path / f"{story_id}-page-0.png").read_bytes()
    assert stored != base64.b64decode(uploaded)
    assert stored.startswith(b"\x89PNG")


def test_client_supplied_filenames_and_paths_are_ignored(tmp_path):
    story_id = make_synced_story(tmp_path)
    book = storybook(pages=[{
        "text": "Page one.",
        "image": image_b64(),
        "image_path": "../../evil.png",
        "filename": "../evil.png",
    }])

    store_uploaded_storybook(story_id, book, [], stories_dir=tmp_path)

    story = load_story(story_id, stories_dir=tmp_path)
    assert story["pages"][0]["image_path"] == f"{story_id}-page-0.png"
    assert not (tmp_path.parent / "evil.png").exists()
    assert sorted(p.name for p in tmp_path.glob("*.png")) == [f"{story_id}-page-0.png"]


def test_a_failed_image_write_keeps_the_text_storybook(tmp_path, monkeypatch):
    story_id = make_synced_story(tmp_path)
    # Built BEFORE patching: image_b64() itself uses Image.save().
    book = storybook(pages=[{"text": "One.", "image": image_b64()}])

    def boom(self, *args, **kwargs):
        raise OSError("disk full")

    monkeypatch.setattr(Image.Image, "save", boom)

    accepted = store_uploaded_storybook(story_id, book, [], stories_dir=tmp_path)

    assert accepted is True
    story = load_story(story_id, stories_dir=tmp_path)
    assert story["rewrite_status"] == "done"
    assert story.get("illustrations_status") is None


# ---------- rejection ----------


def bad_storybooks():
    too_many_pages = [{"text": f"Page {i}."} for i in range(MAX_PAGES + 1)]
    return [
        pytest.param("not an object", id="not-a-dict"),
        pytest.param({"pages": [{"text": "One."}]}, id="missing-title"),
        pytest.param(storybook(title="   "), id="blank-title"),
        pytest.param(storybook(title=42), id="non-string-title"),
        pytest.param(storybook(title="T" * (MAX_TITLE_CHARS + 1)), id="title-too-long"),
        pytest.param({"title": "Pip"}, id="missing-pages"),
        pytest.param(storybook(pages=[]), id="zero-pages"),
        pytest.param(storybook(pages="nope"), id="pages-not-a-list"),
        pytest.param(storybook(pages=too_many_pages), id="too-many-pages"),
        pytest.param(storybook(pages=["not a dict"]), id="page-not-a-dict"),
        pytest.param(storybook(pages=[{"text": ""}]), id="empty-page-text"),
        pytest.param(storybook(pages=[{"nope": 1}]), id="missing-page-text"),
        pytest.param(storybook(pages=[{"text": "x" * (MAX_PAGE_TEXT_CHARS + 1)}]), id="page-text-too-long"),
        pytest.param(storybook(pages=[{"text": "One.", "image": 5}]), id="image-not-a-string"),
        pytest.param(storybook(pages=[{"text": "One.", "image": "!!!not base64!!!"}]), id="image-bad-base64"),
        pytest.param(
            storybook(pages=[{"text": "One.", "image": base64.b64encode(b"garbage bytes").decode()}]),
            id="image-not-an-image",
        ),
        pytest.param(
            storybook(pages=[{"text": "One.", "image": base64.b64encode(b"x" * (MAX_IMAGE_BYTES + 1)).decode()}]),
            id="image-too-many-bytes",
        ),
        pytest.param(
            storybook(pages=[{"text": "One.", "image": image_b64("GIF")}]),
            id="image-wrong-format",
        ),
        pytest.param(
            storybook(pages=[{"text": "One.", "image": image_b64("PNG", (2049, 2049))}]),
            id="image-over-the-pixel-limit",
        ),
        pytest.param(
            storybook(pages=[{"text": "One.", "image": image_b64("PNG", (64, 64))[:-40]}]),
            id="image-truncated",
        ),
    ]


@pytest.mark.parametrize("bad", bad_storybooks())
def test_a_bad_storybook_is_rejected_and_the_story_left_pending(tmp_path, bad):
    story_id = make_synced_story(tmp_path)

    accepted = store_uploaded_storybook(story_id, bad, [], stories_dir=tmp_path)

    assert accepted is False
    assert_left_pending(story_id, tmp_path)


def test_an_unsafe_title_is_rejected(tmp_path):
    story_id = make_synced_story(tmp_path)
    assert store_uploaded_storybook(story_id, storybook(title="The Knife Fight"), [], stories_dir=tmp_path) is False
    assert_left_pending(story_id, tmp_path)


def test_an_unsafe_page_is_rejected(tmp_path):
    story_id = make_synced_story(tmp_path)
    book = storybook(pages=[{"text": "The knight had to kill the dragon."}])
    assert store_uploaded_storybook(story_id, book, [], stories_dir=tmp_path) is False
    assert_left_pending(story_id, tmp_path)


def test_an_unsafe_shared_fact_is_rejected_via_the_derived_epilogue(tmp_path):
    # The uploaded text is spotless, but the epilogue is built from the
    # real shared fact, so an unsafe fact must still be caught.
    story_id = make_synced_story(tmp_path)
    assert store_uploaded_storybook(
        story_id, storybook(), [("shark", "sharks can kill")], stories_dir=tmp_path
    ) is False
    assert_left_pending(story_id, tmp_path)


def test_an_unknown_story_id_is_rejected_not_raised(tmp_path):
    assert store_uploaded_storybook("ghost123", storybook(), [], stories_dir=tmp_path) is False


# ---------- logging ----------


def test_an_accepted_upload_logs_exactly_one_accepted_line(tmp_path, caplog):
    story_id = make_synced_story(tmp_path)
    with caplog.at_level(logging.INFO, logger="tinytalk.synced_storybook"):
        store_uploaded_storybook(
            story_id, storybook(pages=[{"text": "One.", "image": image_b64()}]), [], stories_dir=tmp_path
        )
    lines = [r.getMessage() for r in caplog.records if r.name == "tinytalk.synced_storybook"]
    assert lines == [f"synced storybook accepted for story {story_id}: 1 page(s), 1 image(s)"]


def test_a_rejected_upload_logs_exactly_one_rejected_line_with_the_reason(tmp_path, caplog):
    story_id = make_synced_story(tmp_path)
    with caplog.at_level(logging.INFO, logger="tinytalk.synced_storybook"):
        store_uploaded_storybook(story_id, storybook(title=""), [], stories_dir=tmp_path)
    lines = [r.getMessage() for r in caplog.records if r.name == "tinytalk.synced_storybook"]
    assert len(lines) == 1
    assert lines[0].startswith(f"synced storybook rejected for story {story_id}:")
    assert "title" in lines[0]

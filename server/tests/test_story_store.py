import json

from tinytalk.conversation import Conversation
from tinytalk.story_store import save_story


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

from tinytalk.animal_facts import find_new_animal


def test_find_new_animal_matches_a_known_animal():
    assert find_new_animal("tell me a story about a fox", set()) == "fox"


def test_find_new_animal_matches_plural_form():
    assert find_new_animal("there were two foxes in the den", set()) == "fox"


def test_find_new_animal_matches_an_alias():
    assert find_new_animal("I saw a ladybird on the leaf", set()) == "ladybug"


def test_find_new_animal_is_case_insensitive():
    assert find_new_animal("A FOX ran past", set()) == "fox"


def test_find_new_animal_returns_none_when_no_known_animal_mentioned():
    assert find_new_animal("the sun was warm and bright", set()) is None


def test_find_new_animal_skips_already_facted_animals():
    assert find_new_animal("the fox and the rabbit ran", {"fox"}) == "rabbit"


def test_find_new_animal_returns_none_if_only_mentioned_animal_already_facted():
    assert find_new_animal("the fox ran fast", {"fox"}) is None


def test_find_new_animal_does_not_match_substrings():
    # "foxglove" contains "fox" but is a plant, not an animal mention.
    assert find_new_animal("the foxglove flowers bloomed", set()) is None


import json

from tinytalk.animal_facts import _load_cache, _save_cache


def test_load_cache_returns_empty_dict_when_file_does_not_exist(tmp_path):
    assert _load_cache(tmp_path / "does_not_exist.json") == {}


def test_save_then_load_round_trips(tmp_path):
    path = tmp_path / "animal_facts.json"
    _save_cache({"fox": ["foxes are great listeners"]}, path)
    assert _load_cache(path) == {"fox": ["foxes are great listeners"]}


def test_save_cache_creates_parent_directory(tmp_path):
    path = tmp_path / "nested" / "animal_facts.json"
    _save_cache({"fox": []}, path)
    assert path.exists()


def test_load_cache_treats_corrupt_json_as_empty(tmp_path):
    path = tmp_path / "animal_facts.json"
    path.write_text("{not valid json")
    assert _load_cache(path) == {}


def test_load_cache_treats_non_object_json_as_empty(tmp_path):
    path = tmp_path / "animal_facts.json"
    path.write_text("[1, 2, 3]")
    assert _load_cache(path) == {}

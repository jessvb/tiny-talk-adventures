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


from tinytalk.animal_facts import _extract_facts


def test_extract_facts_pulls_from_curated_fields():
    record = {
        "characteristics": {
            "most_distinctive_feature": "large pointed ears",
            "diet": "Omnivore",
            "top_speed": "30 mph",
        }
    }
    facts = _extract_facts(record)
    assert "its most distinctive feature is large pointed ears" in facts
    assert "its diet is Omnivore" in facts
    assert "it can move as fast as 30 mph" in facts


def test_extract_facts_skips_missing_and_empty_fields():
    record = {"characteristics": {"most_distinctive_feature": "", "diet": "Omnivore"}}
    facts = _extract_facts(record)
    assert facts == ["its diet is Omnivore"]


def test_extract_facts_ignores_fields_outside_the_curated_allowlist():
    # gestation_period/age_of_sexual_maturity/biggest_threat etc. are
    # deliberately not in _FACT_FIELD_TEMPLATES -- their raw values (e.g.
    # "63 days", "Humans") wouldn't be caught by the word-list safety
    # filter, so exclusion at extraction time is the real protection.
    record = {
        "characteristics": {
            "gestation_period": "63 days",
            "diet": "Omnivore",
        }
    }
    facts = _extract_facts(record)
    assert facts == ["its diet is Omnivore"]


def test_extract_facts_drops_unsafe_candidates():
    record = {"characteristics": {"slogan": "Known for its violent mating rituals"}}
    assert _extract_facts(record) == []


def test_extract_facts_returns_empty_list_when_no_characteristics():
    assert _extract_facts({"name": "Fox"}) == []


import httpx
import pytest

from tinytalk import config
from tinytalk.animal_facts import _fetch_facts_from_api


async def test_fetch_facts_from_api_returns_extracted_facts(monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.params["name"] == "fox"
        assert request.headers["X-Api-Key"] == "test-key"
        return httpx.Response(
            200,
            json=[{"characteristics": {"diet": "Omnivore"}}],
        )

    facts = await _fetch_facts_from_api("fox", transport=httpx.MockTransport(handler))
    assert facts == ["its diet is Omnivore"]


async def test_fetch_facts_from_api_returns_empty_list_for_no_matches(monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=[])

    facts = await _fetch_facts_from_api("nonexistent", transport=httpx.MockTransport(handler))
    assert facts == []


async def test_fetch_facts_from_api_returns_none_on_non_200(monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(429, text="rate limited")

    facts = await _fetch_facts_from_api("fox", transport=httpx.MockTransport(handler))
    assert facts is None


async def test_fetch_facts_from_api_returns_none_on_network_error(monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")

    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("connection refused", request=request)

    facts = await _fetch_facts_from_api("fox", transport=httpx.MockTransport(handler))
    assert facts is None


async def test_fetch_facts_from_api_returns_none_without_an_api_key(monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "")
    facts = await _fetch_facts_from_api("fox")
    assert facts is None


from tinytalk.animal_facts import get_fact


async def test_get_fact_returns_cached_fact_without_calling_the_api(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")
    cache_path = tmp_path / "animal_facts.json"
    _save_cache({"fox": ["foxes have excellent hearing"]}, cache_path)

    def handler(request: httpx.Request) -> httpx.Response:
        raise AssertionError("API must not be called on a cache hit")

    fact = await get_fact(
        "fox", cache_path=cache_path, transport=httpx.MockTransport(handler)
    )
    assert fact == "foxes have excellent hearing"


async def test_get_fact_fetches_and_caches_on_a_miss(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")
    cache_path = tmp_path / "animal_facts.json"

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=[{"characteristics": {"diet": "Omnivore"}}])

    fact = await get_fact(
        "fox", cache_path=cache_path, transport=httpx.MockTransport(handler)
    )
    assert fact == "its diet is Omnivore"
    assert _load_cache(cache_path) == {"fox": ["its diet is Omnivore"]}


async def test_get_fact_returns_none_and_caches_empty_when_api_has_no_data(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")
    cache_path = tmp_path / "animal_facts.json"

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=[])

    fact = await get_fact(
        "fox", cache_path=cache_path, transport=httpx.MockTransport(handler)
    )
    assert fact is None
    assert _load_cache(cache_path) == {"fox": []}


async def test_get_fact_does_not_cache_on_api_failure(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")
    cache_path = tmp_path / "animal_facts.json"

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500, text="server error")

    fact = await get_fact(
        "fox", cache_path=cache_path, transport=httpx.MockTransport(handler)
    )
    assert fact is None
    assert _load_cache(cache_path) == {}


async def test_get_fact_picks_randomly_among_multiple_cached_facts(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")
    cache_path = tmp_path / "animal_facts.json"
    _save_cache({"fox": ["fact one", "fact two", "fact three"]}, cache_path)

    seen = set()
    for _ in range(20):
        fact = await get_fact("fox", cache_path=cache_path, transport=None)
        seen.add(fact)
    assert seen == {"fact one", "fact two", "fact three"}

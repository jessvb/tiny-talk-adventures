from tinytalk.animal_facts import _KNOWN_ANIMALS, find_new_animal


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


def test_find_new_animal_matches_a_newly_added_species():
    assert find_new_animal("we saw an aardvark digging", set()) == "aardvark"


def test_find_new_animal_folds_a_life_stage_name_into_its_parent_species():
    # "calf" is a baby cow, not a different species -- same alias-table
    # pattern as the existing ladybird/ladybug and puppy/dog entries.
    assert find_new_animal("the calf followed its mother", set()) == "cow"


def test_find_new_animal_generic_category_words_are_not_known_animals():
    # Deliberately excluded: the facts API needs an actual species name,
    # not an umbrella category -- the specific animals from that category
    # (fox, cobra, goldfish, ...) are known individually instead.
    for word in ("bird", "fish", "bug", "snake", "lizard", "worm"):
        assert find_new_animal(f"a {word} went by", set()) is None


def test_find_new_animal_prefers_a_more_specific_multi_word_match():
    # "sea turtle" contains the word "turtle", which the plain turtle
    # entry's own pattern also matches -- without specificity-ordered
    # detection, this would incorrectly resolve to "turtle" instead of
    # the more specific "sea turtle" entry.
    assert find_new_animal("a sea turtle swam by", set()) == "sea turtle"
    assert find_new_animal("a plain turtle crawled by", set()) == "turtle"


def test_find_new_animal_prefers_a_multi_word_alias_over_a_generic_entry():
    # Same precedence concern as above, but via an ALIAS rather than the
    # canonical name itself: "mountain lion" is an alias of "cougar", and
    # contains the word "lion", which the separate, existing lion entry's
    # pattern also matches.
    assert find_new_animal("a mountain lion prowled the ridge", set()) == "cougar"
    assert find_new_animal("a lion roared", set()) == "lion"


def test_known_animals_have_no_duplicate_aliases():
    # A regression guard on the whole table, not just a few examples --
    # the same alias string accidentally assigned to two canonical
    # entries would make one of them permanently unreachable (whichever
    # loses the specificity/definition-order tiebreak).
    seen: dict[str, str] = {}
    for canonical, aliases in _KNOWN_ANIMALS.items():
        for alias in aliases:
            assert alias not in seen, (
                f"{alias!r} is used by both {seen.get(alias)!r} and {canonical!r}"
            )
            seen[alias] = canonical


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


async def test_fetch_facts_from_api_returns_none_for_a_non_object_record(monkeypatch):
    # A 200 response whose first list element isn't a dict -- an
    # unexpected shape from the API, not a network/HTTP failure, but
    # still a failure that must be reported as None (and therefore never
    # cached), not raised out to the caller.
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, json=["not-a-dict-record"])

    facts = await _fetch_facts_from_api("fox", transport=httpx.MockTransport(handler))
    assert facts is None


import random

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
    random.seed(0)  # otherwise ~0.09% of runs draw the same fact all 20 times by chance
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")
    cache_path = tmp_path / "animal_facts.json"
    _save_cache({"fox": ["fact one", "fact two", "fact three"]}, cache_path)

    seen = set()
    for _ in range(20):
        fact = await get_fact("fox", cache_path=cache_path, transport=None)
        seen.add(fact)
    assert seen == {"fact one", "fact two", "fact three"}


from tinytalk.animal_facts import AnimalFactTracker
from tinytalk.story_arc import Stage


async def test_tracker_returns_weave_in_guidance_for_a_known_animal(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")
    _save_cache({"fox": ["foxes have excellent hearing"]}, tmp_path / "cache.json")

    tracker = AnimalFactTracker()
    guidance = await tracker.record_turn("tell me about a fox", Stage.SETUP)

    assert "fox" in guidance
    assert "foxes have excellent hearing" in guidance


async def test_tracker_does_not_refact_the_same_animal_twice(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "test-key")
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")
    _save_cache({"fox": ["foxes have excellent hearing"]}, tmp_path / "cache.json")

    tracker = AnimalFactTracker()
    await tracker.record_turn("tell me about a fox", Stage.SETUP)
    guidance = await tracker.record_turn("the fox ran through the forest", Stage.RISING_ACTION)

    assert guidance == ""


async def test_tracker_does_not_retry_a_failed_fetch_within_the_same_story(monkeypatch):
    # A failed fetch (offline, timeout, API cap) must not be retried every
    # turn the same animal is mentioned again -- that would re-stall the
    # turn on a slow network call indefinitely. Mock get_fact itself (the
    # tracker calls it directly) so a fetch that always "fails" (returns
    # None) is spied on for call count.
    calls: list[str] = []

    async def failing_get_fact(canonical: str) -> str | None:
        calls.append(canonical)
        return None

    monkeypatch.setattr("tinytalk.animal_facts.get_fact", failing_get_fact)

    tracker = AnimalFactTracker()
    await tracker.record_turn("tell me about a fox", Stage.SETUP)
    guidance = await tracker.record_turn("the fox ran through the forest", Stage.RISING_ACTION)

    assert calls == ["fox"], "a failed fetch must only be attempted once per story"
    assert guidance == ""


async def test_tracker_nudges_for_an_animal_during_setup_with_none_mentioned(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "")
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")

    tracker = AnimalFactTracker()
    guidance = await tracker.record_turn("let's make up a story", Stage.SETUP)

    assert "animal" in guidance.lower()


async def test_tracker_does_not_nudge_once_an_animal_has_been_mentioned(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "")
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")

    tracker = AnimalFactTracker()
    await tracker.record_turn("tell me about a fox", Stage.SETUP)
    guidance = await tracker.record_turn("what happens next", Stage.SETUP)

    assert guidance == ""


async def test_tracker_does_not_nudge_outside_setup(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "")
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")

    tracker = AnimalFactTracker()
    guidance = await tracker.record_turn("let's keep going", Stage.RISING_ACTION)

    assert guidance == ""


async def test_tracker_returns_empty_string_when_no_fact_is_available(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "ANIMAL_FACTS_API_KEY", "")
    monkeypatch.setattr("tinytalk.animal_facts.FACTS_CACHE_PATH", tmp_path / "cache.json")

    tracker = AnimalFactTracker()
    guidance = await tracker.record_turn("tell me about a fox", Stage.SETUP)

    # No API key configured -- get_fact returns None, so no weave-in
    # guidance, but the animal was still detected/mentioned, so the nudge
    # must not fire either.
    assert guidance == ""
